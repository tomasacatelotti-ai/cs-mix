import 'dart:math';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'models.dart';

/// "Reproductor" mode: a queue that alternates between the two decks,
/// with automatic crossfade at the end and manual transitions at any moment.
class PlayerController extends ChangeNotifier {
  PlayerController(this.app) : fx = app.settings.defaultFx;

  final AppState app;
  List<Track> queue = [];
  int index = -1;
  int active = 0;
  TransitionFx fx;
  String? source;

  bool _pendingPlay = false;
  TransitionFx? _pendingPass;
  Track? _incoming; // track coming in through the running (or pending) transition
  bool _transitioning = false;
  Track? _idleTrack; // what was requested on the idle deck
  double? oneTimeEntry;

  int get idle => 1 - active;
  Track? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get transitioning => _transitioning;

  int? get nextIndex {
    if (queue.isEmpty) return null;
    if (index + 1 < queue.length) return index + 1;
    if (app.settings.repeat) return 0;
    return null;
  }

  Track? get next {
    final i = nextIndex;
    return i == null ? null : queue[i];
  }

  bool get playing => _pendingPlay || app.engine.decks[active].playing;
  DeckSnapshot get currentDeck => app.engine.decks[active];
  DeckSnapshot get nextDeck => app.engine.decks[idle];
  bool get nextLoading => app.deckBusy(idle);

  /// Live check (not the last poll): the deck holds [t] and finished loading it.
  bool _ready(int deck, Track? t) => t != null && app.deckHolds(deck, t) && CsAudio.info(deck).ready;

  void reset() {
    queue = [];
    index = -1;
    active = 0;
    _pendingPlay = false;
    _pendingPass = null;
    _incoming = null;
    _transitioning = false;
    _idleTrack = null;
    oneTimeEntry = null;
    source = null;
    notifyListeners();
  }

  void playList(List<Track> tracks, {int start = 0, String? name}) {
    if (tracks.isEmpty) return;
    app.setMode(Mode.player);
    final list = List.of(tracks);
    var first = start.clamp(0, list.length - 1);
    if (app.settings.shuffle) {
      final t = list.removeAt(first);
      list.shuffle(Random());
      list.insert(0, t);
      first = 0;
    }
    CsAudio.cancelTransition();
    CsAudio.play(0, false);
    CsAudio.play(1, false);
    _transitioning = false;
    _pendingPass = null;
    _incoming = null;
    queue = list;
    index = first;
    active = 0;
    source = name;
    CsAudio.setCrossfader(0);
    _load(active, queue[index], 0);
    _pendingPlay = true;
    _preloadNext();
    notifyListeners();
  }

  /// Where a new "next" goes: after the current track, or after the one fading in.
  int get _insertAt {
    if (_transitioning && _incoming != null) {
      final i = queue.indexOf(_incoming!);
      if (i >= 0) return i + 1;
    }
    return index + 1;
  }

  void playNow(Track t) {
    if (app.mode != Mode.player || current == null) {
      playList([t]);
      return;
    }
    queue.insert(_insertAt, t);
    if (_transitioning) {
      // It plays right after the transition that is already running.
      notifyListeners();
      return;
    }
    _preloadNext();
    passNow();
  }

  void enqueue(Track t) {
    if (app.mode != Mode.player || current == null) {
      playList([t]);
      return;
    }
    queue.add(t);
    if (next == t) _preloadNext();
    notifyListeners();
  }

  void playAfterCurrent(Track t) {
    if (app.mode != Mode.player || current == null) {
      playList([t]);
      return;
    }
    queue.insert(_insertAt, t);
    _preloadNext();
    notifyListeners();
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    if (_transitioning && identical(queue[i], _incoming)) return;
    final wasNext = i == nextIndex;
    queue.removeAt(i);
    if (i < index) index--;
    if (wasNext) _preloadNext();
    notifyListeners();
  }

  void jumpTo(int i) {
    if (i < 0 || i >= queue.length || i == index || _transitioning) return;
    final t = queue.removeAt(i);
    if (i < index) index--;
    queue.insert(index + 1, t);
    _preloadNext();
    passNow();
  }

  void setShuffle(bool on) {
    app.settings.shuffle = on;
    app.saveSettings();
    final from = _insertAt;
    if (on && from < queue.length) {
      final rest = queue.sublist(from)..shuffle(Random());
      queue = [...queue.sublist(0, from), ...rest];
      _preloadNext();
    }
    notifyListeners();
  }

  void setRepeat(bool on) {
    app.settings.repeat = on;
    app.saveSettings();
    if (_idleTrack == null) _preloadNext();
    notifyListeners();
  }

  void setFx(TransitionFx f) {
    fx = f;
    notifyListeners();
  }

  void _load(int deck, Track t, double start) {
    app.loadDeck(deck, t, start);
  }

  void _preloadNext() {
    // Never touch the idle deck while it is fading in: tick() preloads afterwards.
    if (_transitioning) return;
    final n = next;
    oneTimeEntry = null;
    if (n == null) {
      if (_idleTrack != null) {
        CsAudio.unload(idle);
        app.forgetDeck(idle);
      }
      _idleTrack = null;
      return;
    }
    if (identical(_idleTrack, n) && app.deckHolds(idle, n) && !app.deckError(idle)) return;
    _idleTrack = n;
    _load(idle, n, app.entryFor(n));
  }

  double get nextEntry {
    final n = next;
    if (n == null) return 0;
    return oneTimeEntry ?? app.entryFor(n);
  }

  /// Moves the entry point of [t] if it is still the next track; [save] stores it in the track.
  void setNextEntry(Track t, double sec, {required bool save}) {
    if (save) {
      t.entry = sec;
      app.library.changed();
    }
    if (!identical(next, t)) {
      notifyListeners();
      return;
    }
    oneTimeEntry = save ? null : sec;
    CsAudio.seek(idle, sec);
    notifyListeners();
  }

  void togglePlay() {
    if (current == null || _transitioning) return;
    final d = app.engine.decks[active];
    if (_pendingPlay) {
      _pendingPlay = false;
    } else {
      CsAudio.play(active, !d.playing);
    }
    notifyListeners();
  }

  void restart() => seek(0);

  void seek(double sec) {
    if (current == null) return;
    CsAudio.seek(active, sec);
  }

  void previous() {
    if (current == null || _transitioning) return;
    if (currentDeck.position > 4 || index == 0) {
      CsAudio.seek(active, 0);
      return;
    }
    // The idle deck takes the previous track and we cut to it.
    final prev = queue[index - 1];
    _idleTrack = prev;
    _load(idle, prev, 0);
    _incoming = prev;
    _pendingPass = TransitionFx.cut;
    notifyListeners();
  }

  /// Manual transition to the next track with the selected effect.
  void passNow([TransitionFx? f]) {
    if (_transitioning || next == null) return;
    final cur = current;
    if (cur != null) app.noteSkip(cur, currentDeck.position);
    final use = f ?? fx;
    _incoming = next;
    if (!_ready(idle, _incoming)) {
      _pendingPass = use;
      notifyListeners();
      return;
    }
    _start(currentDeck.playing ? use : TransitionFx.cut, app.settings.fxDur[use] ?? 4);
  }

  void _start(TransitionFx f, double seconds) {
    _pendingPass = null;
    _transitioning = true;
    CsAudio.transition(idle, f, seconds);
    notifyListeners();
  }

  void tick() {
    if (current == null) return;
    final e = app.engine;
    final cur = e.decks[active];

    if (_pendingPlay && (cur.ready || app.deckError(active))) {
      _pendingPlay = false;
      if (cur.ready) CsAudio.play(active, true);
      notifyListeners();
    }

    if (_transitioning && !e.transitioning && !CsAudio.transitionActive) {
      _transitioning = false;
      active = idle;
      final inc = _incoming;
      final i = inc == null ? -1 : queue.indexOf(inc);
      index = i >= 0 ? i : (nextIndex ?? index);
      _incoming = null;
      _idleTrack = null;
        _preloadNext();
      notifyListeners();
      return;
    }
    if (_transitioning) return;

    final inc = _incoming;
    if (_pendingPass != null && inc != null) {
      if (_ready(idle, inc)) {
        final f = _pendingPass!;
        _start(cur.playing ? f : TransitionFx.cut, app.settings.fxDur[f] ?? 4);
        return;
      }
      if (app.deckError(idle)) {
        // The track that should come in can't be read: drop it and get the real next one ready.
        _pendingPass = null;
        _incoming = null;
        _idleTrack = null;
        _preloadNext();
        notifyListeners();
        return;
      }
    }

    final n = next;
    final hasNext = n != null && _ready(idle, n);
    if (app.settings.autoCrossfade && hasNext && cur.playing && cur.duration > 0 && cur.remaining <= app.settings.autoSec) {
      _incoming = n;
      _start(TransitionFx.fade, max(0.2, cur.remaining));
      return;
    }
    if (cur.ended && !cur.playing && _pendingPass == null) {
      if (hasNext) {
        _incoming = n;
        _start(TransitionFx.cut, 0);
      } else if (n == null) {
        // End of the queue: rewind and wait.
        CsAudio.seek(active, 0);
        notifyListeners();
      }
    }
    // Error on the incoming deck: skip that track.
    if (n != null && identical(_idleTrack, n) && app.deckError(idle)) {
      final bad = nextIndex!;
      queue.removeAt(bad);
      if (bad < index) index--;
      _idleTrack = null;
      _preloadNext();
      notifyListeners();
    }
  }
}
