import 'package:flutter/material.dart';

import '../models/profile_colors.dart';

/// Desktop's name-derived profile hue (unsigned 32-bit UTF-16 hash).
/// Verified against Hermes 7c6f21a5e12ba9b1c674ec9b410fa6b8c45de4f8.
Color? desktopProfileColor(String name) {
  final key = name.trim();
  if (key.isEmpty || key == 'default') return null;
  final hash = key.codeUnits.fold<int>(
    0,
    (hash, unit) => (hash * 31 + unit) & 0xffffffff,
  );
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), .68, .58).toColor();
}

/// Desktop's twelve profile picker hues, spaced thirty degrees apart.
final List<Color> desktopProfileSwatches = List.unmodifiable([
  for (var hue = 0; hue < 360; hue += 30)
    HSLColor.fromAHSL(1, hue.toDouble(), .68, .58).toColor(),
]);

/// Rendering interprets typed choices; it does not decode stored values.
Color? profileChoiceColor(String name, ProfileColorChoice? choice) =>
    switch (choice?.slot) {
      final slot? => desktopProfileSwatches[slot],
      null => desktopProfileColor(name),
    };
