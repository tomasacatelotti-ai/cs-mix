import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata read from inside an audio file.
class FileTags {
  String? title;
  String? artist;
  String? genre;
  Uint8List? cover;
  String? coverMime;

  bool get isEmpty => title == null && artist == null && genre == null && cover == null;
}

/// Reads ID3v2 (mp3, and inside wav/aiff), FLAC Vorbis comments + pictures and RIFF INFO.
/// Never throws: a damaged tag just gives fewer fields.
FileTags readTags(String path) {
  final tags = FileTags();
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final len = f.lengthSync();
    final head = f.readSync(12);
    if (head.length < 4) return tags;
    if (_ascii(head, 0, 3) == 'ID3') {
      _readId3At(f, 0, len, tags);
    } else if (_ascii(head, 0, 4) == 'fLaC') {
      _readFlac(f, len, tags);
    } else if (_ascii(head, 0, 4) == 'RIFF' && head.length >= 12 && _ascii(head, 8, 4) == 'WAVE') {
      _readChunks(f, 12, len, tags, bigEndian: false);
    } else if (_ascii(head, 0, 4) == 'FORM' && head.length >= 12) {
      _readChunks(f, 12, len, tags, bigEndian: true);
    }
  } catch (_) {
    // Partial tags are fine.
  } finally {
    try {
      f?.closeSync();
    } catch (_) {}
  }
  return tags;
}

String _ascii(List<int> b, int o, int n) => String.fromCharCodes(b.sublist(o, o + n));

int _be32(List<int> b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _le32(List<int> b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _syncsafe(List<int> b, int o) => (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

const _maxTag = 24 * 1024 * 1024;

void _readId3At(RandomAccessFile f, int offset, int fileLen, FileTags tags) {
  f.setPositionSync(offset);
  final h = f.readSync(10);
  if (h.length < 10 || _ascii(h, 0, 3) != 'ID3') return;
  final ver = h[3];
  final flags = h[5];
  final size = _syncsafe(h, 6);
  if (size <= 0 || size > _maxTag || offset + 10 + size > fileLen) return;
  var data = f.readSync(size);
  if ((flags & 0x80) != 0 && ver < 4) data = _unsync(data);
  var p = 0;
  if ((flags & 0x40) != 0 && ver >= 3 && data.length > 4) {
    // Extended header.
    final ext = ver == 4 ? _syncsafe(data, 0) : _be32(data, 0) + 4;
    p = ext.clamp(0, data.length);
  }
  final idLen = ver == 2 ? 3 : 4;
  final hdrLen = ver == 2 ? 6 : 10;
  while (p + hdrLen <= data.length) {
    final id = _ascii(data, p, idLen);
    if (id.codeUnitAt(0) == 0) break;
    int fsize;
    if (ver == 2) {
      fsize = (data[p + 3] << 16) | (data[p + 4] << 8) | data[p + 5];
    } else if (ver == 4) {
      fsize = _syncsafe(data, p + 4);
    } else {
      fsize = _be32(data, p + 4);
    }
    final start = p + hdrLen;
    if (fsize <= 0 || start + fsize > data.length) break;
    final body = Uint8List.sublistView(data, start, start + fsize);
    switch (id) {
      case 'TIT2' || 'TT2':
        tags.title ??= _id3Text(body);
      case 'TPE1' || 'TP1':
        tags.artist ??= _id3Text(body);
      case 'TCON' || 'TCO':
        tags.genre ??= _cleanGenre(_id3Text(body));
      case 'APIC':
        _apic(body, tags, v22: false);
      case 'PIC':
        _apic(body, tags, v22: true);
    }
    p = start + fsize;
  }
}

Uint8List _unsync(Uint8List d) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < d.length; i++) {
    out.addByte(d[i]);
    if (d[i] == 0xFF && i + 1 < d.length && d[i + 1] == 0x00) i++;
  }
  return out.toBytes();
}

String? _id3Text(Uint8List b) {
  if (b.isEmpty) return null;
  final s = _decode(b[0], Uint8List.sublistView(b, 1)).split('\u0000').first.trim();
  return s.isEmpty ? null : s;
}

String _decode(int enc, Uint8List b) {
  switch (enc) {
    case 1:
    case 2:
      var le = enc == 1;
      var o = 0;
      if (b.length >= 2 && enc == 1) {
        if (b[0] == 0xFF && b[1] == 0xFE) {
          le = true;
          o = 2;
        } else if (b[0] == 0xFE && b[1] == 0xFF) {
          le = false;
          o = 2;
        }
      }
      final units = <int>[];
      for (var i = o; i + 1 < b.length; i += 2) {
        units.add(le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
      }
      return String.fromCharCodes(units);
    case 3:
      return utf8.decode(b, allowMalformed: true);
    default:
      return latin1.decode(b);
  }
}

/// Index after a NUL terminator for the given encoding (1 byte, or 2 for UTF-16).
int _skipString(Uint8List b, int o, int enc) {
  if (enc == 1 || enc == 2) {
    var i = o;
    while (i + 1 < b.length && !(b[i] == 0 && b[i + 1] == 0)) {
      i += 2;
    }
    return i + 2;
  }
  var i = o;
  while (i < b.length && b[i] != 0) {
    i++;
  }
  return i + 1;
}

void _apic(Uint8List b, FileTags tags, {required bool v22}) {
  if (b.length < 8) return;
  final enc = b[0];
  String mime;
  int o;
  if (v22) {
    final fmt = _ascii(b, 1, 3).toLowerCase();
    mime = fmt == 'png' ? 'image/png' : 'image/jpeg';
    o = 4;
  } else {
    final end = _skipString(b, 1, 0);
    mime = latin1.decode(b.sublist(1, (end - 1).clamp(1, b.length)));
    o = end;
  }
  if (o >= b.length) return;
  final picType = b[o];
  o = _skipString(b, o + 1, enc);
  if (o >= b.length) return;
  // Prefer the front cover (type 3); otherwise keep the first picture.
  if (tags.cover != null && picType != 3) return;
  tags.cover = Uint8List.fromList(b.sublist(o));
  tags.coverMime = mime.isEmpty ? 'image/jpeg' : mime;
}

void _readFlac(RandomAccessFile f, int fileLen, FileTags tags) {
  var pos = 4;
  while (pos + 4 <= fileLen) {
    f.setPositionSync(pos);
    final h = f.readSync(4);
    if (h.length < 4) return;
    final last = (h[0] & 0x80) != 0;
    final type = h[0] & 0x7F;
    final size = (h[1] << 16) | (h[2] << 8) | h[3];
    if (pos + 4 + size > fileLen) return;
    if ((type == 4 || type == 6) && size < _maxTag) {
      final b = f.readSync(size);
      if (type == 4) _vorbis(b, tags);
      if (type == 6) _flacPicture(b, tags);
    }
    pos += 4 + size;
    if (last) return;
  }
}

void _vorbis(Uint8List b, FileTags tags) {
  if (b.length < 8) return;
  var o = 4 + _le32(b, 0);
  if (o + 4 > b.length) return;
  final n = _le32(b, o);
  o += 4;
  for (var i = 0; i < n && o + 4 <= b.length; i++) {
    final l = _le32(b, o);
    o += 4;
    if (l < 0 || o + l > b.length) return;
    final s = utf8.decode(b.sublist(o, o + l), allowMalformed: true);
    o += l;
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    final k = s.substring(0, eq).toUpperCase();
    final v = s.substring(eq + 1).trim();
    if (v.isEmpty) continue;
    if (k == 'TITLE') tags.title ??= v;
    if (k == 'ARTIST') tags.artist ??= v;
    if (k == 'GENRE') tags.genre ??= _cleanGenre(v);
  }
}

void _flacPicture(Uint8List b, FileTags tags) {
  if (b.length < 32) return;
  var o = 0;
  final type = _be32(b, o);
  o += 4;
  final ml = _be32(b, o);
  o += 4;
  if (o + ml > b.length) return;
  final mime = latin1.decode(b.sublist(o, o + ml));
  o += ml;
  final dl = _be32(b, o);
  o += 4 + dl + 16;
  if (o + 4 > b.length) return;
  final len = _be32(b, o);
  o += 4;
  if (len <= 0 || o + len > b.length) return;
  if (tags.cover != null && type != 3) return;
  tags.cover = Uint8List.fromList(b.sublist(o, o + len));
  tags.coverMime = mime;
}

void _readChunks(RandomAccessFile f, int start, int fileLen, FileTags tags, {required bool bigEndian}) {
  var pos = start;
  var guard = 0;
  while (pos + 8 <= fileLen && guard++ < 64) {
    f.setPositionSync(pos);
    final h = f.readSync(8);
    if (h.length < 8) return;
    final id = _ascii(h, 0, 4);
    final size = bigEndian ? _be32(h, 4) : _le32(h, 4);
    if (size < 0 || pos + 8 + size > fileLen + 1) return;
    if (id == 'ID3 ' || id == 'id3 ') {
      _readId3At(f, pos + 8, fileLen, tags);
    } else if (!bigEndian && id == 'LIST' && size >= 4 && size < 1024 * 1024) {
      final b = f.readSync(size);
      if (_ascii(b, 0, 4) == 'INFO') {
        var o = 4;
        while (o + 8 <= b.length) {
          final sid = _ascii(b, o, 4);
          final sl = _le32(b, o + 4);
          final so = o + 8;
          if (so + sl > b.length) break;
          final v = latin1.decode(b.sublist(so, so + sl)).split('\u0000').first.trim();
          if (v.isNotEmpty) {
            if (sid == 'INAM') tags.title ??= v;
            if (sid == 'IART') tags.artist ??= v;
            if (sid == 'IGNR') tags.genre ??= _cleanGenre(v);
          }
          o = so + sl + (sl & 1);
        }
      }
    }
    pos += 8 + size + (size & 1);
  }
}

String? _cleanGenre(String? g) {
  if (g == null) return null;
  final s = g.replaceAll(RegExp(r'^\(\d+\)'), '').trim();
  return s.isEmpty ? null : s;
}
