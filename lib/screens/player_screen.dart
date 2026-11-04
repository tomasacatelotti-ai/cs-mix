import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'entry_sheet.dart';
import 'library_screen.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app.engine, app.player, app.library]),
          builder: (context, _) {
            final p = app.player;
            final cur = p.current;
            return Column(
              children: [
                CsHeader(
                  title: 'Reproductor',
                  subtitle: '${p.source ?? (cur == null ? 'Elegí qué escuchar' : 'Cola')} · ${app.masterLabel()}',
                  onBack: () => Navigator.of(context).pop(),
                  trailing: [
                    IconBox(icon: Icons.queue_music, tooltip: 'Ver cola', onTap: () => _showQueue(context)),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: cur == null || app.mode != Mode.player ? _empty(context) : _body(context),
                    ),
                  ),
                ),
                if (cur != null && app.mode == Mode.player) _footer(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('NO HAY NADA SONANDO', style: CS.cond(26, color: CS.humo)),
          const SizedBox(height: 8),
          Text('Elegí un tema o una playlist para arrancar.', style: CS.body(15, color: CS.humo)),
          const SizedBox(height: 20),
          PrimaryButton('Elegir temas', onTap: () {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LibraryScreen()));
          }),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final p = app.player;
    final cur = p.current!;
    final deck = p.currentDeck;
    final next = p.next;
    final nd = p.nextDeck;
    final peaks = app.library.peaksOf(cur);
    final progress = deck.duration > 0 ? deck.position / deck.duration : 0.0;
    final fxDur = app.settings.fxDur[p.fx] ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      children: [
        Text(p.transitioning ? 'En transición' : (deck.loading ? 'Cargando…' : 'Sonando'), style: CS.body(13, color: CS.humo)),
        Text(cur.title.toUpperCase(), style: CS.cond(28), maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Row(children: [
          Flexible(child: Text(cur.subtitle, style: CS.body(15, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Pill('${fmtBpm(cur.bpm)} BPM'),
        ]),
        const SizedBox(height: 12),
        WaveformView(
          peaks: peaks,
          progress: progress,
          onSeek: deck.duration > 0 ? (f) => p.seek(f * deck.duration) : null,
        ),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(fmtTime(deck.position), style: CS.body(13, color: CS.humo)),
          Text(fmtTime(deck.remaining, negative: true), style: CS.body(13, color: CS.humo)),
        ]),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SquareButton(icon: Icons.skip_previous, tooltip: 'Tema anterior', onTap: p.previous),
          const SizedBox(width: 24),
          SquareButton(
            icon: p.playing ? Icons.pause : Icons.play_arrow,
            size: 72,
            iconSize: 34,
            color: CS.rojo,
            tooltip: p.playing ? 'Pausa' : 'Reproducir',
            onTap: p.togglePlay,
          ),
          const SizedBox(width: 24),
          SquareButton(icon: Icons.skip_next, tooltip: 'Próximo tema', onTap: next == null ? null : () => p.passNow()),
        ]),
        const SizedBox(height: 16),
        SectionTitle(
          'Al pasar de tema',
          trailing: Text('Duración ${fmtNum(fxDur, decimals: fxDur == fxDur.roundToDouble() ? 0 : 1)} s', style: CS.body(14)),
        ),
        const SizedBox(height: 8),
        SegButtons<TransitionFx>(
          values: TransitionFx.values,
          selected: p.fx,
          label: fxLabel,
          onSelect: p.setFx,
        ),
        const SizedBox(height: 6),
        Text(fxDescription(p.fx), style: CS.body(14, color: CS.humo)),
        const SizedBox(height: 14),
        if (next != null)
          BarCard(
            color: CS.ambar,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle('Próximo', color: CS.ambar, trailing: Pill('${fmtBpm(next.bpm)} BPM')),
                const SizedBox(height: 6),
                Text(next.title, style: CS.body(16, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(next.subtitle, style: CS.body(13, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                WaveformView(
                  peaks: app.library.peaksOf(next),
                  progress: nd.duration > 0 ? p.nextEntry / nd.duration : 0,
                  played: CS.linea,
                  rest: CS.ambar,
                  marker: nd.duration > 0 ? p.nextEntry / nd.duration : 0,
                  height: 38,
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(style: CS.body(14, color: CS.humo), children: [
                        const TextSpan(text: 'Entra en '),
                        TextSpan(text: fmtTime(p.nextEntry), style: CS.body(14, weight: FontWeight.w600)),
                        TextSpan(text: p.oneTimeEntry != null ? ' · solo esta vez' : (next.entry != null ? ' · punto guardado' : ' · automático')),
                      ]),
                    ),
                  ),
                  SecondaryButton('Cambiar entrada', height: 40, onTap: () => showEntrySheet(context, next, p.nextEntry)),
                ]),
              ],
            ),
          )
        else
          BarCard(
            color: CS.linea,
            child: Text(app.settings.repeat ? 'La cola vuelve a empezar.' : 'Es el último tema de la cola.',
                style: CS.body(14, color: CS.humo)),
          ),
        const SizedBox(height: 12),
        PrimaryButton(
          next == null ? 'Sin próximo tema' : (nd.loading ? 'Preparando el próximo…' : 'Pasar ahora con ${fxLabel(p.fx)}'),
          onTap: next == null || p.transitioning ? null : () => p.passNow(),
        ),
      ],
    );
  }

  Widget _footer() {
    final s = app.settings;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: CS.acero))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Crossfade al terminar', style: CS.body(15)),
            Text(s.autoCrossfade ? 'Empieza ${s.autoSec.toStringAsFixed(0)} s antes del final' : 'Apagado: pasa con corte al terminar',
                style: CS.body(13, color: CS.humo)),
          ]),
        ),
        IconBox(
          icon: Icons.shuffle,
          color: s.shuffle ? CS.rojo : CS.humo,
          tooltip: 'Aleatorio',
          onTap: () => app.player.setShuffle(!s.shuffle),
        ),
        const SizedBox(width: 8),
        IconBox(
          icon: Icons.repeat,
          color: s.repeat ? CS.rojo : CS.humo,
          tooltip: 'Repetir la cola',
          onTap: () => app.player.setRepeat(!s.repeat),
        ),
        const SizedBox(width: 12),
        CsToggle(
          value: s.autoCrossfade,
          label: 'Crossfade al terminar',
          onChanged: (v) {
            s.autoCrossfade = v;
            app.saveSettings();
          },
        ),
      ]),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: ListenableBuilder(
          listenable: app.player,
          builder: (ctx, _) {
            final p = app.player;
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: SectionTitle('Cola', trailing: Text('${p.queue.length} temas', style: CS.body(14, color: CS.humo))),
              ),
              Expanded(
                child: p.queue.isEmpty
                    ? Center(child: Text('La cola está vacía.', style: CS.body(15, color: CS.humo)))
                    : ListView.builder(
                        itemCount: p.queue.length,
                        itemBuilder: (ctx, i) {
                          final t = p.queue[i];
                          final isCur = i == p.index;
                          return ListTile(
                            leading: SizedBox(
                              width: 28,
                              child: isCur
                                  ? const Icon(Icons.graphic_eq, color: CS.rojo)
                                  : Text('${i + 1}', style: CS.body(14, color: CS.humo), textAlign: TextAlign.center),
                            ),
                            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: CS.body(15, color: isCur ? CS.rojo : CS.blanco, weight: FontWeight.w500)),
                            subtitle: Text('${t.subtitle} · ${fmtBpm(t.bpm)} BPM',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: CS.body(13, color: CS.humo)),
                            trailing: isCur
                                ? null
                                : IconButton(
                                    tooltip: 'Quitar de la cola',
                                    icon: const Icon(Icons.close, color: CS.humo),
                                    onPressed: () => p.removeAt(i),
                                  ),
                            onTap: isCur ? null : () => p.jumpTo(i),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SecondaryButton('Agregar temas', icon: Icons.add, onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LibraryScreen()));
                }),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Used by other screens to start playback of a single track.
void playTrackFrom(BuildContext context, Track t) => app.player.playNow(t);
