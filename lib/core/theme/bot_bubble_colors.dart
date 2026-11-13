import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'oklch_color.dart';

/// The approved avatar-derived fill and its readable conversation foregrounds.
@immutable
class BotBubbleColors {
  const BotBubbleColors._(
    this.fill,
    this.footer,
    this.text,
    this.muted,
    this.link,
    this.timestamp,
  );
  final Color fill, footer, text, muted, link, timestamp;

  factory BotBubbleColors.fromAvatar(
    Color avatar,
    ThemeData theme, {
    double hueOffset = 0,
    double lightnessOffset = 0,
  }) {
    final source = colorOklch(avatar);
    final dark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    final chroma = math.min(source.chroma, dark ? .045 : .035);
    final hue = source.hue + hueOffset;
    var lightness = ((dark ? .31 : .93) + lightnessOffset).clamp(0.0, 1.0);
    var fill = oklchColor(lightness, chroma, hue);
    for (var i = 0; i < 100 && colorContrast(scheme.onSurface, fill) < 7; i++) {
      lightness = (lightness + (dark ? -.005 : .005)).clamp(0.0, 1.0);
      fill = oklchColor(lightness, chroma, hue);
    }
    fill = Color.lerp(scheme.surfaceContainerLow, fill, .35)!;
    final footer = Color.lerp(scheme.surface, fill, .5)!;
    final backgrounds = [
      fill,
      scheme.surfaceContainerHigh,
      scheme.surfaceContainerLow,
    ];
    return BotBubbleColors._(
      fill,
      footer,
      readableForeground(
        scheme.onSurface,
        backgrounds,
        theme.brightness,
        minimum: 7,
      ),
      readableForeground(
        scheme.onSurfaceVariant,
        backgrounds,
        theme.brightness,
      ),
      readableForeground(scheme.primary, backgrounds, theme.brightness),
      readableForeground(scheme.onSurfaceVariant, [footer], theme.brightness),
    );
  }

  /// Keep normal code surfaces; adapt prose, links and quotes to this fill.
  ThemeData markdownTheme(ThemeData theme) => theme.copyWith(
    colorScheme: theme.colorScheme.copyWith(
      onSurface: text,
      onSurfaceVariant: muted,
      primary: link,
    ),
    textTheme: theme.textTheme.apply(bodyColor: text, displayColor: text),
  );
}

/// Stable member-handle ordering makes repeated colors independent of message
/// order and roster order. Small hue variations keep colliding avatars related.
Map<String, BotBubbleColors> botBubblePalette(
  Map<String, Color> avatars,
  ThemeData theme,
) {
  final result = <String, BotBubbleColors>{};
  final handles = avatars.keys.toList()..sort();
  for (final handle in handles) {
    var colors = BotBubbleColors.fromAvatar(avatars[handle]!, theme);
    final neutral = colorOklch(avatars[handle]!).chroma < .025;
    final matchingAvatar = result.keys.any(
      (previous) => _distance(avatars[previous]!, avatars[handle]!) < .015,
    );
    for (
      var step = 1;
      step <= 20 &&
          matchingAvatar &&
          result.values.any(
            (other) => _distance(colors.fill, other.fill) < .008,
          );
      step++
    ) {
      final offset = ((step + 1) ~/ 2) * (step.isOdd ? 1 : -1) * math.pi / 10;
      colors = BotBubbleColors.fromAvatar(
        avatars[handle]!,
        theme,
        hueOffset: offset,
        lightnessOffset: neutral ? offset / (math.pi / 10) * .012 : 0,
      );
    }
    result[handle] = colors;
  }
  return Map.unmodifiable(result);
}

double _distance(Color a, Color b) {
  final x = colorOklch(a), y = colorOklch(b);
  return math.sqrt(
    math.pow(x.lightness - y.lightness, 2) +
        math.pow(x.chroma * math.cos(x.hue) - y.chroma * math.cos(y.hue), 2) +
        math.pow(x.chroma * math.sin(x.hue) - y.chroma * math.sin(y.hue), 2),
  );
}
