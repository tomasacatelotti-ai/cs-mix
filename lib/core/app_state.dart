import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'dj_controller.dart';
import 'library.dart';
import 'models.dart';
import 'net.dart';
import 'platform.dart';
import 'player_controller.dart';

enum Mode { none, player, dj }

/// Polls the native engine ~30 times per second.
class EngineModel extends ChangeNotifier {
  List<DeckSnapshot> decks = const [DeckSnapshot(), DeckSnapshot()];
  double crossfader = 0;
  bool transitioning = false;
  void Function()? onTick;
  void Function()? onRouteChange;
  int cueStatus = 0;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) => poll());
  }

  void poll() {
    decks = [CsAudio.info(0), CsAudio.info(1)];
    crossfader = CsAudio.crossfader;
    transitioning = CsAudio.transitionActive;
    cueStatus = CsAudio.cueStatus;
    if (CsAudio.takeRouteEvents() != 0) onRouteChange?.call();
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

  /// PC side: shares the library. Phone side: uses the PC's library.
  late final LibraryServer server;
  late final NetClient net;

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
  Timer? _routeTimer;

  /// The pre-listen was moved by the system and is muted until outputs reopen.
  bool get cueMuted => engine.cueStatus == 2;

  File get _settingsFile => File('$dataDir${Platform.pathSeparator}settings.json');

  Future<void> init() async {
    try {
      dataDir = await Native.appDir();
      settings = await _loadSettings();
      if (settings.libraryRoot.isEmpty) settings.libraryRoot = await Native.defaultMusicRoot();
      if (settings.sharePin.isEmpty) {
        settings.sharePin = newPin();
        saveSettings();
      }
      library = LibraryStore(dataDir);
      await library.load();
      server = LibraryServer(library);
      net = NetClient(library, dataDir, deviceName: await Native.deviceName());
      net.cacheLimitMb = settings.cacheLimitMb;

      if (!CsAudio.init()) outputError = 'No se pudo iniciar el audio: ${CsAudio.lastError()}';
      await openOutputs();
      applyAudioSettings();

      player = PlayerController(this);
      dj = DjController(this);
      engine.onTick = _tick;
      engine.onRouteChange = routeChanged;
      engine.start();
      Native.listenMedia(_onMedia, onDevices: routeChanged);

      hasStorage = await Native.hasStorageAccess();
      if (hasStorage) unawaited(library.scan(settings.libraryRoot));
      library.watch(() => hasStorage ? settings.libraryRoot : '');
      if (settings.shareEnabled) unawaited(server.start(pin: settings.sharePin, name: settings.shareName));
      if (settings.netHost.isNotEmpty) unawaited(net.resume(settings.netHost, settings.netPin, settings.netName));
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

  Future<Settings> _loadSettings() async {
    try {
      if (await _settingsFile.exists()) {
        return Settings.fromJson(Map<String, Object?>.from(jsonDecode(await _settingsFile.readAsString()) as Map));
      }
    } catch (e) {
      // A half-written file must never keep the app from starting.
      debugPrint('settings load: $e');
      try {
        await _settingsFile.rename('${_settingsFile.path}.bad');
      } catch (_) {}
    }
    return Settings();
  }

  void saveSettings() {
    _settingsTimer?.cancel();
    _settingsTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        final tmp = File('${_settingsFile.path}.tmp');
        await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
        if (Platform.isWindows && await _settingsFile.exists()) await _settingsFile.delete();
        await tmp.rename(_settingsFile.path);
      } catch (e) {
        debugPrint('settings save: $e');
      }
    });
    notifyListeners();
  }

  // ------------------------------------------------------------------ decks

  final List<String?> _deckWant = [null, null];
  final List<bool> _deckFetching = [false, false];
  final List<bool> _deckFetchFailed = [false, false];

  /// Loads a track on a deck; shared tracks are downloaded from the PC first.
  void loadDeck(int d, Track t, double start) {
    _deckWant[d] = t.path;
    _deckFetchFailed[d] = false;
    CsAudio.setGainDb(d, gainFor(t));
    if (!t.remote) {
      _deckFetching[d] = false;
      CsAudio.load(d, t.path, start);
      library.prioritize(t);
      return;
    }
    CsAudio.unload(d);
    _deckFetching[d] = true;
    unawaited(net.fetchExtras(t));
    net.fetch(t).then((local) {
      if (_deckWant[d] != t.path) return; // something else was loaded meanwhile
      _deckFetching[d] = false;
      if (local == null) {
        _deckFetchFailed[d] = true;
      } else {
        CsAudio.load(d, local, start);
      }
      notifyListeners();
    });
  }

  void forgetDeck(int d) {
    _deckWant[d] = null;
    _deckFetching[d] = false;
    _deckFetchFailed[d] = false;
  }

  /// The deck was asked to hold [t] (it may still be loading).
  bool deckHolds(int d, Track t) => _deckWant[d] == t.path && !_deckFetching[d];
  bool deckBusy(int d) => _deckFetching[d] || engine.decks[d].loading;
  bool deckError(int d) => _deckFetchFailed[d] || engine.decks[d].error;
  double? deckDownload(int d) {
    final p = _deckWant[d];
    return p == null || !_deckFetching[d] ? null : net.progress[p] ?? 0;
  }

  // ------------------------------------------------------------------ network

  Future<void> setSharing(bool on) async {
    settings.shareEnabled = on;
    saveSettings();
    if (on) {
      await server.start(pin: settings.sharePin, name: settings.shareName);
    } else {
      await server.stop();
    }
    notifyListeners();
  }

  Future<void> changePin() async {
    settings.sharePin = newPin();
    saveSettings();
    if (server.running) await server.start(pin: settings.sharePin, name: settings.shareName);
  }

  Future<String?> connectPc(String host, String pin, String name) async {
    final err = await net.connect(host, pin);
    if (err == null) {
      settings.netHost = net.host;
      settings.netPin = pin;
      settings.netName = net.pcName.isEmpty ? name : net.pcName;
      saveSettings();
    }
    return err;
  }

  void disconnectPc() {
    net.disconnect();
    settings.netHost = '';
    settings.netPin = '';
    saveSettings();
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

  /// A device was connected, removed or the system moved a stream: reopen with explicit devices.
  void routeChanged() {
    _routeTimer?.cancel();
    _routeTimer = Timer(const Duration(milliseconds: 1200), openOutputs);
  }

  /// Master device to open: the chosen one, or in "auto" the Bluetooth speaker when there is one
  /// (pinned by id so plugging headphones can't steal the music from the speaker).
  OutputDevice? _masterDevice() {
    if (settings.masterDevice != 'auto') return _find(settings.masterDevice);
    if (Platform.isAndroid && mode == Mode.dj) {
      final bt = outputs.where((d) => d.kind == 'bluetooth').firstOrNull;
      if (bt != null) return bt;
      // No speaker: music on the phone speaker, headphones free for the pre-listen.
      if (autoCue() != null) return outputs.where((d) => d.kind == 'speaker').firstOrNull;
    }
    return null;
  }

  Future<void> openOutputs() async {
    _routeTimer?.cancel();
    outputError = null;
    try {
      outputs = await Native.outputs();
    } catch (e) {
      outputs = [];
    }
    final m = _masterDevice();
    var ok = CsAudio.openMaster(index: m?.index ?? -1, androidId: m?.androidId ?? 0);
    if (!ok && m != null) ok = CsAudio.openMaster();
    if (!ok) outputError = 'No se pudo abrir la salida principal. ${CsAudio.lastError()}';

    // The pre-listen only exists in DJ mode.
    OutputDevice? c;
    if (mode == Mode.dj) {
      if (settings.cueDevice == 'auto') {
        c = autoCue();
      } else if (settings.cueDevice != 'off') {
        c = _find(settings.cueDevice);
      }
    }
    if (c != null && Platform.isAndroid && c.kind == 'bluetooth') {
      c = null;
      outputError = 'La pre-escucha no puede ir por Bluetooth: Android usa un solo dispositivo Bluetooth a la vez. '
          'Conectá los auriculares por cable o USB.';
    }
    if (c != null && m != null && c.key == m.key) {
      c = null;
      outputError = 'La pre-escucha y la salida principal son el mismo dispositivo: la pre-escucha queda apagada.';
    }
    if (c == null) {
      CsAudio.closeCue();
      cueActive = false;
    } else {
      cueActive = CsAudio.openCue(index: c.index, androidId: c.androidId);
      if (!cueActive) {
        outputError = 'Tu celular no dejó mandar la pre-escucha a "${c.label}" por separado, así que quedó apagada '
            'para que no suene en el parlante.';
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
    CsAudio.cancelTransition();
    for (var d = 0; d < 2; d++) {
      CsAudio.play(d, false);
      CsAudio.unload(d);
      CsAudio.setPfl(d, false);
      CsAudio.setPitch(d, 0);
      forgetDeck(d);
    }
    CsAudio.setCrossfader(0);
    player.reset();
    dj.reset();
    mode = m;
    unawaited(openOutputs());
    notifyListeners();
  }

  final List<String?> _countedOn = [null, null];

  /// Track sitting on a deck right now.
  Track? trackOnDeck(int d) {
    if (mode == Mode.dj) return dj.decks[d];
    if (mode == Mode.player) return d == player.active ? player.current : player.next;
    return null;
  }

  void _tick() {
    if (mode == Mode.player) player.tick();
    if (mode == Mode.dj) dj.tick();
    // History: a play counts once a track has sounded for 30 s on a deck.
    for (var d = 0; d < 2; d++) {
      final s = engine.decks[d];
      final t = trackOnDeck(d);
      if (t == null || !s.playing) continue;
      if (s.position >= 30 && _countedOn[d] != t.path) {
        _countedOn[d] = t.path;
        library.recordPlay(t);
      }
    }
    _syncService();
  }

  /// The player calls this when a track is left before it counted as played.
  void noteSkip(Track t, double position) {
    if (position < 30) library.recordSkip(t);
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
    net.nowPlaying = title;
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
