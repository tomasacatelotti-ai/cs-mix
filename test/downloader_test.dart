import 'package:cs_mix/core/downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('link from a shared text', () {
    expect(LinkDownloader.extractUrl('https://ejemplo.com/tema.mp3'), 'https://ejemplo.com/tema.mp3');
    expect(LinkDownloader.extractUrl('Mirá este tema: https://ejemplo.com/a/b.m4a?x=1.'), 'https://ejemplo.com/a/b.m4a?x=1');
    expect(LinkDownloader.extractUrl('(http://ejemplo.com/t.mp4)'), 'http://ejemplo.com/t.mp4');
    expect(LinkDownloader.extractUrl('no hay link acá'), isNull);
    expect(LinkDownloader.extractUrl('ftp://ejemplo.com/t.mp3'), isNull);
  });
}
