import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/screens/connection_setup_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_setup_probe.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/connection_probe_fixture.dart';
import 'support/journey_capture.dart';

/// Production setup on Android; synthetic probes and storage never contact a host.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} setup recovers and saves verified connection',
      (tester) async {
        final fixture = ConnectionProbeFixture()..failAt = ConnectionCheck.chat;
        SavedConnection? saved;
        var saveAttempts = 0;
        await tester.pumpWidget(
          journeyCaptureBoundary(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              home: ConnectionSetupScreen(
                createSession: () => ConnectionSetupSession(
                  initialAccess: null,
                  savedConnections: () => const [],
                  cloud: HermesCloud(),
                  onSaveIcon: null,
                  createProbe: (_) => fixture,
                  onSave: (connection) async {
                    if (++saveAttempts == 1) {
                      throw const CredentialStorageException(
                        'private storage detail',
                      );
                    }
                    saved = connection;
                    return connection;
                  },
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await captureJourney(tester, 'connection-${brightness.name}-choices');
        await _tap(tester, 'Use an address');
        await captureJourney(tester, 'connection-${brightness.name}-address');
        await tester.enterText(
          find.byKey(const Key('connection-address')),
          'https://hermes.example.com/agent/',
        );
        await _swipe(
          tester,
          -150,
          captureName: 'connection-${brightness.name}-swipe-motion',
        );
        expect(find.byKey(const Key('connection-username')), findsOneWidget);
        await _swipe(tester, 150);
        expect(find.byKey(const Key('connection-address')), findsOneWidget);
        await _tap(tester, 'Next');
        await _tap(tester, 'Check connection');
        expect(find.text('Enter your dashboard username.'), findsOneWidget);
        expect(find.text('Enter your dashboard password.'), findsOneWidget);
        expect(fixture.calls, isEmpty);
        await tester.enterText(
          find.byKey(const Key('connection-username')),
          'alex',
        );
        await tester.enterText(
          find.byKey(const Key('connection-password')),
          'synthetic password',
        );
        fixture.discoveryGate = Completer<ProfileDiscovery>();
        await _tap(tester, 'Check connection', settleAfter: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('connection-username')), findsOneWidget);
        final progress = find.byType(StudioLoading);
        expect(progress, findsOneWidget);
        final viewport =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        expect(tester.getRect(progress).overlaps(viewport), isTrue);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('connection-primary')))
              .onPressed,
          isNull,
        );
        await captureJourney(
          tester,
          'connection-${brightness.name}-inline-pending',
        );
        fixture.discoveryGate!.complete(connectionDiscovery);
        await _settle(tester);
        expect(find.byKey(const Key('connection-username')), findsOneWidget);
        expect(saved, isNull);
        expect(find.byTooltip('Save and open'), findsNothing);
        expect(find.textContaining('private-server-detail'), findsNothing);
        await captureJourney(
          tester,
          'connection-${brightness.name}-failed-check',
        );
        fixture.failAt = null;
        await _tap(tester, 'Check connection');
        expect(find.byKey(const Key('connection-username')), findsOneWidget);
        expect(find.text('Available'), findsNWidgets(3));
        final card = tester.widget<SingleChildScrollView>(
          find.byKey(const ValueKey('connection-card-signIn')),
        );
        expect(
          card.controller!.position.maxScrollExtent,
          0,
          reason: 'The normal Android form fits without scrolling',
        );
        await captureJourney(
          tester,
          'connection-${brightness.name}-inline-success',
        );
        await _swipe(tester, -150);
        expect(find.text('Connection verified'), findsOneWidget);
        expect(saved, isNull);
        await tester.enterText(
          find.byKey(const Key('connection-name')),
          'Home',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await _settle(tester);
        await _swipe(tester, 150);
        expect(find.byKey(const Key('connection-username')), findsOneWidget);
        await _tap(tester, 'Next');
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('connection-name')))
              .controller!
              .text,
          'Home',
        );
        await captureJourney(tester, 'connection-${brightness.name}-verified');
        await _tap(tester, 'Save and open', iconAction: true);
        expect(
          find.textContaining('Couldn’t save this connection on this device'),
          findsOneWidget,
        );
        expect(saved, isNull);
        expect(find.textContaining('private storage detail'), findsNothing);
        final checksBeforeSaveRetry = fixture.calls.length;
        await captureJourney(
          tester,
          'connection-${brightness.name}-storage-error',
        );
        await _tap(tester, 'Save and open', iconAction: true);
        expect(saved?.label, 'Home');
        expect(saved?.dashboardPrefix, '/agent');
        expect(saved?.dashboardPassword, 'synthetic password');
        expect(saveAttempts, 2);
        expect(fixture.calls.length, checksBeforeSaveRetry);
        expect(fixture.calls, [
          ConnectionCheck.profiles,
          ConnectionCheck.chat,
          ...ConnectionCheck.values,
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _tap(
  WidgetTester tester,
  String label, {
  bool iconAction = false,
  bool settleAfter = true,
}) async {
  final target = iconAction ? find.byTooltip(label) : find.text(label);
  _trace('waiting to tap $label');
  await _ready(tester, target);
  _trace('tapping $label');
  await tester.tap(target);
  if (settleAfter) await _settle(tester);
  _trace('tapped $label');
}

Future<void> _ready(WidgetTester tester, Finder target) async {
  await _settle(tester);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  do {
    await tester.ensureVisible(target);
    await tester.pump(const Duration(milliseconds: 100));
  } while (target.hitTestable().evaluate().isEmpty &&
      DateTime.now().isBefore(deadline));
  expect(target.hitTestable(), findsOneWidget);
}

Future<void> _swipe(
  WidgetTester tester,
  double distance, {
  String? captureName,
}) async {
  // A scrolled card can put an editable field below the app bar. Swipe an
  // observed, non-editable card heading so native text gestures keep ownership.
  final target = [
    find.text('Profiles & access'),
    find.text('Connection verified'),
    find.text('Sign in to Hermes'),
    find.text('Where’s your Hermes?'),
  ].firstWhere((finder) => finder.evaluate().isNotEmpty);
  _trace(
    'waiting to swipe $distance from ${target.describeMatch(Plurality.many)}',
  );
  await _ready(tester, target);
  _trace('swiping $distance');
  if (captureName == null) {
    await tester.drag(target, Offset(distance.sign * 280, 0));
  } else {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await gesture.moveBy(Offset(distance.sign * 30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(distance.sign * 80, 0));
    await tester.pump();
    await captureJourney(tester, captureName);
    await gesture.moveBy(Offset(distance.sign * 170, 0));
    await gesture.up();
  }
  await _settle(tester);
  _trace('swiped $distance');
}

Future<int> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 15),
);

void _trace(String stage) =>
    debugPrintSynchronously('[connection-journey] $stage');
