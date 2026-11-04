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
  int? _incoming; // queue index coming in through the running transition
  bool _transitioning = false;
  String? _idlePath;
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

  void reset() {
    queue = [];
    index = -1;
    active = 0;
    _pendingPlay = false;
    _pendingPass = null;
    _incoming = null;
    _transitioning = false;
    _idlePath = null;
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

  void playNow(Track t) {
    if (app.mode != Mode.player || current == null) {
      playList([t], name: null);
      return;
    }
    queue.insert(index + 1, t);
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
    queue.insert(index + 1, t);
    _preloadNext();
    notifyListeners();
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    final wasNext = i == nextIndex;
    queue.removeAt(i);
    if (i < index) index--;
    if (wasNext) _preloadNext();
    notifyListeners();
  }

  void jumpTo(int i) {
    if (i < 0 || i >= queue.length || i == index) return;
    final t = queue.removeAt(i);
    if (i < index) index--;
    queue.insert(index + 1, t);
    _preloadNext();
    passNow();
  }

  void setShuffle(bool on) {
    app.settings.shuffle = on;
    app.saveSettings();
    if (on && index + 1 < queue.length) {
      final rest = queue.sublist(index + 1)..shuffle(Random());
      queue = [...queue.sublist(0, index + 1), ...rest];
      _preloadNext();
    }
    notifyListeners();
  }

  void setRepeat(bool on) {
    app.settings.repeat = on;
    app.saveSettings();
    if (_idlePath == null) _preloadNext();
    notifyListeners();
  }

  void setFx(TransitionFx f) {
    fx = f;
    notifyListeners();
  }

  void _load(int deck, Track t, double start) {
    CsAudio.load(deck, t.path, start);
    CsAudio.setGainDb(deck, app.gainFor(t));
    app.library.prioritize(t);
  }

  void _preloadNext() {
    final n = next;
    oneTimeEntry = null;
    if (n == null) {
      if (_idlePath != null) CsAudio.unload(idle);
      _idlePath = null;
      return;
    }
    _idlePath = n.path;
    _load(idle, n, app.entryFor(n));
  }

  double get nextEntry {
    final n = next;
    if (n == null) return 0;
    return oneTimeEntry ?? app.entryFor(n);
  }

  /// Moves the entry point of the next track; [save] stores it in the track.
  void setNextEntry(double sec, {required bool save}) {
    final n = next;
    if (n == null) return;
    if (save) {
      n.entry = sec;
      oneTimeEntry = null;
      app.library.changed();
    } else {
      oneTimeEntry = sec;
    }
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
    _load(idle, prev, 0);
    _idlePath = prev.path;
    _incoming = index - 1;
    _pendingPass = TransitionFx.cut;
    notifyListeners();
  }

  /// Manual transition to the next track with the selected effect.
  void passNow([TransitionFx? f]) {
    if (_transitioning || next == null) return;
    final use = f ?? fx;
    _incoming = nextIndex;
    if (!nextDeck.ready) {
      _pendingPass = use;
      notifyListeners();
      return;
    }
    _start(currentDeck.playing ? use : TransitionFx.cut, app.settings.fxDur[use] ?? 4);
  }

  void _start(TransitionFx f, double seconds) {
    _transitioning = true;
    CsAudio.transition(idle, f, seconds);
    notifyListeners();
  }

  void tick() {
    if (current == null) return;
    final e = app.engine;
    final cur = e.decks[active];
    final nx = e.decks[idle];

    if (_pendingPlay && (cur.ready || cur.error)) {
      _pendingPlay = false;
      if (cur.ready) CsAudio.play(active, true);
      notifyListeners();
    }

    if (_transitioning && !e.transitioning) {
      _transitioning = false;
      active = idle;
      index = _incoming ?? (nextIndex ?? index);
      _incoming = null;
      _preloadNext();
      notifyListeners();
      return;
    }

    if (_pendingPass != null && !_transitioning && (nx.ready || nx.error)) {
      final f = _pendingPass!;
      _pendingPass = null;
      if (nx.ready) {
        _start(cur.playing ? f : TransitionFx.cut, app.settings.fxDur[f] ?? 4);
      } else {
        _incoming = null;
      }
      return;
    }

    if (_transitioning) return;
    final hasNext = next != null && nx.ready;
    if (app.settings.autoCrossfade &&
        hasNext &&
        cur.playing &&
        cur.duration > 0 &&
        cur.remaining <= app.settings.autoSec) {
      _incoming = nextIndex;
      _start(TransitionFx.fade, max(0.2, cur.remaining));
      return;
    }
    if (cur.ended && !cur.playing) {
      if (hasNext) {
        _incoming = nextIndex;
        _start(TransitionFx.cut, 0);
      } else if (next == null) {
        // End of the queue: rewind and wait.
        CsAudio.seek(active, 0);
        notifyListeners();
      }
    }
    // Error on the incoming deck: skip that track.
    if (nx.error && next != null && _idlePath == next!.path) {
      final bad = nextIndex!;
      queue.removeAt(bad);
      if (bad < index) index--;
      _preloadNext();
      notifyListeners();
    }
  }
}
