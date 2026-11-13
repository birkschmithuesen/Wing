import 'support/color_contrast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';

WingTokens? _tokensFrom(ThemeData theme) => theme.extension<WingTokens>();

Future<WingTokens> _pumpAndReadTokens(
  WidgetTester tester,
  ThemeData theme,
) async {
  late WingTokens seen;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          seen = WingTokens.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return seen;
}

void main() {
  group('Studio button press', () {
    testWidgets('held pointer release after leaving the screen is harmless', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioButtonPress(
              child: TextButton(onPressed: () {}, child: const Text('Hold')),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Left'))),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'framework Back button receives the shared press from the theme',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Details')),
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final back = find.byType(BackButton);
        expect(back, findsOneWidget);
        final gesture = await tester.startGesture(tester.getCenter(back));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final motion = find.descendant(
          of: back,
          matching: find.byKey(const ValueKey('studio-button-press-transform')),
        );
        expect(motion, findsOneWidget);
        expect(
          tester.widget<Transform>(motion).transform.entry(0, 0),
          closeTo(.97, .001),
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.text('Open'), findsOneWidget);
      },
    );

    testWidgets('nested action compresses only the inner target', (
      tester,
    ) async {
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioButtonPress(
              child: ListTile(
                title: const Text('Row'),
                onTap: () => actions += 10,
                trailing: StudioButtonPress(
                  child: IconButton(
                    onPressed: () => actions++,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(IconButton)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final transforms = tester
          .widgetList<Transform>(
            find.byKey(const ValueKey('studio-button-press-transform')),
          )
          .toList();
      expect(transforms.first.transform.entry(0, 0), 1);
      expect(transforms.last.transform.entry(0, 0), closeTo(.97, .001));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(actions, 1);
    });

    testWidgets(
      'scroll movement cancels compression without intercepting drag',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: scroll,
                children: [
                  for (var i = 0; i < 30; i++)
                    StudioButtonPress(
                      child: ListTile(title: Text('Row $i'), onTap: () {}),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.drag(find.text('Row 3'), const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(0));
        final transforms = tester.widgetList<Transform>(
          find.byKey(const ValueKey('studio-button-press-transform')),
        );
        expect(transforms, isNotEmpty);
        for (final motion in transforms) {
          expect(motion.transform.entry(0, 0), 1);
        }
      },
    );

    testWidgets('menu entry retains selection and dismissal', (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioButtonPress(
              child: PopupMenuButton<String>(
                onSelected: (value) => selected = value,
                itemBuilder: (_) => [
                  const StudioPopupMenuItem(
                    value: 'retry',
                    child: Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(selected, 'retry');
      expect(find.text('Retry'), findsNothing);
    });

    for (final reduceMotion in [false, true]) {
      testWidgets('quick tap confirms immediately reduced=$reduceMotion', (
        tester,
      ) async {
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Scaffold(
                body: Center(
                  child: StudioButtonPress(
                    child: OutlinedButton(
                      onPressed: () => taps++,
                      child: const Icon(Icons.refresh),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final button = find.byType(OutlinedButton);
        final motion = find
            .descendant(
              of: find.byType(StudioButtonPress),
              matching: find.byKey(
                const ValueKey('studio-button-press-transform'),
              ),
            )
            .first;
        double scale() =>
            tester.widget<Transform>(motion).transform.entry(0, 0);
        final targetBounds = tester.getRect(find.byType(StudioButtonPress));
        final targetSize = tester.getSize(button);
        final gesture = await tester.startGesture(tester.getCenter(button));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pump();
        expect(taps, 1, reason: 'Feedback must not defer activation');
        await tester.pump(const Duration(milliseconds: 60));
        expect(scale(), reduceMotion ? 1 : lessThan(1));
        expect(tester.getRect(find.byType(StudioButtonPress)), targetBounds);
        expect(tester.getSize(button), targetSize);
        expect(tester.widget<Transform>(motion).transformHitTests, isFalse);
        await tester.pumpAndSettle();
        expect(scale(), 1);
      });
    }

    testWidgets('keyboard activation has no scale motion', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioButtonPress(
              child: IconButton(
                focusNode: focus,
                onPressed: () => taps++,
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 120));
      final motion = find
          .descendant(
            of: find.byType(StudioButtonPress),
            matching: find.byKey(
              const ValueKey('studio-button-press-transform'),
            ),
          )
          .first;
      expect(tester.widget<Transform>(motion).transform.entry(0, 0), 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('cancelled and disabled presses do not activate', (
      tester,
    ) async {
      var taps = 0;
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return StudioButtonPress(
                  child: FilledButton(
                    onPressed: enabled ? () => taps++ : null,
                    child: const Icon(Icons.refresh),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final button = find.byType(FilledButton);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(taps, 0);
      update(() => enabled = false);
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(taps, 0);
      final motion = find
          .descendant(
            of: find.byType(StudioButtonPress),
            matching: find.byKey(
              const ValueKey('studio-button-press-transform'),
            ),
          )
          .first;
      expect(tester.widget<Transform>(motion).transform.entry(0, 0), 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('WingSpacing', () {
    test('exposes a strictly increasing 4dp-based scale', () {
      const scale = [
        WingSpacing.xs,
        WingSpacing.sm,
        WingSpacing.md,
        WingSpacing.lg,
        WingSpacing.xl,
      ];

      for (final step in scale) {
        expect(step % 4, 0, reason: '$step must sit on the 4dp grid');
      }
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]));
      }
    });

    test('radii grow from control to sheet', () {
      expect(WingRadius.sm, lessThan(WingRadius.md));
      expect(WingRadius.md, lessThan(WingRadius.xl));
    });

    test('motion durations stay inside the roadmap 150-250ms budget', () {
      expect(WingMotion.fast.inMilliseconds, greaterThanOrEqualTo(100));
      expect(WingMotion.standard.inMilliseconds, inInclusiveRange(150, 250));
      expect(WingMotion.standard, greaterThan(WingMotion.fast));
    });
  });

  group('WingTokens', () {
    test('dark and light token sets are distinct but complete', () {
      final dark = WingTokens.dark();
      final light = WingTokens.light();

      for (final tokens in [dark, light]) {
        expect(tokens.accent.a, 1.0);
        expect(tokens.running, isNot(tokens.blocked));
        expect(tokens.success, isNot(tokens.danger));
        expect(tokens.blocked, isNot(tokens.success));
      }
      expect(dark.surface, isNot(light.surface));
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
    });

    test('Studio pairs the canonical Teal choice across themes', () {
      final savedAccent = WorkspaceAccent.teal;
      expect(savedAccent.label, 'Teal');
      expect(WingTokens.dark().accent, savedAccent.dark);
      expect(WingTokens.light().accent, savedAccent.light);
    });

    test('lerp keeps a valid token set mid-animation', () {
      final dark = WingTokens.dark();
      final light = WingTokens.light();

      final mid = dark.lerp(light, 0.5);

      expect(mid.accent, Color.lerp(dark.accent, light.accent, .5));
      expect(mid.surface, isNot(dark.surface));
    });

    test('lerp against a foreign extension keeps this token set', () {
      final dark = WingTokens.dark();

      expect(dark.lerp(null, 0.5), same(dark));
    });

    test('copyWith overrides only the named token', () {
      final tokens = WingTokens.dark();
      final recolored = tokens.copyWith(danger: const Color(0xFF00FF00));

      expect(recolored.danger, const Color(0xFF00FF00));
      expect(recolored.success, tokens.success);
      expect(recolored.accent, tokens.accent);
    });
  });

  group('WingTypography', () {
    test('the ramp is ordered and mono is a monospace family', () {
      final ramp = WingTypography.ramp(Brightness.dark);

      expect(ramp.display.fontSize, greaterThan(ramp.title.fontSize!));
      expect(ramp.title.fontSize, greaterThan(ramp.section.fontSize!));
      expect(ramp.section.fontSize, greaterThanOrEqualTo(ramp.body.fontSize!));
      expect(ramp.body.fontSize, greaterThan(ramp.label.fontSize!));
      expect(ramp.mono.fontFamily, isNotNull);
      expect(ramp.mono.fontFamilyFallback, contains('monospace'));
    });
  });

  group('wingTheme', () {
    for (final brightness in Brightness.values) {
      testWidgets('default dialogs use Studio section type in $brightness', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: const Scaffold(
              body: AlertDialog(
                title: Text('Room picture'),
                content: Text('Describe the image'),
              ),
            ),
          ),
        );
        final titleStyle = DefaultTextStyle.of(
          tester.element(find.text('Room picture')),
        ).style;
        expect(
          titleStyle.fontSize,
          WingTypography.ramp(brightness).section.fontSize,
        );
        expect(titleStyle.fontFamily, WingTypography.sans);
      });
    }

    testWidgets('attaches tokens to the dark theme', (tester) async {
      final theme = wingTheme(Brightness.dark);
      expect(_tokensFrom(theme), isNotNull);

      final tokens = await _pumpAndReadTokens(tester, theme);
      expect(tokens.brightness, Brightness.dark);
    });

    testWidgets('attaches tokens to the light theme', (tester) async {
      final theme = wingTheme(Brightness.light);
      expect(_tokensFrom(theme), isNotNull);

      final tokens = await _pumpAndReadTokens(tester, theme);
      expect(tokens.brightness, Brightness.light);
    });

    testWidgets('falls back to matching tokens when none are attached', (
      tester,
    ) async {
      final tokens = await _pumpAndReadTokens(
        tester,
        ThemeData(brightness: Brightness.light, useMaterial3: true),
      );

      expect(tokens.brightness, Brightness.light);
      expect(tokens.accent, WingTokens.light().accent);
    });

    test('uses Material 3 and keeps the accent in the color scheme', () {
      for (final brightness in Brightness.values) {
        final theme = wingTheme(brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.brightness, brightness);
        expect(theme.colorScheme.brightness, brightness);
      }
    });

    test('body text meets the WCAG AA contrast floor on the base surface', () {
      for (final brightness in Brightness.values) {
        final tokens = _tokensFrom(wingTheme(brightness))!;
        expect(
          contrastRatio(tokens.onSurface, tokens.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'body text must stay readable in $brightness',
        );
      }
    });

    test('muted text meets the AA ordinary-text floor', () {
      for (final brightness in Brightness.values) {
        final tokens = _tokensFrom(wingTheme(brightness))!;
        expect(
          contrastRatio(tokens.muted, tokens.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'secondary text must remain legible in $brightness',
        );
      }
    });
  });
}
