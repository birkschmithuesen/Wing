import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'oklch_color.dart';

/// Opposing OKLCH hue, restrained chroma, and at least 4.5:1 against the canvas.
/// Conversion matrices: https://bottosson.github.io/posts/oklab/ (public domain).
/// Gamut mapping preserves hue by reducing chroma. Check contrast after rounding
/// to sRGB bytes, as those are the colours actually painted by the calendar.
Color usageSelectionColor(Color accent, Color canvas) {
  final source = colorOklch(accent);
  final lightness = source.lightness;
  final chroma = math.min(source.chroma, .12);
  final hue = source.hue + math.pi;
  final background = canvas.computeLuminance();
  bool passes(Color color) {
    final value = color.computeLuminance();
    return (math.max(value, background) + .05) /
            (math.min(value, background) + .05) >=
        4.5;
  }

  final original = oklchColor(lightness, chroma, hue);
  if (passes(original)) return original;
  Color? best;
  var distance = double.infinity;
  for (var i = 0; i <= 1000; i++) {
    final candidateL = i / 1000;
    final delta = (candidateL - lightness).abs();
    if (delta >= distance) continue;
    final candidate = oklchColor(candidateL, chroma, hue);
    if (passes(candidate)) {
      best = candidate;
      distance = delta;
    }
  }
  // A black or white endpoint always satisfies 4.5:1 on an opaque canvas.
  return best!;
}
