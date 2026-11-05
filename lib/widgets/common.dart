import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../main.dart';
import '../theme.dart';

/// Header with back button and the red-bar brand block.
class CsHeader extends StatelessWidget {
  const CsHeader({super.key, required this.title, this.subtitle, this.onBack, this.trailing = const [], this.leading});

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CS.acero))),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconBox(icon: Icons.chevron_left, tooltip: 'Volver', onTap: onBack!),
            const SizedBox(width: 12),
          ],
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 12),
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: CS.rojo, width: 4))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title.toUpperCase(), style: CS.cond(26), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(subtitle!, style: CS.body(13, color: CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
          for (final w in trailing) ...[const SizedBox(width: 8), w],
        ],
      ),
    );
  }
}

class IconBox extends StatelessWidget {
  const IconBox({super.key, required this.icon, required this.onTap, this.tooltip, this.size = 44, this.color = CS.humo});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CS.radio),
        side: const BorderSide(color: CS.linea),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(CS.radio),
        onTap: onTap,
        child: SizedBox(width: size, height: size, child: Icon(icon, color: color, size: 22)),
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.color = CS.humo, this.size = 20, this.trailing});

  final String text;
  final Color color;
  final double size;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: Text(text.toUpperCase(), style: CS.cond(size, color: color))),
        ?trailing,
      ],
    );
  }
}

/// Grafito card with a colored left bar.
class BarCard extends StatelessWidget {
  const BarCard({super.key, required this.child, this.color = CS.rojo, this.padding = const EdgeInsets.all(14), this.onTap});

  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.only(topRight: Radius.circular(CS.radio), bottomRight: Radius.circular(CS.radio));
    return Material(
      color: CS.grafito,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 4))),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = CS.humo, this.background = CS.acero, this.icon});

  final String text;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: CS.body(13, color: color)),
        ],
      ),
    );
  }
}

/// Segmented buttons: selected = white border on acero.
class SegButtons<T> extends StatelessWidget {
  const SegButtons({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelect,
    this.height = 50,
    this.columns,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelect;
  final double height;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final cols = columns ?? values.length;
    final rows = <Widget>[];
    for (var r = 0; r < values.length; r += cols) {
      final rowVals = values.sublist(r, math.min(r + cols, values.length));
      rows.add(Row(
        children: [
          for (var i = 0; i < cols; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: i < rowVals.length ? _btn(rowVals[i]) : const SizedBox()),
          ],
        ],
      ));
    }
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) const SizedBox(height: 8), rows[i]],
      ],
    );
  }

  Widget _btn(T v) {
    final on = v == selected;
    return Semantics(
      selected: on,
      button: true,
      child: Material(
        color: on ? CS.acero : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CS.radio),
          side: BorderSide(color: on ? CS.blanco : CS.linea),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CS.radio),
          onTap: () => onSelect(v),
          child: SizedBox(
            height: height,
            child: Center(
              child: Text(label(v),
                  style: CS.body(15, color: on ? CS.blanco : CS.humo, weight: FontWeight.w500),
                  textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}

class CsToggle extends StatelessWidget {
  const CsToggle({super.key, required this.value, required this.onChanged, this.label});

  final bool value;
  final ValueChanged<bool> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: label,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 54,
          height: 32,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: value ? CS.rojo : CS.linea, borderRadius: BorderRadius.circular(99)),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(color: CS.blanco, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.text, {super.key, required this.onTap, this.height = 58, this.color = CS.rojo, this.ink = CS.blanco, this.size = 22});

  final String text;
  final VoidCallback? onTap;
  final double height;
  final Color color;
  final Color ink;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? color : CS.acero,
      borderRadius: BorderRadius.circular(CS.radio),
      child: InkWell(
        borderRadius: BorderRadius.circular(CS.radio),
        onTap: onTap,
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Center(
            child: Text(text.toUpperCase(),
                style: CS.cond(size, color: enabled ? ink : CS.humo), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton(this.text, {super.key, required this.onTap, this.height = 46, this.icon, this.color = CS.blanco});

  final String text;
  final VoidCallback? onTap;
  final double height;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CS.radio),
        side: const BorderSide(color: CS.linea),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(CS.radio),
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: color), const SizedBox(width: 6)],
              Text(text, style: CS.body(15, color: onTap == null ? CS.humo : color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Square transport button.
class SquareButton extends StatelessWidget {
  const SquareButton({super.key, required this.icon, required this.onTap, this.size = 54, this.color = CS.grafito, this.ink = CS.blanco, this.tooltip, this.iconSize = 26, this.border});

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color color;
  final Color ink;
  final String? tooltip;
  final double iconSize;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CS.radio),
        side: border == null ? BorderSide.none : BorderSide(color: border!),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(CS.radio),
        onTap: onTap,
        child: SizedBox(width: size, height: size, child: Icon(icon, color: ink, size: iconSize)),
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// Whole-track waveform from 30-per-second peaks.
class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.peaks,
    required this.progress,
    this.played = CS.rojo,
    this.rest = CS.linea,
    this.marker,
    this.height = 56,
    this.onSeek,
    this.markerColor = CS.blanco,
  });

  final Uint8List? peaks;
  final double progress; // 0..1
  final Color played;
  final Color rest;
  final double? marker; // 0..1
  final double height;
  final ValueChanged<double>? onSeek;
  final Color markerColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      void seek(Offset p) => onSeek?.call((p.dx / w).clamp(0.0, 1.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onSeek == null ? null : (d) => seek(d.localPosition),
        onHorizontalDragUpdate: onSeek == null ? null : (d) => seek(d.localPosition),
        child: CustomPaint(
          size: Size(w, height),
          painter: _WavePainter(peaks, progress, played, rest, marker, markerColor),
        ),
      );
    });
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.progress, this.played, this.rest, this.marker, this.markerColor);

  final Uint8List? peaks;
  final double progress;
  final Color played;
  final Color rest;
  final double? marker;
  final Color markerColor;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0, gap = 2.0;
    final n = math.max(1, (size.width / (barW + gap)).floor());
    final p = Paint();
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      double v;
      final pk = peaks;
      if (pk == null || pk.isEmpty) {
        v = 0.15 + 0.1 * math.sin(i * 0.7).abs();
      } else {
        final a = (i * pk.length / n).floor();
        final b = math.max(a + 1, ((i + 1) * pk.length / n).floor());
        var m = 0;
        for (var k = a; k < b && k < pk.length; k++) {
          if (pk[k] > m) m = pk[k];
        }
        v = m / 255.0;
      }
      final h = math.max(2.0, v * size.height);
      p.color = (i + 0.5) / n <= progress ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(i * (barW + gap), mid - h / 2, barW, h), const Radius.circular(1.5)),
        p,
      );
    }
    if (marker != null) {
      final x = marker!.clamp(0.0, 1.0) * size.width;
      p.color = markerColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x - 1.5, -4, 3, size.height + 8), const Radius.circular(1.5)),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.peaks != peaks || o.progress != progress || o.marker != marker || o.played != played;
}

/// Zoomed waveform that scrolls under a fixed play head (DJ decks).
class ScrollingWave extends StatelessWidget {
  const ScrollingWave({super.key, required this.peaks, required this.position, required this.color, this.window = 8, this.height = 48, this.cues = const []});

  final Uint8List? peaks;
  final double position; // seconds
  final Color color;
  final double window; // seconds shown on each side
  final double height;
  final List<double> cues;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(double.infinity, height),
        painter: _ScrollPainter(peaks, position, color, window, cues),
      );
}

class _ScrollPainter extends CustomPainter {
  _ScrollPainter(this.peaks, this.position, this.color, this.window, this.cues);

  final Uint8List? peaks;
  final double position;
  final Color color;
  final double window;
  final List<double> cues;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final mid = size.height / 2;
    const step = 3.0;
    final n = (size.width / step).floor();
    final secPerBar = window * 2 / n;
    for (var i = 0; i < n; i++) {
      final t = position - window + i * secPerBar;
      double v = 0;
      final pk = peaks;
      if (pk != null && t >= 0) {
        final k = (t * 30).floor();
        if (k < pk.length) v = pk[k] / 255.0;
      }
      final h = math.max(1.0, v * size.height);
      p.color = t < position ? color.withValues(alpha: 0.45) : color;
      canvas.drawRect(Rect.fromLTWH(i * step, mid - h / 2, 2, h), p);
    }
    p.color = CS.ambar;
    for (final c in cues) {
      final x = (c - position + window) / (window * 2) * size.width;
      if (x >= 0 && x <= size.width) canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), p);
    }
    p.color = CS.blanco;
    canvas.drawRect(Rect.fromLTWH(size.width / 2 - 1, -3, 2, size.height + 6), p);
  }

  @override
  bool shouldRepaint(_ScrollPainter o) => o.position != position || o.peaks != peaks || o.cues.length != cues.length;
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

/// Opens a screen so that "back" always lands on Inicio (no long history).
void openScreen(BuildContext context, Widget screen) {
  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => screen), (r) => r.isFirst);
}

/// Back to Inicio from anywhere.
void goHome(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);

/// Cover picture from inside the file, or a tile in the genre's color.
class CoverArt extends StatelessWidget {
  const CoverArt(this.track, {super.key, this.size = 48, this.radius = 6});

  final Track? track;
  final double size;
  final double radius;

  static const _tints = [
    (Color(0xFF3A0D0F), Color(0xFFFF6B70)),
    (Color(0xFF3A2A10), CS.ambar),
    (Color(0xFF262626), Color(0xFFD0D0D0)),
  ];

  @override
  Widget build(BuildContext context) {
    final t = track;
    final f = t == null ? null : app.library.coverOf(t);
    if (t != null && f == null && t.remote && t.hasCover) app.net.fetchCover(t);
    final tint = _tints[(t?.folder.hashCode ?? 0).abs() % _tints.length];
    final px = (size * MediaQuery.of(context).devicePixelRatio).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: f != null
            ? Image.file(
                f,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: px,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(tint),
              )
            : _placeholder(tint),
      ),
    );
  }

  Widget _placeholder((Color, Color) tint) => Container(
        decoration: BoxDecoration(color: tint.$1, border: Border(left: BorderSide(color: tint.$2, width: 3))),
        alignment: Alignment.center,
        child: Icon(Icons.music_note, color: tint.$2, size: size * 0.4),
      );
}

/// "8A · Festivo" style details for a track.
String trackDetails(Track t) {
  final parts = <String>[
    if (camelot(t.key).isNotEmpty) camelot(t.key),
    if (t.mood.isNotEmpty) t.mood,
  ];
  return parts.join(' · ');
}

