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
