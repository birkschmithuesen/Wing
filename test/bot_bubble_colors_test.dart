import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/bot_bubble_colors.dart';
import 'package:wing/core/theme/oklch_color.dart';
import 'package:wing/core/theme/profile_colors.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  test(
    'bot prose, Markdown and time remain readable in every workspace theme',
    () {
      for (final brightness in Brightness.values) {
        for (final accent in WorkspaceAccent.values) {
          final theme = profileWorkspaceTheme(
            wingTheme(brightness),
            accent: accent,
          );
          for (final avatar in [
            ...desktopProfileSwatches,
            Colors.black,
            Colors.white,
            Colors.grey,
          ]) {
            final colors = BotBubbleColors.fromAvatar(avatar, theme);
            expect(
              colorContrast(colors.text, colors.fill),
              greaterThanOrEqualTo(7),
            );
            expect(
              colorContrast(colors.muted, colors.fill),
              greaterThanOrEqualTo(4.5),
            );
            expect(
              colorContrast(colors.link, colors.fill),
              greaterThanOrEqualTo(4.5),
            );
            expect(
              colorContrast(colors.timestamp, colors.footer),
              greaterThanOrEqualTo(4.5),
            );
            expect(
              colors.footer,
              Color.lerp(theme.colorScheme.surface, colors.fill, .5),
            );
            expect(colors.fill.a, 1);
            final markdown = colors.markdownTheme(theme);
            expect(
              markdown.colorScheme.surfaceContainerLow,
              theme.colorScheme.surfaceContainerLow,
            );
            expect(
              colorContrast(
                markdown.colorScheme.onSurface,
                markdown.colorScheme.surfaceContainerHigh,
              ),
              greaterThanOrEqualTo(7),
            );
          }
        }
      }
    },
  );

  test('approved twelve-color gallery keeps the avatar-derived fills', () {
    for (final brightness in Brightness.values) {
      final theme = wingTheme(brightness);
      final avatars = {
        for (var i = 0; i < desktopProfileSwatches.length; i++)
          '$i': desktopProfileSwatches[i],
      };
      final palette = botBubblePalette(avatars, theme);
      expect(palette.values.map((c) => c.fill).toSet(), hasLength(12));
      for (final entry in avatars.entries) {
        expect(
          palette[entry.key]!.fill,
          BotBubbleColors.fromAvatar(entry.value, theme).fill,
        );
      }
    }
  });

  test(
    'six matching avatars get distinct stable shades including neutral avatars',
    () {
      for (final brightness in Brightness.values) {
        final theme = wingTheme(brightness);
        for (final seed in [
          ...desktopProfileSwatches,
          Colors.black,
          Colors.white,
          Colors.grey,
        ]) {
          final avatars = {for (var i = 0; i < 6; i++) 'bot-$i': seed};
          final palette = botBubblePalette(avatars, theme);
          final reordered = botBubblePalette(
            Map.fromEntries(avatars.entries.toList().reversed),
            theme,
          );
          expect(palette.values.map((c) => c.fill).toSet(), hasLength(6));
          for (final entry in palette.entries) {
            expect(entry.value.fill, reordered[entry.key]!.fill);
            expect(
              colorContrast(entry.value.text, entry.value.fill),
              greaterThanOrEqualTo(7),
            );
            expect(
              colorContrast(entry.value.timestamp, entry.value.footer),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      }
    },
  );

  test(
    'workspace accent affects user colors while a bot keeps its own hue',
    () {
      for (final brightness in Brightness.values) {
        final fills = <Color>{}, userFills = <Color>{};
        for (final accent in WorkspaceAccent.values) {
          final theme = profileWorkspaceTheme(
            wingTheme(brightness),
            accent: accent,
          );
          fills.add(
            BotBubbleColors.fromAvatar(desktopProfileSwatches[9], theme).fill,
          );
          userFills.add(theme.colorScheme.primaryContainer);
        }
        expect(fills, hasLength(1));
        expect(userFills, hasLength(5));
      }
    },
  );
}
