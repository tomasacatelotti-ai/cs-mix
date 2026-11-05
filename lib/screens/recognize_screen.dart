import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/recognize.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum _St { pending, working, found, none, error }

class _Row {
  _Row(this.track);
  final Track track;
  _St st = _St.pending;
  Recognition? hit;
  String? error;
}

/// Finds tracks with poor names and fixes them by their sound (the file is never renamed).
class RecognizeScreen extends StatefulWidget {
  const RecognizeScreen({super.key, this.only});

  /// Open for a single track (from the track menu).
  final Track? only;

  @override
  State<RecognizeScreen> createState() => _RecognizeScreenState();
}

class _RecognizeScreenState extends State<RecognizeScreen> {
  late final _key = TextEditingController(text: app.settings.acoustidKey);
  late List<_Row> _rows;
  bool _running = false;
  bool _stop = false;

  @override
  void initState() {
    super.initState();
    final list = widget.only != null
        ? [widget.only!]
        : app.library.localTracks.where((t) => !t.fixedName && LibraryStore.looksMisnamed(t)).toList();
    _rows = [for (final t in list) _Row(t)];
  }

  Future<void> _identify(_Row r) async {
    setState(() => r.st = _St.working);
    try {
      var path = r.track.path;
      if (r.track.remote) {
        final local = await app.net.fetch(r.track);
        if (local == null) throw const RecognizeError('No se pudo bajar el tema de la PC.');
        path = local;
      }
      final hit = await Recognizer(app.settings.acoustidKey).identify(path);
      r.hit = hit;
      r.st = hit == null ? _St.none : _St.found;
    } on RecognizeError catch (e) {
      r.st = _St.error;
      r.error = e.message;
    } catch (e) {
      r.st = _St.error;
      r.error = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _all() async {
    setState(() {
      _running = true;
      _stop = false;
    });
    for (final r in _rows) {
      if (_stop || !mounted) break;
      if (r.st == _St.found) continue;
      await _identify(r);
      if (r.st == _St.error && (r.error ?? '').contains('clave')) break;
      await Future<void>.delayed(const Duration(milliseconds: 400)); // AcoustID allows 3 per second
    }
    if (mounted) setState(() => _running = false);
  }

  void _accept(_Row r, String artist, String title) {
    r.track
      ..artist = artist
      ..title = title
      ..fixedName = true;
    app.library.changed();
    setState(() => _rows.remove(r));
  }

  Future<void> _edit(_Row r) async {
    final a = TextEditingController(text: r.hit?.artist ?? r.track.artist);
    final t = TextEditingController(text: r.hit?.title ?? r.track.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('CORREGIR NOMBRE', style: CS.cond(24)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, style: CS.body(16), decoration: const InputDecoration(labelText: 'Artista')),
          const SizedBox(height: 10),
          TextField(controller: t, style: CS.body(16), decoration: const InputDecoration(labelText: 'Título')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true && t.text.trim().isNotEmpty) _accept(r, a.text.trim(), t.text.trim());
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = app.settings.acoustidKey.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          CsHeader(
            title: 'Reconocer temas',
            subtitle: widget.only != null ? widget.only!.fileName : '${_rows.length} temas con nombre dudoso',
            onBack: () => widget.only != null ? Navigator.of(context).pop() : goHome(context),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (!hasKey) _keyCard() else _keyRow(),
                  const SizedBox(height: 12),
                  Text(
                    'Se reconoce por el sonido (huella acústica) y se corrige el nombre solo dentro de CS Mix: '
                    'el archivo no se renombra, así tus playlists de Virtual DJ siguen funcionando.',
                    style: CS.body(13, color: CS.humo),
                  ),
                  const SizedBox(height: 12),
                  if (widget.only == null && _rows.isNotEmpty)
                    PrimaryButton(
                      _running ? 'Detener' : 'Reconocer todos',
                      height: 50,
                      size: 20,
                      onTap: !hasKey ? null : (_running ? () => setState(() => _stop = true) : _all),
                    ),
                  if (_rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text('No hay temas con nombre dudoso.', style: CS.body(15, color: CS.humo)),
                    ),
                  const SizedBox(height: 8),
                  for (final r in List.of(_rows)) _rowWidget(r, hasKey),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _keyCard() {
    return BarCard(
      color: CS.ambar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Falta la clave gratuita de AcoustID', style: CS.body(16, weight: FontWeight.w600, color: CS.ambar)),
        const SizedBox(height: 6),
        Text(
          '1. Entrá a acoustid.org y tocá "Sign in" (se usa una cuenta de MusicBrainz, gratis).\n'
          '2. Andá a "Applications" → "Register a new application". Nombre: CS Mix. Versión: 1.\n'
          '3. Copiá la "API key" que te da y pegala acá abajo.',
          style: CS.body(14, color: CS.humo).copyWith(height: 1.5),
        ),
        const SizedBox(height: 8),
        SecondaryButton('Abrir acoustid.org', icon: Icons.open_in_new, onTap: () {
          launchUrl(Uri.parse('https://acoustid.org/new-application'), mode: LaunchMode.externalApplication);
        }),
        const SizedBox(height: 10),
        _keyField(),
        const SizedBox(height: 6),
        Text('AcoustID es gratis para uso no comercial y tiene planes pagos para empresas.', style: CS.body(12, color: CS.humo)),
      ]),
    );
  }

  Widget _keyRow() => Row(children: [
        const Icon(Icons.key, color: CS.humo, size: 18),
        const SizedBox(width: 8),
        Expanded(child: _keyField()),
      ]);

  Widget _keyField() => TextField(
        controller: _key,
        style: CS.body(15),
        decoration: const InputDecoration(hintText: 'Clave de AcoustID (API key)'),
        onChanged: (v) {
          app.settings.acoustidKey = v.trim();
          app.saveSettings();
        },
        onSubmitted: (_) => setState(() {}),
        onEditingComplete: () => setState(() {}),
      );

  Widget _rowWidget(_Row r, bool hasKey) {
    final t = r.track;
    Widget status;
    switch (r.st) {
      case _St.pending:
        status = Text('Sin revisar', style: CS.body(13, color: CS.humo));
      case _St.working:
        status = Row(children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: CS.rojo)),
          const SizedBox(width: 8),
          Text('Escuchando y buscando…', style: CS.body(13, color: CS.humo)),
        ]);
      case _St.found:
        status = Text.rich(TextSpan(style: CS.body(14), children: [
          const TextSpan(text: 'Es: '),
          TextSpan(text: '${r.hit!.artist} – ${r.hit!.title}', style: CS.body(14, weight: FontWeight.w600, color: const Color(0xFF4CC38A))),
          TextSpan(text: '  (${(r.hit!.score * 100).round()} %)', style: CS.body(12, color: CS.humo)),
        ]));
      case _St.none:
        status = Text('No se encontró en la base. Podés corregirlo a mano.', style: CS.body(13, color: CS.ambar));
      case _St.error:
        status = Text(r.error ?? 'Error', style: CS.body(13, color: const Color(0xFFFF8A8F)));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CoverArt(t, size: 42),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.fileName, style: CS.body(14, weight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
              Text('Ahora: ${t.artist.isEmpty ? 'sin artista' : t.artist} · ${t.title}',
                  style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        status,
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (r.st == _St.found)
            SecondaryButton('Aceptar', icon: Icons.check, color: const Color(0xFF4CC38A), height: 40,
                onTap: () => _accept(r, r.hit!.artist, r.hit!.title)),
          if (r.st != _St.working && r.st != _St.found)
            SecondaryButton('Reconocer', icon: Icons.graphic_eq, height: 40, onTap: hasKey ? () => unawaited(_identify(r)) : null),
          SecondaryButton('Editar a mano', icon: Icons.edit, height: 40, onTap: () => _edit(r)),
          if (widget.only == null) SecondaryButton('Dejar así', height: 40, onTap: () {
            t.fixedName = true;
            app.library.changed();
            setState(() => _rows.remove(r));
          }),
        ]),
      ]),
    );
  }
}
