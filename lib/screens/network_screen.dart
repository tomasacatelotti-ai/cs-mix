import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/net.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// PC: share the library on the gym Wi-Fi. Phone: connect to it.
class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = !(Platform.isAndroid || Platform.isIOS);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          CsHeader(
            title: 'Biblioteca en red',
            subtitle: pc ? 'Compartir la música de esta PC' : 'Música de la PC sin copiarla al celular',
            onBack: () => goHome(context),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: pc ? const _PcShare() : const _PhoneConnect(),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- PC

class _PcShare extends StatefulWidget {
  const _PcShare();

  @override
  State<_PcShare> createState() => _PcShareState();
}

class _PcShareState extends State<_PcShare> {
  late final _name = TextEditingController(text: app.settings.shareName);

  Future<void> _autostart(bool on) async {
    app.settings.autostart = on;
    app.saveSettings();
    if (!Platform.isWindows) return;
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    try {
      final r = on
          ? await Process.run('reg', ['add', key, '/v', 'CS Mix', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f'])
          : await Process.run('reg', ['delete', key, '/v', 'CS Mix', '/f']);
      if (r.exitCode != 0 && on && mounted) toast(context, 'Windows no dejó activar el inicio automático.');
    } catch (_) {
      if (mounted) toast(context, 'Windows no dejó cambiar el inicio automático.');
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app.server, app.library]),
      builder: (context, _) {
        final s = app.settings;
        final srv = app.server;
        final clients = srv.activeClients;
        return ListView(padding: const EdgeInsets.all(20), children: [
          BarCard(
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('COMPARTIR BIBLIOTECA EN LA RED', style: CS.cond(22)),
                  Text('Los celulares con CS Mix en el Wi-Fi del gimnasio usan esta música sin copiarla.',
                      style: CS.body(13, color: CS.humo)),
                ]),
              ),
              const SizedBox(width: 10),
              CsToggle(value: s.shareEnabled, label: 'Compartir', onChanged: (v) => app.setSharing(v)),
            ]),
          ),
          const SizedBox(height: 12),
          if (srv.error != null) BarCard(color: CS.ambar, child: Text(srv.error!, style: CS.body(14, color: const Color(0xFFFFD489)))),
          if (srv.running)
            Row(children: [
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF4CC38A), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text('Compartiendo · ${app.library.localTracks.length} temas · ${app.library.playlists.length} playlists', style: CS.body(15)),
            ]),
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _box(
              'Nombre en la red',
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _name,
                  style: CS.body(17, weight: FontWeight.w600),
                  onSubmitted: (v) async {
                    s.shareName = v.trim().isEmpty ? 'PC del gimnasio' : v.trim();
                    app.saveSettings();
                    if (srv.running) await srv.start(pin: s.sharePin, name: s.shareName);
                  },
                ),
                const SizedBox(height: 6),
                for (final a in srv.addresses) SelectableText('Dirección: $a:$netPort', style: CS.body(13, color: CS.humo)),
              ]),
            ),
            _box(
              'PIN para conectarse',
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.sharePin, style: CS.cond(42).copyWith(letterSpacing: 6)),
                const SizedBox(height: 4),
                SecondaryButton('Cambiar PIN', height: 38, onTap: () async {
                  await app.changePin();
                  if (context.mounted) toast(context, 'PIN nuevo: los celulares tienen que volver a ingresarlo.');
                }),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          BarCard(
            color: CS.ambar,
            child: Text(
              'Dejá CS Mix abierto en esta PC mientras se usa la sala (puede quedar minimizado). '
              'La primera vez Windows pregunta si permitís el acceso a la red privada: tocá Permitir.',
              style: CS.body(14, color: const Color(0xFFE0E0E0)),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Abrir CS Mix al iniciar Windows', style: CS.body(15)),
                  Text('Así la biblioteca queda disponible sin acordarse', style: CS.body(13, color: CS.humo)),
                ]),
              ),
              CsToggle(value: s.autostart, label: 'Inicio automático', onChanged: _autostart),
            ]),
          ),
          const SizedBox(height: 18),
          SectionTitle('Celulares conectados', trailing: Text('${clients.length}', style: CS.body(14, color: CS.humo))),
          const SizedBox(height: 6),
          if (clients.isEmpty) Text('Ninguno por ahora.', style: CS.body(14, color: CS.humo)),
          for (final c in clients)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Icon(Icons.smartphone, color: c.nowPlaying.isEmpty ? CS.humo : CS.rojo),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: CS.body(15)),
                    Text(c.nowPlaying.isEmpty ? 'Conectado · ${c.address}' : 'Sonando: ${c.nowPlaying}',
                        style: CS.body(12, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ]),
            ),
          const SizedBox(height: 10),
          Text('BPM, tonalidad, energía y forma de onda se calculan en esta PC una sola vez y los celulares los reciben listos.',
              style: CS.body(13, color: CS.humo)),
        ]);
      },
    );
  }

  Widget _box(String label, Widget child) => Container(
        width: 300,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: CS.grafito, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: CS.body(13, color: CS.humo)),
          const SizedBox(height: 4),
          child,
        ]),
      );
}

// ---------------------------------------------------------------- phone

class _PhoneConnect extends StatefulWidget {
  const _PhoneConnect();

  @override
  State<_PhoneConnect> createState() => _PhoneConnectState();
}

class _PhoneConnectState extends State<_PhoneConnect> {
  List<FoundPc> _found = [];
  bool _searching = false;
  FoundPc? _picked;
  final _pin = TextEditingController();
  final _host = TextEditingController();
  bool _manual = false;
  bool _busy = false;
  int? _cacheBytes;

  @override
  void initState() {
    super.initState();
    if (!app.net.online) _search();
    _loadCache();
  }

  Future<void> _loadCache() async {
    final b = await app.net.cacheBytes();
    if (mounted) setState(() => _cacheBytes = b);
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final f = await NetClient.discover();
    if (!mounted) return;
    setState(() {
      _found = f;
      _searching = false;
      if (f.length == 1) _picked = f.first;
    });
  }

  Future<void> _connect() async {
    final host = _manual ? _host.text.trim() : _picked?.host ?? '';
    if (host.isEmpty || _pin.text.trim().length < 4) return;
    setState(() => _busy = true);
    final err = await app.connectPc(host.contains(':') ? host : '$host:$netPort', _pin.text.trim(), _picked?.name ?? '');
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, err ?? 'Conectado: ${app.library.remoteCount} temas de la PC.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.net,
      builder: (context, _) {
        final net = app.net;
        return ListView(padding: const EdgeInsets.all(20), children: [
          if (net.online) ...[
            BarCard(
              color: const Color(0xFF4CC38A),
              child: Row(children: [
                const Icon(Icons.computer, color: Color(0xFF4CC38A), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(net.pcName.isEmpty ? 'PC conectada' : net.pcName, style: CS.body(16, weight: FontWeight.w600)),
                    Text('Conectada · ${app.library.remoteCount} temas · ${app.library.remotePlaylists.length} playlists',
                        style: CS.body(13, color: CS.humo)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: SecondaryButton('Actualizar lista', icon: Icons.refresh, onTap: net.refresh)),
              const SizedBox(width: 8),
              Expanded(child: SecondaryButton('Desconectar', icon: Icons.link_off, onTap: app.disconnectPc)),
            ]),
          ] else ...[
            if (net.error != null) ...[
              BarCard(color: CS.ambar, child: Text(net.error!, style: CS.body(14, color: const Color(0xFFFFD489)))),
              const SizedBox(height: 12),
            ],
            SectionTitle('PCs en este Wi-Fi',
                trailing: _searching
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: CS.rojo))
                    : IconBox(icon: Icons.refresh, tooltip: 'Buscar de nuevo', onTap: _search)),
            const SizedBox(height: 8),
            if (!_searching && _found.isEmpty && !_manual)
              Text('No se encontró ninguna. Revisá que la PC tenga CS Mix abierto con "Compartir biblioteca" activado y que '
                  'los dos estén en el mismo Wi-Fi.', style: CS.body(14, color: CS.humo)),
            for (final pc in _found)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: identical(pc, _picked) ? CS.acero : CS.grafito,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: identical(pc, _picked) ? CS.blanco : Colors.transparent),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() {
                      _picked = pc;
                      _manual = false;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        const Icon(Icons.computer, color: Color(0xFF4CC38A)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(pc.name, style: CS.body(16, weight: FontWeight.w600)),
                            Text('${pc.tracks} temas · ${pc.host}', style: CS.body(13, color: CS.humo)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => setState(() => _manual = !_manual),
              child: Text(_manual ? 'Elegir de la lista' : 'Escribir la dirección a mano', style: CS.body(14)),
            ),
            if (_manual)
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                style: CS.body(16),
                decoration: const InputDecoration(hintText: 'Ej: 192.168.0.20 (la muestra la PC en Biblioteca en red)'),
              ),
            const SizedBox(height: 12),
            Text('PIN que muestra la PC', style: CS.body(14, color: CS.humo)),
            const SizedBox(height: 6),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: CS.cond(34).copyWith(letterSpacing: 10),
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(counterText: ''),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              _busy ? 'Conectando…' : (_pin.text.length == 4 ? 'Conectar' : 'Ingresá el PIN'),
              onTap: _busy || _pin.text.length < 4 || (!_manual && _picked == null) ? null : _connect,
            ),
          ],
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Espacio temporal', style: CS.body(15)),
                  Text(
                    'Temas bajados mientras suenan · ${_cacheBytes == null ? '…' : '${(_cacheBytes! / 1048576).round()} MB'} '
                    'de ${(app.settings.cacheLimitMb / 1024).toStringAsFixed(0)} GB · lo más viejo se borra solo',
                    style: CS.body(13, color: CS.humo),
                  ),
                ]),
              ),
              SecondaryButton('Vaciar', height: 40, onTap: () async {
                await app.net.clearCache();
                await _loadCache();
              }),
            ]),
          ),
          const SizedBox(height: 10),
          Text('Límite del espacio temporal', style: CS.body(13, color: CS.humo)),
          const SizedBox(height: 6),
          SegButtons<int>(
            values: const [1024, 2048, 4096, 8192],
            selected: app.settings.cacheLimitMb,
            label: (v) => '${v ~/ 1024} GB',
            height: 42,
            onSelect: (v) {
              app.settings.cacheLimitMb = v;
              app.net.cacheLimitMb = v;
              app.saveSettings();
              setState(() {});
            },
          ),
        ]);
      },
    );
  }
}
