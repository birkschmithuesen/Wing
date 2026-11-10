import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_fallback_page.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/administration_fixture.dart';

// Current stock canonical fallback routes preserve all routing fields.
// Legacy strings/coercion are deliberately removed per the clean-breaking policy.
const _entry = {
  'provider': 'example',
  'model': 'backup-model',
  'base_url': 'https://example.invalid/v1',
  'key_env': 'EXAMPLE_API_KEY',
};

Future<void> _open(WidgetTester tester, AdministrationFixture fixture) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AdminFallbackPage(profile: fixture.server.profile('default')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _manage(WidgetTester tester, int index, String action) async {
  await tester.tap(find.byTooltip('Manage fallback $index'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

Future<void> _selectSecond(WidgetTester tester, String action) async {
  final model = find.byKey(const Key('admin-model-example-second'));
  if (!tester.any(model.hitTestable())) {
    await tester.tap(find.byKey(const Key('admin-model-provider-example')));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(model);
  await tester.tap(model);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(action).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final invalid in <Object?>[
    null,
    42,
    false,
    {},
    'example/legacy-model',
  ]) {
    testWidgets(
      'malformed ${invalid.runtimeType} is visible and never rewritten',
      (tester) async {
        final fixture = AdministrationFixture();
        fixture.configs['default']!['fallback_providers'] = [invalid, _entry];
        await _open(tester, fixture);
        expect(find.textContaining('Could not load'), findsOneWidget);
        expect(find.byTooltip('Add fallback'), findsNothing);
        expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
        expect(fixture.configs['default']!['fallback_providers'], [
          invalid,
          _entry,
        ]);
      },
    );
  }

  testWidgets('editing a row preserves its routing fields', (tester) async {
    final fixture = AdministrationFixture();
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    await tester.tap(find.text('backup-model'));
    await tester.pumpAndSettle();
    await _selectSecond(tester, 'Save fallback');
    expect(fixture.configs['default']!['fallback_providers'], [
      {..._entry, 'model': 'second'},
    ]);
  });

  testWidgets('malformed external configuration blocks a valid pending edit', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    fixture.configs['default']!['fallback_providers'] = [false, _entry];
    await _manage(tester, 1, 'Remove');
    expect(find.textContaining('could not be confirmed'), findsOneWidget);
    expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
    expect(fixture.configs['default']!['fallback_providers'], [false, _entry]);
  });

  testWidgets(
    'concurrent fallback changes require review before applying a pending list',
    (tester) async {
      final fixture = AdministrationFixture();
      fixture.configs['default']!['fallback_providers'] = [_entry];
      await _open(tester, fixture);
      fixture.configs['default']!['fallback_providers'] = [
        {'provider': 'example', 'model': 'external-model'},
      ];

      await tester.tap(find.byTooltip('Add fallback'));
      await tester.pumpAndSettle();
      await _selectSecond(tester, 'Add fallback');
      expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);
      expect(find.text('Review pending fallback change'), findsOneWidget);

      await tester.tap(find.text('Review pending fallback change'));
      await tester.pumpAndSettle();
      expect(find.textContaining('external-model'), findsWidgets);
      expect(find.textContaining('second'), findsWidgets);
      await tester.tap(find.byTooltip('Cancel').last);
      await tester.pumpAndSettle();
      expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);

      await tester.tap(find.text('Review pending fallback change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Apply pending list'));
      await tester.pumpAndSettle();
      expect(
        fixture.requests.where((request) => request.$1 == 'PUT'),
        hasLength(1),
      );
    },
  );

  const capture = bool.fromEnvironment('CAPTURE_FALLBACK');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('fallback ${brightness.name} at ${scale}x text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = AdministrationFixture('Claw');
        fixture.configs['default']!['fallback_providers'] = [
          {..._entry, 'model': 'first-model'},
          _entry,
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: const ValueKey('capture'),
              child: AdminFallbackPage(
                profile: fixture.server.profile('default'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('first-model'), 100);
        expect(find.text('first-model'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byTooltip('Manage fallback 1'),
          100,
        );
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('Manage fallback 1').hitTestable(),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(find.text('backup-model'), 100);
        expect(find.text('backup-model'), findsOneWidget);
        await tester.scrollUntilVisible(find.byTooltip('Add fallback'), 100);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Add fallback').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.drag(find.byType(ListView), const Offset(0, 1000));
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/fallback-review/${brightness.name}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  for (final value in <Object?>[
    {..._entry},
    'example/model',
    42,
  ]) {
    testWidgets(
      'non-list ${value.runtimeType} is reported without overwriting',
      (tester) async {
        final fixture = AdministrationFixture();
        fixture.configs['default']!['fallback_providers'] = value;
        await _open(tester, fixture);
        expect(find.text('No fallback models configured.'), findsNothing);
        expect(find.byTooltip('Add fallback'), findsNothing);
        expect(find.textContaining('Could not load'), findsOneWidget);
        expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      },
    );
  }

  for (final value in [
    <Object?>[],
    [_entry],
  ]) {
    testWidgets('fallback screen loads ${value.runtimeType}', (tester) async {
      final fixture = AdministrationFixture();
      fixture.configs['default']!['fallback_providers'] = value;
      await _open(tester, fixture);
      expect(find.byTooltip('Add fallback'), findsOneWidget);
      expect(find.textContaining('Could not load'), findsNothing);
    });
  }

  testWidgets('list edits save an ordered list with route metadata', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    await tester.tap(find.byTooltip('Add fallback'));
    await tester.pumpAndSettle();
    await _selectSecond(tester, 'Add fallback');
    expect(fixture.configs['default']!['fallback_providers'], [
      _entry,
      {'provider': 'example', 'model': 'second'},
    ]);
    await _manage(tester, 2, 'Move up');
    expect(fixture.configs['default']!['fallback_providers'], [
      {'provider': 'example', 'model': 'second'},
      _entry,
    ]);
    await _manage(tester, 1, 'Remove');
    await _manage(tester, 1, 'Remove');
    expect(fixture.configs['default']!['fallback_providers'], isEmpty);
    expect(find.textContaining('changed elsewhere'), findsNothing);
    final writes = fixture.requests.where((r) => r.$1 == 'PUT').toList();
    expect(writes, hasLength(4));
    for (final write in writes) {
      expect(write.$3['profile'], 'default');
      expect(write.$4!['profile'], 'default');
      expect((write.$4!['config'] as Map).keys, ['fallback_providers']);
    }
    expect(
      fixture.configs['personal']!.containsKey('fallback_providers'),
      false,
    );
  });

  testWidgets('external list change blocks saving until refreshed', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    fixture.configs['default']!['fallback_providers'] = [
      {..._entry, 'model': 'changed-model'},
    ];
    await _manage(tester, 1, 'Remove');
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('changed-model'), findsOneWidget);
    await _manage(tester, 1, 'Remove');
    expect(fixture.configs['default']!['fallback_providers'], isEmpty);
  });

  testWidgets('unconfirmed save retains the last confirmed entry', (
    tester,
  ) async {
    final fixture = AdministrationFixture()..ignoreSave = true;
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    await _manage(tester, 1, 'Remove');
    expect(find.text('backup-model'), findsOneWidget);
    expect(find.textContaining('Save not confirmed'), findsOneWidget);
    fixture.ignoreSave = false;
    await _manage(tester, 1, 'Remove');
    expect(find.text('backup-model'), findsNothing);
    expect(fixture.configs['default']!['fallback_providers'], isEmpty);
  });

  testWidgets('a failed request can retry and load a single entry', (
    tester,
  ) async {
    final fixture = AdministrationFixture()..failReads = true;
    fixture.configs['default']!['fallback_providers'] = [_entry];
    await _open(tester, fixture);
    expect(find.textContaining('Could not load'), findsOneWidget);
    fixture.failReads = false;
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('backup-model'), findsOneWidget);
    expect(find.textContaining('Could not load'), findsNothing);
  });
}
