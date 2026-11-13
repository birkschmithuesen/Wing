import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Perceptual lightness, chroma and hue (radians), converted from sRGB.
({double lightness, double chroma, double hue}) colorOklch(Color color) {
  double linear(double v) =>
      v <= .04045 ? v / 12.92 : math.pow((v + .055) / 1.055, 2.4).toDouble();
  final r = linear(color.r), g = linear(color.g), b = linear(color.b);
  double cbrt(double v) => math.pow(v, 1 / 3).toDouble();
  final l = cbrt(.4122214708 * r + .5363325363 * g + .0514459929 * b);
  final m = cbrt(.2119034982 * r + .6806995451 * g + .1073969566 * b);
  final s = cbrt(.0883024619 * r + .2817188376 * g + .6299787005 * b);
  final lightness = .2104542553 * l + .793617785 * m - .0040720468 * s;
  final a = 1.9779984951 * l - 2.428592205 * m + .4505937099 * s;
  final bb = .0259040371 * l + .7827717662 * m - .808675766 * s;
  return (
    lightness: lightness,
    chroma: math.sqrt(a * a + bb * bb),
    hue: math.atan2(bb, a),
  );
}

/// Preserve hue and lightness by reducing chroma to fit sRGB.
/// Conversion matrices: https://bottosson.github.io/posts/oklab/ (public domain).
Color oklchColor(double lightness, double chroma, double hue) {
  List<double> rgb(double c) {
    final a = c * math.cos(hue), b = c * math.sin(hue);
    double cube(double v) => v * v * v;
    final l = cube(lightness + .3963377774 * a + .2158037573 * b);
    final m = cube(lightness - .1055613458 * a - .0638541728 * b);
    final s = cube(lightness - .0894841775 * a - 1.291485548 * b);
    return [
      4.0767416621 * l - 3.3077115913 * m + .2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - .3413193965 * s,
      -.0041960863 * l - .7034186147 * m + 1.707614701 * s,
    ];
  }

  bool fits(List<double> channels) =>
      channels.every((c) => c >= -1e-8 && c <= 1 + 1e-8);
  var channels = rgb(chroma);
  if (!fits(channels)) {
    var low = 0.0, high = chroma;
    for (var i = 0; i < 22; i++) {
      final mid = (low + high) / 2;
      if (fits(rgb(mid))) {
        low = mid;
      } else {
        high = mid;
      }
    }
    channels = rgb(low);
  }
  int byte(double value) {
    final v = value.clamp(0.0, 1.0);
    return (255 *
            (v <= .0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - .055))
        .round();
  }

  return Color.fromARGB(
    255,
    byte(channels[0]),
    byte(channels[1]),
    byte(channels[2]),
  );
}

/// WCAG relative-luminance contrast for opaque painted colors.
double colorContrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

/// Move a foreground toward the theme's text endpoint until every fill passes.
Color readableForeground(
  Color foreground,
  Iterable<Color> backgrounds,
  Brightness brightness, {
  double minimum = 4.5,
}) {
  final endpoint = brightness == Brightness.dark ? Colors.white : Colors.black;
  for (var i = 0; i <= 100; i++) {
    final color = Color.lerp(foreground, endpoint, i / 100)!;
    if (backgrounds.every(
      (background) => colorContrast(color, background) >= minimum,
    )) {
      return color;
    }
  }
  return endpoint;
}
