import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'tags.dart';

/// Tracks, playlists, analysis queue and on-disk persistence.
///
/// Local tracks come from the library folder; remote tracks ("csnet:" paths) come from
/// the gym PC over the network and are kept apart so a local rescan never drops them.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.dataDir);

  final String dataDir;
  final Map<String, Track> _tracks = {};
  final Map<String, Track> _remote = {};
  final List<Playlist> playlists = [];

  /// Playlists shared by the gym PC (read-only here).
  List<Playlist> remotePlaylists = [];
  final Map<String, Uint8List> _peaks = {};
  final List<String> _peakOrder = [];

  bool scanning = false;
  String? scanError;
  DateTime? lastScan;
  int analyzedCount = 0;
  bool _analyzing = false;
  final List<String> _priority = [];
  Timer? _saveTimer;
  Timer? _notifyTimer;
  Timer? _rescanTimer;

  List<Track> get tracks => [..._tracks.values, ..._remote.values];
  List<Track> get localTracks => _tracks.values.toList(growable: false);
  int get count => _tracks.length + _remote.length;
  int get remoteCount => _remote.length;
  Track? byPath(String path) => _tracks[path] ?? _remote[path];
  Track? localByRel(String rel) => _tracks.values.where((t) => t.relPath == rel).firstOrNull;
  List<Playlist> get allPlaylists => [...playlists, ...remotePlaylists];

  bool needsAnalysis(Track t) => !t.remote && !t.failed && (!t.analyzed || t.version < Track.analysisVersion);
  int get pendingAnalysis => _tracks.values.where(needsAnalysis).length;

  List<String> get folders {
    final s = <String>{for (final t in tracks) t.folder}..remove('');
    return s.toList()..sort();
  }

  // ---------------------------------------------------------------- storage

  String get _sep => Platform.pathSeparator;
  File get _libFile => File('$dataDir${_sep}library.json');
  File get _remoteFile => File('$dataDir${_sep}remote.json');
  File get _plFile => File('$dataDir${_sep}playlists.json');
  Directory get _peakDir => Directory('$dataDir${_sep}peaks');
  Directory get coverDir => Directory('$dataDir${_sep}covers');

  /// Reads one JSON file; a damaged one is kept aside as .bad instead of being overwritten later.
  Future<Object?> _readJson(File f) async {
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (e) {
      debugPrint('load ${f.path}: $e');
      try {
        await f.copy('${f.path}.bad');
      } catch (_) {}
      return null;
    }
  }

  Future<void> load() async {
    final lib = await _readJson(_libFile);
    if (lib is List) {
      for (final e in lib) {
        try {
          final t = Track.fromJson(Map<String, Object?>.from(e as Map));
          _tracks[t.path] = t;
        } catch (_) {}
      }
    }
    final rem = await _readJson(_remoteFile);
    if (rem is Map) {
      try {
        for (final e in (rem['t'] as List? ?? const [])) {
          final t = Track.fromJson(Map<String, Object?>.from(e as Map));
          _remote[t.path] = t;
        }
        remotePlaylists = [for (final e in (rem['p'] as List? ?? const [])) Playlist.fromJson(Map<String, Object?>.from(e as Map))];
      } catch (_) {}
    }
    final pl = await _readJson(_plFile);
    if (pl is List) {
      for (final e in pl) {
        try {
          playlists.add(Playlist.fromJson(Map<String, Object?>.from(e as Map)));
        } catch (_) {}
      }
    }
    await _peakDir.create(recursive: true);
    await coverDir.create(recursive: true);
    analyzedCount = _tracks.values.where((t) => t.analyzed).length;
    _computeSharedDepth();
    notifyListeners();
  }

  /// How many leading folders all tracks share, so genres are the first folder that differs.
  void _computeSharedDepth() {
    List<String>? common;
    for (final t in tracks) {
      final segs = t.dir.isEmpty ? <String>[] : t.dir.split('/');
      if (common == null) {
        common = segs;
        continue;
      }
      var k = 0;
      while (k < common.length && k < segs.length && common[k] == segs[k]) {
        k++;
      }
      common = common.sublist(0, k);
      if (common.isEmpty) break;
    }
    Track.sharedDepth = common?.length ?? 0;
  }

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    try {
      await _writeAtomic(_libFile, jsonEncode([for (final t in _tracks.values) t.toJson()]));
      await _writeAtomic(_plFile, jsonEncode([for (final p in playlists) p.toJson()]));
      await _writeAtomic(
        _remoteFile,
        jsonEncode({
          't': [for (final t in _remote.values) t.toJson()],
          'p': [for (final p in remotePlaylists) p.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('library save: $e');
    }
  }

  Future<void> _writeAtomic(File f, String data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    if (Platform.isWindows && await f.exists()) {
      // rename() over an existing file can fail on Windows while another process reads it.
      try {
        await tmp.rename(f.path);
        return;
      } catch (_) {
        await f.delete();
      }
    }
    await tmp.rename(f.path);
  }

  void changed() {
    save();
    _notifySoon();
  }

  void _notifySoon() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 400), notifyListeners);
  }

  // ---------------------------------------------------------------- scanning

  /// Rescans [root] in a background isolate and merges the result.
  Future<void> scan(String root) async {
    if (scanning || root.isEmpty) return;
    scanning = true;
    scanError = null;
    notifyListeners();
    try {
      final found = await Isolate.run(() => _scanDir(root));
      if (found.isEmpty && _tracks.isNotEmpty) {
        // Card not mounted or permission gone: keep what we know instead of wiping it.
        scanError = 'La carpeta de la biblioteca aparece vacía. Se conservan los temas conocidos.';
        return;
      }
      final seen = <String>{};
      for (final f in found) {
        seen.add(f.path);
        final old = _tracks[f.path];
        if (old != null && old.size == f.size && old.mtime == f.mtime) {
          old.relPath = f.rel;
          continue;
        }
        final name = Track.parseName(f.rel.split('/').last);
        final t = Track(path: f.path, relPath: f.rel, title: name.title, artist: name.artist, size: f.size, mtime: f.mtime);
        if (old != null) _keepUserData(t, old);
        _tracks[f.path] = t;
      }
      _tracks.removeWhere((p, _) => !seen.contains(p));
      _computeSharedDepth();
      lastScan = DateTime.now();
      analyzedCount = _tracks.values.where((t) => t.analyzed).length;
      save();
      _startAnalysis();
    } catch (e) {
      scanError = 'No se pudo leer la carpeta: $e';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// What the person set on a track survives a rescan or a refresh from the PC.
  static void _keepUserData(Track t, Track old) {
    t.entry = old.entry ?? t.entry;
    t.cue = old.cue ?? t.cue;
    if (old.hotcues.any((h) => h != null)) t.hotcues = old.hotcues;
    t.plays = old.plays > t.plays ? old.plays : t.plays;
    t.skips = old.skips > t.skips ? old.skips : t.skips;
    t.lastPlayed = old.lastPlayed > t.lastPlayed ? old.lastPlayed : t.lastPlayed;
    if (old.fixedName) {
      t.artist = old.artist;
      t.title = old.title;
      t.fixedName = true;
    }
  }

  /// Rescans periodically so files copied into the folder appear on their own.
  void watch(String Function() root) {
    _rescanTimer?.cancel();
    _rescanTimer = Timer.periodic(const Duration(seconds: 60), (_) => scan(root()));
  }

  static Future<List<({String path, String rel, int size, int mtime})>> _scanDir(String root) async {
    final out = <({String path, String rel, int size, int mtime})>[];
    final dir = Directory(root);
    if (!dir.existsSync()) throw FileSystemException('No existe', root);
    final rootLen = dir.path.length;
    // Folders that can't be read (Android/data, System Volume Information) are skipped, not fatal.
    final stream = dir.list(recursive: true, followLinks: false).handleError((Object _) {});
    await for (final e in stream) {
      if (e is! File) continue;
      final p = e.path;
      final dot = p.lastIndexOf('.');
      if (dot < 0) continue;
      final ext = p.substring(dot).toLowerCase();
      if (!audioExtensions.contains(ext)) continue;
      final name = p.substring(p.lastIndexOf(Platform.pathSeparator) + 1);
      if (name.startsWith('.')) continue;
      try {
        final st = e.statSync();
        var rel = p.substring(rootLen).replaceAll('\\', '/');
        while (rel.startsWith('/')) {
          rel = rel.substring(1);
        }
        out.add((path: p, rel: rel, size: st.size, mtime: st.modified.millisecondsSinceEpoch));
      } catch (_) {
        // unreadable file: skip
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- remote (gym PC)

  /// Replaces the tracks shared by the PC, keeping what was set on this phone.
  void setRemote(List<Track> remote, List<Playlist> remoteLists) {
    final next = <String, Track>{};
    for (final t in remote) {
      final old = _remote[t.path];
      if (old != null) _keepUserData(t, old);
      next[t.path] = t;
    }
    _remote
      ..clear()
      ..addAll(next);
    remotePlaylists = remoteLists;
    _computeSharedDepth();
    changed();
  }

  void clearRemote() {
    _remote.clear();
    remotePlaylists = [];
    _computeSharedDepth();
    changed();
  }

  // ---------------------------------------------------------------- analysis

  /// Puts a track first in the analysis queue (it was just loaded on a deck).
  void prioritize(Track t) {
    if (!needsAnalysis(t)) return;
    _priority.remove(t.path);
    _priority.insert(0, t.path);
    _startAnalysis();
  }

  void _startAnalysis() {
    if (_analyzing) return;
    _analyzing = true;
    unawaited(_analysisLoop());
  }

  Future<void> _analysisLoop() async {
    try {
      while (true) {
        Track? next;
        while (_priority.isNotEmpty && next == null) {
          final t = _tracks[_priority.removeAt(0)];
          if (t != null && needsAnalysis(t)) next = t;
        }
        next ??= _tracks.values.where(needsAnalysis).firstOrNull;
        if (next == null) break;
        await analyzeNow(next);
      }
    } finally {
      _analyzing = false;
      notifyListeners();
    }
  }

  Future<void> analyzeNow(Track t) async {
    final path = t.path;
    final coverBase = coverPathBase(path);
    final r = await CsAudio.analyze(path);
    // Tags and the cover picture, read in the background too.
    final tags = await Isolate.run(() {
      final tg = readTags(path);
      var savedCover = false;
      if (tg.cover != null && tg.cover!.length > 64) {
        try {
          File(coverBase).writeAsBytesSync(tg.cover!, flush: false);
          savedCover = true;
        } catch (_) {}
      }
      return (title: tg.title, artist: tg.artist, genre: tg.genre, cover: savedCover);
    });
    if (r == null) {
      t.failed = true;
    } else {
      t.duration = r.duration;
      t.bpm = r.bpm;
      t.gainDb = r.gainDb;
      t.intro = r.introSec;
      t.key = r.key;
      t.keyConf = r.keyConf;
      t.loudDb = r.loudDb;
      t.onsetRate = r.onsetRate;
      t.pulse = r.pulse;
      t.brightness = r.brightness;
      t.energy = energyOf(loudDb: r.loudDb, onsetRate: r.onsetRate, bpm: r.bpm, brightness: r.brightness);
      t.mood = moodOf(energy: t.energy, pulse: r.pulse, key: r.key, brightness: r.brightness);
      if (!t.analyzed) analyzedCount++;
      t.analyzed = true;
      t.failed = false;
      t.version = Track.analysisVersion;
      final bytes = Uint8List(r.peaks.length);
      for (var i = 0; i < r.peaks.length; i++) {
        bytes[i] = (r.peaks[i].clamp(0.0, 1.0) * 255).round();
      }
      _cachePeaks(t.path, bytes);
      try {
        await File(peakPath(t.path)).writeAsBytes(bytes, flush: false);
      } catch (_) {}
    }
    t.hasCover = tags.cover;
    t.genreTag = tags.genre ?? '';
    // The file name wins when it has "Artist - Title"; tags fill in when it doesn't.
    if (!t.fixedName && (t.artist.isEmpty || looksMisnamed(t))) {
      if (tags.artist != null && tags.artist!.isNotEmpty) t.artist = tags.artist!;
      if (tags.title != null && tags.title!.isNotEmpty) t.title = tags.title!;
    }
    changed();
  }

  /// Names that probably need recognition ("Track 03", "audio", digits only, no artist).
  static bool looksMisnamed(Track t) {
    if (t.artist.trim().isEmpty) return true;
    final n = t.title.toLowerCase().trim();
    return n.isEmpty ||
        RegExp(r'^(track|pista|audio|unknown|desconocido|sin t[ií]tulo)\s*\d*$').hasMatch(n) ||
        RegExp(r'^[\d\s_\-\.()]+$').hasMatch(n);
  }

  // ---------------------------------------------------------------- history

  void recordPlay(Track t) {
    t.plays++;
    t.lastPlayed = DateTime.now().millisecondsSinceEpoch;
    changed();
  }

  void recordSkip(Track t) {
    t.skips++;
    changed();
  }

  // ---------------------------------------------------------------- peaks and covers

  static String _hash(String path) {
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode(path)) {
      h ^= c;
      h = (h * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  String peakPath(String path) => '${_peakDir.path}$_sep${_hash(path)}.bin';

  /// Cover image file for a track (format detected from its bytes when shown).
  String coverPathBase(String path) => '${coverDir.path}$_sep${_hash(path)}.img';

  File? coverOf(Track t) {
    if (!t.hasCover) return null;
    final f = File(coverPathBase(t.path));
    return f.existsSync() ? f : null;
  }

  void _cachePeaks(String path, Uint8List data) {
    _peaks[path] = data;
    _peakOrder
      ..remove(path)
      ..add(path);
    while (_peakOrder.length > 24) {
      _peaks.remove(_peakOrder.removeAt(0));
    }
  }

  void putPeaks(String path, Uint8List data) => _cachePeaks(path, data);

  /// Overview peaks (30 per second, 0..255) or null while not analyzed yet.
  Uint8List? peaksOf(Track t) {
    final hit = _peaks[t.path];
    if (hit != null) return hit;
    if (!t.analyzed) return null;
    final f = File(peakPath(t.path));
    if (!f.existsSync()) return null;
    final data = f.readAsBytesSync();
    _cachePeaks(t.path, data);
    return data;
  }

  // ---------------------------------------------------------------- playlists

  Playlist newPlaylist(String name, {List<String>? paths, String? source}) {
    final p = Playlist(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name, paths: paths, source: source);
    playlists.add(p);
    changed();
    return p;
  }

  void deletePlaylist(Playlist p) {
    playlists.remove(p);
    changed();
  }

  List<Track> tracksOf(Playlist p) => [for (final path in p.paths) ?byPath(path)];
}
