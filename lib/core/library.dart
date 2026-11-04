import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

/// Tracks, playlists, analysis queue and on-disk persistence.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.dataDir);

  final String dataDir;
  final Map<String, Track> _tracks = {};
  final List<Playlist> playlists = [];
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

  List<Track> get tracks => _tracks.values.toList(growable: false);
  int get count => _tracks.length;
  Track? byPath(String path) => _tracks[path];
  int get pendingAnalysis => _tracks.values.where((t) => !t.analyzed && !t.failed).length;

  List<String> get folders {
    final s = <String>{for (final t in _tracks.values) t.folder}..remove('');
    return s.toList()..sort();
  }

  // ---------------------------------------------------------------- storage

  File get _libFile => File('$dataDir${Platform.pathSeparator}library.json');
  File get _plFile => File('$dataDir${Platform.pathSeparator}playlists.json');
  Directory get _peakDir => Directory('$dataDir${Platform.pathSeparator}peaks');

  Future<void> load() async {
    try {
      if (await _libFile.exists()) {
        final j = jsonDecode(await _libFile.readAsString()) as List;
        for (final e in j) {
          final t = Track.fromJson(Map<String, Object?>.from(e as Map));
          _tracks[t.path] = t;
        }
      }
      if (await _plFile.exists()) {
        final j = jsonDecode(await _plFile.readAsString()) as List;
        playlists
          ..clear()
          ..addAll([for (final e in j) Playlist.fromJson(Map<String, Object?>.from(e as Map))]);
      }
    } catch (e) {
      debugPrint('library load: $e');
    }
    await _peakDir.create(recursive: true);
    analyzedCount = _tracks.values.where((t) => t.analyzed).length;
    notifyListeners();
  }

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    try {
      final lib = jsonEncode([for (final t in _tracks.values) t.toJson()]);
      final pl = jsonEncode([for (final p in playlists) p.toJson()]);
      await _writeAtomic(_libFile, lib);
      await _writeAtomic(_plFile, pl);
    } catch (e) {
      debugPrint('library save: $e');
    }
  }

  Future<void> _writeAtomic(File f, String data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
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
        if (old != null) {
          t.entry = old.entry;
          t.cue = old.cue;
          t.hotcues = old.hotcues;
          if (old.artist.isNotEmpty && old.title.isNotEmpty) {
            t.artist = old.artist;
            t.title = old.title;
          }
        }
        _tracks[f.path] = t;
      }
      _tracks.removeWhere((p, _) => !seen.contains(p));
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

  /// Rescans periodically so files copied into the folder appear on their own.
  void watch(String Function() root) {
    _rescanTimer?.cancel();
    _rescanTimer = Timer.periodic(const Duration(seconds: 60), (_) => scan(root()));
  }

  static List<({String path, String rel, int size, int mtime})> _scanDir(String root) {
    final out = <({String path, String rel, int size, int mtime})>[];
    final dir = Directory(root);
    if (!dir.existsSync()) throw FileSystemException('No existe', root);
    final rootLen = dir.path.length;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
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

  // ---------------------------------------------------------------- analysis

  /// Puts a track first in the analysis queue (it was just loaded on a deck).
  void prioritize(Track t) {
    if (t.analyzed || t.failed) return;
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
          if (t != null && !t.analyzed && !t.failed) next = t;
        }
        next ??= _tracks.values.cast<Track?>().firstWhere((t) => !t!.analyzed && !t.failed, orElse: () => null);
        if (next == null) break;
        await analyzeNow(next);
      }
    } finally {
      _analyzing = false;
      notifyListeners();
    }
  }

  Future<void> analyzeNow(Track t) async {
    final r = await CsAudio.analyze(t.path);
    if (r == null) {
      t.failed = true;
    } else {
      t.duration = r.duration;
      t.bpm = r.bpm;
      t.gainDb = r.gainDb;
      t.intro = r.introSec;
      t.analyzed = true;
      t.failed = false;
      final bytes = Uint8List(r.peaks.length);
      for (var i = 0; i < r.peaks.length; i++) {
        bytes[i] = (r.peaks[i].clamp(0.0, 1.0) * 255).round();
      }
      _cachePeaks(t.path, bytes);
      try {
        await File(_peakPath(t.path)).writeAsBytes(bytes, flush: false);
      } catch (_) {}
      analyzedCount++;
    }
    changed();
  }

  // ---------------------------------------------------------------- peaks

  String _peakPath(String path) {
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode(path)) {
      h ^= c;
      h = (h * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return '${_peakDir.path}${Platform.pathSeparator}${h.toRadixString(16)}.bin';
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

  /// Overview peaks (30 per second, 0..255) or null while not analyzed yet.
  Uint8List? peaksOf(Track t) {
    final hit = _peaks[t.path];
    if (hit != null) return hit;
    if (!t.analyzed) return null;
    final f = File(_peakPath(t.path));
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

  List<Track> tracksOf(Playlist p) => [for (final path in p.paths) ?_tracks[path]];
}
