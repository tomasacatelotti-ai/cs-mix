import 'dart:convert';
import 'dart:io';

import 'library.dart';
import 'models.dart';

/// One entry of a Virtual DJ playlist.
class VdjEntry {
  VdjEntry({required this.path, this.artist = '', this.title = '', this.size = 0, this.length = 0});

  final String path;
  final String artist;
  final String title;
  final int size;
  final double length;

  /// Path segments, without drive letter.
  List<String> get segments =>
      path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty && !s.endsWith(':')).toList();

  String get fileName => segments.isEmpty ? path : segments.last;
}

class VdjImport {
  VdjImport(this.name, this.matched, this.missing);

  final String name;
  final List<Track> matched;
  final List<VdjEntry> missing;
}

/// Reads and writes Virtual DJ .m3u playlists (#EXTVDJ lines + absolute paths).
class Vdj {
  static final _tag = RegExp(r'<(\w+)>(.*?)</\1>');

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static List<VdjEntry> parse(String text) {
    if (text.startsWith('﻿')) text = text.substring(1);
    final out = <VdjEntry>[];
    Map<String, String> meta = {};
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTVDJ:')) {
        meta = {for (final m in _tag.allMatches(line)) m.group(1)!.toLowerCase(): _unescape(m.group(2)!)};
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        final info = comma > 0 ? line.substring(comma + 1) : '';
        final sep = info.indexOf(' - ');
        meta = sep > 0 ? {'artist': info.substring(0, sep), 'title': info.substring(sep + 3)} : {'title': info};
        continue;
      }
      if (line.startsWith('#')) continue;
      out.add(VdjEntry(
        path: line,
        artist: meta['artist'] ?? '',
        title: meta['title'] ?? '',
        size: int.tryParse(meta['filesize'] ?? '') ?? 0,
        length: double.tryParse(meta['songlength'] ?? '') ?? 0,
      ));
      meta = {};
    }
    return out;
  }

  static Future<List<File>> findPlaylists(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return [];
    final out = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.m3u') && !e.path.toLowerCase().endsWith('(cs mix).m3u')) {
        out.add(e);
      }
    }
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return out;
  }

  static String nameOf(File f) {
    final p = f.path.replaceAll('\\', '/');
    final n = p.substring(p.lastIndexOf('/') + 1);
    return n.replaceAll(RegExp(r'\.m3u$', caseSensitive: false), '');
  }

  /// Matches playlist entries against the library: by path under the library
  /// root folder, then by file name (size breaks ties), then artist + title.
  static Future<VdjImport> import(File file, LibraryStore lib, String pcRoot) async {
    final bytes = await file.readAsBytes();
    final entries = parse(utf8.decode(bytes, allowMalformed: true));

    final byRel = <String, Track>{};
    final byName = <String, List<Track>>{};
    final bySize = <int, List<Track>>{};
    final byMeta = <String, Track>{};
    for (final t in lib.tracks) {
      byRel[t.relPath.toLowerCase()] = t;
      byName.putIfAbsent(t.fileName.toLowerCase(), () => []).add(t);
      bySize.putIfAbsent(t.size, () => []).add(t);
      if (t.artist.isNotEmpty) byMeta['${_norm(t.artist)}|${_norm(t.title)}'] = t;
    }
    final rootName = pcRoot.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).lastOrNull?.toLowerCase();

    final matched = <Track>[];
    final missing = <VdjEntry>[];
    for (final e in entries) {
      final segs = e.segments;
      Track? hit;
      // 1. Path relative to the PC library root, or any suffix of the path.
      final ri = rootName == null ? -1 : segs.indexWhere((s) => s.toLowerCase() == rootName);
      if (ri >= 0) hit = byRel[segs.sublist(ri + 1).join('/').toLowerCase()];
      for (var k = 1; hit == null && k < segs.length; k++) {
        hit = byRel[segs.sublist(k).join('/').toLowerCase()];
      }
      // 2. File name, size to break ties.
      if (hit == null) {
        final c = byName[e.fileName.toLowerCase()];
        if (c != null && c.isNotEmpty) {
          hit = c.length == 1 ? c.first : (c.where((t) => t.size == e.size).firstOrNull ?? c.first);
        }
      }
      // 3. Same size and close name, then artist + title.
      if (hit == null && e.size > 0) hit = bySize[e.size]?.firstOrNull;
      if (hit == null && e.artist.isNotEmpty) hit = byMeta['${_norm(e.artist)}|${_norm(e.title)}'];

      if (hit == null) {
        missing.add(e);
        continue;
      }
      if (e.artist.isNotEmpty && e.title.isNotEmpty) {
        hit.artist = e.artist;
        hit.title = e.title;
      }
      if (!matched.contains(hit)) matched.add(hit);
    }
    lib.changed();
    return VdjImport(nameOf(file), matched, missing);
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  /// Writes "`name` (CS Mix).m3u" next to the library, with PC paths so it opens in Virtual DJ.
  static Future<File> export(Playlist p, LibraryStore lib, String libraryRoot, String pcRoot) async {
    final sb = StringBuffer('﻿');
    for (final t in lib.tracksOf(p)) {
      final path = Platform.isWindows ? t.path : '${pcRoot.replaceAll(RegExp(r'[\\/]+$'), '')}\\${t.relPath.replaceAll('/', '\\')}';
      sb.write('#EXTVDJ:<filesize>${t.size}</filesize>');
      if (t.artist.isNotEmpty) sb.write('<artist>${_escape(t.artist)}</artist>');
      sb.write('<title>${_escape(t.title)}</title>');
      if (t.duration > 0) sb.write('<songlength>${t.duration.toStringAsFixed(3)}</songlength>');
      sb.write('\r\n$path\r\n');
    }
    final safe = p.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final f = File('$libraryRoot${Platform.pathSeparator}$safe (CS Mix).m3u');
    await f.writeAsString(sb.toString(), flush: true);
    return f;
  }
}
