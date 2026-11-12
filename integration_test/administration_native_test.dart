import '../test/support/hosted_connection_request_scenarios.dart';
import 'dart:convert';
import 'dart:io';
import 'package:wing/core/services/profile_capabilities_session.dart';
import 'package:wing/core/screens/administration/provider_recovery_routes.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/screens/administration/admin_identity_page.dart';
import 'package:wing/core/screens/administration/admin_runtime_health.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/profile_identity_edit_session.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/profile_capabilities_screen.dart';
import 'package:wing/core/theme/wing_theme.dart';
import '../test/support/administration_design_fixture.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';
import '../test/support/upstream_capabilities_scenarios.dart';

/// Hold the real Android viewport, including its IME, for the disposable driver.
Future<void> _captureAdministration(
  WidgetTester tester,
  String name,
  bool keyboard,
) async {
  if (!const bool.fromEnvironment('ADMINISTRATION_NATIVE_CAPTURE')) return;
  final directory = Directory.systemTemp.path;
  final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
  await File('$directory/wing-administration-stage.json').writeAsString(
    jsonEncode({'name': name, 'token': token, 'keyboard': keyboard}),
  );
  final ack = File('$directory/wing-administration-ack');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (await ack.exists() && await ack.readAsString() == token) return;
  }
  throw StateError('Native Android capture did not complete $name');
}

/// Production widgets on disposable Android with in-memory observations only.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerConnectionRequestScenarios(
    native: true,
    nativeCapture: _captureAdministration,
  );
  registerUpstreamCapabilitiesScenarios(
    native: true,
    nativeCapture: _captureAdministration,
  );
  testWidgets('Android runtime findings survive reviewing the same operation', (
    tester,
  ) async {
    final fixture = AdministrationDesignFixture();
    final health = AdministrationHealth(fixture.server);
    addTearDown(health.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AdminRuntimeHealth(health: health),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Doctor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doctor'));
    // Beginning the operation animates the underlying Server refresh spinner
    // while confirmation is open. Settle the dialog transition without waiting
    // for that spinner to stop before we can confirm the operation.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Run'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);
    // Unstructured diagnostic failures expose their output immediately.
    await tester.ensureVisible(find.textContaining('A required dependency'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A required dependency'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);
    await tester.ensureVisible(find.text('Doctor'));
    await tester.pumpAndSettle();
    final statusReads = fixture.requests
        .where((r) => r.$2 == 'actions/doctor/status')
        .length;
    expect(statusReads, greaterThanOrEqualTo(1));
    await tester.tap(find.text('Doctor'));
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('A required dependency'), findsOneWidget);
    expect(fixture.requests.where((r) => r.$1 == 'POST'), hasLength(1));
    expect(
      fixture.requests.singleWhere((r) => r.$1 == 'POST').$2,
      'ops/doctor',
    );
    // Reviewing a completed retained observation neither reruns Doctor nor
    // starts a new status poll. These operations belong to the server.
    expect(
      fixture.requests.where((r) => r.$2 == 'actions/doctor/status'),
      hasLength(statusReads),
    );
    expect(fixture.requests.every((r) => !r.$3.containsKey('profile')), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android editors: keyboard, conflict, accessibility action and discard',
    (tester) async {
      final fixture = AdministrationDesignFixture();
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => adminPush(
                      context,
                      (context) => AdminSettingsPage(
                        profile: fixture.server.profile('personal'),
                        title: 'Memory settings',
                        fields: [memoryFields[2]],
                      ),
                    ),
                    child: const Text('Edit memory'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final entry = tester.getSemantics(find.text('Edit memory'));
        tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
          entry.id,
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextFormField));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '2800');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Save changes').hitTestable(), findsOneWidget);
        (fixture.configs['personal']!['memory'] as Map)['memory_char_limit'] =
            3200;
        await tester.tap(find.byTooltip('Save changes'));
        await tester.pumpAndSettle();
        // Hide the native IME before navigating the comparison below the input.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Keep my value'));
        await tester.pumpAndSettle();
        expect(find.text('Current server value: 3200'), findsOneWidget);
        await tester.tap(find.text('Keep my value'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Save changes'));
        await tester.pumpAndSettle();
        expect(
          (fixture.configs['personal']!['memory'] as Map)['memory_char_limit'],
          2800,
        );
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit memory'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextFormField));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '2900');
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('1 unsaved change'), findsOneWidget);
        expect(find.byTooltip('Cancel').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.text('Discard edits?'), findsOneWidget);
        await tester.tap(find.byTooltip('Discard'));
        await tester.pumpAndSettle();
        expect(find.text('Edit memory'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('Android full-screen Identity retains long draft on back', (
    tester,
  ) async {
    final fixture = AdministrationDesignFixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showAdminIdentityEditor(
                context,
                createSession: () => ProfileIdentityEditSession(
                  fixture.server.profile('personal'),
                ),
              ),
              child: const Text('Edit identity'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit identity'));
    await tester.pumpAndSettle();
    final soul = find.byKey(const ValueKey('profile-soul-field'));
    await tester.ensureVisible(soul);
    await tester.enterText(
      soul,
      List.filled(20, 'Be thoughtful, clear and precise.').join('\n'),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save changes').hitTestable(), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    final discardDialog = find.ancestor(
      of: find.text('Discard unsaved changes?'),
      matching: find.byType(StudioDialog),
    );
    await tester.tap(
      find.descendant(of: discardDialog, matching: find.byTooltip('Cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(soul).controller!.text,
      contains('precise.\nBe thoughtful'),
    );
    await tester.tap(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    expect(fixture.soul.split('\n'), hasLength(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android provider ownership and separate capability actions at large text',
    (tester) async {
      final fixture = AdministrationDesignFixture();
      final profile = fixture.server.profile('personal');
      var setup = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: providerRecoveryPage(profile: profile, providerId: 'research'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home server / personal'), findsOneWidget);
      expect(find.text('Manage shared account'), findsNothing);
      await tester.scrollUntilVisible(find.text('Sign in again'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in again'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in to Research provider'), findsOneWidget);
      expect(find.text('Home server / personal'), findsOneWidget);
      expect(
        find.text('Save this sign-in for personal on Home server.'),
        findsOneWidget,
      );
      expect(find.text('Start sign-in'), findsOneWidget);
      // Credential provenance does not redirect a profile-owned account to
      // default. Opening its sign-in options must not start OAuth implicitly.
      final oauthReads = fixture.requests.where(
        (r) => r.$2 == 'providers/oauth',
      );
      expect(oauthReads, isNotEmpty);
      expect(oauthReads.every((r) => r.$3['profile'] == 'personal'), isTrue);
      expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ProfileCapabilitiesScreen(
            createSession: () => ProfileCapabilitiesSession(profile.gateway),
            connectionLabel: 'Home server',
            onToolSetup: (_) async {
              setup = true;
            },
            onLibrary: () async {},
            onHub: () async {},
            onPlugins: () async {},
            onConnectedApps: () async {},
            onMcpConnectors: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Capabilities'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Web search and research'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final capabilityTitle = find.text('Web search and research');
      await Scrollable.ensureVisible(
        tester.element(capabilityTitle),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      expect(capabilityTitle.hitTestable(), findsOneWidget);
      await tester.tap(capabilityTitle);
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Setup and providers for Web search and research'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      final toggle = find.byType(CompactSwitch);
      await Scrollable.ensureVisible(tester.element(toggle), alignment: .5);
      await tester.pumpAndSettle();
      expect(toggle.hitTestable(), findsOneWidget);
      expect(tester.getSize(toggle).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
      await tester.tapAt(tester.getTopLeft(toggle) + const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
        find.byTooltip('Setup and providers for Web search and research'),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byTooltip('Setup and providers for Web search and research'),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('Setup and providers for Web search and research'),
      );
      await tester.pumpAndSettle();
      expect(setup, isTrue);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_NATIVE_ADMINISTRATION')) {
        debugPrint('NATIVE_ADMINISTRATION_CAPTURE_READY');
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    },
  );
}
