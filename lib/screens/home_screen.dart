import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/smart.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'dj_screen.dart';
import 'download_sheet.dart';
import 'library_screen.dart';
import 'network_screen.dart';
import 'player_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';

/// Everything Inicio shows, computed once per library change.
class _HomeData {
  _HomeData(List<Track> all, Phase phase, List<Playlist> lists) {
    final s = Smart(all);
    analyzed = s.tracks.length;
    forYou = s.forPhase(phase, n: 30);
    final recent = s.recentlyPlayed(n: 20);
    recentlyPlayed = recent;
    seed = recent.isNotEmpty ? recent.first : (forYou.isNotEmpty ? forYou.first : null);
    similar = seed == null ? [] : s.similar(seed!, n: 25);
    forgotten = s.forgotten();
    recentlyAdded = s.recentlyAdded(all);
    supermix = Smart.mixOrder(s.forPhase(phase, n: 40), n: 25);
    mixes = [
      ...s.bpmMixes().take(3),
      ...s.keyMixes(max: 3),
      ...s.artistMixes(max: 3),
      ...s.energyMixes().take(2),
      ...s.moodMixes(),
    ];
    final counts = <String, int>{};
    for (final t in all) {
      if (t.folder.isNotEmpty) counts.update(t.folder, (v) => v + 1, ifAbsent: () => 1);
    }
    genres = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    genreCounts = counts;
    shortcuts = [
      for (final p in lists.take(3)) _Shortcut(p.name, 'Playlist', () => app.library.tracksOf(p)),
      for (final g in genres.take(3)) _Shortcut(genreName(g), 'Género', () => all.where((t) => t.folder == g).toList()),
      if (mixes.isNotEmpty) _Shortcut(mixes.first.title, 'Mix', () => mixes.first.tracks),
      if (supermix.isNotEmpty) _Shortcut('Mi Supermix', 'Mix', () => supermix),
    ].take(8).toList();
  }

  late int analyzed;
  late List<Track> forYou, recentlyPlayed, similar, forgotten, recentlyAdded, supermix;
  Track? seed;
  late List<SmartMix> mixes;
  late List<String> genres;
  late Map<String, int> genreCounts;
  late List<_Shortcut> shortcuts;
}

class _Shortcut {
  _Shortcut(this.name, this.kind, this.tracks);
  final String name;
  final String kind;
  final List<Track> Function() tracks;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _phase = 0;
  _HomeData? _data;
  int _dataRev = -1;
  int _dataPhase = -1;
  final _ask = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Links shared to CS Mix from another app ("Compartir" → "Descargar en CS Mix").
    app.onSharedLink = (link) {
      if (mounted) showDownloadSheet(context, link: link);
    };
    final pending = app.takePendingLink();
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showDownloadSheet(context, link: pending);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.onSharedLink = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      app.recheckStorage();
      if (app.hasStorage) app.library.scan(app.settings.libraryRoot);
      if (app.net.host.isNotEmpty && !app.net.online) app.net.refresh();
    }
  }

  void _go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  _HomeData _homeData() {
    final lib = app.library;
    if (_data == null || _dataRev != lib.revision || _dataPhase != _phase) {
      _data = _HomeData(lib.tracks, phases[_phase], lib.allPlaylists);
      _dataRev = lib.revision;
      _dataPhase = _phase;
    }
    return _data!;
  }

  void _play(List<Track> tracks, String name) {
    if (tracks.isEmpty) return;
    app.player.playList(tracks, name: name);
    _go(const PlayerScreen());
  }

  void _open(List<Track> tracks, String title) => _go(LibraryScreen(initialTracks: tracks, title: title));

  void _askMusic(String text) {
    if (text.trim().isEmpty) return;
    final playing = app.mode == Mode.player ? app.player.current : null;
    final r = MusicRequest.parse(text, app.library.tracks, playing: playing);
    if (r.tracks.isEmpty) {
      toast(context, 'No encontré temas para "$text". Probá con un género, un BPM o "tranqui".');
      return;
    }
    _ask.clear();
    FocusScope.of(context).unfocus();
    _play(r.tracks, r.summary);
  }

  String _status() {
    if (Platform.isAndroid || Platform.isIOS) {
      if (app.net.online) return '${app.net.pcName.isEmpty ? 'PC' : app.net.pcName} · conectada';
      if (app.settings.netHost.isNotEmpty) return 'PC sin conexión · música del celular';
      return 'Música de este celular';
    }
    if (app.server.running) {
      final n = app.server.activeClients.length;
      return 'Compartiendo en la red · $n ${n == 1 ? 'celular' : 'celulares'}';
    }
    return 'Catelotti Sport';
  }

  Color _statusColor() {
    if (app.net.online || app.server.running) return const Color(0xFF4CC38A);
    if (app.settings.netHost.isNotEmpty) return CS.ambar;
    return CS.humo;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app, app.library, app.player, app.net, app.server]),
          builder: (context, _) {
            final lib = app.library;
            final d = _homeData();
            return Column(children: [
              _header(),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 20),
                      children: [
                        _chips(),
                        if (!app.hasStorage) _pad(_storageBanner()),
                        if (app.outputError != null) _pad(_warn(app.outputError!)),
                        if (lib.scanError != null) _pad(_warn(lib.scanError!)),
                        _pad(_modes()),
                        if (lib.count == 0 && !lib.scanning) _pad(_emptyLibrary()),
                        if (lib.pendingAnalysis > 0)
                          _pad(Text('Analizando BPM, tonalidad y energía: faltan ${lib.pendingAnalysis} temas.',
                              style: CS.body(13, color: CS.humo))),
                        if (d.shortcuts.isNotEmpty) ...[_title('Accesos directos'), _pad(_shortcutGrid(d))],
                        if (d.forYou.isNotEmpty) ...[
                          _title('Para vos ahora',
                              sub: 'Según lo que escuchás · ${phases[_phase].name}',
                              action: _pillButton('Reproducir todo', () => _play(d.forYou, phases[_phase].name))),
                          for (final t in d.forYou.take(4)) _pad(_trackRow(t, d.forYou)),
                        ],
                        if (d.mixes.isNotEmpty) ...[
                          _title('Mixes automáticos', sub: 'Armados solos con tu biblioteca'),
                          _mixRow(d.mixes),
                        ],
                        _title('Pedir música', sub: 'Escribí qué querés y arma la cola'),
                        _pad(_askBox()),
                        if (lib.allPlaylists.isNotEmpty) ...[
                          _title('Tus playlists', action: _pillButton('Ver todas', () => _go(const PlaylistsScreen()))),
                          _playlistRow(lib.allPlaylists),
                        ],
                        if (d.seed != null && d.similar.isNotEmpty) ...[
                          _title('Similares a ${d.seed!.title}', sub: 'Mismo género, BPM parecido y tonalidad compatible'),
                          _pad(_similarCard(d)),
                        ],
                        if (d.recentlyPlayed.isNotEmpty) ...[
                          _title('Escuchado recientemente'),
                          _trackCards(d.recentlyPlayed),
                        ],
                        if (d.forgotten.isNotEmpty) ...[
                          _title('Favoritos olvidados', sub: 'Los ponías seguido y hace semanas que no suenan'),
                          _trackCards(d.forgotten),
                        ],
                        if (d.supermix.length >= 4) ...[
                          _title('Mi Supermix', sub: 'Ordenado para mezclar: el BPM sube de a poco y las tonalidades encajan'),
                          _pad(_supermixCard(d.supermix)),
                        ],
                        if (d.recentlyAdded.isNotEmpty) ...[
                          _title('Agregados recientemente'),
                          _trackCards(d.recentlyAdded),
                        ],
                        if (d.genres.isNotEmpty) ...[
                          _title('Explorar géneros'),
                          _pad(_genreGrid(d)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (app.mode == Mode.player && app.player.current != null) _miniPlayer(),
              _nav(),
            ]);
          },
        ),
      ),
    );
  }

  Widget _pad(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: w);

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 6),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset('assets/logo.png', width: 42, height: 42, semanticLabel: 'Logo CS Mix'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: () => _go(const NetworkScreen()),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CS MIX', style: CS.cond(26)),
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: _statusColor(), shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Flexible(child: Text(_status(), style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ]),
          ),
        ),
        IconButton(
          tooltip: 'Buscar',
          icon: const Icon(Icons.search, color: CS.blanco),
          onPressed: () => _go(const LibraryScreen(autofocus: true)),
        ),
        IconButton(
          tooltip: 'Biblioteca en red',
          icon: const Icon(Icons.wifi_tethering, color: CS.blanco),
          onPressed: () => _go(const NetworkScreen()),
        ),
        IconButton(
          tooltip: 'Ajustes',
          icon: const Icon(Icons.tune, color: CS.blanco),
          onPressed: () => _go(const SettingsScreen()),
        ),
      ]),
    );
  }

  Widget _chips() {
    return SizedBox(
      height: 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        itemCount: phases.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final on = i == _phase;
          return Material(
            color: on ? CS.blanco : CS.acero,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _phase = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Text(phases[i].name, style: CS.body(14, color: on ? CS.negro : CS.blanco)),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _modes() {
    Widget card(Color color, IconData icon, String title, VoidCallback onTap) => Expanded(
          child: BarCard(
            color: color,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            onTap: onTap,
            child: Row(children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(title.toUpperCase(), style: CS.cond(19), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        );
    return Row(children: [
      card(CS.rojo, Icons.music_note, 'Reproductor', () => _go(const PlayerScreen())),
      const SizedBox(width: 10),
      card(CS.ambar, Icons.album, 'DJ en vivo', () => _go(const DjScreen())),
    ]);
  }

  Widget _title(String text, {String? sub, Widget? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (sub != null) Text(sub, style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(text.toUpperCase(), style: CS.cond(24), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 8), action],
      ]),
    );
  }

  Widget _pillButton(String text, VoidCallback onTap) => Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99), side: const BorderSide(color: CS.linea)),
        child: InkWell(
          borderRadius: BorderRadius.circular(99),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(text, style: CS.body(13)),
          ),
        ),
      );

  Widget _shortcutGrid(_HomeData d) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 560 ? 8 : 4;
      final w = (c.maxWidth - (cols - 1) * 10) / cols;
      return Wrap(spacing: 10, runSpacing: 10, children: [
        for (final s in d.shortcuts)
          SizedBox(
            width: w,
            child: InkWell(
              onTap: () => _open(s.tracks(), s.name),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _mosaic(s.tracks(), w, s.kind),
                const SizedBox(height: 4),
                Text(s.name, style: CS.body(12), maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
      ]);
    });
  }

  /// 2×2 covers of the first tracks, like YouTube Music's shortcut tiles.
  Widget _mosaic(List<Track> tracks, double size, String label) {
    final half = (size - 2) / 2;
    final ts = tracks.take(4).toList();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        if (ts.length >= 4)
          Wrap(spacing: 2, runSpacing: 2, children: [for (final t in ts) CoverArt(t, size: half, radius: 3)])
        else
          CoverArt(ts.isEmpty ? null : ts.first, size: size, radius: 8),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(4)),
            child: Text(label.toUpperCase(), style: CS.cond(11)),
          ),
        ),
      ]),
    );
  }

  Widget _trackRow(Track t, List<Track> list) {
    return InkWell(
      onTap: () => _play(list.sublist(list.indexOf(t)), phases[_phase].name),
      child: Row(children: [
        CoverArt(t, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, style: CS.body(15, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${t.subtitle} · ${genreName(t.folder)} · ${fmtBpm(t.bpm)}',
                style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        Text(camelot(t.key), style: CS.cond(18, color: CS.humo)),
      ]),
    );
  }

  Widget _mixRow(List<SmartMix> mixes) {
    const tints = [(Color(0xFF3A0D0F), Color(0xFFFF6B70)), (Color(0xFF3A2A10), CS.ambar), (Color(0xFF262626), Color(0xFFD0D0D0))];
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: mixes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final m = mixes[i];
          final tint = tints[i % tints.length];
          return SizedBox(
            width: 150,
            child: InkWell(
              onTap: () => _open(m.tracks, m.title),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 150,
                  height: 150,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: tint.$1, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.kind, style: CS.body(12, color: tint.$2)),
                    const Spacer(),
                    Text(m.big.toUpperCase(), style: CS.cond(28, color: tint.$2), maxLines: 2, overflow: TextOverflow.ellipsis),
                    Align(
                      alignment: Alignment.centerRight,
                      child: SquareButton(
                        icon: Icons.play_arrow,
                        size: 34,
                        iconSize: 20,
                        color: CS.blanco,
                        ink: CS.negro,
                        tooltip: 'Reproducir ${m.title}',
                        onTap: () => _play(m.tracks, m.title),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 6),
                Text(m.title, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(m.subtitle, style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _askBox() {
    Widget sug(String text, Color bg) => Expanded(
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _askMusic(text),
              child: Container(
                height: 72,
                padding: const EdgeInsets.all(10),
                alignment: Alignment.bottomLeft,
                child: Text(text, style: CS.body(14), maxLines: 2),
              ),
            ),
          ),
        );
    return Column(children: [
      Row(children: [
        sug('Entrada en calor de 20 minutos', CS.rojoFondo),
        const SizedBox(width: 10),
        sug('Algo con energía que mezcle con lo que suena', CS.ambarFondo),
      ]),
      const SizedBox(height: 10),
      TextField(
        controller: _ask,
        style: CS.body(15),
        textInputAction: TextInputAction.go,
        onSubmitted: _askMusic,
        decoration: InputDecoration(
          hintText: 'Ej: tech 126 para funcional, 40 min',
          prefixIcon: const Icon(Icons.auto_awesome, color: CS.humo),
          suffixIcon: IconButton(
            tooltip: 'Armar',
            icon: const Icon(Icons.arrow_forward, color: CS.blanco),
            onPressed: () => _askMusic(_ask.text),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(99)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: const BorderSide(color: CS.linea)),
        ),
      ),
    ]);
  }

  Widget _playlistRow(List<Playlist> lists) {
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: lists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final p = lists[i];
          final tracks = app.library.tracksOf(p);
          final from = p.source == null ? '' : (p.source!.startsWith('pc') ? ' · de la PC' : ' · VDJ');
          return SizedBox(
            width: 134,
            child: InkWell(
              onTap: () => _open(tracks, p.name),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Stack(children: [
                  _mosaic(tracks, 134, 'Playlist'),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: SquareButton(
                      icon: Icons.play_arrow,
                      size: 34,
                      iconSize: 20,
                      color: CS.rojo,
                      tooltip: 'Reproducir ${p.name}',
                      onTap: tracks.isEmpty ? null : () => _play(tracks, p.name),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(p.name, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${tracks.length} temas$from', style: CS.body(12, color: CS.humo), maxLines: 1),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _similarCard(_HomeData d) {
    final seed = d.seed!;
    final radio = [seed, ...d.similar];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Row(children: [
          CoverArt(seed, size: 60, radius: 8),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('RADIO ${seed.title.toUpperCase()}', style: CS.cond(20), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('Mix · ${radio.length} temas', style: CS.body(12, color: CS.humo)),
            ]),
          ),
          SquareButton(
            icon: Icons.play_arrow,
            size: 46,
            color: CS.blanco,
            ink: CS.negro,
            tooltip: 'Reproducir radio',
            onTap: () => _play(radio, 'Radio ${seed.title}'),
          ),
        ]),
        for (final t in d.similar.take(3))
          InkWell(
            onTap: () => _play([t, ...d.similar.where((x) => x != t)], 'Radio ${seed.title}'),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: CS.acero))),
              margin: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(t.subtitle, style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                Text('${fmtBpm(t.bpm)} · ${camelot(t.key)}', style: CS.body(12, color: CS.humo)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _trackCards(List<Track> list) {
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final t = list[i];
          return SizedBox(
            width: 134,
            child: InkWell(
              onTap: () => _play(list.sublist(i), t.title),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CoverArt(t, size: 134, radius: 10),
                const SizedBox(height: 6),
                Text(t.title, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(t.subtitle, style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _supermixCard(List<Track> list) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        for (var i = 0; i < list.length && i < 5; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(width: 22, child: Text('${i + 1}', style: CS.body(13, color: CS.humo))),
              CoverArt(list[i], size: 36, radius: 4),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(list[i].title, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(list[i].subtitle, style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Pill('${fmtBpm(list[i].bpm)} · ${camelot(list[i].key)}'),
            ]),
          ),
        const SizedBox(height: 6),
        PrimaryButton('Reproducir Supermix', height: 46, size: 20, onTap: () => _play(list, 'Mi Supermix')),
      ]),
    );
  }

  Widget _genreGrid(_HomeData d) {
    const accents = [Color(0xFFFF6B70), CS.ambar, Color(0xFFD0D0D0)];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 560 ? 4 : 3;
      final w = (c.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < d.genres.length; i++)
          SizedBox(
            width: w,
            height: 58,
            child: Material(
              color: CS.grafito,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _go(LibraryScreen(initialDir: d.genres[i])),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: accents[i % 3], width: 3))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(genreName(d.genres[i]).toUpperCase(), style: CS.cond(15), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${d.genreCounts[d.genres[i]]} temas', style: CS.body(11, color: CS.humo)),
                  ]),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  Widget _miniPlayer() {
    final p = app.player;
    final t = p.current!;
    return ListenableBuilder(
      listenable: app.engine,
      builder: (context, _) {
        final s = p.currentDeck;
        final prog = s.duration > 0 ? (s.position / s.duration).clamp(0.0, 1.0) : 0.0;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: () => _go(const PlayerScreen()),
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                CoverArt(t, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title, style: CS.body(14, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(p.next == null ? t.subtitle : 'Próximo: ${p.next!.title}',
                        style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                IconButton(
                  tooltip: p.playing ? 'Pausa' : 'Reproducir',
                  icon: Icon(p.playing ? Icons.pause : Icons.play_arrow, color: CS.blanco),
                  onPressed: p.togglePlay,
                ),
                IconButton(
                  tooltip: 'Pasar al próximo',
                  icon: const Icon(Icons.skip_next, color: CS.blanco),
                  onPressed: p.next == null ? null : () => p.passNow(),
                ),
              ]),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            height: 2,
            alignment: Alignment.centerLeft,
            color: CS.linea,
            child: FractionallySizedBox(widthFactor: prog, child: Container(color: CS.rojo)),
          ),
        ]);
      },
    );
  }

  Widget _emptyLibrary() {
    final phone = Platform.isAndroid;
    return BarCard(
      color: CS.ambar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Todavía no hay música', style: CS.body(16, weight: FontWeight.w600, color: CS.ambar)),
        const SizedBox(height: 4),
        Text(
          phone
              ? 'Conectate a la PC del gimnasio para usar su biblioteca, o elegí una carpeta de este celular.'
              : 'Elegí la carpeta de tu biblioteca en Ajustes.',
          style: CS.body(14, color: CS.humo),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (phone) SecondaryButton('Conectar a la PC', color: CS.ambar, onTap: () => _go(const NetworkScreen())),
          SecondaryButton('Elegir carpeta', onTap: () => _go(const SettingsScreen())),
        ]),
      ]),
    );
  }

  Widget _storageBanner() {
    return BarCard(
      color: CS.ambar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Falta el permiso para leer tu música', style: CS.body(16, weight: FontWeight.w600, color: CS.ambar)),
        const SizedBox(height: 4),
        Text('Android pide "acceso a todos los archivos" para leer la carpeta de la biblioteca y las playlists .m3u de Virtual DJ. '
            'Si usás solo la biblioteca de la PC, no hace falta.',
            style: CS.body(14, color: CS.humo)),
        const SizedBox(height: 10),
        SecondaryButton('Dar permiso', onTap: Native.requestStorageAccess, color: CS.ambar),
      ]),
    );
  }

  Widget _warn(String text) => BarCard(color: CS.ambar, child: Text(text, style: CS.body(14, color: const Color(0xFFFFD489))));

  Widget _nav() {
    Widget item(String label, IconData icon, bool on, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: on ? CS.blanco : CS.humo),
                Text(label, style: CS.body(12, color: on ? CS.blanco : CS.humo)),
              ]),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Row(children: [
        item('Inicio', Icons.home, true, () {}),
        item('Temas', Icons.library_music, false, () => _go(const LibraryScreen())),
        item('DJ', Icons.album, false, () => _go(const DjScreen())),
        item('Listas', Icons.queue_music, false, () => _go(const PlaylistsScreen())),
      ]),
    );
  }
}

