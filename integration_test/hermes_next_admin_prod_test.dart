import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_connectors.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/screens/administration/admin_plugins_page.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_connectors_session.dart';
import 'package:wing/core/services/profile_plugins_session.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/settings_edit_session.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/existing_backend_login.dart';
import '../test/helpers/journey_controls.dart';
import 'support/journey_capture.dart';

/// Real production UI and transport. The driver owns creation and deletion of
/// the unique blank QA profile, including its disabled MCP connector and skill.
/// No shared profile, installed plugin, probe or managed policy is changed here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('Production N18 plugin maintenance confirms isolated inventory', (
    tester,
  ) async {
    await _journey(tester, 'n18', (profile) async {
      final before = await profile.rpc('plugins.manage', {'action': 'list'});
      expect(before['user_count'], 0, reason: 'Requires a blank QA profile');
      await _tap(tester, find.text('Skills and tools'));
      await _tap(tester, find.byTooltip('Manage capabilities'));
      await _tap(tester, find.text('Agent plugins'));
      await _until(
        tester,
        () => find.byType(AdminPluginsPage).evaluate().isNotEmpty,
        'Plugin page opens',
      );
      final session = _owner<ProfilePluginsSession>(tester);
      await _until(
        tester,
        () => !session.state.busy,
        'Plugin inventory settles',
      );
      expect(session.state.verified, isTrue);
      expect(session.state.error, isNull);
      expect(session.state.maintenance, isNull);
      await captureJourney(tester, 'prod-n18-inventory');
      await _tap(tester, find.byTooltip('Update installed plugins'));
      await captureJourney(tester, 'prod-n18-update-dispatched');
      await _until(
        tester,
        () => !session.state.busy,
        'Plugin maintenance settles',
      );
      expect(session.state.error, isNull);
      expect(
        session.state.verified,
        isTrue,
        reason: 'Inventory readback completed',
      );
      final receipt = session.state.maintenance;
      expect(
        receipt,
        isNotNull,
        reason: 'Requires the actual update_all receipt',
      );
      expect(receipt!.updated, 0);
      expect(find.textContaining('0 updated ·'), findsOneWidget);
      expect(
        (await profile.rpc('plugins.manage', {'action': 'list'}))['user_count'],
        0,
      );
      await captureJourney(tester, 'prod-n18-update-confirmed');
      debugPrint(
        'PROD_N18: update_all receipt and refreshed empty user inventory confirmed',
      );
    });
  });

  testWidgets('Production N19 cached MCP refresh retains disabled connector', (
    tester,
  ) async {
    await _journey(tester, 'n19', (profile) async {
      await _tap(tester, find.text('Access and connectors'));
      await _tap(tester, find.text('MCP connectors'));
      await _until(
        tester,
        () => find.byType(AdminConnectorsPage).evaluate().isNotEmpty,
        'Connector page opens',
      );
      final session = _owner<ProfileConnectorsSession>(tester);
      await _until(
        tester,
        () => !session.state.busy,
        'Cached connector read settles',
      );
      void verify() {
        final state = session.state;
        expect(state.error, isNull);
        expect(state.runtimeError, isNull);
        expect(state.verified, isTrue);
        final connector = state.connectors.singleWhere(
          (row) => row.name == 'wing-qa-disabled',
        );
        expect(connector.enabled, isFalse);
        expect(
          state.runtime?.forConnector(connector)?.status,
          ConnectorRuntimeStatus.disabled,
        );
        expect(find.text('wing-qa-disabled'), findsOneWidget);
        expect(find.textContaining('Cached: Disabled'), findsOneWidget);
      }

      verify();
      final initial = session.state.runtime;
      await captureJourney(tester, 'prod-n19-disabled-cached');
      await _tap(tester, find.byTooltip('Refresh connectors'));
      await captureJourney(tester, 'prod-n19-refresh-dispatched');
      await _until(
        tester,
        () => !session.state.busy,
        'Connector refresh settles',
      );
      verify();
      expect(
        identical(initial, session.state.runtime),
        isFalse,
        reason: 'Refresh must publish a fresh real cached observation',
      );
      final raw = await profile.rpc('mcp.servers.status');
      expect(
        (raw['servers'] as List)
            .where((row) => row['name'] == 'wing-qa-disabled')
            .single['status'],
        'disabled',
      );
      await captureJourney(tester, 'prod-n19-refresh-confirmed');
      debugPrint(
        'PROD_N19: nonempty disabled cached status refreshed without probe or reconnect',
      );
    });
  });

  testWidgets('Production N23 settings save confirms isolated profile readback', (
    tester,
  ) async {
    await _journey(tester, 'n23', (profile) async {
      await _tap(tester, find.text('Memory'));
      await _tap(tester, find.byTooltip('Memory settings'));
      await _until(
        tester,
        () => find.byType(AdminSettingsPage).evaluate().isNotEmpty,
        'Memory settings opens',
      );
      final session = _owner<SettingsEditSession>(tester);
      await _until(
        tester,
        () => !session.state.loading,
        'Settings read settles',
      );
      expect(session.state.hasObservation, isTrue);
      expect(session.state.error, isNull);
      final field = session.state.fields.singleWhere(
        (item) => item.field.key == 'memory.memory_char_limit',
      );
      final desired = field.value == 2800 ? 2801 : 2800;
      final input = find.byKey(
        const ValueKey('setting:memory.memory_char_limit'),
      );
      await _visible(tester, input);
      await tester.tap(input);
      await tester.enterText(input, '$desired');
      await tester.pump();
      expect(tester.widget<TextFormField>(input).controller!.text, '$desired');
      expect(
        session.state.fields
            .singleWhere((item) => item.field.key == 'memory.memory_char_limit')
            .value,
        desired,
      );
      expect(session.state.canSave, isTrue);
      await captureJourney(tester, 'prod-n23-memory-draft');
      await _tap(tester, find.byTooltip('Save changes'));
      await _until(
        tester,
        () =>
            session.state.error != null ||
            (!session.state.saving &&
                find
                    .text('Settings saved.')
                    .hitTestable()
                    .evaluate()
                    .isNotEmpty),
        'Settings save settles with visible confirmation',
      );
      expect(session.state.error, isNull);
      expect(session.state.dirtyCount, 0);
      expect(find.text('Settings saved.').hitTestable(), findsOneWidget);
      // Observe the transient acknowledgement before any capture or readback
      // can consume its display interval.
      await captureJourney(tester, 'prod-n23-save-confirmed');
      expect((await profile.config())['memory']['memory_char_limit'], desired);
      await _tap(tester, find.byTooltip('Cancel'));
      await _until(
        tester,
        () => find.byType(AdminSettingsPage).evaluate().isEmpty,
        'Saved settings route closes',
      );
      await _tap(tester, find.byTooltip('Memory settings'));
      await _until(
        tester,
        () => find.byType(AdminSettingsPage).evaluate().isNotEmpty,
        'Settings editor reopens',
      );
      final reopened = _owner<SettingsEditSession>(tester);
      await _until(
        tester,
        () => !reopened.state.loading,
        'Reopened settings read settles',
      );
      expect(
        reopened.state.fields
            .singleWhere((item) => item.field.key == 'memory.memory_char_limit')
            .value,
        desired,
      );
      await captureJourney(tester, 'prod-n23-reopened');
      debugPrint(
        'PROD_N23: QA-only setting saved, HTTP readback and reopened editor agree',
      );
    });
  });

  testWidgets('Production N17 skill lock and unlock confirm isolated readback', (
    tester,
  ) async {
    await _journey(tester, 'n17', (profile) async {
      const name = 'wing-qa-skill';
      final initialRows = (await profile.read('skills'))['data'] as List;
      expect(
        initialRows.where((row) => row['name'] == name).single['locked'],
        isFalse,
        reason: 'Runner must seed the owned unlocked QA skill',
      );
      final content = (await profile.read('skills/content', {
        'name': name,
      }))['content'];
      expect(content, isA<String>());
      expect(content, contains('name: wing-qa-skill'));
      await _tap(tester, find.text('Skills and tools'));
      await _tap(tester, find.byTooltip('Manage capabilities'));
      await _tap(tester, find.text('Skill library'));
      await _until(
        tester,
        () => find.byType(AdminSkillLibraryPage).evaluate().isNotEmpty,
        'Skill library opens',
      );
      final session = _owner<ProfileSkillsSession>(tester);
      await _until(
        tester,
        () => !session.state.busy,
        'Owned skill inventory settles',
      );
      expect(session.state.error, isNull);
      expect(session.state.verified, isTrue);
      expect(
        session.state.installed.singleWhere((row) => row.name == name).locked,
        isFalse,
      );
      await _tap(tester, find.text(name));
      await _until(
        tester,
        () =>
            find.byType(AdminSkillDetail).evaluate().isNotEmpty &&
            !session.state.busy,
        'Owned skill detail settles',
      );
      expect(session.state.error, isNull);
      expect(find.text('Agent edits are not locked'), findsOneWidget);
      await captureJourney(tester, 'prod-n17-skill-unlocked');

      for (final locked in [true, false]) {
        await _tap(tester, find.byTooltip('Skill actions'));
        await _tap(
          tester,
          find.byTooltip(
            locked ? 'Lock against agent edits' : 'Unlock agent edits',
          ),
        );
        await _until(
          tester,
          () =>
              session.state.error != null ||
              (!session.state.busy &&
                  session.state.installed
                          .singleWhere((row) => row.name == name)
                          .locked ==
                      locked),
          locked ? 'Skill lock is confirmed' : 'Skill unlock is confirmed',
        );
        expect(session.state.error, isNull);
        expect(session.state.verified, isTrue);
        expect(
          find.text(
            locked
                ? 'Locked against agent edits'
                : 'Agent edits are not locked',
          ),
          findsWidgets,
        );
        final rows = (await profile.read('skills'))['data'] as List;
        expect(
          rows.where((row) => row['name'] == name).single['locked'],
          locked,
        );
        expect(
          (await profile.read('skills/content', {'name': name}))['content'],
          content,
          reason: 'Locking changes protection, not skill instructions',
        );
        await captureJourney(
          tester,
          locked ? 'prod-n17-lock-confirmed' : 'prod-n17-unlock-confirmed',
        );
      }
      debugPrint(
        'PROD_N17: QA skill locked and unlocked through detail actions with unchanged content and HTTP readback',
      );
    });
  });
}

Future<void> _journey(
  WidgetTester tester,
  String name,
  Future<void> Function(ProfileAdministration) body,
) async {
  const url = String.fromEnvironment('WING_HERMES_URL');
  const loginFile = String.fromEnvironment('WING_HERMES_LOGIN_FILE');
  const profileName = String.fromEnvironment('WING_QA_PROFILE');
  expect(url.isNotEmpty && loginFile.isNotEmpty, isTrue);
  expect(
    profileName.startsWith('wing-qa-') &&
        HermesProfile.isCanonicalName(profileName),
    isTrue,
    reason: 'Runner must supply its uniquely owned blank QA profile',
  );
  final connection = await readExistingBackendConnection(
    url: url,
    loginFile: loginFile,
    id: 'hermes-next-admin-prod-$name',
  );
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  expect(
    (await appPreferences
            .admitProfileSelection(connection.id, profileName)
            .settled)
        .confirmed,
    isTrue,
  );
  final controller = ProfileWorkspaceController(
    appPreferences: appPreferences,
    access: ConnectionAccess(connection: connection, dashboardOAuth: null),
    connectionIdentity: connection.id,
    preferences: preferences,
  );
  try {
    await controller.initialize();
    expect(controller.current?.scope.profileName, profileName);
    expect(controller.current?.chat, isNull);
    await tester.pumpWidget(
      journeyCaptureBoundary(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(
            journeyTheme == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: ProfileWorkspaceScreen(
            controller: controller,
            onConnections: () {},
          ),
        ),
      ),
    );
    await _tap(tester, find.byTooltip('Open navigation menu'));
    await _tap(tester, find.text('Hermes administration'));
    await _until(
      tester,
      () => find.text('Models and reasoning').evaluate().isNotEmpty,
      'Normal administration destination opens',
    );
    await body(controller.administration().profile(profileName));
    expect(controller.current?.scope.profileName, profileName);
    expect(controller.current?.chat, isNull);
    expect(tester.takeException(), isNull);
  } catch (error, stack) {
    if (find.byKey(const ValueKey('journey-capture')).evaluate().isNotEmpty) {
      try {
        await captureJourney(tester, 'prod-$name-failure', failure: true);
      } catch (_) {
        // Preserve the original verdict when capture itself is unavailable.
      }
    }
    Error.throwWithStackTrace(error, stack);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    appPreferences.dispose();
  }
}

T _owner<T>(WidgetTester tester) {
  final owners = Set<T>.identity()
    ..addAll(
      tester
          .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
          .map((builder) => builder.listenable)
          .whereType<T>(),
    );
  return owners.single;
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 70));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _visible(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    Finder scrollable() => find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .hitTestable();
    await _until(
      tester,
      () => target.evaluate().isNotEmpty || scrollable().evaluate().isNotEmpty,
      'Destination renders its controls',
    );
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        220,
        scrollable: scrollable().last,
        maxScrolls: 30,
      );
    }
  }
  await revealJourneyControl(tester, target.last);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _visible(tester, target);
  await tapJourneyControl(tester, target.last);
  await tester.pump();
}
