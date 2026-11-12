import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/compact_switch.dart';

void main() {
  setUpAll(() async {
    final fontPath = Platform.environment['HERMES_CONTROL_FONT'];
    if (fontPath != null) {
      final loader = FontLoader(WingTypography.sans);
      loader.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  Future<void> showSwitch(
    WidgetTester tester, {
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: CompactSwitch(
            semanticLabel: 'Enable research',
            value: value,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );

  testWidgets('small face retains a minimum 48 dp edge-tappable target', (
    tester,
  ) async {
    bool? requested;
    await showSwitch(
      tester,
      value: false,
      onChanged: (value) => requested = value,
    );
    final control = find.byType(CompactSwitch);
    final size = tester.getSize(control);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    await tester.tapAt(tester.getTopLeft(control) + const Offset(2, 2));
    expect(requested, isTrue);
  });

  testWidgets('focused switch toggles through the keyboard', (tester) async {
    bool? requested;
    await showSwitch(
      tester,
      value: true,
      onChanged: (value) => requested = value,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(requested, isFalse);
  });

  for (final value in [false, true]) {
    testWidgets('accessibility exposes the current switch value $value', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await showSwitch(tester, value: value, onChanged: (_) {});
        expect(
          tester.getSemantics(find.byType(CompactSwitch)),
          matchesSemantics(
            label: 'Enable research',
            hasToggledState: true,
            isToggled: value,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('disabled switch exposes disabled state without a tap action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await showSwitch(tester, value: false, onChanged: null);
      expect(
        tester.getSemantics(find.byType(CompactSwitch)),
        matchesSemantics(
          label: 'Enable research',
          hasToggledState: true,
          hasEnabledState: true,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} rows wrap at 320dp and 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                body: ListView(
                  children: [
                    CompactSwitchListTile(
                      title: const Text('agent-runtime-supervision'),
                      subtitle: const Text('autonomous-ai-agents · bundled'),
                      value: true,
                      onChanged: (_) => calls++,
                    ),
                    const CompactSwitchListTile(
                      title: Text('Disabled setting'),
                      subtitle: Text('Saving changes on Hermes'),
                      value: false,
                      onChanged: null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('agent-runtime-supervision'));
      expect(calls, 1);
      await tester.tap(find.byType(CompactSwitch).last);
      expect(calls, 1);
      if (Platform.environment['HERMES_CONTROL_PREVIEWS'] == '1') {
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/control-previews/${brightness.name}-large-text.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
