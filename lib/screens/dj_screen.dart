import 'dart:io';

import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'library_screen.dart';

class DjScreen extends StatefulWidget {
  const DjScreen({super.key});

  @override
  State<DjScreen> createState() => _DjScreenState();
}

class _DjScreenState extends State<DjScreen> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => app.dj.enter());
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _load(int deck) async {
    final t = await Navigator.of(context).push<Track>(
      MaterialPageRoute(builder: (_) => LibraryScreen(pickLabel: 'deck ${deck == 0 ? 'A' : 'B'}')),
    );
    if (t != null) app.dj.load(deck, t);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([app.engine, app.dj, app.library]),
          builder: (context, _) {
            return Column(children: [
              _header(context),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: LayoutBuilder(builder: (context, c) {
                    final narrow = c.maxWidth < 640;
                    if (narrow) {
                      return ListView(children: [
                        _deck(0),
                        const SizedBox(height: 10),
                        _mixer(),
                        const SizedBox(height: 10),
                        _deck(1),
                      ]);
                    }
                    final deckW = ((c.maxWidth - 20) * 0.37).clamp(260.0, 520.0);
                    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SizedBox(width: deckW, child: _deck(0)),
                      const SizedBox(width: 10),
                      Expanded(child: _mixer()),
                      const SizedBox(width: 10),
                      SizedBox(width: deckW, child: _deck(1)),
                    ]);
                  }),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final cue = app.cueLabel();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(children: [
        IconBox(icon: Icons.chevron_left, tooltip: 'Volver a Inicio', onTap: () => goHome(context)),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(border: Border(left: BorderSide(color: CS.rojo, width: 4))),
            child: Text('DJ EN VIVO', style: CS.cond(24)),
          ),
        ),
        Flexible(child: Pill('Master: ${app.masterLabel()}', icon: Icons.speaker)),
        const SizedBox(width: 8),
        Flexible(
          child: app.cueMuted
              ? const Pill('Pre-escucha silenciada: el sistema la movió, reconectando…', icon: Icons.headset_off, color: CS.ambar, background: CS.ambarFondo)
              : cue == null
              ? const Pill('Pre-escucha: conectá auriculares por cable o USB', icon: Icons.headset_off, color: CS.ambar, background: CS.ambarFondo)
              : Pill('Pre-escucha: $cue', icon: Icons.headphones, color: CS.ambar, background: CS.ambarFondo),
        ),
      ]),
    );
  }

  Widget _deck(int d) {
    final dj = app.dj;
    final t = dj.decks[d];
    final s = dj.snap(d);
    final color = CS.deckColors[d];
    final ink = CS.deckInk[d];
    const radius = BorderRadius.only(topRight: Radius.circular(CS.radio), bottomRight: Radius.circular(CS.radio));
    return Container(
      decoration: BoxDecoration(
        color: CS.grafito,
        borderRadius: radius,
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: Text(d == 0 ? 'A' : 'B', style: CS.cond(20, color: ink)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _load(d),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t?.title ?? 'Tocá para cargar un tema', style: CS.body(15, weight: FontWeight.w500, color: t == null ? CS.humo : CS.blanco),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  t == null ? '' : '${t.subtitle} · ${app.deckDownload(d) != null ? 'bajando de la PC ${(app.deckDownload(d)! * 100).round()} %' : (app.deckBusy(d) ? 'cargando…' : fmtTime(s.remaining, negative: true))}',
                  style: CS.body(12, color: CS.humo),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(fmtBpm(dj.liveBpm(d)), style: CS.cond(26)),
            Text('BPM', style: CS.body(11, color: CS.humo)),
          ]),
          const SizedBox(width: 6),
          IconBox(icon: Icons.library_music, size: 40, tooltip: 'Cargar tema', onTap: () => _load(d)),
        ]),
        const SizedBox(height: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: t == null || s.duration <= 0
              ? null
              : (e) => CsAudio.seek(d, (s.position - e.delta.dx * 0.03).clamp(0, s.duration).toDouble()),
          child: ScrollingWave(
            peaks: t == null ? null : app.library.peaksOf(t),
            position: s.position,
            color: color,
            cues: [if (t?.cue != null) t!.cue!, for (final h in t?.hotcues ?? const <double?>[]) ?h],
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: _hotcue(d, i, color)),
          ],
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Text('Pitch', style: CS.body(12, color: CS.humo)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: CS.linea,
                inactiveTrackColor: CS.linea,
                trackHeight: 4,
              ),
              child: Slider(
                value: dj.pitch[d],
                min: -0.08,
                max: 0.08,
                // Snaps to 0 near the center so it is easy to land on it.
                onChanged: t == null
                    ? null
                    : (v) {
                        final r = (v * 1000).roundToDouble() / 1000;
                        dj.setPitch(d, r.abs() <= 0.004 ? 0 : r);
                      },
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text('${dj.pitch[d] >= 0 ? '+' : ''}${fmtNum(dj.pitch[d] * 100)} %',
                textAlign: TextAlign.right, style: CS.body(12)),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Pitch a 0',
            child: Material(
              color: dj.pitch[d] == 0 ? Colors.transparent : CS.acero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: dj.pitch[d] == 0 ? CS.linea : color),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => dj.setPitch(d, 0),
                child: SizedBox(
                  width: 44,
                  height: 32,
                  child: Center(child: Text('0', style: CS.cond(18, color: dj.pitch[d] == 0 ? CS.humo : CS.blanco))),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: SquareButton(
              icon: Icons.first_page,
              size: 46,
              color: Colors.transparent,
              border: CS.linea,
              tooltip: 'Volver al inicio del tema',
              onTap: t == null ? null : () => dj.restart(d),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CS.radio), side: const BorderSide(color: CS.linea)),
              child: InkWell(
                borderRadius: BorderRadius.circular(CS.radio),
                onTap: t == null ? null : () => dj.cue(d),
                child: SizedBox(height: 46, child: Center(child: Text('CUE', style: CS.cond(18)))),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SquareButton(
              icon: s.playing ? Icons.pause : Icons.play_arrow,
              size: 46,
              color: color,
              ink: ink,
              tooltip: s.playing ? 'Pausa' : 'Reproducir',
              onTap: t == null || !s.ready ? null : () => dj.togglePlay(d),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SquareButton(
              icon: Icons.headphones,
              size: 46,
              color: dj.pfl[d] ? CS.ambarFondo : Colors.transparent,
              ink: dj.pfl[d] ? CS.ambar : CS.humo,
              border: dj.pfl[d] ? CS.ambar : CS.linea,
              tooltip: 'Pre-escucha en el celular',
              onTap: () => dj.togglePfl(d),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _hotcue(int d, int i, Color color) {
    final t = app.dj.decks[d];
    final set = t?.hotcues[i] != null;
    return Tooltip(
      message: set ? 'Hot cue ${i + 1}: tocá para saltar, mantené para borrar' : 'Tocá para marcar el hot cue ${i + 1}',
      child: Material(
        color: CS.acero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: set ? color : CS.linea)),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: t == null ? null : () => app.dj.hotcue(d, i),
          onLongPress: set ? () => app.dj.clearHotcue(d, i) : null,
          child: SizedBox(
            height: 34,
            child: Center(child: Text('${i + 1}', style: CS.body(14, weight: FontWeight.w600, color: set ? color : CS.humo))),
          ),
        ),
      ),
    );
  }

  Widget _mixer() {
    final dj = app.dj;
    final xf = app.engine.crossfader;
    final target = xf < 0.5 ? 1 : 0;
    final dur = app.settings.fxDur[dj.fx] ?? 0;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Transición', size: 18, trailing: Text('${fmtNum(dur, decimals: dur == dur.roundToDouble() ? 0 : 1)} s', style: CS.body(13))),
      const SizedBox(height: 6),
      SegButtons<TransitionFx>(
        values: TransitionFx.values,
        selected: dj.fx,
        label: fxLabel,
        onSelect: dj.setFx,
        height: 38,
        columns: 2,
      ),
      const SizedBox(height: 8),
      SecondaryButton('Sync BPM ${target == 1 ? 'B → A' : 'A → B'}', height: 38, onTap: () {
        final err = dj.sync(target);
        if (err != null) toast(context, err);
      }),
      const SizedBox(height: 8),
      Row(children: [
        Text('A', style: CS.cond(16, color: CS.rojo)),
        Expanded(child: Center(child: Text('Crossfader', style: CS.body(12, color: CS.humo)))),
        Text('B', style: CS.cond(16, color: CS.ambar)),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: CS.linea,
          inactiveTrackColor: CS.linea,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 13),
          trackHeight: 6,
        ),
        child: Slider(value: xf.clamp(0.0, 1.0), onChanged: app.engine.transitioning ? null : dj.setCrossfader),
      ),
      const SizedBox(height: 6),
      PrimaryButton(
        'Pasar a ${target == 1 ? 'B' : 'A'} · ${fxLabel(dj.fx)}',
        height: 50,
        size: 20,
        onTap: dj.decks[target] == null || app.engine.transitioning ? null : () => dj.passTo(target),
      ),
    ]);
  }
}
