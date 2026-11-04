import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/platform.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'dj_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      app.recheckStorage();
      if (app.hasStorage) app.library.scan(app.settings.libraryRoot);
    }
  }

  void _go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app, app.library, app.player]),
          builder: (context, _) {
            final lib = app.library;
            return Column(
              children: [
                CsHeader(
                  title: 'CS Mix',
                  subtitle: 'Catelotti Sport',
                  trailing: [IconBox(icon: Icons.tune, tooltip: 'Ajustes', onTap: () => _go(const SettingsScreen()))],
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                        children: [
                          if (!app.hasStorage) ...[_storageBanner(), const SizedBox(height: 14)],
                          if (app.outputError != null) ...[_warn(app.outputError!), const SizedBox(height: 14)],
                          const SectionTitle('Elegí el modo', size: 22),
                          const SizedBox(height: 12),
                          _modeCard(
                            color: CS.rojo,
                            icon: Icons.music_note,
                            title: 'Reproductor',
                            text: 'Cola automática con crossfade entre temas. Para la sala del gym o para escuchar.',
                            pills: [
                              Pill('Crossfade ${app.settings.autoSec.toStringAsFixed(0)} s'),
                              const Pill('Fade · Reverse · Brake'),
                              const Pill('Pantalla apagada'),
                            ],
                            onTap: () => _go(const PlayerScreen()),
                          ),
                          const SizedBox(height: 12),
                          _modeCard(
                            color: CS.ambar,
                            icon: Icons.album,
                            title: 'DJ en vivo',
                            text: 'Dos decks y crossfader manual. Pre-escuchás el próximo tema en el celular mientras suena el Bluetooth.',
                            pills: const [
                              Pill('Pre-escucha', color: CS.ambar, background: CS.ambarFondo),
                              Pill('Pitch ±8 %'),
                              Pill('Hot cues'),
                            ],
                            onTap: () => _go(const DjScreen()),
                          ),
                          const SizedBox(height: 26),
                          const SectionTitle('Seguir escuchando', size: 22),
                          const SizedBox(height: 4),
                          if (app.mode == Mode.player && app.player.current != null)
                            _row(
                              title: app.player.current!.title,
                              subtitle: 'Sonando en el Reproductor',
                              action: SquareButton(
                                icon: Icons.open_in_full,
                                size: 46,
                                color: CS.rojo,
                                iconSize: 20,
                                tooltip: 'Abrir',
                                onTap: () => _go(const PlayerScreen()),
                              ),
                            )
                          else if (lib.playlists.isNotEmpty)
                            _row(
                              title: lib.playlists.last.name,
                              subtitle: '${lib.playlists.last.paths.length} temas · Reproductor',
                              action: SquareButton(
                                icon: Icons.play_arrow,
                                size: 46,
                                color: CS.rojo,
                                iconSize: 22,
                                tooltip: 'Reproducir playlist',
                                onTap: () {
                                  final p = lib.playlists.last;
                                  app.player.playList(lib.tracksOf(p), name: p.name);
                                  _go(const PlayerScreen());
                                },
                              ),
                            )
                          else
                            _row(title: 'Todavía no hay playlists', subtitle: 'Creá una o importá las de Virtual DJ en Listas'),
                          _row(
                            title: 'Biblioteca',
                            subtitle: lib.scanning
                                ? 'Buscando temas…'
                                : '${lib.count} temas · ${lib.pendingAnalysis > 0 ? 'analizando BPM (${lib.pendingAnalysis} restantes)' : 'BPM analizado'}',
                            action: SecondaryButton(
                              'Escanear',
                              onTap: lib.scanning || !app.hasStorage ? null : () => lib.scan(app.settings.libraryRoot),
                            ),
                          ),
                          if (lib.scanError != null) Padding(padding: const EdgeInsets.only(top: 8), child: _warn(lib.scanError!)),
                        ],
                      ),
                    ),
                  ),
                ),
                _nav(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _modeCard({
    required Color color,
    required IconData icon,
    required String title,
    required String text,
    required List<Widget> pills,
    required VoidCallback onTap,
  }) {
    return BarCard(
      color: color,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 12),
            Expanded(child: Text(title.toUpperCase(), style: CS.cond(28))),
            const Icon(Icons.chevron_right, color: CS.humo),
          ]),
          const SizedBox(height: 8),
          Text(text, style: CS.body(15, color: CS.humo)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: pills),
        ],
      ),
    );
  }

  Widget _row({required String title, required String subtitle, Widget? action}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: CS.body(16, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(subtitle, style: CS.body(13, color: CS.humo), maxLines: 2),
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 12), action],
      ]),
    );
  }

  Widget _storageBanner() {
    return BarCard(
      color: CS.ambar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Falta el permiso para leer tu música', style: CS.body(16, weight: FontWeight.w600, color: CS.ambar)),
        const SizedBox(height: 4),
        Text('Android pide "acceso a todos los archivos" para leer la carpeta de la biblioteca y las playlists .m3u de Virtual DJ.',
            style: CS.body(14, color: CS.humo)),
        const SizedBox(height: 10),
        SecondaryButton('Dar permiso', onTap: Native.requestStorageAccess, color: CS.ambar),
      ]),
    );
  }

  Widget _warn(String text) => BarCard(color: CS.ambar, child: Text(text, style: CS.body(14, color: const Color(0xFFFFD489))));

  Widget _nav() {
    Widget item(String label, bool on, VoidCallback onTap) => Expanded(
          child: Material(
            color: on ? CS.rojo : CS.grafito,
            borderRadius: BorderRadius.circular(CS.radio),
            child: InkWell(
              borderRadius: BorderRadius.circular(CS.radio),
              onTap: onTap,
              child: SizedBox(height: 54, child: Center(child: Text(label.toUpperCase(), style: CS.cond(16)))),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: CS.acero))),
      child: Row(children: [
        item('Inicio', true, () {}),
        const SizedBox(width: 8),
        item('Temas', false, () => _go(const LibraryScreen())),
        const SizedBox(width: 8),
        item('Listas', false, () => _go(const PlaylistsScreen())),
        const SizedBox(width: 8),
        item('Ajustes', false, () => _go(const SettingsScreen())),
      ]),
    );
  }
}
