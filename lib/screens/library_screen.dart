import 'package:flutter/material.dart';

import '../core/models.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

enum _Sort { name, bpm, folder, recent }

/// Library browser. With [pickLabel] it returns the tapped track instead.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.pickLabel, this.initialTracks, this.title});

  final String? pickLabel;
  final List<Track>? initialTracks;
  final String? title;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _q = TextEditingController();
  String _folder = '';
  _Sort _sort = _Sort.name;

  List<Track> _filtered() {
    final src = widget.initialTracks ?? app.library.tracks;
    final q = _q.text.trim().toLowerCase();
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = src.where((t) {
      if (_folder.isNotEmpty && t.folder != _folder) return false;
      if (words.isEmpty) return true;
      final hay = '${t.title} ${t.artist} ${t.relPath}'.toLowerCase();
      for (final w in words) {
        final n = double.tryParse(w);
        if (n != null && t.bpm > 0 && (t.bpm - n).abs() <= 2) continue;
        if (!hay.contains(w)) return false;
      }
      return true;
    }).toList();
    switch (_sort) {
      case _Sort.name:
        out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _Sort.bpm:
        out.sort((a, b) => (a.bpm <= 0 ? 999 : a.bpm).compareTo(b.bpm <= 0 ? 999 : b.bpm));
      case _Sort.folder:
        out.sort((a, b) => a.relPath.toLowerCase().compareTo(b.relPath.toLowerCase()));
      case _Sort.recent:
        out.sort((a, b) => b.mtime.compareTo(a.mtime));
    }
    if (widget.initialTracks != null && _sort == _Sort.name && words.isEmpty && _folder.isEmpty) {
      return List.of(widget.initialTracks!);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialTracks != null) _sort = _Sort.name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app.library,
          builder: (context, _) {
            final lib = app.library;
            final list = _filtered();
            final folders = widget.initialTracks == null ? lib.folders : const <String>[];
            return Column(children: [
              CsHeader(
                title: widget.pickLabel != null ? 'Cargar en ${widget.pickLabel}' : (widget.title ?? 'Temas'),
                subtitle: lib.scanning
                    ? 'Buscando temas…'
                    : '${list.length} de ${widget.initialTracks?.length ?? lib.count} temas'
                        '${lib.pendingAnalysis > 0 ? ' · analizando ${lib.pendingAnalysis}' : ''}',
                onBack: () => Navigator.of(context).pop(),
                trailing: [
                  PopupMenuButton<_Sort>(
                    tooltip: 'Ordenar',
                    color: CS.grafito,
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: _Sort.name, child: Text('Nombre')),
                      PopupMenuItem(value: _Sort.bpm, child: Text('BPM')),
                      PopupMenuItem(value: _Sort.folder, child: Text('Carpeta')),
                      PopupMenuItem(value: _Sort.recent, child: Text('Agregados recientemente')),
                    ],
                    child: const IgnorePointer(child: IconBox(icon: Icons.sort, onTap: _noop)),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: TextField(
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  style: CS.body(16),
                  decoration: InputDecoration(
                    hintText: 'Buscar tema, artista, carpeta o BPM',
                    prefixIcon: const Icon(Icons.search, color: CS.humo),
                    suffixIcon: _q.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar',
                            icon: const Icon(Icons.close, color: CS.humo),
                            onPressed: () => setState(_q.clear),
                          ),
                  ),
                ),
              ),
              if (folders.isNotEmpty)
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    children: [
                      _chip('Todo', ''),
                      for (final f in folders) _chip(f, f),
                    ],
                  ),
                ),
              if (widget.pickLabel == null && list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Row(children: [
                    Expanded(
                      child: SecondaryButton('Reproducir todo', icon: Icons.play_arrow, onTap: () {
                        app.player.playList(list, name: _folder.isEmpty ? (widget.title ?? 'Biblioteca') : _folder);
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerScreen()));
                      }),
                    ),
                  ]),
                ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            lib.count == 0
                                ? 'No hay temas en la carpeta de la biblioteca. Elegí la carpeta en Ajustes o copiá tu música ahí.'
                                : 'Nada coincide con la búsqueda.',
                            style: CS.body(15, color: CS.humo),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemExtent: 64,
                        itemBuilder: (context, i) => _tile(list[i]),
                      ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  static void _noop() {}

  Widget _chip(String label, String value) {
    final on = _folder == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? CS.rojo : CS.grafito,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          borderRadius: BorderRadius.circular(99),
          onTap: () => setState(() => _folder = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(label, style: CS.body(14, color: on ? CS.blanco : CS.humo)),
          ),
        ),
      ),
    );
  }

  Widget _tile(Track t) {
    return InkWell(
      onTap: () {
        if (widget.pickLabel != null) {
          Navigator.of(context).pop(t);
        } else {
          _actions(t);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
        child: Row(children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: CS.body(15, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(t.artist.isEmpty ? t.folder : '${t.artist} · ${t.folder}',
                    style: CS.body(13, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(t.failed ? 'Error' : fmtBpm(t.bpm), style: CS.cond(20, color: t.failed ? const Color(0xFFFF8A8F) : CS.blanco)),
              Text(t.duration > 0 ? fmtTime(t.duration) : '', style: CS.body(12, color: CS.humo)),
            ],
          ),
        ]),
      ),
    );
  }

  void _actions(Track t) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(IconData icon, String label, VoidCallback onTap) => ListTile(
              leading: Icon(icon, color: CS.blanco),
              title: Text(label, style: CS.body(16)),
              onTap: () {
                Navigator.of(ctx).pop();
                onTap();
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(t.title, style: CS.body(16, weight: FontWeight.w600), maxLines: 2),
            ),
            item(Icons.play_arrow, 'Reproducir ahora', () {
              app.player.playNow(t);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerScreen()));
            }),
            item(Icons.playlist_play, 'Que suene después', () {
              app.player.playAfterCurrent(t);
              toast(context, 'Va a sonar después del tema actual.');
            }),
            item(Icons.queue, 'Agregar al final de la cola', () {
              app.player.enqueue(t);
              toast(context, 'Agregado a la cola.');
            }),
            item(Icons.playlist_add, 'Agregar a una playlist', () => addToPlaylist(context, [t])),
            if (t.failed)
              item(Icons.refresh, 'Analizar de nuevo', () {
                t.failed = false;
                app.library.analyzeNow(t);
              }),
          ]),
        );
      },
    );
  }
}

/// Picks (or creates) a playlist and adds [tracks] to it.
Future<void> addToPlaylist(BuildContext context, List<Track> tracks) async {
  final lib = app.library;
  final ctrl = TextEditingController();
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: SectionTitle('Agregar a playlist')),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
            child: ListView(shrinkWrap: true, children: [
              for (final p in lib.playlists)
                ListTile(
                  title: Text(p.name, style: CS.body(16)),
                  subtitle: Text('${p.paths.length} temas', style: CS.body(13, color: CS.humo)),
                  onTap: () => Navigator.of(ctx).pop(p),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(children: [
              Expanded(
                child: TextField(controller: ctrl, style: CS.body(16), decoration: const InputDecoration(hintText: 'Nueva playlist')),
              ),
              const SizedBox(width: 8),
              SecondaryButton('Crear', onTap: () {
                if (ctrl.text.trim().isNotEmpty) Navigator.of(ctx).pop(ctrl.text.trim());
              }),
            ]),
          ),
        ]),
      ),
    ),
  );
  if (choice == null) return;
  final p = choice is Playlist ? choice : lib.newPlaylist(choice as String);
  for (final t in tracks) {
    if (!p.paths.contains(t.path)) p.paths.add(t.path);
  }
  lib.changed();
  if (context.mounted) toast(context, 'Agregado a "${p.name}".');
}
