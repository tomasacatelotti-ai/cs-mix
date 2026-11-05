import 'package:cs_mix/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Camelot codes', () {
    expect(camelot(0), '8B'); // C
    expect(camelot(21), '8A'); // Am
    expect(camelot(7), '9B'); // G
    expect(camelot(23), '10A'); // Bm
    expect(keyDistance(0, 21), 1); // relative
    expect(keyDistance(0, 7), 1); // fifth
    expect(keyDistance(0, 0), 0);
    expect(keyDistance(0, 6) >= 2, true);
  });

  test('names from files', () {
    final n = Track.parseName('Bad Bunny - Baile Inolvidable.mp3');
    expect(n.artist, 'Bad Bunny');
    expect(n.title, 'Baile Inolvidable');
  });
}
