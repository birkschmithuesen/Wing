import 'dart:math' as math;
import 'package:flutter/material.dart';

/// WCAG relative luminance contrast ratio between two opaque sRGB colors.
///
/// Exposed so accessibility expectations live in tests rather than in review
/// opinions: ordinary text, including secondary text, must clear 4.5:1.
/// Only qualifying large text uses the reduced 3:1 threshold.
double contrastRatio(Color foreground, Color background) {
  final a = _relativeLuminance(foreground);
  final b = _relativeLuminance(background);
  final lighter = math.max(a, b);
  final darker = math.min(a, b);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  double channel(double value) {
    return value <= 0.04045
        ? value / 12.92
        : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}
