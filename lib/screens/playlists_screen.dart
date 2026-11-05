import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/vdj.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'library_screen.dart';
import 'player_screen.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  List<File> _vdj = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _findVdj();
  }

  Future<void> _findVdj() async {
    final f = await Vdj.findPlaylists(app.settings.libraryRoot);
    if (mounted) setState(() => _vdj = f);
  }

  Future<void> _import(File f) async {
    setState(() => _busy = true);
    try {
      final r = await Vdj.import(f, app.library, app.settings.pcRoot);
      final lib = app.library;
      final existing = lib.playlists.where((p) => p.source == f.path).firstOrNull;
      if (existing != null) {
        existing.paths
          ..clear()
          ..addAll(r.matched.map((t) => t.path));
        lib.changed();
      } else {
        lib.newPlaylist(r.name, paths: r.matched.map((t) => t.path).toList(), source: f.path);
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(r.name.toUpperCase(), style: CS.cond(24)),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r.matched.length} temas encontrados en tu biblioteca.', style: CS.body(15)),
              if (r.missing.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('${r.missing.length} no están en esta carpeta:', style: CS.body(15, color: CS.ambar)),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(shrinkWrap: true, children: [
                    for (final m in r.missing)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(m.fileName, style: CS.body(13, color: CS.humo)),
                      ),
                  ]),
                ),
              ],
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Listo'))],
        ),
      );
    } catch (e) {
      if (mounted) toast(context, 'No se pudo importar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(Playlist p) async {
    try {
      final f = await Vdj.export(p, app.library, app.settings.libraryRoot, app.settings.pcRoot);
      if (mounted) toast(context, 'Guardada como ${f.path.split(Platform.pathSeparator).last} en la carpeta de la biblioteca.');
      _findVdj();
    } catch (e) {
      if (mounted) toast(context, 'No se pudo exportar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app.library,
          builder: (context, _) {
            final lib = app.library;
            return Column(children: [
              CsHeader(
                title: 'Listas',
                subtitle: '${lib.playlists.length} playlists',
                onBack: () => goHome(context),
                trailing: [IconBox(icon: Icons.add, tooltip: 'Nueva playlist', onTap: _create)],
              ),
              if (_busy) const LinearProgressIndicator(color: CS.rojo, backgroundColor: CS.acero),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 20), children: [
                      const SectionTitle('Mis playlists', size: 22),
                      const SizedBox(height: 4),
                      if (lib.playlists.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text('Todavía no hay. Importá las de Virtual DJ o creá una nueva.', style: CS.body(15, color: CS.humo)),
                        ),
                      for (final p in lib.playlists) _playlistRow(p),
                      if (lib.remotePlaylists.isNotEmpty) ...[
                        const SizedBox(height: 26),
                        SectionTitle('Playlists de la PC', size: 22, trailing: Text('${lib.remotePlaylists.length}', style: CS.body(14, color: CS.humo))),
                        const SizedBox(height: 4),
                        for (final p in lib.remotePlaylists) _remoteRow(p),
                      ],
                      if (app.settings.wishlist.isNotEmpty) ...[
                        const SizedBox(height: 26),
                        const SectionTitle('Para conseguir', size: 22),
                        const SizedBox(height: 4),
                        Text('Lo que buscaste y no estaba en la biblioteca.', style: CS.body(14, color: CS.humo)),
                        for (final w in List.of(app.settings.wishlist)) _wishRow(w),
                      ],
                      const SizedBox(height: 26),
                      SectionTitle('Playlists de Virtual DJ', size: 22, trailing: IconBox(icon: Icons.refresh, tooltip: 'Buscar de nuevo', onTap: _findVdj)),
                      const SizedBox(height: 4),
                      Text('Archivos .m3u en la carpeta de la biblioteca.', style: CS.body(14, color: CS.humo)),
                      const SizedBox(height: 6),
                      if (_vdj.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text('No se encontraron .m3u en ${app.settings.libraryRoot}', style: CS.body(14, color: CS.humo)),
                        ),
                      for (final f in _vdj) _vdjRow(f),
                    ]),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _playlistRow(Playlist p) {
    final tracks = app.library.tracksOf(p);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: () => openScreen(context, LibraryScreen(initialTracks: tracks, title: p.name)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: CS.body(16, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('${tracks.length} temas${p.source != null ? ' · de Virtual DJ' : ''}', style: CS.body(13, color: CS.humo)),
            ]),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Opciones',
          color: CS.grafito,
          icon: const Icon(Icons.more_vert, color: CS.humo),
          onSelected: (v) async {
            switch (v) {
              case 'export':
                await _export(p);
              case 'rename':
                await _rename(p);
              case 'delete':
                app.library.deletePlaylist(p);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'export', child: Text('Exportar a Virtual DJ (.m3u)')),
            PopupMenuItem(value: 'rename', child: Text('Cambiar nombre')),
            PopupMenuItem(value: 'delete', child: Text('Borrar')),
          ],
        ),
        SquareButton(
          icon: Icons.play_arrow,
          size: 46,
          color: CS.rojo,
          iconSize: 22,
          tooltip: 'Reproducir',
          onTap: tracks.isEmpty
              ? null
              : () {
                  app.player.playList(tracks, name: p.name);
                  openScreen(context, const PlayerScreen());
                },
        ),
      ]),
    );
  }

  Widget _remoteRow(Playlist p) {
    final tracks = app.library.tracksOf(p);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: () => openScreen(context, LibraryScreen(initialTracks: tracks, title: p.name)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: CS.body(16, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('${tracks.length} temas · de ${app.net.pcName.isEmpty ? 'la PC' : app.net.pcName}', style: CS.body(13, color: CS.humo)),
            ]),
          ),
        ),
        SquareButton(
          icon: Icons.play_arrow,
          size: 46,
          color: CS.rojo,
          iconSize: 22,
          tooltip: 'Reproducir',
          onTap: tracks.isEmpty
              ? null
              : () {
                  app.player.playList(tracks, name: p.name);
                  openScreen(context, const PlayerScreen());
                },
        ),
      ]),
    );
  }

  Widget _wishRow(String w) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        const Icon(Icons.bookmark_border, color: CS.ambar),
        const SizedBox(width: 10),
        Expanded(child: Text(w, style: CS.body(15))),
        IconButton(
          tooltip: 'Buscar de nuevo',
          icon: const Icon(Icons.search, color: CS.blanco),
          onPressed: () => openScreen(context, LibraryScreen(autofocus: false, initialQuery: w)),
        ),
        IconButton(
          tooltip: 'Quitar',
          icon: const Icon(Icons.close, color: CS.humo),
          onPressed: () {
            app.settings.wishlist.remove(w);
            app.saveSettings();
            setState(() {});
          },
        ),
      ]),
    );
  }

  Widget _vdjRow(File f) {
    final imported = app.library.playlists.any((p) => p.source == f.path);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        Expanded(child: Text(Vdj.nameOf(f), style: CS.body(15), maxLines: 2)),
        const SizedBox(width: 10),
        SecondaryButton(imported ? 'Actualizar' : 'Importar', onTap: _busy ? null : () => _import(f)),
      ]),
    );
  }

  Future<String?> _askName(String title, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title.toUpperCase(), style: CS.cond(24)),
        content: TextField(controller: c, autofocus: true, style: CS.body(16)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(c.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final name = await _askName('Nueva playlist', '');
    if (name == null || name.isEmpty) return;
    app.library.newPlaylist(name);
  }

  Future<void> _rename(Playlist p) async {
    final name = await _askName('Cambiar nombre', p.name);
    if (name == null || name.isEmpty) return;
    p.name = name;
    app.library.changed();
  }
}
