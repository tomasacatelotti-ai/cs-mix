import 'dart:async';
import 'dart:io';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

enum DownloadStage { idle, downloading, converting, done, error }

/// Downloads an audio file from a direct link into the "Descargas" folder of the library.
///
/// MP3, FLAC, WAV and AIFF are saved exactly as they come (no re-encoding, no quality lost).
/// MP4, M4A, AAC and other audio/video files are converted to a 160 kbps MP3, because the
/// engine only plays MP3, FLAC, WAV and AIFF. A link that opens a web page is refused.
class LinkDownloader extends ChangeNotifier {
  LinkDownloader({required this.root, required this.canWrite, required this.onSaved});

  /// Library folder; the downloads go into its [folderName] subfolder.
  final String Function() root;
  final bool Function() canWrite;
  final void Function(String path) onSaved;

  static const folderName = 'Descargas';
  static const kbps = 160;
  static const _maxBytes = 1024 * 1024 * 1024;

  DownloadStage stage = DownloadStage.idle;

  /// 0..1, or null while the size is unknown.
  double? progress;

  /// Name of the file being downloaded, without extension.
  String fileName = '';
  String message = '';
  String? savedPath;

  bool get busy => stage == DownloadStage.downloading || stage == DownloadStage.converting;

  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _transfer;
  Mp3Job? _job;
  bool _cancel = false;
  DateTime _lastNotify = DateTime(0);

  /// Extensions the converter takes (decoded by the system: MediaCodec / Media Foundation).
  static const _convertExt = {'.mp4', '.m4a', '.m4v', '.aac', '.mov', '.3gp', '.webm', '.ogg', '.oga', '.opus', '.mkv'};

  /// Types saved as they come, with the extension they get when the link has none.
  static const _directMime = {
    'audio/mpeg': '.mp3',
    'audio/mp3': '.mp3',
    'audio/mpeg3': '.mp3',
    'audio/x-mpeg': '.mp3',
    'audio/flac': '.flac',
    'audio/x-flac': '.flac',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'audio/wave': '.wav',
    'audio/vnd.wave': '.wav',
    'audio/aiff': '.aiff',
    'audio/x-aiff': '.aiff',
  };

  /// First http(s) link in [text] (a shared text can come with a title before the link).
  static String? extractUrl(String text) {
    final m = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final u = m.group(0)!.replaceFirst(RegExp(r'''[)\]>.,;:!?'"»”]+$'''), '');
    final uri = Uri.tryParse(u);
    return uri != null && uri.host.isNotEmpty ? u : null;
  }

  Future<void> start(String text) async {
    if (busy) return;
    final url = extractUrl(text);
    if (url == null) {
      _fail('Pegá un link que empiece con http:// o https://');
      return;
    }
    if (!canWrite()) {
      _fail('CS Mix no tiene permiso para guardar archivos. Dáselo en Ajustes y probá de nuevo.');
      return;
    }
    final base = root();
    if (base.isEmpty) {
      _fail('Primero elegí la carpeta de la biblioteca en Ajustes.');
      return;
    }

    _cancel = false;
    stage = DownloadStage.downloading;
    progress = null;
    fileName = '';
    message = 'Conectando…';
    savedPath = null;
    notifyListeners();

    final sep = Platform.pathSeparator;
    final dir = Directory('$base$sep$folderName');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final partIn = File('${dir.path}$sep.cs-descarga-$stamp.part');
    final partOut = File('${dir.path}$sep.cs-descarga-$stamp.mp3.part');
    try {
      await dir.create(recursive: true);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = 'CS Mix';
      _client = client;
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      req.maxRedirects = 10;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _Fail('El servidor respondió ${res.statusCode}. Revisá que el link sea directo al archivo y que se pueda abrir sin iniciar sesión.');
      }
      final mime = res.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (_isPage(mime)) throw _Fail(_pageMessage);
      final total = res.contentLength;
      if (total > _maxBytes) throw _Fail('El archivo pesa más de 1 GB.');

      var finalUri = uri;
      for (final r in res.redirects) {
        finalUri = finalUri.resolveUri(r.location);
      }
      final (name, ext) = _nameOf(res.headers.value('content-disposition'), finalUri);
      final plan = _plan(ext, mime);
      if (plan == null) {
        throw _Fail('Ese link no es un archivo de audio ni de video (${mime.isEmpty ? 'tipo desconocido' : mime}).');
      }
      fileName = name;
      message = 'Descargando…';
      notifyListeners();

      await _download(res, partIn, total);
      if (await _startsLikeHtml(partIn)) throw _Fail(_pageMessage);

      final String dest;
      if (plan.convert) {
        stage = DownloadStage.converting;
        progress = 0;
        message = 'Convirtiendo a MP3 de $kbps kbps…';
        notifyListeners();
        final job = CsAudio.convertToMp3(partIn.path, partOut.path, kbps: kbps);
        _job = job;
        if (_cancel) job.cancel();
        final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
          progress = job.progress;
          notifyListeners();
        });
        final ConvertResult r;
        try {
          r = await job.done;
        } finally {
          timer.cancel();
          _job = null;
        }
        if (r == ConvertResult.cancelled) throw const _Cancelled();
        if (r != ConvertResult.ok) throw _Fail(_convertMessage(r));
        dest = await _unique(dir.path, sep, name, '.mp3');
        await partOut.rename(dest);
      } else {
        dest = await _unique(dir.path, sep, name, plan.ext);
        await partIn.rename(dest);
      }

      savedPath = dest;
      stage = DownloadStage.done;
      progress = 1;
      message = 'Guardado en $folderName: ${dest.substring(dest.lastIndexOf(sep) + 1)}';
      notifyListeners();
      onSaved(dest);
    } on _Cancelled {
      _cancelled();
    } on _Fail catch (e) {
      _cancel ? _cancelled() : _fail(e.message);
    } on FileSystemException catch (e) {
      _cancel ? _cancelled() : _fail('No se pudo guardar en la carpeta de la biblioteca (${e.osError?.message ?? e.message}).');
    } on TimeoutException {
      _cancel ? _cancelled() : _fail('El servidor tardó demasiado en responder.');
    } catch (e) {
      _cancel ? _cancelled() : _fail('No se pudo descargar: revisá la conexión y el link.');
      debugPrint('download: $e');
    } finally {
      _client?.close(force: true);
      _client = null;
      _sub = null;
      _transfer = null;
      for (final f in [partIn, partOut]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  void cancel() {
    if (!busy) return;
    _cancel = true;
    message = 'Cancelando…';
    notifyListeners();
    _job?.cancel();
    _sub?.cancel();
    final t = _transfer;
    if (t != null && !t.isCompleted) t.completeError(const _Cancelled());
    _client?.close(force: true);
  }

  /// Back to the empty form (after a result was shown).
  void reset() {
    if (busy) return;
    stage = DownloadStage.idle;
    progress = null;
    message = '';
    fileName = '';
    savedPath = null;
    notifyListeners();
  }

  Future<void> _download(HttpClientResponse res, File to, int total) async {
    final sink = to.openWrite();
    final done = Completer<void>();
    _transfer = done;
    var got = 0;
    _sub = res.listen(
      (chunk) {
        got += chunk.length;
        if (got > _maxBytes) {
          _sub?.cancel();
          if (!done.isCompleted) done.completeError(_Fail('El archivo pesa más de 1 GB.'));
          return;
        }
        sink.add(chunk);
        final now = DateTime.now();
        if (now.difference(_lastNotify).inMilliseconds >= 150) {
          _lastNotify = now;
          progress = total > 0 ? got / total : null;
          message = total > 0 ? 'Descargando…' : 'Descargando… ${(got / 1048576).toStringAsFixed(1)} MB';
          notifyListeners();
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) {
          if (total > 0 && got < total) {
            done.completeError(_Fail('La descarga se cortó antes de terminar.'));
          } else {
            done.complete();
          }
        }
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      await sink.close();
    }
  }

  void _fail(String text) {
    stage = DownloadStage.error;
    progress = null;
    message = text;
    notifyListeners();
  }

  void _cancelled() {
    stage = DownloadStage.idle;
    progress = null;
    message = 'Descarga cancelada.';
    notifyListeners();
  }

  static const _pageMessage =
      'Ese link abre una página web, no un archivo. Usá el link directo al archivo (el que hace que se descargue al abrirlo).';

  static bool _isPage(String mime) =>
      mime == 'text/html' || mime == 'application/xhtml+xml' || mime == 'application/json' || mime == 'text/plain';

  /// Saved as it comes (with that extension) or converted to MP3. Null: not audio or video.
  static ({bool convert, String ext})? _plan(String ext, String mime) {
    if (audioExtensions.contains(ext)) return (convert: false, ext: ext);
    final direct = _directMime[mime];
    if (direct != null) return (convert: false, ext: direct);
    if (_convertExt.contains(ext) || mime.startsWith('audio/') || mime.startsWith('video/')) {
      return (convert: true, ext: '.mp3');
    }
    // Servers that don't say what it is: the decoder finds out (and refuses what isn't media).
    if (mime.isEmpty || mime == 'application/octet-stream' || mime == 'binary/octet-stream') {
      return (convert: true, ext: '.mp3');
    }
    return null;
  }

  /// File name (sanitized, without extension) and lower-case extension.
  static (String, String) _nameOf(String? disposition, Uri uri) {
    var raw = '';
    if (disposition != null) {
      final star = RegExp(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", caseSensitive: false).firstMatch(disposition);
      final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(disposition);
      if (star != null) {
        try {
          raw = Uri.decodeComponent(star.group(2)!.trim());
        } catch (_) {
          raw = star.group(2)!.trim();
        }
      } else if (plain != null) {
        raw = plain.group(1)!.trim();
      }
    }
    if (raw.isEmpty) {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      raw = segs.isEmpty ? '' : segs.last;
    }
    raw = raw.split(RegExp(r'[\\/]')).last;
    var ext = '';
    final dot = raw.lastIndexOf('.');
    if (dot > 0 && raw.length - dot <= 6) {
      ext = raw.substring(dot).toLowerCase();
      raw = raw.substring(0, dot);
    }
    var name = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(RegExp(r'^\.+'), '')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (name.length > 120) name = name.substring(0, 120).trim();
    if (name.isEmpty) {
      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      name = 'Descarga ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}.${two(n.minute)}';
    }
    return (name, ext);
  }

  /// "name.mp3", or "name (2).mp3" if that already exists.
  static Future<String> _unique(String dir, String sep, String name, String ext) async {
    var path = '$dir$sep$name$ext';
    for (var n = 2; await File(path).exists(); n++) {
      path = '$dir$sep$name ($n)$ext';
    }
    return path;
  }

  /// Some servers answer a login or error page labelled as a file.
  static Future<bool> _startsLikeHtml(File f) async {
    try {
      final raf = await f.open();
      try {
        final head = String.fromCharCodes(await raf.read(256)).trimLeft().toLowerCase();
        return head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<?xml') || head.startsWith('{');
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  static String _convertMessage(ConvertResult r) {
    switch (r) {
      case ConvertResult.noAudio:
        return 'El archivo no tiene una pista de audio que se pueda leer.';
      case ConvertResult.unsupported:
        return Platform.isWindows
            ? 'Windows no puede leer el audio de este archivo (en Windows "N" hace falta instalar el Media Feature Pack).'
            : 'El celular no puede leer el audio de este archivo.';
      case ConvertResult.write:
        return 'No se pudo escribir el MP3 en la carpeta de la biblioteca.';
      case ConvertResult.encoder:
        return 'No se pudo codificar el MP3 con este audio.';
      case ConvertResult.decode:
        return 'El audio falló a mitad de camino: el archivo puede estar dañado o incompleto.';
      case ConvertResult.ok:
      case ConvertResult.cancelled:
        return '';
    }
  }
}

class _Fail implements Exception {
  _Fail(this.message);
  final String message;
}

class _Cancelled implements Exception {
  const _Cancelled();
}
