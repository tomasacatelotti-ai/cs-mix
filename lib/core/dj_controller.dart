import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'models.dart';

/// "DJ en vivo" mode: two decks under manual control.
class DjController extends ChangeNotifier {
  DjController(this.app) : fx = app.settings.defaultFx;

  final AppState app;
  final List<Track?> decks = [null, null];
  final List<double> pitch = [0, 0];
  final List<bool> pfl = [false, true];
  TransitionFx fx;
  static const pitchRange = 0.08;

  void reset() {
    decks[0] = null;
    decks[1] = null;
    pitch[0] = pitch[1] = 0;
    notifyListeners();
  }

  void enter() {
    if (app.mode == Mode.dj) return;
    app.setMode(Mode.dj);
    for (var d = 0; d < 2; d++) {
      CsAudio.setPfl(d, pfl[d]);
    }
  }

  void load(int deck, Track t) {
    enter();
    decks[deck] = t;
    CsAudio.load(deck, t.path, t.cue ?? 0);
    CsAudio.setGainDb(deck, app.gainFor(t));
    CsAudio.setPitch(deck, pitch[deck]);
    app.library.prioritize(t);
    notifyListeners();
  }

  DeckSnapshot snap(int deck) => app.engine.decks[deck];

  /// Back to 0:00, keeping play/pause as it was.
  void restart(int deck) {
    if (decks[deck] == null) return;
    CsAudio.seek(deck, 0);
  }

  void togglePlay(int deck) {
    if (decks[deck] == null) return;
    CsAudio.play(deck, !snap(deck).playing);
  }

  /// Playing: back to the cue point and stop. Stopped: set the cue point here.
  void cue(int deck) {
    final t = decks[deck];
    if (t == null) return;
    final s = snap(deck);
    if (s.playing) {
      CsAudio.play(deck, false);
      CsAudio.seek(deck, t.cue ?? 0);
    } else {
      t.cue = s.position;
      app.library.changed();
      notifyListeners();
    }
  }

  void hotcue(int deck, int i) {
    final t = decks[deck];
    if (t == null) return;
    final h = t.hotcues[i];
    if (h == null) {
      t.hotcues[i] = snap(deck).position;
      app.library.changed();
      notifyListeners();
    } else {
      CsAudio.seek(deck, h);
    }
  }

  void clearHotcue(int deck, int i) {
    final t = decks[deck];
    if (t == null) return;
    t.hotcues[i] = null;
    app.library.changed();
    notifyListeners();
  }

  void setPitch(int deck, double v) {
    pitch[deck] = v.clamp(-pitchRange, pitchRange);
    CsAudio.setPitch(deck, pitch[deck]);
    notifyListeners();
  }

  double liveBpm(int deck) {
    final t = decks[deck];
    if (t == null || t.bpm <= 0) return 0;
    return t.bpm * (1 + pitch[deck]);
  }

  /// Matches this deck's tempo to the other one (also across double/half time).
  String? sync(int deck) {
    final me = decks[deck], other = decks[1 - deck];
    if (me == null || other == null || me.bpm <= 0 || other.bpm <= 0) return 'Falta el BPM de algún tema.';
    final target = liveBpm(1 - deck);
    for (final f in [1.0, 2.0, 0.5]) {
      final p = target * f / me.bpm - 1;
      if (p.abs() <= pitchRange) {
        setPitch(deck, p);
        return null;
      }
    }
    return 'Los tempos están muy lejos para igualarlos con ±8 %.';
  }

  void togglePfl(int deck) {
    pfl[deck] = !pfl[deck];
    CsAudio.setPfl(deck, pfl[deck]);
    notifyListeners();
  }

  void setCrossfader(double x) => CsAudio.setCrossfader(x);

  void setFx(TransitionFx f) {
    fx = f;
    notifyListeners();
  }

  /// Automated transition into [deck] with the selected effect.
  void passTo(int deck) {
    if (decks[deck] == null || !snap(deck).ready) return;
    CsAudio.transition(deck, fx, app.settings.fxDur[fx] ?? 4);
  }

  void tick() {}
}
