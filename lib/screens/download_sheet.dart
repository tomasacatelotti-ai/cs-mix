import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/downloader.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'library_screen.dart';

/// Opens the "Descargar desde link" sheet. With [link] (shared from another app) it starts at once.
/// If the sheet is already open, the link goes into it instead of opening a second one.
Future<void> showDownloadSheet(BuildContext context, {String? link}) async {
  final open = _DownloadSheetState._current;
  if (open != null) {
    open._take(link);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _DownloadSheet(link: link),
  );
}

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({this.link});

  final String? link;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  static _DownloadSheetState? _current;

  final _url = TextEditingController();
  LinkDownloader get _dl => app.downloader;

  @override
  void initState() {
    super.initState();
    _current = this;
    _dl.reset(); // an old result is not shown again (does nothing while a download runs)
    final link = widget.link;
    if (link != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _take(link);
      });
    }
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    _url.dispose();
    super.dispose();
  }

  /// A shared link: into the field and straight to downloading.
  void _take(String? link) {
    if (link == null) return;
    final url = LinkDownloader.extractUrl(link) ?? link.trim();
    if (_dl.busy) {
      toast(context, 'Esperá a que termine la descarga actual.');
      return;
    }
    setState(() => _url.text = url);
    _start();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) toast(context, 'No hay nada copiado.');
      return;
    }
    setState(() => _url.text = LinkDownloader.extractUrl(text) ?? text);
  }

  void _start() {
    FocusScope.of(context).unfocus();
    _dl.start(_url.text);
  }

  void _again() {
    _dl.reset();
    setState(_url.clear);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListenableBuilder(
          listenable: _dl,
          builder: (context, _) {
            final busy = _dl.busy;
            final stage = _dl.stage;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionTitle('Descargar desde link', color: CS.blanco),
                const SizedBox(height: 4),
                Text(
                  'MP3, FLAC y WAV se guardan tal cual. MP4 y M4A se convierten a MP3 de ${LinkDownloader.kbps} kbps. '
                  'Todo va a la carpeta ${LinkDownloader.folderName} de la biblioteca.',
                  style: CS.body(13, color: CS.humo),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _url,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _start(),
                  style: CS.body(15),
                  decoration: InputDecoration(
                    hintText: 'https://…/tema.mp3',
                    prefixIcon: const Icon(Icons.link, color: CS.humo),
                    suffixIcon: IconButton(
                      tooltip: 'Pegar',
                      icon: const Icon(Icons.content_paste, color: CS.humo),
                      onPressed: busy ? null : _paste,
                    ),
                  ),
                ),
                if (stage != DownloadStage.idle || _dl.message.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _status(stage),
                ],
                const SizedBox(height: 16),
                if (busy)
                  SecondaryButton('Cancelar', icon: Icons.close, onTap: _dl.cancel)
                else if (stage == DownloadStage.done) ...[
                  PrimaryButton('Ver en la biblioteca', height: 52, size: 20, onTap: () {
                    final name = _dl.fileName;
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.pushAndRemoveUntil(
                      MaterialPageRoute<void>(builder: (_) => LibraryScreen(initialQuery: name)),
                      (r) => r.isFirst,
                    );
                  }),
                  const SizedBox(height: 10),
                  SecondaryButton('Descargar otro', icon: Icons.download, onTap: _again),
                ] else
                  PrimaryButton('Descargar', height: 52, size: 20, onTap: _url.text.trim().isEmpty ? null : _start),
              ]),
            );
          },
        ),
      ),
    );
  }

  Widget _status(DownloadStage stage) {
    final error = stage == DownloadStage.error;
    final done = stage == DownloadStage.done;
    final busy = _dl.busy;
    final p = _dl.progress;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? CS.rojoFondo : CS.grafito,
        borderRadius: BorderRadius.circular(CS.radio),
        border: Border.all(color: error ? CS.rojo : CS.linea),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_dl.fileName.isNotEmpty) ...[
          Row(children: [
            Icon(done ? Icons.check_circle : Icons.music_note, size: 18, color: done ? CS.ambar : CS.humo),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_dl.fileName, style: CS.body(15, weight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 8),
        ],
        if (busy) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: p, minHeight: 6, color: CS.rojo, backgroundColor: CS.acero),
          ),
          const SizedBox(height: 8),
        ],
        Row(children: [
          if (error) ...[const Icon(Icons.error_outline, size: 18, color: CS.rojo), const SizedBox(width: 6)],
          Expanded(child: Text(_dl.message, style: CS.body(14, color: error ? CS.blanco : CS.humo))),
          if (busy && p != null) Text('${(p * 100).round()} %', style: CS.body(14, color: CS.humo)),
        ]),
      ]),
    );
  }
}
