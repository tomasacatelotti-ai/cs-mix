/// Dart bindings for the CS Mix native audio engine (src/cs_audio.h).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Transition types, same values as CSA_FX_* in cs_audio.h.
enum TransitionFx { fade, reverse, brake, cut }

final class CsaDeckInfo extends Struct {
  @Int32()
  external int state;
  @Int32()
  external int playing;
  @Int32()
  external int ended;
  @Int32()
  external int pfl;
  @Double()
  external double position;
  @Double()
  external double duration;
  @Float()
  external double rate;
  @Float()
  external double level;
}

final class CsaAnalysis extends Struct {
  @Double()
  external double duration;
  @Float()
  external double bpm;
  @Float()
  external double gainDb;
  @Float()
  external double introSec;
  @Float()
  external double loudDb;
  @Int32()
  external int key;
  @Float()
  external double keyConf;
  @Float()
  external double onsetRate;
  @Float()
  external double pulse;
  @Float()
  external double brightness;
}

/// Plain copy of a deck's state.
class DeckSnapshot {
  const DeckSnapshot({
    this.state = 0,
    this.playing = false,
    this.ended = false,
    this.pfl = false,
    this.position = 0,
    this.duration = 0,
    this.rate = 0,
    this.level = 0,
  });

  /// 0 empty, 1 loading, 2 ready, -1 error.
  final int state;
  final bool playing;
  final bool ended;
  final bool pfl;
  final double position;
  final double duration;
  final double rate;
  final double level;

  bool get ready => state == 2;
  bool get loading => state == 1;
  bool get error => state == -1;
  double get remaining => (duration - position).clamp(0, double.infinity);
}

/// Result of [CsAudio.analyze].
class AnalysisResult {
  const AnalysisResult({
    required this.duration,
    required this.bpm,
    required this.gainDb,
    required this.introSec,
    required this.loudDb,
    required this.peaks,
    this.key = -1,
    this.keyConf = 0,
    this.onsetRate = 0,
    this.pulse = 0,
    this.brightness = 0,
  });

  final double duration;
  final double bpm;
  final double gainDb;
  final double introSec;
  final double loudDb;

  /// 30 values per second, 0..1.
  final Float32List peaks;

  /// 0..11 major (C..B), 12..23 minor, -1 unknown.
  final int key;
  final double keyConf;
  final double onsetRate;
  final double pulse;
  final double brightness;
}

typedef _VoidV = Void Function();
typedef _VoidD = void Function();
typedef _IntV = Int32 Function();
typedef _IntD = int Function();

class _Bindings {
  _Bindings(DynamicLibrary lib)
      : init = lib.lookupFunction<_IntV, _IntD>('csa_init'),
        shutdown = lib.lookupFunction<_VoidV, _VoidD>('csa_shutdown'),
        lastError = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
            'csa_last_error'),
        deviceCount = lib.lookupFunction<_IntV, _IntD>('csa_device_count'),
        deviceName = lib.lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Int32),
            int Function(int, Pointer<Utf8>, int)>('csa_device_name'),
        openMaster =
            lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('csa_open_master'),
        openCue = lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('csa_open_cue'),
        closeCue = lib.lookupFunction<_VoidV, _VoidD>('csa_close_cue'),
        cueOpen = lib.lookupFunction<_IntV, _IntD>('csa_cue_open'),
        cueStatus = lib.lookupFunction<_IntV, _IntD>('csa_cue_status'),
        takeRouteEvents = lib.lookupFunction<_IntV, _IntD>('csa_take_route_events'),
        fingerprint = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Int32>),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Int32>)>('csa_fingerprint'),
        deckLoad = lib.lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Double),
            int Function(int, Pointer<Utf8>, double)>('csa_deck_load'),
        deckUnload = lib.lookupFunction<Void Function(Int32), void Function(int)>('csa_deck_unload'),
        deckInfo = lib.lookupFunction<Void Function(Int32, Pointer<CsaDeckInfo>),
            void Function(int, Pointer<CsaDeckInfo>)>('csa_deck_info'),
        deckPlay = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('csa_deck_play'),
        deckSeek = lib.lookupFunction<Void Function(Int32, Double), void Function(int, double)>('csa_deck_seek'),
        deckSetPitch =
            lib.lookupFunction<Void Function(Int32, Float), void Function(int, double)>('csa_deck_set_pitch'),
        deckSetGainDb =
            lib.lookupFunction<Void Function(Int32, Float), void Function(int, double)>('csa_deck_set_gain_db'),
        deckSetPfl = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('csa_deck_set_pfl'),
        setCrossfader = lib.lookupFunction<Void Function(Float), void Function(double)>('csa_set_crossfader'),
        getCrossfader = lib.lookupFunction<Float Function(), double Function()>('csa_get_crossfader'),
        setCurve = lib.lookupFunction<Void Function(Int32), void Function(int)>('csa_set_curve'),
        transition = lib.lookupFunction<Void Function(Int32, Int32, Float), void Function(int, int, double)>(
            'csa_transition'),
        transitionActive = lib.lookupFunction<_IntV, _IntD>('csa_transition_active'),
        transitionCancel = lib.lookupFunction<_VoidV, _VoidD>('csa_transition_cancel'),
        setEq = lib.lookupFunction<Void Function(Int32, Float), void Function(int, double)>('csa_set_eq'),
        setMasterVolume = lib.lookupFunction<Void Function(Float), void Function(double)>('csa_set_master_volume'),
        setCueDelayMs = lib.lookupFunction<Void Function(Float), void Function(double)>('csa_set_cue_delay_ms'),
        setCueMix = lib.lookupFunction<Void Function(Float), void Function(double)>('csa_set_cue_mix'),
        testTone = lib.lookupFunction<Void Function(Int32), void Function(int)>('csa_test_tone'),
        analyze = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<CsaAnalysis>, Pointer<Float>, Int32),
            int Function(Pointer<Utf8>, Pointer<CsaAnalysis>, Pointer<Float>, int)>('csa_analyze');

  final _IntD init;
  final _VoidD shutdown;
  final int Function(Pointer<Utf8>, int) lastError;
  final _IntD deviceCount;
  final int Function(int, Pointer<Utf8>, int) deviceName;
  final int Function(int, int) openMaster;
  final int Function(int, int) openCue;
  final _VoidD closeCue;
  final _IntD cueOpen;
  final _IntD cueStatus;
  final _IntD takeRouteEvents;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Int32>) fingerprint;
  final int Function(int, Pointer<Utf8>, double) deckLoad;
  final void Function(int) deckUnload;
  final void Function(int, Pointer<CsaDeckInfo>) deckInfo;
  final void Function(int, int) deckPlay;
  final void Function(int, double) deckSeek;
  final void Function(int, double) deckSetPitch;
  final void Function(int, double) deckSetGainDb;
  final void Function(int, int) deckSetPfl;
  final void Function(double) setCrossfader;
  final double Function() getCrossfader;
  final void Function(int) setCurve;
  final void Function(int, int, double) transition;
  final _IntD transitionActive;
  final _VoidD transitionCancel;
  final void Function(int, double) setEq;
  final void Function(double) setMasterVolume;
  final void Function(double) setCueDelayMs;
  final void Function(double) setCueMix;
  final void Function(int) testTone;
  final int Function(Pointer<Utf8>, Pointer<CsaAnalysis>, Pointer<Float>, int) analyze;
}

DynamicLibrary _open() {
  if (Platform.isWindows) return DynamicLibrary.open('cs_audio.dll');
  if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.open('cs_audio.framework/cs_audio');
  return DynamicLibrary.open('libcs_audio.so');
}

// One instance per isolate (analysis runs in background isolates).
final _Bindings _b = _Bindings(_open());

/// Thin, synchronous wrapper. All calls are cheap except [analyze].
class CsAudio {
  CsAudio._();

  static final Pointer<CsaDeckInfo> _info = calloc<CsaDeckInfo>();

  static bool init() => _b.init() == 0;
  static void shutdown() => _b.shutdown();

  static String lastError() {
    final buf = calloc<Uint8>(512).cast<Utf8>();
    try {
      _b.lastError(buf, 512);
      return buf.toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  /// Desktop output devices (name, isDefault). Android uses AudioManager ids instead.
  static List<({String name, bool isDefault})> devices() {
    final n = _b.deviceCount();
    final out = <({String name, bool isDefault})>[];
    final buf = calloc<Uint8>(512).cast<Utf8>();
    try {
      for (var i = 0; i < n; i++) {
        final def = _b.deviceName(i, buf, 512);
        out.add((name: buf.toDartString(), isDefault: def == 1));
      }
    } finally {
      calloc.free(buf);
    }
    return out;
  }

  static bool openMaster({int index = -1, int androidId = 0}) => _b.openMaster(index, androidId) == 0;
  static bool openCue({int index = -1, int androidId = 0}) => _b.openCue(index, androidId) == 0;
  static void closeCue() => _b.closeCue();
  static bool get cueOpen => _b.cueOpen() == 1;

  /// 0 closed, 1 ok, 2 muted because the system moved the pre-listen output.
  static int get cueStatus => _b.cueStatus();

  /// Bit 1 master rerouted, bit 2 cue rerouted (clears them).
  static int takeRouteEvents() => _b.takeRouteEvents();

  /// Chromaprint fingerprint (for AcoustID), in a background isolate.
  static Future<({String fingerprint, int duration})?> fingerprintOf(String path) => Isolate.run(() {
        final p = path.toNativeUtf8();
        final out = calloc<Uint8>(32768).cast<Utf8>();
        final dur = calloc<Int32>();
        try {
          final n = _b.fingerprint(p, out, 32768, dur);
          if (n <= 0) return null;
          return (fingerprint: out.toDartString(), duration: dur.value);
        } finally {
          calloc.free(p);
          calloc.free(out);
          calloc.free(dur);
        }
      });

  static void load(int deck, String path, double startSec) {
    final p = path.toNativeUtf8();
    try {
      _b.deckLoad(deck, p, startSec);
    } finally {
      calloc.free(p);
    }
  }

  static void unload(int deck) => _b.deckUnload(deck);

  static DeckSnapshot info(int deck) {
    _b.deckInfo(deck, _info);
    final i = _info.ref;
    return DeckSnapshot(
      state: i.state,
      playing: i.playing == 1,
      ended: i.ended == 1,
      pfl: i.pfl == 1,
      position: i.position,
      duration: i.duration,
      rate: i.rate,
      level: i.level,
    );
  }

  static void play(int deck, bool play) => _b.deckPlay(deck, play ? 1 : 0);
  static void seek(int deck, double sec) => _b.deckSeek(deck, sec);
  static void setPitch(int deck, double delta) => _b.deckSetPitch(deck, delta);
  static void setGainDb(int deck, double db) => _b.deckSetGainDb(deck, db);
  static void setPfl(int deck, bool on) => _b.deckSetPfl(deck, on ? 1 : 0);
  static void setCrossfader(double x) => _b.setCrossfader(x);
  static double get crossfader => _b.getCrossfader();
  static void setCurve(int curve) => _b.setCurve(curve);
  static void transition(int toDeck, TransitionFx fx, double seconds) =>
      _b.transition(toDeck, fx.index, seconds);
  static bool get transitionActive => _b.transitionActive() == 1;
  static void cancelTransition() => _b.transitionCancel();
  static void setEq(int band, double db) => _b.setEq(band, db);
  static void setMasterVolume(double v) => _b.setMasterVolume(v);
  static void setCueDelayMs(double ms) => _b.setCueDelayMs(ms);
  static void setCueMix(double m) => _b.setCueMix(m);
  static void testTone(bool on) => _b.testTone(on ? 1 : 0);

  /// Analyzes a file in a background isolate.
  static Future<AnalysisResult?> analyze(String path) => Isolate.run(() => _analyzeSync(path));

  static AnalysisResult? _analyzeSync(String path) {
    const maxPeaks = 30 * 60 * 120; // up to two hours
    final p = path.toNativeUtf8();
    final a = calloc<CsaAnalysis>();
    final peaks = calloc<Float>(maxPeaks);
    try {
      final n = _b.analyze(p, a, peaks, maxPeaks);
      if (n < 0) return null;
      final r = a.ref;
      return AnalysisResult(
        duration: r.duration,
        bpm: r.bpm,
        gainDb: r.gainDb,
        introSec: r.introSec,
        loudDb: r.loudDb,
        peaks: Float32List.fromList(peaks.asTypedList(n)),
        key: r.key,
        keyConf: r.keyConf,
        onsetRate: r.onsetRate,
        pulse: r.pulse,
        brightness: r.brightness,
      );
    } finally {
      calloc.free(p);
      calloc.free(a);
      calloc.free(peaks);
    }
  }
}
