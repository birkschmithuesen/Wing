import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/models/dashboard_oauth_grant.dart';
import 'package:wing/core/services/dashboard_oauth_session.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/connection_setup_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/playful_portrait.dart';
import 'package:wing/core/widgets/studio_selection_tile.dart';

import 'support/connection_probe_fixture.dart';

const _frame = Key('cloud-render');
const _captureEnabled = bool.fromEnvironment('CAPTURE_CONNECTION_SETUP');
const _instance = CloudInstance(
  id: 'research',
  name: 'Research assistant',
  state: 'running',
  dashboardUrl: 'https://research.example',
);
const _stopped = CloudInstance(
  id: 'home',
  name: 'Home assistant',
  state: 'stopped',
  dashboardUrl: 'https://home.example',
);

class _Cloud extends HermesCloud {
  CloudDiscovery result = const CloudDiscovery(
    instances: [_instance, _stopped],
    organization: CloudOrganization('personal', 'Personal'),
  );
  Completer<CloudDiscovery?>? discovery;
  Completer<DashboardOAuthSession?>? signInResult;
  int signIns = 0;
  DashboardOAuthSession? lastOwner;
  @override
  Future<CloudDiscovery?> discover({
    String? organization,
    bool switchAccount = false,
  }) async => discovery == null ? result : discovery!.future;
  @override
  Future<DashboardOAuthSession?> signIn(CloudInstance instance) async {
    signIns++;
    final owner = signInResult == null
        ? DashboardOAuthSession(
            DashboardOAuthGrant(
              id: 'grant',
              baseUrl: instance.dashboardUrl!,
              accessToken: 'secret-access',
              refreshToken: 'secret-refresh',
              expiresAt: DateTime.now().add(const Duration(hours: 1)),
            ),
          )
        : await signInResult!.future;
    lastOwner = owner;
    return owner;
  }

  @override
  Future<void> cancel() async {}
  @override
  void close() {}
}

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = label == 'Save and open'
      ? find.byTooltip(label)
      : find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureEnabled) return;
  await tester.runAsync(() async {
    final context = tester.element(find.byKey(_frame));
    await Future.wait(
      tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => precacheImage(image.image, context)),
    );
  });
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/cloud-review')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Cloud cloud, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  List<SavedConnection> saved = const [],
  SavedConnection? initial,
  Future<SavedConnection> Function(SavedConnection)? onSave,
  ConnectionProbeFixture? probe,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ConnectionSetupScreen(
          createSession: () => ConnectionSetupSession(
            cloud: cloud,
            savedConnections: () => saved,
            initialAccess: initial == null
                ? null
                : ConnectionAccess(
                    connection: initial,
                    dashboardOAuth: initial.dashboardGrant == null
                        ? null
                        : DashboardOAuthSession(initial.dashboardGrant!),
                  ),
            onSaveIcon: initial == null ? null : (_) async {},
            createProbe: (_) => probe ?? ConnectionProbeFixture(),
            onSave: onSave ?? (candidate) async => candidate,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!_captureEnabled) return;
    const dir = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$dir/$file').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
  });
  for (final theme in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        '${theme.name} Cloud journey at ${scale}x retains shared frame and explicit save',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final cloud = _Cloud();
          final probe = ConnectionProbeFixture();
          SavedConnection? saved;
          await _pump(
            tester,
            cloud,
            brightness: theme,
            scale: scale,
            probe: probe,
            onSave: (c) async {
              saved = c;
              return c;
            },
          );
          await _capture(tester, '${theme.name}-$scale-choices');
          await _tap(tester, 'Use an address');
          expect(find.text('Where’s your Hermes?'), findsOneWidget);
          expect(find.text('One address for your agent'), findsOneWidget);
          expect(find.byTooltip('Find my address'), findsOneWidget);
          expect(find.byType(PlayfulPortrait), findsOneWidget);
          await _capture(tester, '${theme.name}-$scale-address');
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await _tap(tester, 'Hermes Cloud');
          expect(find.text('Where’s your Hermes?'), findsOneWidget);
          expect(find.byType(PlayfulPortrait), findsOneWidget);
          await _capture(tester, '${theme.name}-$scale-cloud-sign-in');
          await _tap(tester, 'Next');
          expect(find.text('Research assistant'), findsOneWidget);
          expect(
            tester
                .widget<StudioRadioTile<String>>(
                  find.byWidgetPredicate(
                    (w) => w is StudioRadioTile<String> && w.value == 'home',
                  ),
                )
                .enabled,
            false,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('connection-primary')),
                )
                .onPressed,
            isNull,
          );
          await _tap(tester, 'Research assistant');
          await _capture(tester, '${theme.name}-$scale-instances');
          await _tap(tester, 'Next');
          await _tap(tester, 'Next');
          expect(find.text('Connection verified'), findsOneWidget);
          expect(saved, isNull);
          expect(cloud.signIns, 1);
          expect(probe.calls, hasLength(3));
          await _capture(tester, '${theme.name}-$scale-review');
          await _tap(tester, 'Save and open');
          expect(saved!.label, 'Research assistant');
          expect(saved!.cloudInstanceId, 'research');
          expect(saved!.dashboardGrant!.accessToken, 'secret-access');
          expect(saved!.dashboardPassword, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final dispose in [false, true]) {
    testWidgets(
      'provisional sign-in retires on ${dispose ? 'route disposal' : 'instance refresh'}',
      (tester) async {
        final cloud = _Cloud();
        await _pump(tester, cloud);
        await _tap(tester, 'Hermes Cloud');
        await _tap(tester, 'Next');
        await _tap(tester, 'Research assistant');
        await _tap(tester, 'Next');
        final owner = cloud.lastOwner!;
        expect(owner.isActive, isTrue);
        if (dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await _tap(tester, 'Refresh');
        }
        expect(owner.isActive, isFalse);
      },
    );
  }

  testWidgets('late provisional sign-in after route disposal is retired', (
    tester,
  ) async {
    final cloud = _Cloud()..signInResult = Completer<DashboardOAuthSession?>();
    await _pump(tester, cloud);
    await _tap(tester, 'Hermes Cloud');
    await _tap(tester, 'Next');
    await _tap(tester, 'Research assistant');
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(cloud.signIns, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    final owner = DashboardOAuthSession(
      DashboardOAuthGrant(
        id: 'late-grant',
        baseUrl: _instance.dashboardUrl!,
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    cloud.signInResult!.complete(owner);
    await tester.pumpAndSettle();
    expect(owner.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled discovery cannot replace the route with late results',
    (tester) async {
      final cloud = _Cloud()..discovery = Completer<CloudDiscovery?>();
      await _pump(tester, cloud);
      await _tap(tester, 'Hermes Cloud');
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      cloud.discovery!.complete(cloud.result);
      await tester.pumpAndSettle();
      expect(find.text('Connect your agent'), findsOneWidget);
      expect(find.text('Research assistant'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'existing instance offers Open without a duplicate sign-in or save',
    (tester) async {
      final cloud = _Cloud();
      final saved = SavedConnection(
        id: 'saved',
        label: 'My research',
        host: 'research.example',
        port: 443,
        apiKey: '',
        useHttps: true,
        cloudInstanceId: 'research',
        cloudOrganization: 'personal',
      );
      await _pump(
        tester,
        cloud,
        saved: [saved],
        onSave: (_) async => throw StateError('No duplicate save'),
      );
      await _tap(tester, 'Hermes Cloud');
      await _tap(tester, 'Next');
      await _tap(tester, 'Research assistant');
      expect(find.text('Open instance'), findsOneWidget);
      await _tap(tester, 'Open instance');
      expect(cloud.signIns, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty account gives creation and refresh actions with no Connect',
    (tester) async {
      final cloud = _Cloud()..result = const CloudDiscovery();
      await _pump(tester, cloud);
      await _tap(tester, 'Hermes Cloud');
      await _tap(tester, 'Next');
      expect(find.text('No Cloud instances yet'), findsOneWidget);
      expect(find.text('Open Nous Portal'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('connection-primary')))
            .onPressed,
        isNull,
      );
    },
  );
}
