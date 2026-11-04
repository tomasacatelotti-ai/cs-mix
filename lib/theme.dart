import 'package:flutter/material.dart';

/// Palette taken from the Catelotti Sport apps.
class CS {
  static const negro = Color(0xFF000000);
  static const grafito = Color(0xFF161616);
  static const acero = Color(0xFF262626);
  static const linea = Color(0xFF333333);
  static const blanco = Color(0xFFFFFFFF);
  static const humo = Color(0xFF9C9C9C);
  static const rojo = Color(0xFFC4161C);
  static const rojoHover = Color(0xFFA31217);
  static const ambar = Color(0xFFE8A33D);
  static const ambarFondo = Color(0xFF3A2A10);
  static const rojoFondo = Color(0xFF3A0D0F);
  static const radio = 10.0;

  static const deckColors = [rojo, ambar];
  static const deckInk = [blanco, negro];

  /// Condensed italic uppercase headings (Saira Condensed look, from the variable font).
  static TextStyle cond(double size, {Color color = blanco}) => TextStyle(
        fontFamily: 'Saira',
        fontSize: size,
        fontStyle: FontStyle.italic,
        fontWeight: FontWeight.w700,
        letterSpacing: size * 0.02,
        height: 1.05,
        color: color,
        fontVariations: const [FontVariation('wdth', 75), FontVariation('wght', 700)],
      );

  static TextStyle body(double size, {Color color = blanco, FontWeight weight = FontWeight.w400}) => TextStyle(
        fontFamily: 'Saira',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.35,
        fontVariations: [FontVariation('wght', weight.value.toDouble())],
      );

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: 'Saira',
      scaffoldBackgroundColor: negro,
      colorScheme: const ColorScheme.dark(
        primary: rojo,
        onPrimary: blanco,
        secondary: ambar,
        onSecondary: negro,
        surface: grafito,
        onSurface: blanco,
        error: Color(0xFFFF8A8F),
      ),
    );
    return base.copyWith(
      dividerColor: acero,
      sliderTheme: const SliderThemeData(
        activeTrackColor: rojo,
        inactiveTrackColor: linea,
        thumbColor: blanco,
        overlayColor: Color(0x33C4161C),
        trackHeight: 6,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: grafito,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: grafito, surfaceTintColor: Colors.transparent),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: blanco,
        contentTextStyle: TextStyle(color: negro, fontFamily: 'Saira', fontSize: 15),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: negro,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: const TextStyle(color: humo),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: linea),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: rojo, width: 2),
        ),
      ),
    );
  }
}

String fmtTime(double sec, {bool negative = false}) {
  if (sec.isNaN || sec.isInfinite) sec = 0;
  final s = sec.abs().round();
  final m = s ~/ 60;
  final r = s % 60;
  final t = m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}' : '$m:${r.toString().padLeft(2, '0')}';
  return negative ? '−$t' : t;
}

String fmtBpm(double bpm) {
  if (bpm <= 0) return '—';
  return bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(1);
}

String fmtNum(double v, {int decimals = 1}) => v.toStringAsFixed(decimals).replaceAll('.', ',');
