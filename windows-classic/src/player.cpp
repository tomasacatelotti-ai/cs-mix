// Queue player on the two engine decks: same rules as lib/core/player_controller.dart.
#include "app.h"
#include <algorithm>
#include <random>

#include "../../packages/cs_audio/src/cs_audio.h"

Player gPlayer;

static std::mt19937& Rng() {
  static std::mt19937 r((unsigned)GetTickCount());
  return r;
}

int Player::NextIndex() const {
  if (queue.empty()) return -1;
  if (index + 1 < (int)queue.size()) return index + 1;
  if (s.repeat) return 0;
  return -1;
}

TrackP Player::Next() const {
  int i = NextIndex();
  return i < 0 ? nullptr : queue[i];
}

bool Player::Playing() const { return pendingPlay_ || decks_[active].playing; }
bool Player::NextLoading() const { return decks_[Idle()].loading(); }

double Player::EntryFor(const Track& t) const {
  std::lock_guard<std::mutex> lk(gLib.m);
  switch (s.entryMode) {
    case 0: return t.entry >= 0 ? t.entry : (t.analyzed ? t.intro : 0);
    case 1: return t.analyzed ? t.intro : 0;
    default: return 0;
  }
}

void Player::Poll() {
  for (int d = 0; d < 2; ++d) {
    CsaDeckInfo i;
    csa_deck_info(d, &i);
    decks_[d].state = i.state;
    decks_[d].playing = i.playing != 0;
    decks_[d].ended = i.ended != 0;
    decks_[d].position = i.position;
    decks_[d].duration = i.duration;
  }
}

bool Player::Ready(int deck, const TrackP& t) const {
  if (!t || want_[deck] != t) return false;
  CsaDeckInfo i;
  csa_deck_info(deck, &i);
  return i.state == CSA_DECK_READY;
}

void Player::Load(int deck, const TrackP& t, double start) {
  want_[deck] = t;
  counted_[deck] = nullptr;
  float gain = 0;
  {
    std::lock_guard<std::mutex> lk(gLib.m);
    if (s.autoGain && t->analyzed) gain = (float)t->gain;
  }
  csa_deck_set_gain_db(deck, gain);
  csa_deck_load(deck, U8(t->path).c_str(), start);
  gLib.Prioritize(t);
}

void Player::Unload(int deck) {
  csa_deck_unload(deck);
  want_[deck] = nullptr;
}

void Player::ReapplyGain() {
  for (int d = 0; d < 2; ++d) {
    float gain = 0;
    if (want_[d]) {
      std::lock_guard<std::mutex> lk(gLib.m);
      if (s.autoGain && want_[d]->analyzed) gain = (float)want_[d]->gain;
    }
    csa_deck_set_gain_db(d, gain);
  }
}

void Player::Clear() {
  csa_transition_cancel();
  for (int d = 0; d < 2; ++d) {
    csa_deck_play(d, 0);
    Unload(d);
    counted_[d] = nullptr;
  }
  csa_set_crossfader(0);
  queue.clear();
  index = -1;
  active = 0;
  pendingPlay_ = false;
  pendingPass_ = -1;
  incoming_ = nullptr;
  transitioning_ = false;
  idleTrack_ = nullptr;
  oneTimeEntry = -1;
  source.clear();
  changed = true;
}

void Player::PlayList(const std::vector<TrackP>& tracks, int start, const std::string& name) {
  if (tracks.empty()) return;
  std::vector<TrackP> list = tracks;
  int first = std::max(0, std::min(start, (int)list.size() - 1));
  if (s.shuffle) {
    TrackP t = list[first];
    list.erase(list.begin() + first);
    std::shuffle(list.begin(), list.end(), Rng());
    list.insert(list.begin(), t);
    first = 0;
  }
  csa_transition_cancel();
  csa_deck_play(0, 0);
  csa_deck_play(1, 0);
  transitioning_ = false;
  pendingPass_ = -1;
  incoming_ = nullptr;
  idleTrack_ = nullptr;
  queue = list;
  index = first;
  active = 0;
  source = name;
  csa_set_crossfader(0);
  Load(active, queue[index], 0);
  pendingPlay_ = true;
  PreloadNext();
  changed = true;
}

int Player::InsertAt() const {
  if (transitioning_ && incoming_) {
    auto it = std::find(queue.begin(), queue.end(), incoming_);
    if (it != queue.end()) return (int)(it - queue.begin()) + 1;
  }
  return index + 1;
}

void Player::PlayNow(const TrackP& t) {
  if (!Current()) {
    PlayList({t}, 0, "");
    return;
  }
  queue.insert(queue.begin() + InsertAt(), t);
  changed = true;
  if (transitioning_) return;  // it plays right after the transition that is already running
  PreloadNext();
  PassNow();
}

void Player::PlayAfterCurrent(const TrackP& t) {
  if (!Current()) {
    PlayList({t}, 0, "");
    return;
  }
  queue.insert(queue.begin() + InsertAt(), t);
  PreloadNext();
  changed = true;
}

void Player::Enqueue(const TrackP& t) {
  if (!Current()) {
    PlayList({t}, 0, "");
    return;
  }
  queue.push_back(t);
  if (Next() == t) PreloadNext();
  changed = true;
}

void Player::RemoveAt(int i) {
  if (i == index || i < 0 || i >= (int)queue.size()) return;
  if (transitioning_ && queue[i] == incoming_) return;
  bool wasNext = i == NextIndex();
  queue.erase(queue.begin() + i);
  if (i < index) index--;
  if (wasNext) PreloadNext();
  changed = true;
}

void Player::JumpTo(int i) {
  if (i < 0 || i >= (int)queue.size() || i == index || transitioning_) return;
  TrackP t = queue[i];
  queue.erase(queue.begin() + i);
  if (i < index) index--;
  queue.insert(queue.begin() + index + 1, t);
  PreloadNext();
  PassNow();
  changed = true;
}

void Player::PreloadNext() {
  // Never touch the idle deck while it is fading in: Tick() preloads afterwards.
  if (transitioning_) return;
  TrackP n = Next();
  oneTimeEntry = -1;
  int idle = Idle();
  if (!n) {
    if (idleTrack_) Unload(idle);
    idleTrack_ = nullptr;
    return;
  }
  if (idleTrack_ == n && want_[idle] == n && !decks_[idle].error()) return;
  idleTrack_ = n;
  Load(idle, n, EntryFor(*n));
}

void Player::TogglePlay() {
  if (!Current() || transitioning_) return;
  if (pendingPlay_) {
    pendingPlay_ = false;
  } else {
    CsaDeckInfo i;
    csa_deck_info(active, &i);
    csa_deck_play(active, i.playing ? 0 : 1);
  }
  changed = true;
}

void Player::Seek(double sec) {
  if (!Current()) return;
  csa_deck_seek(active, sec);
}

void Player::Previous() {
  if (!Current() || transitioning_) return;
  if (decks_[active].position > 4 || index == 0) {
    csa_deck_seek(active, 0);
    return;
  }
  TrackP prev = queue[index - 1];
  idleTrack_ = prev;
  Load(Idle(), prev, 0);
  incoming_ = prev;
  pendingPass_ = FX_CUT;
  changed = true;
}

void Player::PassNow() {
  if (transitioning_ || !Next()) return;
  TrackP cur = Current();
  if (cur && decks_[active].position < 30) gLib.RecordSkip(cur);
  incoming_ = Next();
  if (!Ready(Idle(), incoming_)) {
    pendingPass_ = fx;
    changed = true;
    return;
  }
  StartTransition(decks_[active].playing ? fx : FX_CUT, s.fxDur[fx]);
}

void Player::StartTransition(int f, double sec) {
  pendingPass_ = -1;
  transitioning_ = true;
  csa_transition(Idle(), f, (float)sec);
  changed = true;
}

void Player::Tick() {
  Poll();
  // History: a play counts once a track has sounded for 30 s on a deck.
  for (int d = 0; d < 2; ++d) {
    if (want_[d] && decks_[d].playing && decks_[d].position >= 30 && counted_[d] != want_[d]) {
      counted_[d] = want_[d];
      gLib.RecordPlay(want_[d]);
    }
  }
  if (!Current()) return;
  const DeckView& cur = decks_[active];
  int idle = Idle();

  if (pendingPlay_ && (cur.ready() || cur.error())) {
    pendingPlay_ = false;
    if (cur.ready()) csa_deck_play(active, 1);
    changed = true;
  }

  if (transitioning_ && !csa_transition_active()) {
    transitioning_ = false;
    active = idle;
    auto it = incoming_ ? std::find(queue.begin(), queue.end(), incoming_) : queue.end();
    index = it != queue.end() ? (int)(it - queue.begin()) : (NextIndex() >= 0 ? NextIndex() : index);
    incoming_ = nullptr;
    idleTrack_ = nullptr;
    PreloadNext();
    changed = true;
    return;
  }
  if (transitioning_) return;

  if (pendingPass_ >= 0 && incoming_) {
    if (Ready(idle, incoming_)) {
      int f = pendingPass_;
      StartTransition(cur.playing ? f : FX_CUT, s.fxDur[f]);
      return;
    }
    if (decks_[idle].error()) {
      // The track that should come in can't be read: drop it and get the real next one ready.
      pendingPass_ = -1;
      incoming_ = nullptr;
      idleTrack_ = nullptr;
      PreloadNext();
      changed = true;
      return;
    }
  }

  TrackP n = Next();
  bool hasNext = n && Ready(idle, n);
  if (s.autoCrossfade && hasNext && cur.playing && cur.duration > 0 && cur.remaining() <= s.autoSec) {
    incoming_ = n;
    StartTransition(FX_FADE, std::max(0.2, cur.remaining()));
    return;
  }
  if (cur.ended && !cur.playing && pendingPass_ < 0) {
    if (hasNext) {
      incoming_ = n;
      StartTransition(FX_CUT, 0);
      return;
    }
    if (!n) {
      // End of the queue: rewind and wait.
      csa_deck_seek(active, 0);
      changed = true;
    }
  }
  // Error on the incoming deck: skip that track.
  if (n && idleTrack_ == n && decks_[idle].error() && NextIndex() != index) {
    int bad = NextIndex();
    queue.erase(queue.begin() + bad);
    if (bad < index) index--;
    idleTrack_ = nullptr;
    PreloadNext();
    changed = true;
  }
}
