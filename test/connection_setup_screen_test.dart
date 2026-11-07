import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/connection_setup_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_setup_probe.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/playful_portrait.dart';
import 'package:wing/core/widgets/connection_icon_picker.dart';
import 'package:wing/core/widgets/wing_wordmark.dart';

import 'support/connection_probe_fixture.dart';

const _captureEnabled = bool.fromEnvironment('CAPTURE_CONNECTION_SETUP');
const _frame = Key('connection-render');

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.pumpAndSettle();
  final finder = switch (label) {
    'Save connection icon' ||
    'Cancel' ||
    'Use connection settings' ||
    'Save and open' ||
    'Save changes' => find.byTooltip(label),
    _ => find.text(label),
  };
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _pump(
  WidgetTester tester, {
  ConnectionProbeFixture? fixture,
  Future<SavedConnection> Function(SavedConnection)? save,
  Future<void> Function(ConnectionIcon)? saveIcon,
  void Function(SavedConnection)? candidate,
  SavedConnection? initial,
  Brightness brightness = Brightness.light,
  WorkspaceAccent accent = WorkspaceAccent.teal,
  double scale = 1,
  double keyboard = 0,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: profileWorkspaceTheme(wingTheme(brightness), accent: accent),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: ConnectionSetupScreen(
          createSession: () => ConnectionSetupSession(
            initialAccess: initial == null
                ? null
                : ConnectionAccess(connection: initial, dashboardOAuth: null),
            savedConnections: () => const [],
            cloud: HermesCloud(),
            onSaveIcon: initial == null ? null : saveIcon ?? (_) async {},
            createProbe: (connection) {
              candidate?.call(connection.connection);
              return fixture ?? ConnectionProbeFixture();
            },
            onSave: save ?? (connection) async => connection,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (initial == null) await _tap(tester, 'Use an address');
}

Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('connection-address')),
    'https://hermes.example.com/agent/',
  );
  await _tap(tester, 'Next');
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('connection-username')), 'alex');
  await tester.enterText(
    find.byKey(const Key('connection-password')),
    ' secret with spaces ',
  );
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  bool pending = false,
}) async {
  if (!_captureEnabled) return;
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  final context = tester.element(find.byKey(_frame));
  await tester.runAsync(() async {
    await Future.wait(
      images.map((image) => precacheImage(image.image, context)),
    );
  });
  if (pending) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/connection-review')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!_captureEnabled) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    if (directory.isEmpty) {
      throw StateError('Capture requires CAPTURE_FONT_DIR.');
    }
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
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'swipes and Next retain inline results ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = ConnectionProbeFixture()
            ..discoveryGate = Completer<ProfileDiscovery>();
          await _pump(
            tester,
            fixture: fixture,
            brightness: brightness,
            scale: scale,
          );
          Future<void> swipe(double distance) async {
            await tester.pump();
            await tester.dragFrom(
              tester.getTopLeft(find.byKey(const Key('connection-cards'))) +
                  const Offset(8, 8),
              Offset(distance.sign * 260, 0),
            );
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          }

          await tester.enterText(
            find.byKey(const Key('connection-address')),
            'https://hermes.example.com',
          );
          await swipe(-150);
          expect(find.byKey(const Key('connection-username')), findsOneWidget);
          await swipe(150);
          expect(find.byKey(const Key('connection-address')), findsOneWidget);
          await _tap(tester, 'Next');
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('connection-username')),
            'alex',
          );
          await tester.enterText(
            find.byKey(const Key('connection-password')),
            'password',
          );
          await swipe(-150);
          expect(find.byKey(const Key('connection-name')), findsNothing);
          await _tap(tester, 'Check connection');
          await tester.pump();
          expect(find.byKey(const Key('connection-username')), findsOneWidget);
          final progress = find.byType(StudioLoading);
          expect(progress, findsOneWidget);
          expect(
            tester
                .getRect(progress)
                .overlaps(const Rect.fromLTWH(0, 0, 390, 844)),
            isTrue,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('connection-primary')),
                )
                .onPressed,
            isNull,
          );
          await _capture(
            tester,
            '${brightness.name}-inline-pending-${scale}x',
            pending: true,
          );
          await swipe(-150);
          expect(find.byKey(const Key('connection-name')), findsNothing);
          fixture.discoveryGate!.complete(connectionDiscovery);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('connection-username')), findsOneWidget);
          expect(
            find.bySemanticsLabel(RegExp(r', Available$')),
            findsNWidgets(3),
          );
          await _capture(tester, '${brightness.name}-inline-success-${scale}x');
          await swipe(-150);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('connection-name')), findsOneWidget);
          await tester.enterText(
            find.byKey(const Key('connection-name')),
            'Home',
          );
          await swipe(150);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('connection-username')), findsOneWidget);
          await _tap(tester, 'Next');
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextFormField>(find.byKey(const Key('connection-name')))
                .controller!
                .text,
            'Home',
          );
          expect(fixture.calls, ConnectionCheck.values);
          await swipe(150);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('connection-password')),
            'changed password',
          );
          await swipe(-150);
          expect(find.byKey(const Key('connection-name')), findsNothing);
          expect(find.bySemanticsLabel(RegExp(r', Available$')), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('wrong endpoint recovery ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = ConnectionProbeFixture()..chatGate = Completer<void>();
        await _pump(
          tester,
          fixture: fixture,
          brightness: brightness,
          scale: scale,
        );
        await _signIn(tester);
        await _tap(tester, 'Check connection');
        await tester.pump();
        expect(find.byType(StudioLoading), findsWidgets);
        fixture.chatGate!.completeError(
          JsonRpcError(
            'gateway.ready',
            'Unavailable',
            reason: 'session_authority_unavailable',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Webapp address'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('connection-results')));
        await tester.pumpAndSettle();
        await _capture(tester, '${brightness.name}-wrong-endpoint-${scale}x');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('connection-address')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('connection-address')),
          'https://gateway.example.com',
        );
        await _tap(tester, 'Next');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('connection-username')),
              )
              .controller!
              .text,
          'alex',
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('connection-password')),
              )
              .controller!
              .text,
          ' secret with spaces ',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'sign-in icon saves an existing connection without verification',
    (tester) async {
      final initial = SavedConnection(
        id: 'saved',
        label: 'Office',
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        apiKey: '',
        icon: ConnectionIcon.cloud,
      );
      final fixture = ConnectionProbeFixture();
      var savedIcon = initial.icon;
      var saves = 0;
      var fail = true;
      await _pump(
        tester,
        initial: initial,
        fixture: fixture,
        save: (c) async {
          saves++;
          return c;
        },
        saveIcon: (icon) async {
          if (fail) throw StateError('disk unavailable');
          savedIcon = icon;
        },
      );
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Change connection icon'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('connection-icon-rocket')));
      await _tap(tester, 'Save connection icon');
      await tester.pumpAndSettle();
      expect(savedIcon, ConnectionIcon.cloud);
      expect(find.text('Couldn’t save this icon. Try again.'), findsOneWidget);
      fail = false;
      await _tap(tester, 'Save connection icon');
      await tester.pumpAndSettle();
      expect(savedIcon, ConnectionIcon.rocket);
      expect(
        tester
            .widget<ConnectionIconBadge>(find.byType(ConnectionIconBadge))
            .icon,
        ConnectionIcon.rocket,
      );
      expect(fixture.calls, isEmpty);
      expect(saves, 0);
      await tester.tap(find.byTooltip('Change connection icon'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('connection-icon-rocket')),
            )
            .isSelected,
        isTrue,
      );
      await _tap(tester, 'Cancel');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(savedIcon, ConnectionIcon.rocket);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('check geometry stays fixed ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = scale == 1
            ? const Size(360, 772)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = ConnectionProbeFixture()
          ..discoveryGate = Completer<ProfileDiscovery>()
          ..chatGate = Completer<void>();
        await _pump(
          tester,
          fixture: fixture,
          brightness: brightness,
          scale: scale,
          initial: SavedConnection(
            id: 'saved',
            label: 'Home',
            host: 'hermes.example.com',
            port: 9120,
            useHttps: false,
            apiKey: '',
            dashboardUsername: 'alex',
            dashboardPassword: 'synthetic password',
          ),
        );
        await _tap(tester, 'Next');
        await tester.pumpAndSettle();
        final check = find.text('Check connection');
        await tester.ensureVisible(check);
        await tester.pumpAndSettle();
        final anchors = [
          find.byType(BackButton),
          find.byKey(const Key('connection-username')),
          find.byKey(const Key('connection-password')),
          find.text('Custom setup'),
          find
              .ancestor(of: check, matching: find.byType(StudioButtonPress))
              .first,
          find.byKey(const Key('connection-results')),
          find.byKey(const Key('connection-primary')),
          find.text('Profiles & access'),
          find.text('Live chat'),
          find.text('Chat history'),
        ];
        final before = anchors.map(tester.getRect).toList();
        void expectStable() {
          for (var i = 0; i < anchors.length; i++) {
            expect(
              tester.getRect(anchors[i]),
              before[i],
              reason: anchors[i].toString(),
            );
          }
          expect(tester.takeException(), isNull);
        }

        if (scale == 1) {
          final card = tester.widget<SingleChildScrollView>(
            find.byKey(const ValueKey('connection-card-signIn')),
          );
          expect(
            card.controller!.position.maxScrollExtent,
            0,
            reason: 'Normal phone form fits one screen',
          );
          expect(
            tester.getRect(find.byKey(const Key('connection-results'))).bottom,
            lessThan(
              tester.getRect(find.byKey(const Key('connection-primary'))).top,
            ),
          );
        }
        await _capture(tester, '${brightness.name}-stable-idle-${scale}x');
        await tester.tap(check);
        await tester.pump();
        expectStable();
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);
        fixture.discoveryGate!.complete(connectionDiscovery);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expectStable();
        fixture.chatGate!.completeError(StateError('synthetic failure'));
        await tester.pumpAndSettle();
        expectStable();
        await _capture(tester, '${brightness.name}-stable-failure-${scale}x');
        fixture.chatGate = null;
        fixture.discoveryGate = Completer<ProfileDiscovery>();
        await tester.tap(check);
        await tester.pump();
        expectStable();
        fixture.discoveryGate!.complete(connectionDiscovery);
        await tester.pumpAndSettle();
        expectStable();
        expect(
          find.bySemanticsLabel(RegExp(r', Available$')),
          findsNWidgets(3),
        );
        await _capture(tester, '${brightness.name}-stable-success-${scale}x');
        await _tap(tester, 'Next');
        await tester.pumpAndSettle();
        if (scale == 1) {
          final card = tester.widget<SingleChildScrollView>(
            find.byKey(const ValueKey('connection-card-review')),
          );
          expect(
            card.controller!.position.maxScrollExtent,
            0,
            reason: 'Name and save fit one screen',
          );
        }
        await _capture(tester, '${brightness.name}-stable-review-${scale}x');
      });
    }
  }

  testWidgets(
    'leaving verified card stays on the chosen card after a long swipe',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, fixture: ConnectionProbeFixture());
      await _signIn(tester);
      await _tap(tester, 'Check connection');
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      final cards = find.byKey(const Key('connection-cards'));
      final controller = tester.widget<PageView>(cards).controller!;
      expect(controller.page, 2);
      // Keep moving through the middle card before releasing the gesture.
      final gesture = await tester.startGesture(
        tester.getTopLeft(cards) + const Offset(8, 8),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump(const Duration(milliseconds: 70));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      expect(find.text('Where’s your Hermes?'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.page, 0);
      await tester.drag(cards, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      expect(find.bySemanticsLabel(RegExp(r', Available$')), findsNWidgets(3));
      await tester.drag(cards, const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(controller.page, 2);
      expect(find.text('Connection verified'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cards follow a drag, reverse without navigation, and ease on Next',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = ConnectionProbeFixture()
        ..discoveryGate = Completer<ProfileDiscovery>();
      await _pump(tester, fixture: fixture);
      await tester.enterText(
        find.byKey(const Key('connection-address')),
        'https://hermes.example.com',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final address = find.byKey(const Key('connection-address'));
      final origin = tester.getRect(address);
      final page = find.byKey(const Key('connection-cards'));
      final start = tester.getTopLeft(page) + const Offset(8, 8);
      final drag = await tester.startGesture(start);
      await drag.moveBy(const Offset(-30, 0));
      await tester.pump();
      await drag.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(tester.getRect(address).left, lessThan(origin.left - 50));
      await _capture(tester, 'swipe-mid-drag', pending: true);
      await drag.moveBy(const Offset(110, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(address), origin);
      await _tap(tester, 'Next');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final username = find.byKey(const Key('connection-username'));
      expect(tester.getRect(username).left, greaterThan(16));
      expect(tester.getRect(username).left, lessThan(390));
      await tester.pumpAndSettle();
      expect(tester.getRect(username).left, 16);
      await tester.enterText(username, 'alex');
      await tester.enterText(
        find.byKey(const Key('connection-password')),
        'password',
      );
      await _tap(tester, 'Check connection');
      await tester.pump();
      final backDrag = await tester.startGesture(start);
      await backDrag.moveBy(const Offset(110, 0));
      await tester.pump();
      await backDrag.moveBy(const Offset(-110, 0));
      await backDrag.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(fixture.closed, isFalse);
      expect(find.byType(StudioLoading), findsOneWidget);
      fixture.discoveryGate!.complete(connectionDiscovery);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r', Available$')), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'full-width check action and status LEDs ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = ConnectionProbeFixture();
          await _pump(
            tester,
            fixture: fixture,
            brightness: brightness,
            scale: scale,
          );
          await _signIn(tester);
          await _tap(tester, 'Check connection');
          await tester.pumpAndSettle();
          expect(find.text('Available'), findsNothing);
          expect(find.byIcon(Icons.edit_outlined), findsNothing);
          for (final stage in ConnectionCheck.values) {
            final dot = find.byKey(
              ValueKey('connection-check-${stage.name}-led'),
            );
            final theme = Theme.of(
              tester.element(dot),
            ).extension<WingTokens>()!;
            final decoration =
                tester.widget<Container>(dot).decoration! as BoxDecoration;
            expect(decoration.color, theme.success);
          }
          await _capture(tester, '${brightness.name}-led-success-${scale}x');
          expect(find.byTooltip('Connection details'), findsNothing);
          final check = tester.getRect(
            find.ancestor(
              of: find.text('Check connection'),
              matching: find.byType(OutlinedButton),
            ),
          );
          final field = tester.getRect(
            find.byKey(const Key('connection-password')),
          );
          expect(check.left, field.left);
          expect(check.right, field.right);
          fixture.failAt = ConnectionCheck.chat;
          await _tap(tester, 'Check connection');
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel('Live chat, Failed'), findsOneWidget);
          final failedLed = find.byKey(const Key('connection-check-chat-led'));
          expect(
            (tester.widget<Container>(failedLed).decoration! as BoxDecoration)
                .color,
            Theme.of(tester.element(failedLed)).extension<WingTokens>()!.danger,
          );
          final waitingLed = find.byKey(
            const Key('connection-check-history-led'),
          );
          expect(
            (tester.widget<Container>(waitingLed).decoration! as BoxDecoration)
                .color,
            Theme.of(tester.element(waitingLed)).extension<WingTokens>()!.muted,
          );
          expect(find.byTooltip('Connection details'), findsNothing);
          expect(find.byIcon(Icons.edit_outlined), findsNothing);
          await _capture(tester, '${brightness.name}-led-failure-${scale}x');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('reduced motion keeps inline check feedback and explicit Next', (
    tester,
  ) async {
    final fixture = ConnectionProbeFixture()
      ..discoveryGate = Completer<ProfileDiscovery>();
    await _pump(tester, fixture: fixture, disableAnimations: true);
    await _signIn(tester);
    await _tap(tester, 'Check connection');
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(
      find.bySemanticsLabel('Profiles & access, Checking…'),
      findsOneWidget,
    );
    expect(
      find.text('Checking access to your Hermes. No message will be sent.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('connection-name')), findsNothing);
    fixture.discoveryGate!.complete(connectionDiscovery);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection-username')), findsOneWidget);
    await _tap(tester, 'Next');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection-name')), findsOneWidget);
  });

  testWidgets('check feedback remains visible while the keyboard closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = ConnectionProbeFixture()
      ..discoveryGate = Completer<ProfileDiscovery>();
    await _pump(tester, fixture: fixture, keyboard: 280);
    await _signIn(tester);
    final header = tester.getRect(find.byType(BackButton));
    await _tap(tester, 'Check connection');
    await tester.pump();
    final pulse = find.byType(StudioLoading);
    expect(pulse, findsOneWidget);
    expect(tester.getRect(pulse).center.dy, lessThan(header.bottom));
    expect(tester.getRect(find.byType(BackButton)), header);
    fixture.discoveryGate!.complete(connectionDiscovery);
    await tester.pumpAndSettle();
    expect(find.byType(StudioLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid navigation and save remain valid during card motion', (
    tester,
  ) async {
    var saves = 0;
    await _pump(
      tester,
      save: (connection) async {
        saves++;
        return connection;
      },
    );
    await _signIn(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Check connection');
    await _tap(tester, 'Next');
    // The footer is available before the destination form finishes sliding in.
    await tester.tap(find.byTooltip('Save and open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(saves, 1);
  });

  testWidgets('compact review keeps edits blocked while saving', (
    tester,
  ) async {
    final saving = Completer<SavedConnection>();
    SavedConnection? candidate;
    await _pump(
      tester,
      save: (connection) {
        candidate = connection;
        return saving.future;
      },
    );
    await _signIn(tester);
    await _tap(tester, 'Check connection');
    await _tap(tester, 'Next');
    await _tap(tester, 'Save and open');
    await tester.pump();
    expect(
      tester
          .widget<ConnectionIconButton>(find.byType(ConnectionIconButton))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('connection-appearance')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<PageView>(find.byKey(const Key('connection-cards')))
          .physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    saving.complete(candidate!);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new connection keeps its sign-in icon until final save', (
    tester,
  ) async {
    SavedConnection? saved;
    await _pump(
      tester,
      save: (c) async {
        saved = c;
        return c;
      },
    );
    await _signIn(tester);
    await tester.tap(find.byTooltip('Change connection icon'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection-icon-home')));
    await _tap(tester, 'Save connection icon');
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await _tap(tester, 'Check connection');
    await tester.pumpAndSettle();
    await _tap(tester, 'Next');
    await tester.pumpAndSettle();
    await _tap(tester, 'Save and open');
    await tester.pumpAndSettle();
    expect(saved?.icon, ConnectionIcon.home);
  });

  testWidgets(
    'one address, explicit sign-in, real checks, then a separate save',
    (tester) async {
      final fixture = ConnectionProbeFixture();
      SavedConnection? checked;
      SavedConnection? saved;
      await _pump(
        tester,
        fixture: fixture,
        candidate: (c) => checked = c,
        save: (c) async {
          saved = c;
          return c;
        },
      );
      expect(find.byType(PlayfulPortrait), findsOneWidget);
      expect(find.byType(WingFeathers), findsOneWidget);
      expect(find.text('Port'), findsNothing);
      expect(find.text('Access headers'), findsNothing);
      await _signIn(tester);
      expect(fixture.calls, isEmpty);
      await _tap(tester, 'Check connection');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection-username')), findsOneWidget);
      expect(find.byKey(const Key('connection-name')), findsNothing);
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      expect(find.text('Connection verified'), findsOneWidget);
      expect(checked?.port, 443);
      expect(checked?.dashboardPort, 443);
      expect(checked?.dashboardPrefix, '/agent');
      expect(checked?.dashboardPassword, ' secret with spaces ');
      expect(checked?.desktopGatewayUrl, isNull);
      expect(checked?.apiKey, isEmpty);
      expect(saved, isNull);
      await tester.enterText(find.byKey(const Key('connection-name')), 'Home');
      await _tap(tester, 'Instance icon');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('connection-icon-home')));
      await _tap(tester, 'Save connection icon');
      await tester.pumpAndSettle();
      await _tap(tester, 'Save and open');
      await tester.pumpAndSettle();
      expect(saved?.label, 'Home');
      expect(saved?.icon, ConnectionIcon.home);
      expect(fixture.calls, ConnectionCheck.values);
    },
  );

  testWidgets(
    'password mode cannot accidentally attempt unauthenticated access',
    (tester) async {
      final fixture = ConnectionProbeFixture();
      await _pump(tester, fixture: fixture);
      await tester.enterText(
        find.byKey(const Key('connection-address')),
        'https://hermes.example.com',
      );
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      await _tap(tester, 'Check connection');
      await tester.pumpAndSettle();
      expect(find.text('Enter your dashboard username.'), findsOneWidget);
      expect(find.text('Enter your dashboard password.'), findsOneWidget);
      expect(fixture.calls, isEmpty);
    },
  );

  testWidgets('back during a check cancels and late results cannot advance', (
    tester,
  ) async {
    final fixture = ConnectionProbeFixture()
      ..discoveryGate = Completer<ProfileDiscovery>();
    await _pump(tester, fixture: fixture);
    await _signIn(tester);
    await _tap(tester, 'Check connection');
    await tester.pump();
    expect(find.text('Checking…'), findsNothing);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(
      find.bySemanticsLabel('Profiles & access, Checking…'),
      findsOneWidget,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    fixture.discoveryGate!.complete(connectionDiscovery);
    await tester.pumpAndSettle();
    expect(fixture.closed, isTrue);
    expect(find.byKey(const Key('connection-address')), findsOneWidget);
    await _tap(tester, 'Next');
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Hermes'), findsOneWidget);
    expect(find.text('Connection verified'), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('connection-password')))
          .controller!
          .text,
      ' secret with spaces ',
    );
  });

  testWidgets(
    'save failure preserves the verified draft and retries only storage',
    (tester) async {
      final fixture = ConnectionProbeFixture();
      var saves = 0;
      await _pump(
        tester,
        fixture: fixture,
        save: (c) async {
          saves++;
          throw const CredentialStorageException('private storage error');
        },
      );
      await _signIn(tester);
      await _tap(tester, 'Check connection');
      await tester.pumpAndSettle();
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      await _tap(tester, 'Save and open');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t save this connection on this device'),
        findsOneWidget,
      );
      expect(find.textContaining('private storage error'), findsNothing);
      await _tap(tester, 'Save and open');
      await tester.pumpAndSettle();
      expect(saves, 2);
      expect(fixture.calls, ConnectionCheck.values);
      expect(find.text('Connection verified'), findsOneWidget);
    },
  );

  testWidgets(
    'custom setup applies explicit proxy auth and a same-host chat path',
    (tester) async {
      SavedConnection? checked;
      await _pump(tester, candidate: (c) => checked = c);
      await _signIn(tester);
      await _tap(tester, 'Custom setup');
      await tester.pumpAndSettle();
      await _tap(tester, 'My access proxy handles sign-in');
      await _tap(tester, 'Use a separate chat address');
      await tester.enterText(
        find.byKey(const Key('connection-chat-address')),
        'https://hermes.example.com:8443/chat/',
      );
      await _tap(tester, 'Use connection settings');
      await tester.pumpAndSettle();
      expect(find.text('Connect through your proxy'), findsOneWidget);
      await _tap(tester, 'Check connection');
      await tester.pumpAndSettle();
      expect(checked?.dashboardProxied, isTrue);
      expect(checked?.dashboardUsername, isNull);
      expect(checked?.dashboardPassword, isNull);
      expect(
        checked?.desktopGatewayUrl,
        'https://hermes.example.com:8443/chat',
      );
    },
  );

  testWidgets(
    'editing keeps current secrets and can remove custom chat routing',
    (tester) async {
      final initial = SavedConnection(
        id: 'saved',
        label: 'Office',
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        apiKey: '',
        dashboardPortOverride: 443,
        dashboardUsername: 'alex',
        dashboardPassword: ' exact password ',
        desktopGatewayUrl: 'https://chat.example.com',
        gatewayHeaders: {'X-Access': 'hidden-secret'},
      );
      SavedConnection? checked;
      await _pump(tester, initial: initial, candidate: (c) => checked = c);
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      await _tap(tester, 'Custom setup');
      await tester.pumpAndSettle();
      expect(find.text('hidden-secret'), findsNothing);
      await _tap(tester, 'Use a separate chat address');
      await _tap(tester, 'Use connection settings');
      await tester.pumpAndSettle();
      await _tap(tester, 'Check connection');
      await tester.pumpAndSettle();
      expect(checked?.desktopGatewayUrl, isNull);
      expect(checked?.gatewayHeaders, initial.gatewayHeaders);
      expect(checked?.dashboardPassword, ' exact password ');
      await _tap(tester, 'Next');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Save changes'), findsOneWidget);
    },
  );

  if (_captureEnabled) {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name} portrait connection review', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pump(tester, brightness: brightness);
        await _capture(tester, '${brightness.name}-portrait-address');
        await _signIn(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await _capture(tester, '${brightness.name}-portrait-signin');
        await _tap(tester, 'Check connection');
        await tester.pumpAndSettle();
        await _capture(tester, '${brightness.name}-portrait-verified');
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        '${brightness.name} journey fits 320dp at ${scale}x including keyboard and failure',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = ConnectionProbeFixture()
            ..failAt = ConnectionCheck.chat;
          await _pump(
            tester,
            fixture: fixture,
            brightness: brightness,
            scale: scale,
          );
          await _capture(tester, '${brightness.name}-address-${scale}x');
          await _signIn(tester);
          await _capture(tester, '${brightness.name}-signin-${scale}x');
          await _tap(tester, 'Check connection');
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Profiles are available, but live chat'),
            findsOneWidget,
          );
          await _capture(tester, '${brightness.name}-recovery-${scale}x');
          await _tap(tester, 'Custom setup');
          await tester.pumpAndSettle();
          await _tap(tester, 'Use a separate chat address');
          await tester.pumpAndSettle();
          final chatAddress = find.byKey(const Key('connection-chat-address'));
          await tester.scrollUntilVisible(
            chatAddress,
            160,
            scrollable: find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .last,
          );
          await Scrollable.ensureVisible(
            tester.element(chatAddress),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(find.text('Chat gateway base address'), findsOneWidget);
          final viewport =
              Offset.zero &
              (tester.view.physicalSize / tester.view.devicePixelRatio);
          expect(
            viewport.contains(
              tester.getCenter(find.text('Chat gateway base address')),
            ),
            isTrue,
          );
          await _capture(tester, '${brightness.name}-custom-${scale}x');
          await tester.tap(chatAddress);
          await tester.pumpAndSettle();
          await _capture(tester, '${brightness.name}-custom-focused-${scale}x');
          await tester.enterText(chatAddress, 'https://chat.example.com');
          await tester.pumpAndSettle();
          expect(find.text('Chat gateway base address'), findsOneWidget);
          await _capture(tester, '${brightness.name}-custom-filled-${scale}x');
          await tester.enterText(chatAddress, 'ws://chat.example.com');
          await _tap(tester, 'Use connection settings');
          // The submit button is below this lazy field. A large default test
          // font can scroll the field out of the tree while reaching it.
          await tester.scrollUntilVisible(
            chatAddress,
            -160,
            scrollable: find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .last,
          );
          await Scrollable.ensureVisible(
            tester.element(chatAddress),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(
            tester.state<FormFieldState<String>>(chatAddress).hasError,
            isTrue,
          );
          expect(find.text('Chat gateway base address'), findsOneWidget);
          await _capture(tester, '${brightness.name}-custom-invalid-${scale}x');
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox());
          await _pump(
            tester,
            brightness: brightness,
            scale: scale,
            keyboard: 260,
          );
          await _signIn(tester);
          await tester.pumpAndSettle();
          final primary = find.byKey(const Key('connection-primary'));
          await tester.ensureVisible(primary);
          await tester.pumpAndSettle();
          final rect = tester.getRect(primary);
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
          expect(primary.hitTestable(), findsOneWidget);
          await _capture(
            tester,
            '${brightness.name}-signin-keyboard-${scale}x',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
