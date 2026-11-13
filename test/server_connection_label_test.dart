import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/server_connection_label.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_CONNECTION_BUTTONS');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '/tmp/wing-header-fonts/${entry.value}',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final pixels = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/connection-buttons/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      pixels.dispose();
    });
  }

  testWidgets('unsupported chat endpoint stays red despite healthy HTTP', (
    tester,
  ) async {
    final status = ServerConnectionStatus('Claw')
      ..observeChatEndpoint(false)
      ..accessAvailable();
    addTearDown(status.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: ServerConnectionLabel(label: 'Claw', status: status),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('connection-status-target')))
          .label,
      contains('Chat address needs changing'),
    );
    semantics.dispose();
    await tester.tap(find.byKey(const ValueKey('connection-status-target')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This address doesn’t support Wing chats.'),
      findsOneWidget,
    );
    expect(find.textContaining('Open the instance menu'), findsOneWidget);
    expect(find.textContaining('network returns'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      testWidgets(
        'retry press and held recovery ${brightness.name} $enlarged',
        (tester) async {
          final size = Size(enlarged ? 320 : 390, 844);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final status = ServerConnectionStatus('Claw');
          addTearDown(status.dispose);
          status.liveChanged('chat', false);
          var retries = 0;
          status.retry = () async {
            retries++;
            status.beginRecovery('chat');
          };
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('capture'),
              child: MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(enlarged ? 2 : 1)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ServerConnectionLabel(label: 'Claw', status: status),
                ),
              ),
            ),
          );
          await tester.tap(
            find.byKey(const ValueKey('connection-status-target')),
          );
          await tester.pumpAndSettle();
          final retry = find.widgetWithIcon(IconButton, Icons.refresh);
          await tester.ensureVisible(retry);
          await tester.pumpAndSettle();
          final motion = find
              .descendant(
                of: find.ancestor(
                  of: retry,
                  matching: find.byType(StudioButtonPress),
                ),
                matching: find.byType(Transform),
              )
              .first;
          double scale() =>
              tester.widget<Transform>(motion).transform.entry(0, 0);
          final bounds = tester.getRect(retry);
          expect(bounds.height, greaterThanOrEqualTo(48));
          expect(
            find.widgetWithIcon(IconButton, Icons.refresh),
            findsOneWidget,
          );
          await snapshot(tester, '${brightness.name}-$enlarged-ready');
          status.waitForRecovery('chat');
          await tester.pump();
          expect(tester.widget<IconButton>(retry).onPressed, isNotNull);
          await snapshot(tester, '${brightness.name}-$enlarged-backoff');
          final gesture = await tester.startGesture(tester.getCenter(retry));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 120));
          expect(scale(), allOf(greaterThan(0), lessThan(1)));
          await snapshot(tester, '${brightness.name}-$enlarged-pressed');
          await gesture.up();
          await tester.pump();
          expect(retries, 1);
          expect(find.byIcon(Icons.refresh), findsOneWidget);
          expect(tester.widget<IconButton>(retry).onPressed, isNull);
          await tester.pump(const Duration(milliseconds: 160));
          expect(scale(), 1);
          expect(tester.getRect(retry), bounds);
          await snapshot(tester, '${brightness.name}-$enlarged-reconnecting');
          final disabledTap = await tester.startGesture(
            tester.getCenter(retry),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 120));
          expect(scale(), allOf(greaterThan(0), lessThan(1)));
          expect(
            retries,
            1,
            reason: 'Disabled taps acknowledge without retrying',
          );
          await snapshot(
            tester,
            '${brightness.name}-$enlarged-disabled-pressed',
          );
          await disabledTap.up();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 160));
          expect(retries, 1);
          status.failRecovery('chat', 'Could not reconnect. Try again.');
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.refresh), findsOneWidget);
          expect(tester.widget<IconButton>(retry).onPressed, isNotNull);
          await snapshot(tester, '${brightness.name}-$enlarged-failed');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('header and drawer both open the current connection details', (
    tester,
  ) async {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    final connection = SavedConnection(
      id: 'claw',
      label: 'Claw',
      host: 'localhost',
      port: 8642,
      apiKey: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              ServerConnectionLabel(label: 'Claw', status: status),
              DrawerConnectionLabel(connection: connection, status: status),
            ],
          ),
        ),
      ),
    );

    for (final key in ['connection-status-target', 'menu-connection']) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsOneWidget);
      expect(find.text('Server access'), findsOneWidget);
      await tester.tap(find.byTooltip('Close connection details'));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsNothing);
    }
  });

  testWidgets('connection details retain live status and retry behavior', (
    tester,
  ) async {
    final status = ServerConnectionStatus('Claw');
    addTearDown(status.dispose);
    status.liveChanged('chat', false);
    var retries = 0;
    status.retry = () async {
      retries++;
      status.beginRecovery('chat');
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: ServerConnectionLabel(label: 'Claw', status: status),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    try {
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('connection-status-target')),
        ),
        matchesSemantics(
          label: 'Claw, Disconnected. Connection details',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
    } finally {
      semantics.dispose();
    }
    await tester.tap(find.byKey(const ValueKey('connection-status-target')));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
    status.waitForRecovery('chat');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.text('Reconnecting'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNull,
    );
    status.accessAvailable();
    status.liveChanged('chat', true);
    status.endRecovery('chat');
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Available'), findsNWidgets(2));
    expect(find.widgetWithIcon(IconButton, Icons.refresh), findsNothing);
    await tester.tap(find.byTooltip('Close connection details'));
    await tester.pumpAndSettle();
    expect(find.text('Connection details'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'server label and details fit narrow enlarged ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final status = ServerConnectionStatus('Claw · a longer server name');
        status.beginRecovery('travel');
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 700),
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ServerConnectionLabel(
                  label: status.label,
                  icon: ConnectionIcon.rocket,
                  status: status,
                  suffix: 'Travel',
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.text('${status.label} · Travel').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('connection-status-target')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byType(InkWell).first).height,
          greaterThanOrEqualTo(48),
        );
        final fade = tester.widget<FadeTransition>(
          find.byType(FadeTransition).last,
        );
        expect(fade.opacity.value, 1);
        await tester.tap(
          find.byKey(const ValueKey('connection-status-target')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Server access'), findsOneWidget);
        expect(find.text('Live chat'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        status.dispose();
      },
    );
  }
}
