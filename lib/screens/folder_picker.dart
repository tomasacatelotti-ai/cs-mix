import 'dart:io';

import 'package:flutter/material.dart';

import '../core/platform.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Minimal folder browser (needs "all files" access on Android).
class FolderPicker extends StatefulWidget {
  const FolderPicker({super.key, required this.initial});

  final String initial;

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  String? _path;
  List<String> _roots = [];
  List<Directory> _dirs = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _roots = await Native.roots();
      final start = Directory(widget.initial);
      await _open(widget.initial.isNotEmpty && await start.exists() ? start.path : null);
    } catch (_) {
      await _open(null);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String? path) async {
    _error = null;
    if (path == null) {
      if (!mounted) return;
      setState(() {
        _path = null;
        _dirs = [];
      });
      return;
    }
    try {
      final list = <Directory>[];
      await for (final e in Directory(path).list(followLinks: false)) {
        if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.')) list.add(e);
        }
      }
      list.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _path = path;
        _dirs = list;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'No se puede abrir esta carpeta. Revisá en Ajustes de Android que CS Mix tenga "Acceso a todos los archivos".');
      }
    }
  }

  String? _parent(String p) {
    if (_roots.any((r) => _same(r, p))) return null;
    final d = Directory(p).parent.path;
    return d == p ? null : d;
  }

  bool _same(String a, String b) {
    String n(String s) => s.replaceAll(RegExp(r'[\\/]+$'), '').toLowerCase();
    return n(a) == n(b);
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          CsHeader(
            title: 'Elegir carpeta',
            subtitle: path ?? 'Almacenamiento',
            onBack: () => Navigator.of(context).pop(),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: CS.body(14, color: CS.ambar))),
          if (_loading) const LinearProgressIndicator(color: CS.rojo, backgroundColor: CS.acero),
          Expanded(
            child: ListView(children: [
              if (!_loading && path == null && _roots.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('No se encontró el almacenamiento del celular.', style: CS.body(15, color: CS.humo)),
                ),
              if (path == null)
                for (final r in _roots)
                  ListTile(
                    leading: const Icon(Icons.sd_storage, color: CS.humo),
                    title: Text(r, style: CS.body(16)),
                    onTap: () => _open(r),
                  )
              else ...[
                ListTile(
                  leading: const Icon(Icons.arrow_upward, color: CS.humo),
                  title: Text('Subir', style: CS.body(16, color: CS.humo)),
                  onTap: () => _open(_parent(path)),
                ),
                if (_dirs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Text('No hay carpetas adentro. Podés usar esta o tocar Subir.', style: CS.body(14, color: CS.humo)),
                  ),
                for (final r in _roots)
                  if (!_same(r, path))
                    ListTile(
                      leading: const Icon(Icons.sd_storage, color: CS.humo),
                      title: Text('Ir a $r', style: CS.body(14, color: CS.humo)),
                      dense: true,
                      onTap: () => _open(r),
                    ),
                for (final d in _dirs)
                  ListTile(
                    leading: const Icon(Icons.folder, color: CS.ambar),
                    title: Text(d.path.split(Platform.pathSeparator).last, style: CS.body(16)),
                    onTap: () => _open(d.path),
                  ),
              ],
            ]),
          ),
          if (path != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: PrimaryButton('Usar esta carpeta', onTap: () => Navigator.of(context).pop(path)),
            ),
        ]),
      ),
    );
  }
}
