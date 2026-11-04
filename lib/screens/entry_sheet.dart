import 'package:flutter/material.dart';

import '../core/models.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Lets the user pick where the next track comes in.
Future<void> showEntrySheet(BuildContext context, Track track, double current) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EntrySheet(track: track, initial: current),
  );
}

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.track, required this.initial});

  final Track track;
  final double initial;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late double sec = widget.initial;

  double get dur {
    final d = app.player.nextDeck.duration;
    return d > 0 ? d : (widget.track.duration > 0 ? widget.track.duration : 1);
  }

  void _set(double v) => setState(() => sec = v.clamp(0, dur - 1).toDouble());

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Punto de entrada', color: CS.ambar),
            const SizedBox(height: 4),
            Text(t.title, style: CS.body(16, weight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 14),
            WaveformView(
              peaks: app.library.peaksOf(t),
              progress: sec / dur,
              played: CS.linea,
              rest: CS.ambar,
              marker: sec / dur,
              height: 64,
              onSeek: (f) => _set(f * dur),
            ),
            const SizedBox(height: 6),
            Text('Arrastrá sobre la forma de onda para elegir desde dónde entra.', style: CS.body(13, color: CS.humo)),
            const SizedBox(height: 12),
            Row(children: [
              IconBox(icon: Icons.replay_5, tooltip: '−5 s', onTap: () => _set(sec - 5)),
              const SizedBox(width: 8),
              IconBox(icon: Icons.remove, tooltip: '−1 s', onTap: () => _set(sec - 1)),
              Expanded(child: Center(child: Text(fmtTime(sec), style: CS.cond(34)))),
              IconBox(icon: Icons.add, tooltip: '+1 s', onTap: () => _set(sec + 1)),
              const SizedBox(width: 8),
              IconBox(icon: Icons.forward_5, tooltip: '+5 s', onTap: () => _set(sec + 5)),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              SecondaryButton('Desde el inicio', height: 40, onTap: () => _set(0)),
              if (t.analyzed)
                SecondaryButton('Saltar intro (${fmtTime(t.intro)})', height: 40, onTap: () => _set(t.intro)),
              if (t.entry != null)
                SecondaryButton('Guardado (${fmtTime(t.entry!)})', height: 40, onTap: () => _set(t.entry!)),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: SecondaryButton('Solo esta vez', height: 50, onTap: () {
                  app.player.setNextEntry(sec, save: false);
                  Navigator.of(context).pop();
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton('Guardar en el tema', height: 50, size: 18, onTap: () {
                  app.player.setNextEntry(sec, save: true);
                  Navigator.of(context).pop();
                }),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
