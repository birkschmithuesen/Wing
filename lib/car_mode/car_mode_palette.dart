import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/wing_theme.dart';
import 'car_mode_state.dart';

class CarColors {
  const CarColors({required this.fill, required this.label, required this.hint, this.border});
  final Color fill;
  final Color label;
  final Color hint;
  final Color? border;
}

class CarBadgeColors {
  const CarBadgeColors({required this.background, required this.foreground});
  final Color background;
  final Color foreground;
}

/// Day: the state token as fill with white text. Night: the token mixed 28 %
/// into the dark canvas, token-coloured label and a softer hint; no white.
CarColors carColorsFor(CarPhase phase, WingTokens t, Brightness brightness) {
  final night = brightness == Brightness.dark;
  if (phase == CarPhase.idle) {
    return CarColors(fill: t.raised, label: t.accent, hint: t.muted, border: t.accent);
  }
  final token = switch (phase) {
    CarPhase.listening || CarPhase.transcribing => t.danger,
    CarPhase.thinking => t.running,
    CarPhase.speaking => t.accent,
    CarPhase.attention || CarPhase.error => t.warning,
    CarPhase.waiting || CarPhase.idle => t.muted,
  };
  if (!night) return CarColors(fill: token, label: Colors.white, hint: Colors.white);
  return CarColors(
    fill: Color.lerp(t.surface, token, .28)!,
    label: token,
    hint: Color.lerp(token, t.onSurface, .5)!,
  );
}

/// The connection badge: a surface pill with token-coloured border, icon and
/// text, so it stands out on every state fill (spec §4.4).
CarBadgeColors carBadgeColorsFor(CarConnection c, WingTokens t) => CarBadgeColors(
  background: t.surface,
  foreground: switch (c) {
    CarConnection.ok => t.success,
    CarConnection.reconnecting => t.warning,
    CarConnection.offline => t.danger,
  },
);

/// WCAG 2 contrast ratio.
double carContrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
