import 'dart:math';

import 'models.dart';

/// A playlist built automatically from the library.
class SmartMix {
  SmartMix({required this.id, required this.title, required this.subtitle, required this.kind, required this.big, required this.tracks});

  final String id;
  final String title;
  final String subtitle;

  /// "Por BPM", "Por tonalidad"…
  final String kind;

  /// Short label drawn large on the card ("90–100", "8A").
  final String big;
  final List<Track> tracks;
}

/// Class phases used as filters on Inicio.
class Phase {
  const Phase(this.name, {this.minE = 0, this.maxE = 1, this.minBpm = 0, this.maxBpm = 999, this.moods});

  final String name;
  final double minE, maxE, minBpm, maxBpm;
  final Set<String>? moods;

  bool fits(Track t) {
    if (!t.analyzed) return false;
    if (t.energy < minE || t.energy > maxE) return false;
    final b = t.bpm;
    if (b > 0 && (minBpm > 0 || maxBpm < 999)) {
      // Half/double time counts: 64 BPM fits a 128 spinning class.
      final ok = [b, b * 2, b / 2].any((x) => x >= minBpm && x <= maxBpm);
      if (!ok) return false;
    }
    if (moods != null && !moods!.contains(t.mood)) return false;
    return true;
  }
}

const phases = [
  Phase('Para la sala', minE: 0.45),
  Phase('Entrada en calor', minE: 0.3, maxE: 0.65, maxBpm: 125),
  Phase('Funcional', minE: 0.6),
  Phase('Spinning', minE: 0.55, minBpm: 118, maxBpm: 140),
  Phase('Previa', minE: 0.5, moods: {'Festivo', 'Enérgico'}),
  Phase('Vuelta a la calma', maxE: 0.5, maxBpm: 112),
];

class Smart {
  Smart(List<Track> all, {Random? random})
      : tracks = all.where((t) => t.analyzed).toList(),
        _rnd = random ?? Random(DateTime.now().day);

  final List<Track> tracks;
  final Random _rnd;

  static String mainArtist(Track t) {
    final a = t.artist.split(RegExp(r',|&| x | X | feat\.? | ft\.? | y ', caseSensitive: false)).first.trim();
    return a;
  }

  /// Distance between two tracks: tempo (half/double aware), key, energy, folder, brightness.
  static double distance(Track a, Track b) {
    double bpm = 1.5;
    if (a.bpm > 0 && b.bpm > 0) {
      bpm = [b.bpm, b.bpm * 2, b.bpm / 2].map((x) => (a.bpm - x).abs()).reduce(min) / 8;
    }
    final key = keyDistance(a.key, b.key) * 0.45;
    final en = (a.energy - b.energy).abs() * 2.5;
    final folder = a.folder == b.folder ? 0.0 : 0.8;
    final bright = (a.brightness - b.brightness).abs() * 2;
    final mood = a.mood == b.mood ? 0.0 : 0.3;
    return bpm + key + en + folder + bright + mood;
  }

  List<Track> similar(Track seed, {int n = 25, Iterable<Track>? from}) {
    final pool = (from ?? tracks).where((t) => t.path != seed.path).toList();
    pool.sort((x, y) => distance(seed, x).compareTo(distance(seed, y)));
    return pool.take(n).toList();
  }

  List<Track> recentlyPlayed({int n = 20}) {
    final l = tracks.where((t) => t.lastPlayed > 0).toList()..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    return l.take(n).toList();
  }

  List<Track> mostPlayed({int n = 25}) {
    final l = tracks.where((t) => t.plays > 0).toList()..sort((a, b) => b.plays.compareTo(a.plays));
    return l.take(n).toList();
  }

  List<Track> forgotten({int n = 20}) {
    final cut = DateTime.now().subtract(const Duration(days: 21)).millisecondsSinceEpoch;
    final l = tracks.where((t) => t.plays >= 3 && t.lastPlayed > 0 && t.lastPlayed < cut).toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    return l.take(n).toList();
  }

  List<Track> recentlyAdded(List<Track> all, {int n = 20}) {
    final l = List.of(all)..sort((a, b) => b.mtime.compareTo(a.mtime));
    return l.take(n).toList();
  }

  /// Tracks for a class phase, closest first to what has been playing lately.
  List<Track> forPhase(Phase p, {int n = 30}) {
    final pool = tracks.where(p.fits).toList();
    final recent = recentlyPlayed(n: 5);
    final hourAgo = DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    double score(Track t) {
      var s = _rnd.nextDouble() * 0.8;
      if (recent.isNotEmpty) s += recent.map((r) => distance(r, t)).reduce(min) * 0.5;
      s -= min(t.plays, 20) * 0.03;
      s += t.skips * 0.15;
      if (t.lastPlayed > hourAgo) s += 3; // just heard
      return s;
    }

    final scored = {for (final t in pool) t: score(t)};
    pool.sort((a, b) => scored[a]!.compareTo(scored[b]!));
    return pool.take(n).toList();
  }

  /// Orders tracks so they mix well: tempo climbing in small steps, keys that fit.
  static List<Track> mixOrder(List<Track> list, {int? n}) {
    final pool = List.of(list.where((t) => t.bpm > 0));
    if (pool.isEmpty) return List.of(list);
    pool.sort((a, b) => (a.energy + a.bpm / 400).compareTo(b.energy + b.bpm / 400));
    final out = <Track>[pool.removeAt(0)];
    final limit = n ?? list.length;
    while (pool.isNotEmpty && out.length < limit) {
      final cur = out.last;
      Track? best;
      var bestCost = double.infinity;
      for (final t in pool) {
        final step = t.bpm - cur.bpm;
        final tempo = step >= -1 && step <= 4 ? step.abs() * 0.1 : step.abs() * 0.4;
        final cost = tempo + keyDistance(cur.key, t.key) * 0.6 + (t.energy - cur.energy).abs();
        if (cost < bestCost) {
          bestCost = cost;
          best = t;
        }
      }
      out.add(best!);
      pool.remove(best);
    }
    return out;
  }

  List<SmartMix> bpmMixes() {
    const ranges = [(0, 90), (90, 100), (100, 110), (110, 120), (120, 128), (128, 135), (135, 999)];
    final out = <SmartMix>[];
    for (final (lo, hi) in ranges) {
      final l = tracks.where((t) => t.bpm >= lo && t.bpm < hi).toList();
      if (l.length < 6) continue;
      final big = hi == 999 ? '$lo+' : (lo == 0 ? '−$hi' : '$lo–$hi');
      out.add(SmartMix(
        id: 'bpm-$lo',
        title: 'Mix $big BPM',
        subtitle: '${l.length} temas · ${_topFolders(l)}',
        kind: 'Por BPM',
        big: big,
        tracks: mixOrder(l, n: 60),
      ));
    }
    return out;
  }

  List<SmartMix> keyMixes({int max = 6}) {
    final byCam = <String, List<Track>>{};
    for (final t in tracks) {
      if (t.key < 0) continue;
      byCam.putIfAbsent(camelot(t.key), () => []).add(t);
    }
    final keys = byCam.keys.toList()..sort((a, b) => byCam[b]!.length.compareTo(byCam[a]!.length));
    final out = <SmartMix>[];
    for (final k in keys.take(max)) {
      final seed = byCam[k]!.first.key;
      final l = tracks.where((t) => t.key >= 0 && keyDistance(seed, t.key) <= 1).toList();
      if (l.length < 6) continue;
      out.add(SmartMix(
        id: 'key-$k',
        title: 'Mix en $k',
        subtitle: 'Tonalidades que mezclan sin chocar',
        kind: 'Por tonalidad',
        big: k,
        tracks: mixOrder(l, n: 60),
      ));
    }
    return out;
  }

  List<SmartMix> artistMixes({int max = 8}) {
    final by = <String, List<Track>>{};
    for (final t in tracks) {
      final a = mainArtist(t);
      if (a.isEmpty) continue;
      by.putIfAbsent(a.toLowerCase(), () => []).add(t);
    }
    final names = by.keys.where((k) => by[k]!.length >= 4).toList()
      ..sort((a, b) => by[b]!.length.compareTo(by[a]!.length));
    return [
      for (final k in names.take(max))
        SmartMix(
          id: 'art-$k',
          title: 'Todo ${mainArtist(by[k]!.first)}',
          subtitle: '${by[k]!.length} temas',
          kind: 'Por artista',
          big: mainArtist(by[k]!.first),
          tracks: by[k]!,
        ),
    ];
  }

  List<SmartMix> moodMixes() {
    final out = <SmartMix>[];
    for (final m in moods) {
      final l = tracks.where((t) => t.mood == m).toList();
      if (l.length < 6) continue;
      out.add(SmartMix(id: 'mood-$m', title: m, subtitle: '${l.length} temas', kind: 'Por ánimo', big: m, tracks: mixOrder(l, n: 60)));
    }
    return out;
  }

  List<SmartMix> energyMixes() {
    final defs = [('Pico', 0.7, 1.01, 'Para el bloque principal'), ('Media', 0.45, 0.7, 'Ritmo sostenido'), ('Suave', 0.0, 0.45, 'Para bajar')];
    final out = <SmartMix>[];
    for (final (name, lo, hi, sub) in defs) {
      final l = tracks.where((t) => t.energy >= lo && t.energy < hi).toList();
      if (l.length < 6) continue;
      out.add(SmartMix(id: 'en-$name', title: 'Energía ${name.toLowerCase()}', subtitle: sub, kind: 'Por energía', big: name, tracks: mixOrder(l, n: 60)));
    }
    return out;
  }

  String _topFolders(List<Track> l) {
    final c = <String, int>{};
    for (final t in l) {
      if (t.folder.isNotEmpty) c.update(_genreName(t.folder), (v) => v + 1, ifAbsent: () => 1);
    }
    final k = c.keys.toList()..sort((a, b) => c[b]!.compareTo(c[a]!));
    return k.take(2).join(' y ');
  }

  /// "REGUETON - TOMI" → "Reguetón"-ish display name.
  static String _genreName(String folder) => genreName(folder);
}

String genreName(String folder) {
  var s = folder.replaceAll(RegExp(r'\s*-\s*TOMI\s*$', caseSensitive: false), '').trim();
  if (s.isEmpty) s = folder;
  final lower = s.toLowerCase();
  return lower.isEmpty ? s : lower[0].toUpperCase() + lower.substring(1);
}

/// "Pedir música" without internet: reads genre, BPM, energy words and minutes.
class MusicRequest {
  MusicRequest({required this.tracks, required this.summary});

  final List<Track> tracks;
  final String summary;

  static MusicRequest parse(String text, List<Track> all, {Track? playing}) {
    final q = text.toLowerCase();
    final smart = Smart(all);
    var pool = smart.tracks;
    final parts = <String>[];

    // Genre: any library folder named in the text.
    final folders = <String>{for (final t in pool) t.folder}..remove('');
    final hit = folders.where((f) {
      final g = genreName(f).toLowerCase().replaceAll('ó', 'o').replaceAll('é', 'e');
      final qq = q.replaceAll('ó', 'o').replaceAll('é', 'e');
      return g.length >= 3 && qq.contains(g);
    }).toSet();
    if (hit.isNotEmpty) {
      pool = pool.where((t) => hit.contains(t.folder)).toList();
      parts.add(hit.map(genreName).join(', '));
    }

    // Mood words.
    for (final m in moods) {
      if (q.contains(m.toLowerCase().substring(0, 5))) {
        pool = pool.where((t) => t.mood == m).toList();
        parts.add(m.toLowerCase());
      }
    }

    // Phase / energy words.
    if (RegExp(r'calent|calor|arranque').hasMatch(q)) {
      pool = pool.where(phases[1].fits).toList();
      parts.add('para entrar en calor');
    } else if (RegExp(r'calma|bajar|elonga|estira|relaj|tranqu|lento').hasMatch(q)) {
      pool = pool.where((t) => t.energy < 0.5).toList();
      parts.add('tranquilo');
    } else if (RegExp(r'arriba|pico|fuerte|intens|energ|spinning|funcional|hiit').hasMatch(q)) {
      pool = pool.where((t) => t.energy >= 0.6).toList();
      parts.add('con energía');
    }

    // BPM: a number between 60 and 200 that isn't minutes.
    final bpmM = RegExp(r'(\d{2,3})\s*(bpm)?(?!\s*min)').allMatches(q);
    for (final m in bpmM) {
      final v = int.parse(m.group(1)!);
      if (v >= 60 && v <= 200) {
        pool = pool.where((t) => t.bpm > 0 && [t.bpm, t.bpm * 2, t.bpm / 2].any((x) => (x - v).abs() <= 4)).toList();
        parts.add('cerca de $v BPM');
        break;
      }
    }

    // Mixes with what is playing.
    if (playing != null && RegExp(r'mezcl|compatib|suena|sonando').hasMatch(q)) {
      pool = pool.where((t) => keyDistance(playing.key, t.key) <= 1 && t.path != playing.path).toList();
      parts.add('que mezcla con ${playing.title}');
    }

    // Length: "20 min", "una hora".
    double? minutes;
    final minM = RegExp(r'(\d{1,3})\s*min').firstMatch(q);
    if (minM != null) minutes = double.parse(minM.group(1)!);
    if (q.contains('una hora')) minutes = 60;

    var ordered = Smart.mixOrder(pool);
    if (minutes != null) {
      final out = <Track>[];
      var total = 0.0;
      for (final t in ordered) {
        if (total >= minutes * 60) break;
        out.add(t);
        total += t.duration > 0 ? t.duration : 200;
      }
      ordered = out;
      parts.add('${minutes.round()} min');
    } else if (ordered.length > 60) {
      ordered = ordered.take(60).toList();
    }
    final summary = parts.isEmpty ? 'Selección de tu biblioteca' : parts.join(' · ');
    return MusicRequest(tracks: ordered, summary: summary[0].toUpperCase() + summary.substring(1));
  }
}
