import 'package:cs_audio/cs_audio.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/platform.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'folder_picker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _tone = false;
  late final _pc = TextEditingController(text: app.settings.pcRoot);

  @override
  void initState() {
    super.initState();
    app.refreshOutputs();
  }

  @override
  void dispose() {
    if (_tone) CsAudio.testTone(false);
    super.dispose();
  }

  void _save() {
    app.saveSettings();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final s = app.settings;
            return Column(children: [
              CsHeader(title: 'Ajustes', subtitle: 'Transiciones, sonido y salida', onBack: () => Navigator.of(context).pop()),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 30), children: [
                      _head('Al terminar el tema', trailing: CsToggle(value: s.autoCrossfade, label: 'Crossfade automático', onChanged: (v) {
                        s.autoCrossfade = v;
                        _save();
                      })),
                      _slider('Crossfade automático', s.autoSec, 1, 12, '${s.autoSec.toStringAsFixed(0)} s', (v) {
                        s.autoSec = v.roundToDouble();
                        _save();
                      }),
                      _label('Curva del fade'),
                      SegButtons<int>(
                        values: const [0, 1],
                        selected: s.curve,
                        label: (v) => v == 0 ? 'Lineal' : 'Potencia constante',
                        height: 46,
                        onSelect: (v) {
                          s.curve = v;
                          CsAudio.setCurve(v);
                          _save();
                        },
                      ),
                      _head('Al cambiar manualmente'),
                      _label('Efecto por defecto'),
                      SegButtons<TransitionFx>(
                        values: TransitionFx.values,
                        selected: s.defaultFx,
                        label: fxLabel,
                        height: 46,
                        onSelect: (v) {
                          s.defaultFx = v;
                          app.player.setFx(v);
                          app.dj.setFx(v);
                          _save();
                        },
                      ),
                      for (final fx in [TransitionFx.fade, TransitionFx.reverse, TransitionFx.brake])
                        _slider('Duración de ${fxLabel(fx)}', s.fxDur[fx]!, 0.5, 12, '${fmtNum(s.fxDur[fx]!)} s', (v) {
                          s.fxDur[fx] = (v * 2).roundToDouble() / 2;
                          _save();
                        }),
                      _head('Punto de entrada'),
                      for (final m in EntryMode.values) _entryOption(m),
                      _head('Ecualizador', trailing: Pill('Preset: ${s.eqPreset}')),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final p in eqPresets.keys)
                          SecondaryButton(p, height: 38, color: s.eqPreset == p ? CS.rojo : CS.blanco, onTap: () {
                            s.eqPreset = p;
                            s.eq = List.of(eqPresets[p]!);
                            for (var i = 0; i < 5; i++) {
                              CsAudio.setEq(i, s.eq[i]);
                            }
                            _save();
                          }),
                      ]),
                      const SizedBox(height: 10),
                      _eq(),
                      _rowSwitch('Volumen automático', 'Nivela los temas entre sí', s.autoGain, (v) {
                        s.autoGain = v;
                        _save();
                      }),
                      _slider('Volumen general', s.masterVolume, 0, 1.5, '${(s.masterVolume * 100).round()} %', (v) {
                        s.masterVolume = v;
                        CsAudio.setMasterVolume(v);
                        _save();
                      }),
                      _head('Salidas de audio'),
                      _deviceRow('Salida principal', app.masterLabel(), () => _pickDevice(master: true)),
                      _deviceRow(
                        'Pre-escucha (modo DJ)',
                        app.cueLabel() ?? 'Apagada',
                        () => _pickDevice(master: false),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Bluetooth solo para el parlante: Android usa un dispositivo Bluetooth a la vez. '
                          'Los auriculares de pre-escucha conectalos por cable o USB-C.',
                          style: CS.body(13, color: CS.humo),
                        ),
                      ),
                      if (app.outputError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: BarCard(color: CS.ambar, child: Text(app.outputError!, style: CS.body(14, color: const Color(0xFFFFD489)))),
                        ),
                      const SizedBox(height: 8),
                      _slider('Compensación de latencia', s.cueDelayMs, 0, 500, '${s.cueDelayMs.round()} ms', (v) {
                        s.cueDelayMs = (v / 5).roundToDouble() * 5;
                        CsAudio.setCueDelayMs(s.cueDelayMs);
                        _save();
                      }),
                      Text(
                        'Retrasa la pre-escucha para que coincida con el parlante Bluetooth. '
                        'Calibrar: tocá "Probar", escuchá el clic en el parlante y en los auriculares, y mové la barra hasta que suenen juntos.',
                        style: CS.body(13, color: CS.humo),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        SecondaryButton(_tone ? 'Parar clic' : 'Probar', icon: _tone ? Icons.stop : Icons.graphic_eq,
                            color: _tone ? CS.rojo : CS.blanco, onTap: () {
                          setState(() => _tone = !_tone);
                          CsAudio.testTone(_tone);
                        }),
                        const SizedBox(width: 8),
                        SecondaryButton('Bluetooth típico (200 ms)', onTap: () {
                          s.cueDelayMs = 200;
                          CsAudio.setCueDelayMs(200);
                          _save();
                        }),
                      ]),
                      _head('Biblioteca'),
                      _deviceRow('Carpeta de la música', s.libraryRoot, _pickFolder),
                      const SizedBox(height: 8),
                      _label('Ruta de la biblioteca en la PC (para exportar a Virtual DJ)'),
                      TextField(
                        controller: _pc,
                        style: CS.body(15),
                        onChanged: (v) {
                          s.pcRoot = v.trim();
                          app.saveSettings();
                        },
                      ),
                      const SizedBox(height: 18),
                      Text('CS Mix 0.1 · Catelotti Sport', style: CS.body(12, color: CS.humo), textAlign: TextAlign.center),
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

  Widget _head(String t, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: BarCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [Expanded(child: Text(t.toUpperCase(), style: CS.cond(20))), ?trailing]),
        ),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: Text(t, style: CS.body(13, color: CS.humo)),
      );

  Widget _slider(String label, double value, double min, double max, String shown, ValueChanged<double> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: CS.body(13, color: CS.humo))),
          Text(shown, style: CS.body(14, weight: FontWeight.w600)),
        ]),
      ),
      Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged),
    ]);
  }

  Widget _entryOption(EntryMode m) {
    final s = app.settings;
    final on = s.entryMode == m;
    final (title, sub) = switch (m) {
      EntryMode.saved => ('Punto guardado del tema', 'Si no tiene, salta la intro'),
      EntryMode.intro => ('Saltar intro siempre', 'Arranca en el primer golpe fuerte'),
      EntryMode.start => ('Desde el inicio', 'Sin saltear nada'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: on ? CS.acero : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CS.radio),
          side: BorderSide(color: on ? CS.blanco : CS.linea),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CS.radio),
          onTap: () {
            s.entryMode = m;
            _save();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: CS.body(15, weight: FontWeight.w500)),
              Text(sub, style: CS.body(13, color: CS.humo)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _eq() {
    final s = app.settings;
    return Row(children: [
      for (var i = 0; i < 5; i++)
        Expanded(
          child: Column(children: [
            Text('${s.eq[i] > 0 ? '+' : ''}${s.eq[i].round()} dB', style: CS.body(12)),
            SizedBox(
              height: 130,
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  value: s.eq[i],
                  min: -12,
                  max: 12,
                  onChanged: (v) {
                    s.eq[i] = v.roundToDouble();
                    s.eqPreset = 'Personalizado';
                    CsAudio.setEq(i, s.eq[i]);
                    _save();
                  },
                ),
              ),
            ),
            Text(eqLabels[i], style: CS.body(12, color: CS.humo)),
          ]),
        ),
    ]);
  }

  Widget _rowSwitch(String title, String sub, bool value, ValueChanged<bool> onChanged) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        margin: const EdgeInsets.only(top: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: CS.body(15)),
              Text(sub, style: CS.body(13, color: CS.humo)),
            ]),
          ),
          CsToggle(value: value, onChanged: onChanged, label: title),
        ]),
      );

  Widget _deviceRow(String title, String value, VoidCallback onTap) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: CS.body(15)),
              Text(value, style: CS.body(13, color: CS.humo), maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          SecondaryButton('Cambiar', height: 40, onTap: onTap),
        ]),
      );

  Future<void> _pickDevice({required bool master}) async {
    await app.refreshOutputs();
    if (!mounted) return;
    final s = app.settings;
    final current = master ? s.masterDevice : s.cueDevice;
    final options = <(String, String)>[
      ('auto', master ? 'Automática (la que use el sistema)' : 'Automática (auriculares o parlante del celular)'),
      if (!master) ('off', 'Apagada'),
      // Android plays to one Bluetooth device at a time, so the cue can't be Bluetooth.
      for (final d in app.outputs)
        if (master || d.kind != 'bluetooth') (d.key, d.label),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: SectionTitle(master ? 'Salida principal' : 'Pre-escucha'),
          ),
          if (!master)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Android manda audio a un solo dispositivo Bluetooth a la vez. Con el parlante por Bluetooth, '
                'los auriculares de pre-escucha van por cable o USB.',
                style: CS.body(13, color: CS.humo),
              ),
            ),
          for (final o in options)
            ListTile(
              title: Text(o.$2, style: CS.body(16, color: o.$1 == current ? CS.rojo : CS.blanco)),
              trailing: o.$1 == current ? const Icon(Icons.check, color: CS.rojo) : null,
              onTap: () => Navigator.of(ctx).pop(o.$1),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == null) return;
    if (master) {
      s.masterDevice = picked;
    } else {
      s.cueDevice = picked;
    }
    app.saveSettings();
    await app.openOutputs();
    if (mounted) setState(() {});
  }

  Future<void> _pickFolder() async {
    final s = app.settings;
    if (!await Native.hasStorageAccess()) {
      await Native.requestStorageAccess();
      return;
    }
    if (!mounted) return;
    final p = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FolderPicker(initial: s.libraryRoot)));
    if (p == null) return;
    s.libraryRoot = p;
    app.saveSettings();
    await app.library.scan(p);
    if (mounted) setState(() {});
  }
}
