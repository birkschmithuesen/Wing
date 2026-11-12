import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection_icon.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/connection_icon_picker.dart';
import 'package:wing/core/widgets/server_connection_label.dart';

const _capture = bool.fromEnvironment('CAPTURE_CONNECTION_ICONS');
const _frame = Key('icon-render');

Future<void> capture(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/connection-review')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> openPicker(
  WidgetTester tester, {
  required Future<void> Function(ConnectionIcon) save,
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConnectionIconPicker(
              context,
              connectionName: 'Claw · a longer connection name',
              initialIcon: ConnectionIcon.cloud,
              onSave: save,
            ),
            child: const Text('Appearance'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Appearance'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$directory/$name').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final width in [390.0, 320.0]) {
      testWidgets('connection appearance render ${brightness.name} at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(width == 320 ? 2 : 1)),
                child: child!,
              ),
              home: Scaffold(
                appBar: AppBar(title: const Text('Connections')),
                body: Builder(
                  builder: (context) => Card(
                    margin: const EdgeInsets.all(16),
                    child: ListTile(
                      horizontalTitleGap: 0,
                      leading: ServerConnectionIndicator(
                        label: 'Claw',
                        icon: ConnectionIcon.rocket,
                        onIconPressed: () => showConnectionIconPicker(
                          context,
                          connectionName: 'Claw',
                          initialIcon: ConnectionIcon.rocket,
                          onSave: (_) async {},
                        ),
                      ),
                      title: const Text('Claw'),
                      subtitle: const Text('hermes.hollinger.asia:443'),
                      trailing: IconButton(
                        tooltip: 'Appearance',
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => showConnectionIconPicker(
                          context,
                          connectionName: 'Claw',
                          initialIcon: ConnectionIcon.rocket,
                          onSave: (_) async {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final led = tester.getRect(
          find.byKey(const ValueKey('server-connection-led')),
        );
        expect(tester.getRect(find.text('Claw')).left - led.right, 16);
        await capture(tester, 'connection-icons-row-${brightness.name}-$width');
        await tester.tap(find.byTooltip('Change connection icon'));
        await tester.pumpAndSettle();
        final heading = find.text('Instance icon');
        expect(
          tester.widget<Text>(heading).style!.fontSize,
          Theme.of(
            tester.element(heading),
          ).dialogTheme.titleTextStyle!.fontSize,
        );
        await capture(
          tester,
          'connection-icons-picker-${brightness.name}-$width',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('icon choices fit narrow enlarged ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ConnectionIcon? saved;
      final semantics = tester.ensureSemantics();
      await openPicker(
        tester,
        brightness: brightness,
        scale: 2,
        save: (icon) async => saved = icon,
      );
      final rocket = find.byKey(const ValueKey('connection-icon-rocket'));
      await tester.ensureVisible(rocket);
      await tester.tap(rocket);
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(
        tester.getSemantics(rocket),
        matchesSemantics(
          label: 'Rocket',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(tester.getSize(rocket).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(rocket).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(find.byTooltip('Save connection icon'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save connection icon'));
      await tester.pumpAndSettle();
      expect(saved, ConnectionIcon.rocket);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('cancel discards selection and keyboard can activate a choice', (
    tester,
  ) async {
    ConnectionIcon? saved;
    await openPicker(tester, save: (icon) async => saved = icon);
    final rocket = find.byKey(const ValueKey('connection-icon-rocket'));
    Focus.of(
      tester.element(
        find.descendant(of: rocket, matching: find.byType(Icon)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<IconButton>(rocket).isSelected, isTrue);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('connection-icon-cloud')),
          )
          .isSelected,
      isTrue,
    );
  });

  testWidgets('pending save disables writes and failure leaves a retry', (
    tester,
  ) async {
    final pending = Completer<void>();
    var attempts = 0;
    await openPicker(
      tester,
      save: (_) {
        attempts++;
        return attempts == 1 ? pending.future : Future.value();
      },
    );
    await tester.tap(find.byTooltip('Save connection icon'));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('connection-icon-home')),
          )
          .onPressed,
      isNull,
    );
    pending.completeError(StateError('disk unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t save this icon. Try again.'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Save connection icon'));
    await tester.tap(find.byTooltip('Save connection icon'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Instance icon'), findsNothing);
  });
}
