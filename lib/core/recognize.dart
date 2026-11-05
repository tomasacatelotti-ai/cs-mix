import 'dart:convert';
import 'dart:io';

import 'package:cs_audio/cs_audio.dart';

/// What AcoustID / MusicBrainz say a recording is.
class Recognition {
  Recognition(this.artist, this.title, this.score);
  final String artist;
  final String title;
  final double score;
}

/// Identifies a file from its sound: Chromaprint fingerprint + AcoustID lookup.
class Recognizer {
  Recognizer(this.apiKey);

  final String apiKey;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  /// Returns the best match, null when nothing matched, or throws with a readable message.
  Future<Recognition?> identify(String path) async {
    if (apiKey.trim().isEmpty) throw const RecognizeError('Falta la clave de AcoustID (Ajustes → Reconocer temas).');
    final fp = await CsAudio.fingerprintOf(path);
    if (fp == null || fp.duration < 10) throw const RecognizeError('No se pudo escuchar el archivo para reconocerlo.');
    final body = Uri(queryParameters: {
      'client': apiKey.trim(),
      'duration': '${fp.duration}',
      'fingerprint': fp.fingerprint,
      'meta': 'recordings',
      'format': 'json',
    }).query;
    late String text;
    try {
      final req = await _http.postUrl(Uri.parse('https://api.acoustid.org/v2/lookup')).timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 20));
      text = await res.transform(utf8.decoder).join();
    } on SocketException {
      throw const RecognizeError('Sin internet: el reconocimiento consulta una base de datos online.');
    }
    final j = jsonDecode(text) as Map;
    if (j['status'] != 'ok') {
      final msg = (j['error'] as Map?)?['message'] ?? 'error';
      if ('$msg'.contains('invalid API key')) throw const RecognizeError('La clave de AcoustID no es válida.');
      throw RecognizeError('AcoustID respondió: $msg');
    }
    Recognition? best;
    for (final r in (j['results'] as List? ?? const [])) {
      final score = ((r as Map)['score'] as num?)?.toDouble() ?? 0;
      if (score < 0.5) continue;
      for (final rec in (r['recordings'] as List? ?? const [])) {
        final title = (rec as Map)['title'] as String?;
        if (title == null || title.isEmpty) continue;
        final sb = StringBuffer();
        for (final a in (rec['artists'] as List? ?? const [])) {
          sb.write((a as Map)['name'] ?? '');
          sb.write(a['joinphrase'] ?? '');
        }
        final artist = sb.toString().trim();
        if (best == null || score > best.score) best = Recognition(artist, title, score);
        break;
      }
    }
    return best;
  }
}

class RecognizeError implements Exception {
  const RecognizeError(this.message);
  final String message;
  @override
  String toString() => message;
}
