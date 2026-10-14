import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_palette.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  for (final accent in WorkspaceAccent.values) {
    for (final brightness in Brightness.values) {
      final tokens = wingTheme(
        brightness,
        accent: brightness == Brightness.dark ? accent.dark : accent.light,
      ).extension<WingTokens>()!;
      test('${accent.name} ${brightness.name}: label ≥ 3:1, hint ≥ 4.5:1, badge ≥ 4.5:1', () {
        for (final phase in CarPhase.values) {
          final c = carColorsFor(phase, tokens, brightness);
          expect(carContrast(c.label, c.fill), greaterThanOrEqualTo(3.0), reason: '$phase label');
          expect(carContrast(c.hint, c.fill), greaterThanOrEqualTo(4.5), reason: '$phase hint');
        }
        for (final connection in CarConnection.values) {
          final b = carBadgeColorsFor(connection, tokens);
          expect(carContrast(b.foreground, b.background), greaterThanOrEqualTo(4.5), reason: '$connection');
        }
      });
      if (brightness == Brightness.dark) {
        test('${accent.name} night has no pure white', () {
          final colors = [
            for (final phase in CarPhase.values) ...[
              carColorsFor(phase, tokens, brightness).fill,
              carColorsFor(phase, tokens, brightness).label,
              carColorsFor(phase, tokens, brightness).hint,
              ?carColorsFor(phase, tokens, brightness).border,
            ],
            for (final connection in CarConnection.values) ...[
              carBadgeColorsFor(connection, tokens).background,
              carBadgeColorsFor(connection, tokens).foreground,
            ],
          ];
          for (final color in colors) {
            expect(color.toARGB32(), isNot(0xFFFFFFFF));
          }
        });
      }
    }
  }

  test('day listening uses the danger token with white text; badge colours follow the connection', () {
    final tokens = wingTheme(Brightness.light).extension<WingTokens>()!;
    final c = carColorsFor(CarPhase.listening, tokens, Brightness.light);
    expect(c.fill, tokens.danger);
    expect(c.label, Colors.white);
    expect(carContrast(Colors.white, const Color(0xFFB91C1C)), closeTo(6.5, 0.1));
    expect(carBadgeColorsFor(CarConnection.ok, tokens).foreground, tokens.success);
    expect(carBadgeColorsFor(CarConnection.reconnecting, tokens).foreground, tokens.warning);
    expect(carBadgeColorsFor(CarConnection.offline, tokens).foreground, tokens.danger);
    expect(carBadgeColorsFor(CarConnection.offline, tokens).background, tokens.surface);
  });
}
