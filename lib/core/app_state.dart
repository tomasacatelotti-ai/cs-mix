import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'dj_controller.dart';
import 'library.dart';
import 'models.dart';
import 'platform.dart';
import 'player_controller.dart';

enum Mode { none, player, dj }

/// Polls the native engine ~30 times per second.
class EngineModel extends ChangeNotifier {
  List<DeckSnapshot> decks = const [DeckSnapshot(), DeckSnapshot()];
  double crossfader = 0;
  bool transitioning = false;
  void Function()? onTick;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) => poll());
  }

  void poll() {
    decks = [CsAudio.info(0), CsAudio.info(1)];
    crossfader = CsAudio.crossfader;
    transitioning = CsAudio.transitionActive;
    onTick?.call();
    notifyListeners();
  }

  bool get anyPlaying => decks[0].playing || decks[1].playing;
}

class AppState extends ChangeNotifier {
  late String dataDir;
  Settings settings = Settings();
  late LibraryStore library;
  final engine = EngineModel();
  late final PlayerController player;
  late final DjController dj;

  Mode mode = Mode.none;
  bool ready = false;
  bool hasStorage = true;
  String? startupError;
  List<OutputDevice> outputs = [];
  String? outputError;
  bool cueActive = false;
  bool _servicePlaying = false;
  String _serviceTitle = '';
  Timer? _settingsTimer;

  File get _settingsFile => File('$dataDir${Platform.pathSeparator}settings.json');

  Future<void> init() async {
    try {
      dataDir = await Native.appDir();
      if (await _settingsFile.exists()) {
        settings = Settings.fromJson(Map<String, Object?>.from(jsonDecode(await _settingsFile.readAsString()) as Map));
      }
      if (settings.libraryRoot.isEmpty) settings.libraryRoot = await Native.defaultMusicRoot();
      library = LibraryStore(dataDir);
      await library.load();

      if (!CsAudio.init()) outputError = 'No se pudo iniciar el audio: ${CsAudio.lastError()}';
      await openOutputs();
      applyAudioSettings();

      player = PlayerController(this);
      dj = DjController(this);
      engine.onTick = _tick;
      engine.start();
      Native.listenMedia(_onMedia);

      hasStorage = await Native.hasStorageAccess();
      if (hasStorage) unawaited(library.scan(settings.libraryRoot));
      library.watch(() => hasStorage ? settings.libraryRoot : '');
    } catch (e) {
      startupError = '$e';
    }
    ready = true;
    notifyListeners();
  }

  Future<void> recheckStorage() async {
    final had = hasStorage;
    hasStorage = await Native.hasStorageAccess();
    if (hasStorage && (!had || library.count == 0)) unawaited(library.scan(settings.libraryRoot));
    notifyListeners();
  }

  void saveSettings() {
    _settingsTimer?.cancel();
    _settingsTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        await _settingsFile.writeAsString(jsonEncode(settings.toJson()), flush: true);
      } catch (e) {
        debugPrint('settings save: $e');
      }
    });
    notifyListeners();
  }

  // ------------------------------------------------------------------ audio

  OutputDevice? _find(String key) => outputs.where((d) => d.key == key).firstOrNull;

  /// The pre-listen device used when the setting is "auto".
  OutputDevice? autoCue() {
    if (Platform.isAndroid) {
      final phones = outputs.where((d) => d.kind == 'headphones' || d.kind == 'usb').firstOrNull;
      if (phones != null) return phones;
      final bt = outputs.any((d) => d.kind == 'bluetooth');
      if (bt) return outputs.where((d) => d.kind == 'speaker').firstOrNull;
    }
    return null;
  }

  Future<void> openOutputs() async {
    outputError = null;
    try {
      outputs = await Native.outputs();
    } catch (e) {
      outputs = [];
    }
    final m = settings.masterDevice == 'auto' ? null : _find(settings.masterDevice);
    var ok = CsAudio.openMaster(index: m?.index ?? -1, androidId: m?.androidId ?? 0);
    if (!ok && m != null) ok = CsAudio.openMaster();
    if (!ok) outputError = 'No se pudo abrir la salida principal. ${CsAudio.lastError()}';

    OutputDevice? c;
    if (settings.cueDevice == 'auto') {
      c = autoCue();
    } else if (settings.cueDevice != 'off') {
      c = _find(settings.cueDevice);
    }
    if (c == null) {
      CsAudio.closeCue();
      cueActive = false;
    } else {
      cueActive = CsAudio.openCue(index: c.index, androidId: c.androidId);
      if (!cueActive) {
        outputError = 'Tu equipo no permite usar "${c.label}" para la pre-escucha al mismo tiempo que la salida principal.';
      }
    }
    notifyListeners();
  }

  /// Re-reads the output list without touching the open devices.
  Future<void> refreshOutputs() async {
    try {
      outputs = await Native.outputs();
    } catch (_) {}
    notifyListeners();
  }

  String? cueLabel() {
    if (!cueActive) return null;
    final c = settings.cueDevice == 'auto' ? autoCue() : _find(settings.cueDevice);
    return c?.label;
  }

  String masterLabel() {
    if (settings.masterDevice == 'auto') {
      final bt = outputs.where((d) => d.kind == 'bluetooth').firstOrNull;
      return bt != null ? bt.label : 'Salida del sistema';
    }
    return _find(settings.masterDevice)?.label ?? 'Salida del sistema';
  }

  void applyAudioSettings() {
    CsAudio.setCurve(settings.curve);
    for (var i = 0; i < 5; i++) {
      CsAudio.setEq(i, settings.eq[i]);
    }
    CsAudio.setMasterVolume(settings.masterVolume);
    CsAudio.setCueDelayMs(settings.cueDelayMs);
  }

  double gainFor(Track t) => settings.autoGain && t.analyzed ? t.gainDb : 0;

  /// Where a track starts when it comes in through a transition.
  double entryFor(Track t) {
    switch (settings.entryMode) {
      case EntryMode.saved:
        return t.entry ?? (t.analyzed ? t.intro : 0);
      case EntryMode.intro:
        return t.analyzed ? t.intro : 0;
      case EntryMode.start:
        return 0;
    }
  }

  /// Both modes share the two decks: switching mode stops everything.
  void setMode(Mode m) {
    if (mode == m) return;
    for (var d = 0; d < 2; d++) {
      CsAudio.play(d, false);
      CsAudio.unload(d);
      CsAudio.setPfl(d, false);
      CsAudio.setPitch(d, 0);
    }
    CsAudio.setCrossfader(0);
    player.reset();
    dj.reset();
    mode = m;
    notifyListeners();
  }

  void _tick() {
    if (mode == Mode.player) player.tick();
    if (mode == Mode.dj) dj.tick();
    _syncService();
  }

  void _syncService() {
    final playing = engine.anyPlaying;
    String title = '';
    if (mode == Mode.player) {
      final t = player.current;
      if (t != null) title = t.artist.isEmpty ? t.title : '${t.artist} – ${t.title}';
    } else if (mode == Mode.dj) {
      final a = engine.decks[0], b = engine.decks[1];
      final deck = (b.playing && (!a.playing || engine.crossfader > 0.5)) ? 1 : 0;
      final t = dj.decks[deck];
      if (t != null) title = t.title;
    }
    if (playing != _servicePlaying || title != _serviceTitle) {
      final wasActive = _servicePlaying || _serviceTitle.isNotEmpty;
      _servicePlaying = playing;
      _serviceTitle = title;
      final active = playing || (title.isNotEmpty && wasActive);
      unawaited(Native.serviceUpdate(active: active, title: title.isEmpty ? 'CS Mix' : title, playing: playing));
    }
  }

  void _onMedia(String action) {
    switch (action) {
      case 'toggle':
        if (mode == Mode.player) player.togglePlay();
        if (mode == Mode.dj) {
          final any = engine.anyPlaying;
          for (var d = 0; d < 2; d++) {
            if (any) CsAudio.play(d, false);
          }
        }
      case 'next':
        if (mode == Mode.player) player.passNow();
      case 'stop':
        for (var d = 0; d < 2; d++) {
          CsAudio.play(d, false);
        }
    }
  }
}
