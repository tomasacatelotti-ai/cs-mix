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
  _Sort _sort = _Sort.name;

  /// Folder being browsed, relative to the library root ('/' separated). '' = everything.
  String? _dir;

  bool get _browsing => widget.initialTracks == null;
  List<Track> get _src => widget.initialTracks ?? app.library.tracks;

  /// Folders every track sits in (e.g. "BIBLIOTECA - EN USO"): browsing starts below them.
  String get _root {
    if (!_browsing || Track.sharedDepth == 0 || app.library.count == 0) return '';
    final segs = app.library.tracks.first.relPath.split('/');
    return segs.take(Track.sharedDepth).join('/');
  }

  String get _cur => _dir ?? _root;

  bool _inDir(Track t, String dir) => dir.isEmpty || t.relPath.startsWith('$dir/');

  /// Immediate subfolders of [dir] with how many tracks each holds (recursively).
  Map<String, int> _subfolders(List<Track> inDir, String dir) {
    final cut = dir.isEmpty ? 0 : dir.length + 1;
    final out = <String, int>{};
    for (final t in inDir) {
      final rest = t.relPath.substring(cut);
      final i = rest.indexOf('/');
      if (i > 0) out.update(rest.substring(0, i), (v) => v + 1, ifAbsent: () => 1);
    }
    return out;
  }

  List<String> get _words => _q.text.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  bool _matches(Track t, List<String> words) {
    if (words.isEmpty) return true;
    final hay = '${t.title} ${t.artist} ${t.fileName}'.toLowerCase();
    for (final w in words) {
      final n = double.tryParse(w);
      if (n != null && t.bpm > 0 && (t.bpm - n).abs() <= 2) continue;
      if (!hay.contains(w)) return false;
    }
    return true;
  }

  void _sortTracks(List<Track> out) {
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
  }

  void _open(String dir) => setState(() {
        _dir = dir;
        _q.clear();
      });

  void _up() {
    final cur = _cur;
    if (cur == _root) return;
    final i = cur.lastIndexOf('/');
    final parent = i < 0 ? '' : cur.substring(0, i);
    _open(parent.length < _root.length ? _root : parent);
  }

  String _name(String dir) => dir.isEmpty ? 'Toda la biblioteca' : dir.substring(dir.lastIndexOf('/') + 1);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.library,
      builder: (context, _) {
        final lib = app.library;
        final cur = _cur;
        final words = _words;
        final inDir = [for (final t in _src) if (!_browsing || _inDir(t, cur)) t];
        final subs = _browsing ? _subfolders(inDir, cur) : const <String, int>{};
        final searching = words.isNotEmpty;

        // A folder shows every track inside it (subfolders included); subfolders narrow it down.
        final tracks = [
          for (final t in inDir)
            if (_matches(t, words)) t,
        ];
        if (_browsing || _sort != _Sort.name || searching) _sortTracks(tracks);
        final folderNames = subs.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final playable = tracks;
        final items = tracks;
        final atRoot = cur == _root;

        return PopScope(
          canPop: atRoot,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _up();
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(children: [
                CsHeader(
                  title: widget.pickLabel != null
                      ? 'Cargar en ${widget.pickLabel}'
                      : (widget.title ?? (atRoot ? 'Temas' : _name(cur))),
                  subtitle: lib.scanning
                      ? 'Buscando temas…'
                      : '${playable.length} temas${folderNames.isNotEmpty ? ' · ${folderNames.length} carpetas para filtrar' : ''}'
                          '${lib.pendingAnalysis > 0 ? ' · analizando ${lib.pendingAnalysis}' : ''}',
                  onBack: () => atRoot ? Navigator.of(context).pop() : _up(),
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
                if (_browsing && !atRoot) _breadcrumb(cur),
                if (folderNames.isNotEmpty) _folderChips(folderNames, subs, cur),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: TextField(
                    controller: _q,
                    onChanged: (_) => setState(() {}),
                    style: CS.body(16),
                    decoration: InputDecoration(
                      hintText: atRoot || !_browsing ? 'Buscar tema, artista o BPM' : 'Buscar en ${_name(cur)}',
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
                if (widget.pickLabel == null && playable.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: SecondaryButton(
                      searching ? 'Reproducir resultados' : (atRoot ? 'Reproducir todo' : 'Reproducir esta carpeta'),
                      icon: Icons.play_arrow,
                      onTap: () {
                        final list = List.of(playable);
                        if (!searching) _sortTracks(list);
                        app.player.playList(list, name: widget.title ?? _name(cur));
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerScreen()));
                      },
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              lib.count == 0
                                  ? 'No hay temas en la carpeta de la biblioteca. Elegí la carpeta en Ajustes o copiá tu música ahí.'
                                  : (searching ? 'Nada coincide en ${_name(cur)}.' : 'Esta carpeta está vacía.'),
                              style: CS.body(15, color: CS.humo),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: items.length,
                          itemExtent: 64,
                          itemBuilder: (context, i) {
                            return _tile(items[i]);
                          },
                        ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  static void _noop() {}

  Widget _breadcrumb(String cur) {
    final root = _root;
    final rel = root.isEmpty ? cur : cur.substring(root.length).replaceFirst(RegExp('^/'), '');
    final segs = rel.isEmpty ? <String>[] : rel.split('/');
    final crumbs = <(String, String)>[('Todo', root)];
    for (var k = 0; k < segs.length; k++) {
      final path = [if (root.isNotEmpty) root, ...segs.take(k + 1)].join('/');
      crumbs.add((segs[k], path));
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        children: [
          for (var k = 0; k < crumbs.length; k++) ...[
            if (k > 0) const Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: Icon(Icons.chevron_right, color: CS.humo, size: 18)),
            Material(
              color: k == crumbs.length - 1 ? CS.rojo : CS.grafito,
              borderRadius: BorderRadius.circular(99),
              child: InkWell(
                borderRadius: BorderRadius.circular(99),
                onTap: k == crumbs.length - 1 ? null : () => _open(crumbs[k].$2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Text(crumbs[k].$1, style: CS.body(14, color: k == crumbs.length - 1 ? CS.blanco : CS.humo)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Subfolders of the current folder as filter chips: tapping one narrows the list to it.
  Widget _folderChips(List<String> names, Map<String, int> counts, String cur) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        children: [
          for (final n in names)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                color: CS.grafito,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99), side: const BorderSide(color: CS.linea)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: () => _open(cur.isEmpty ? n : '$cur/$n'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.folder, color: CS.ambar, size: 16),
                      const SizedBox(width: 6),
                      Text(n, style: CS.body(14)),
                      const SizedBox(width: 6),
                      Text('${counts[n] ?? 0}', style: CS.body(12, color: CS.humo)),
                    ]),
                  ),
                ),
              ),
            ),
        ],
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
                Text(t.artist.isEmpty ? _name(t.dir) : '${t.artist} · ${_name(t.dir)}',
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
