import 'package:cs_audio/cs_audio.dart';

const audioExtensions = {'.mp3', '.flac', '.wav', '.aiff', '.aif', '.aifc'};

class Track {
  Track({
    required this.path,
    required this.relPath,
    required this.title,
    required this.artist,
    required this.size,
    required this.mtime,
  });

  final String path;
  String relPath; // relative to the library root, '/' separated
  String title;
  String artist;
  int size;
  int mtime;

  double duration = 0;
  double bpm = 0;
  double gainDb = 0;
  double intro = 0;
  bool analyzed = false;
  bool failed = false;

  /// Analysis format; tracks below [analysisVersion] are analyzed again.
  int version = 0;
  static const analysisVersion = 2;

  /// 0..11 major (C..B), 12..23 minor, -1 unknown.
  int key = -1;
  double keyConf = 0;
  double loudDb = 0;
  double onsetRate = 0;
  double pulse = 0;
  double brightness = 0;

  /// 0..1 mix of loudness, hits per second and tempo.
  double energy = 0;
  String mood = '';
  String genreTag = '';
  bool hasCover = false;

  /// Shared from the gym PC (path starts with "csnet:").
  bool get remote => path.startsWith('csnet:');

  // Listening history.
  int plays = 0;
  int skips = 0;
  int lastPlayed = 0; // ms since epoch

  /// Title/artist fixed by the user or by recognition (the file is never renamed).
  bool fixedName = false;

  /// Saved entry point for transitions (seconds).
  double? entry;

  /// DJ cue point.
  double? cue;
  List<double?> hotcues = [null, null, null, null];

  String get fileName {
    final i = relPath.lastIndexOf('/');
    return i < 0 ? relPath : relPath.substring(i + 1);
  }

  /// Leading folders every track shares (e.g. "BIBLIOTECA - EN USO"), set by the library.
  static int sharedDepth = 0;

  /// First meaningful folder (in this library, the genre).
  String get folder {
    final segs = relPath.split('/');
    return segs.length - 1 > sharedDepth ? segs[sharedDepth] : '';
  }

  /// Folder that holds the file, relative to the library root ('' at the root).
  String get dir {
    final i = relPath.lastIndexOf('/');
    return i < 0 ? '' : relPath.substring(0, i);
  }

  String get subtitle => artist.isEmpty ? folder : artist;

  Map<String, Object?> toJson() => {
        'p': path,
        'r': relPath,
        't': title,
        'a': artist,
        's': size,
        'm': mtime,
        'd': duration,
        'b': bpm,
        'g': gainDb,
        'i': intro,
        'ok': analyzed,
        'f': failed,
        'v': version,
        'k': key,
        'kc': keyConf,
        'ld': loudDb,
        'or': onsetRate,
        'pu': pulse,
        'br': brightness,
        'en': energy,
        'mo': mood,
        'gt': genreTag,
        'cv': hasCover,
        if (plays > 0) 'pl': plays,
        if (skips > 0) 'sk': skips,
        if (lastPlayed > 0) 'lp': lastPlayed,
        if (fixedName) 'fx': true,
        if (entry != null) 'e': entry,
        if (cue != null) 'c': cue,
        if (hotcues.any((h) => h != null)) 'h': hotcues,
      };

  static Track fromJson(Map<String, Object?> j) {
    final t = Track(
      path: j['p'] as String,
      relPath: j['r'] as String? ?? '',
      title: j['t'] as String? ?? '',
      artist: j['a'] as String? ?? '',
      size: (j['s'] as num?)?.toInt() ?? 0,
      mtime: (j['m'] as num?)?.toInt() ?? 0,
    );
    t.duration = (j['d'] as num?)?.toDouble() ?? 0;
    t.bpm = (j['b'] as num?)?.toDouble() ?? 0;
    t.gainDb = (j['g'] as num?)?.toDouble() ?? 0;
    t.intro = (j['i'] as num?)?.toDouble() ?? 0;
    t.analyzed = j['ok'] as bool? ?? false;
    t.failed = j['f'] as bool? ?? false;
    t.version = (j['v'] as num?)?.toInt() ?? 0;
    t.key = (j['k'] as num?)?.toInt() ?? -1;
    t.keyConf = (j['kc'] as num?)?.toDouble() ?? 0;
    t.loudDb = (j['ld'] as num?)?.toDouble() ?? 0;
    t.onsetRate = (j['or'] as num?)?.toDouble() ?? 0;
    t.pulse = (j['pu'] as num?)?.toDouble() ?? 0;
    t.brightness = (j['br'] as num?)?.toDouble() ?? 0;
    t.energy = (j['en'] as num?)?.toDouble() ?? 0;
    t.mood = j['mo'] as String? ?? '';
    t.genreTag = j['gt'] as String? ?? '';
    t.hasCover = j['cv'] as bool? ?? false;
    t.plays = (j['pl'] as num?)?.toInt() ?? 0;
    t.skips = (j['sk'] as num?)?.toInt() ?? 0;
    t.lastPlayed = (j['lp'] as num?)?.toInt() ?? 0;
    t.fixedName = j['fx'] as bool? ?? false;
    t.entry = (j['e'] as num?)?.toDouble();
    t.cue = (j['c'] as num?)?.toDouble();
    final h = j['h'];
    if (h is List) {
      t.hotcues = [for (var k = 0; k < 4; k++) k < h.length ? (h[k] as num?)?.toDouble() : null];
    }
    return t;
  }

  /// "Artist - Title (Remix).mp3" → artist / title.
  static ({String artist, String title}) parseName(String fileName) {
    var base = fileName;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    final sep = base.indexOf(' - ');
    if (sep > 0) {
      return (artist: base.substring(0, sep).trim(), title: base.substring(sep + 3).trim());
    }
    return (artist: '', title: base.trim());
  }
}

class Playlist {
  Playlist({required this.id, required this.name, List<String>? paths, this.source})
      : paths = paths ?? <String>[];

  final String id;
  String name;
  final List<String> paths;

  /// File it was imported from (Virtual DJ .m3u), if any.
  String? source;

  Map<String, Object?> toJson() => {'id': id, 'n': name, 'p': paths, if (source != null) 's': source};

  static Playlist fromJson(Map<String, Object?> j) => Playlist(
        id: j['id'] as String,
        name: j['n'] as String? ?? 'Playlist',
        paths: [for (final p in (j['p'] as List? ?? const [])) p as String],
        source: j['s'] as String?,
      );
}

enum EntryMode { saved, intro, start }

class Settings {
  String libraryRoot = '';
  String pcRoot = r'E:\BIBLIOTECA - EN USO';

  bool autoCrossfade = true;
  double autoSec = 6;
  int curve = 1; // 0 linear, 1 constant power

  TransitionFx defaultFx = TransitionFx.fade;
  Map<TransitionFx, double> fxDur = {
    TransitionFx.fade: 4,
    TransitionFx.reverse: 2,
    TransitionFx.brake: 1.5,
    TransitionFx.cut: 0,
  };

  EntryMode entryMode = EntryMode.saved;
  List<double> eq = [0, 0, 0, 0, 0];
  String eqPreset = 'Plano';
  bool autoGain = true;
  double masterVolume = 1;

  String masterDevice = 'auto';
  String cueDevice = 'auto';
  double cueDelayMs = 200;

  bool shuffle = false;
  bool repeat = false;

  // Network library.
  bool shareEnabled = false;
  String sharePin = '';
  String shareName = 'PC del gimnasio';
  bool autostart = false;
  String netHost = '';
  String netPin = '';
  String netName = '';
  int cacheLimitMb = 2048;

  // Recognition (AcoustID application key) and things to get.
  String acoustidKey = '';
  List<String> wishlist = [];

  Map<String, Object?> toJson() => {
        'root': libraryRoot,
        'pc': pcRoot,
        'auto': autoCrossfade,
        'autoSec': autoSec,
        'curve': curve,
        'fx': defaultFx.index,
        'fxDur': {for (final e in fxDur.entries) e.key.index.toString(): e.value},
        'entry': entryMode.index,
        'eq': eq,
        'eqPreset': eqPreset,
        'gain': autoGain,
        'vol': masterVolume,
        'master': masterDevice,
        'cue': cueDevice,
        'delay': cueDelayMs,
        'shuffle': shuffle,
        'repeat': repeat,
        'share': shareEnabled,
        'pin': sharePin,
        'shareName': shareName,
        'autostart': autostart,
        'netHost': netHost,
        'netPin': netPin,
        'netName': netName,
        'cacheMb': cacheLimitMb,
        'acoustid': acoustidKey,
        'wish': wishlist,
      };

  static Settings fromJson(Map<String, Object?> j) {
    final s = Settings();
    s.libraryRoot = j['root'] as String? ?? '';
    s.pcRoot = j['pc'] as String? ?? s.pcRoot;
    s.autoCrossfade = j['auto'] as bool? ?? true;
    s.autoSec = (j['autoSec'] as num?)?.toDouble() ?? 6;
    s.curve = (j['curve'] as num?)?.toInt() ?? 1;
    s.defaultFx = TransitionFx.values[((j['fx'] as num?)?.toInt() ?? 0).clamp(0, 3)];
    final fd = j['fxDur'];
    if (fd is Map) {
      for (final e in fd.entries) {
        final i = int.tryParse('${e.key}');
        if (i != null && i >= 0 && i < 4) s.fxDur[TransitionFx.values[i]] = (e.value as num).toDouble();
      }
    }
    s.entryMode = EntryMode.values[((j['entry'] as num?)?.toInt() ?? 0).clamp(0, 2)];
    final eq = j['eq'];
    if (eq is List && eq.length == 5) s.eq = [for (final v in eq) (v as num).toDouble()];
    s.eqPreset = j['eqPreset'] as String? ?? 'Plano';
    s.autoGain = j['gain'] as bool? ?? true;
    s.masterVolume = (j['vol'] as num?)?.toDouble() ?? 1;
    s.masterDevice = j['master'] as String? ?? 'auto';
    s.cueDevice = j['cue'] as String? ?? 'auto';
    s.cueDelayMs = (j['delay'] as num?)?.toDouble() ?? 200;
    s.shuffle = j['shuffle'] as bool? ?? false;
    s.repeat = j['repeat'] as bool? ?? false;
    s.shareEnabled = j['share'] as bool? ?? false;
    s.sharePin = j['pin'] as String? ?? '';
    s.shareName = j['shareName'] as String? ?? s.shareName;
    s.autostart = j['autostart'] as bool? ?? false;
    s.netHost = j['netHost'] as String? ?? '';
    s.netPin = j['netPin'] as String? ?? '';
    s.netName = j['netName'] as String? ?? '';
    s.cacheLimitMb = (j['cacheMb'] as num?)?.toInt() ?? 2048;
    s.acoustidKey = j['acoustid'] as String? ?? '';
    s.wishlist = [for (final w in (j['wish'] as List? ?? const [])) '$w'];
    return s;
  }
}

const eqPresets = <String, List<double>>{
  'Plano': [0, 0, 0, 0, 0],
  'Sala': [3, 1, 0, 1, 2],
  'Graves +': [6, 3, 0, 0, 0],
  'Voces': [-2, 0, 3, 2, 0],
  'Fiesta': [4, 1, -1, 2, 3],
};

const eqLabels = ['60 Hz', '230 Hz', '910 Hz', '3,6 kHz', '14 kHz'];

String fxLabel(TransitionFx fx) => switch (fx) {
      TransitionFx.fade => 'Fade',
      TransitionFx.reverse => 'Reverse',
      TransitionFx.brake => 'Brake',
      TransitionFx.cut => 'Corte',
    };

String fxDescription(TransitionFx fx) => switch (fx) {
      TransitionFx.fade => 'Baja el tema actual y sube el próximo al mismo tiempo.',
      TransitionFx.reverse => 'El tema actual suena hacia atrás, como en Virtual DJ, y entra el próximo.',
      TransitionFx.brake => 'El tema actual se frena como un tocadiscos que se apaga y entra el próximo.',
      TransitionFx.cut => 'Cambio instantáneo, sin efecto.',
    };

// ---------------------------------------------------------------- keys

const _keyNames = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];

// Camelot number for each pitch class: majors (B) and minors (A).
const _camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1];
const _camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];

String keyName(int key) {
  if (key < 0 || key > 23) return '';
  return key < 12 ? _keyNames[key] : '${_keyNames[key - 12]}m';
}

/// Camelot code ("8A", "9B") used by DJs to mix in key.
String camelot(int key) {
  if (key < 0 || key > 23) return '';
  return key < 12 ? '${_camelotMajor[key]}B' : '${_camelotMinor[key - 12]}A';
}

({int n, bool minor})? _cam(int key) {
  if (key < 0 || key > 23) return null;
  return key < 12 ? (n: _camelotMajor[key], minor: false) : (n: _camelotMinor[key - 12], minor: true);
}

/// 0 same key, 1 neighbour (±1 or relative major/minor), 2 or more = clash.
int keyDistance(int a, int b) {
  final x = _cam(a), y = _cam(b);
  if (x == null || y == null) return 1;
  final d = ((x.n - y.n) % 12 + 12) % 12;
  final ring = d > 6 ? 12 - d : d;
  if (x.minor == y.minor) return ring;
  return ring == 0 ? 1 : ring + 1;
}

// ---------------------------------------------------------------- energy / mood

/// Energy from loudness, hits per second and tempo (0..1).
double energyOf({required double loudDb, required double onsetRate, required double bpm, required double brightness}) {
  final loud = ((loudDb + 20) / 14).clamp(0.0, 1.0); // -20 dBFS .. -6 dBFS
  final hits = (onsetRate / 7).clamp(0.0, 1.0);
  final tempo = bpm <= 0 ? 0.5 : ((bpm - 70) / 70).clamp(0.0, 1.0);
  final bright = (brightness / 0.35).clamp(0.0, 1.0);
  return (0.35 * loud + 0.3 * hits + 0.2 * tempo + 0.15 * bright).clamp(0.0, 1.0);
}

const moods = ['Enérgico', 'Festivo', 'Intenso', 'Melódico', 'Tranquilo'];

/// Mood from audio features (no neural network): energy, beat clarity and major/minor.
String moodOf({required double energy, required double pulse, required int key, required double brightness}) {
  final minor = key >= 12;
  if (energy < 0.35) return 'Tranquilo';
  if (energy >= 0.62) {
    if (minor && brightness < 0.3) return 'Intenso';
    return pulse >= 0.3 && !minor ? 'Festivo' : 'Enérgico';
  }
  if (pulse >= 0.32 && !minor) return 'Festivo';
  return minor ? 'Melódico' : (pulse < 0.22 ? 'Melódico' : 'Festivo');
}

