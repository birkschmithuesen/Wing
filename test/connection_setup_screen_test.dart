import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
    'Edit gateway address' ||
    'Edit sign-in or custom setup' ||
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
            await tester.dragFrom(
              tester.getTopLeft(
                    find
                        .byWidgetPredicate(
                          (widget) =>
                              widget is GestureDetector &&
                              widget.onHorizontalDragEnd != null,
                        )
                        .first,
                  ) +
                  const Offset(195, 8),
              Offset(distance, 0),
            );
            await tester.pump();
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
          final progress = find.byType(CircularProgressIndicator);
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
          expect(find.text('Available'), findsNWidgets(3));
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
          expect(find.text('Available'), findsNothing);
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
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        fixture.chatGate!.completeError(
          JsonRpcError(
            'gateway.ready',
            'Unavailable',
            reason: 'session_authority_unavailable',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Webapp address'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Edit gateway address'));
        await tester.pumpAndSettle();
        await _capture(tester, '${brightness.name}-wrong-endpoint-${scale}x');
        await _tap(tester, 'Edit gateway address');
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

  testWidgets('reduced motion keeps inline check feedback and explicit Next', (
    tester,
  ) async {
    final fixture = ConnectionProbeFixture()
      ..discoveryGate = Completer<ProfileDiscovery>();
    await _pump(tester, fixture: fixture, disableAnimations: true);
    await _signIn(tester);
    await _tap(tester, 'Check connection');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
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
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
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
          await _tap(tester, 'Edit sign-in or custom setup');
          await tester.pumpAndSettle();
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
