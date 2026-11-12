import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/doctor_finding_draft_session.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'support/administration_operation_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/administration/admin_operations_page.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/doctor_diagnostic.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/administration_fixture.dart';
import 'support/profile_browser_fixture.dart';

const _lines = [
  '=== doctor started 2026-09-19 11:17:00 ===',
  'Diagnostic context outside the findings: profiles checked',
  '────────────────────────────────────────────────────────────',
  'Found 3 issue(s) to address:',
  '1. state.db is large — enable sessions.auto_prune in config.yaml',
  '2. Browser tools (agent-browser) has 2 npm vulnerabilities',
  '3. web workspace has 6 npm vulnerabilities',
];

class _Fixture {
  final admin = AdministrationFixture();
  final browser = ProfileBrowserFixture();
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  Completer<void>? creationGate;
  bool failCreation = false;
  bool failOpening = false;
  final creates = <Map<String, dynamic>>[];
  final opened = <ProfileSessionKey>[];

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: admin.server.connectionId,
          label: admin.id,
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: admin.server.connectionIdentity,
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: (scope) {
        final source = browser.gateway(scope);
        return ProfileGateway(
          scope: scope,
          discover: source.discover,
          get: source.read,
          rpc: (method, params) async {
            if (method == 'session.create') {
              creates.add(Map.of(params));
              final number = creates.length;
              await creationGate?.future;
              if (failCreation) throw StateError('Chat connection unavailable');
              return {
                ...canonicalSnapshotFields,
                'session_id': 'runtime-$number',
                'stored_session_id': 'doctor-$number',
                'info': {'profile_name': scope.profileName},
              };
            }
            return source.call(method, params);
          },
        );
      },
    );
    await controller.initialize();
    admin.override = (method, path, query, body) async =>
        path.startsWith('actions/')
        ? {
            'name': 'doctor',
            'pid': 7,
            'running': false,
            'exit_code': 0,
            'lines': _lines,
          }
        : AdministrationFixture(admin.id).send(method, path, query, body);
  }

  Widget page() {
    final operation = fixtureOperation(
      admin.server,
      const AdministrationAction('doctor', 7),
    );
    return AdminActionPage(
      operation: operation,
      title: 'Doctor',
      scope: admin.id,
      createDraftSession: () =>
          DoctorFindingDraftSession(operation, controller),
      onOpenSession: (key) async {
        if (failOpening) throw StateError('History unavailable');
        opened.add(key);
        await controller.openSession(key);
      },
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: wingTheme(Brightness.dark), home: page()),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  test('prompts focus on one finding and retain all available log text', () {
    final findings = DoctorDiagnostic.fromLines(_lines)!.findings;
    final log = _lines.join('\n');
    final database = findings[0].chatPrompt(log);
    expect(database, contains('Finding:\nstate.db is large'));
    expect(
      database,
      contains(
        'Doctor’s recommendation:\nenable sessions.auto_prune in config.yaml',
      ),
    );
    expect(
      database,
      contains('Do not make changes or run repair commands yet.'),
    );
    expect(database, endsWith('Diagnostic output:\n$log'));
    final browser = findings[1]
        .chatPrompt(log)
        .split('Diagnostic output:')
        .first;
    expect(browser, contains('Finding:\nBrowser tools (agent-browser)'));
    expect(browser, contains('Doctor details:\n2 npm vulnerabilities'));
    expect(browser, isNot(contains('Doctor’s recommendation')));
    expect(browser, isNot(contains('state.db')));
    final unknown = const DoctorFinding(
      'Unknown finding',
      null,
    ).chatPrompt(log);
    expect(unknown, isNot(contains('null')));
    expect(unknown, isNot(contains('Doctor details:')));
  });

  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.initialize();
  });
  tearDown(() {
    fixture.controller.dispose();
    fixture.appPreferences.dispose();
  });

  test(
    'retirement during draft notification prevents later preparation',
    () async {
      final operation = fixtureOperation(
        fixture.admin.server,
        const AdministrationAction('doctor', 7),
      );
      await operation.refresh();
      final draft = DoctorFindingDraftSession(operation, fixture.controller);
      await draft.openFinding(
        0,
        navigate: (key) async => fixture.opened.add(key),
        isRouteCurrent: () => false,
      );
      expect(fixture.creates, isEmpty);
      expect(fixture.opened, isEmpty);
      draft.addListener(draft.dispose);
      await draft.openFinding(
        0,
        navigate: (key) async => fixture.opened.add(key),
        isRouteCurrent: () => true,
      );
      expect(fixture.creates, isEmpty);
      expect(fixture.opened, isEmpty);
    },
  );

  testWidgets(
    'each finding creates an editable unsent draft on the selected profile',
    (tester) async {
      final controller = fixture.controller;
      await controller.switchProfile('work');
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'newest'),
      );
      final existing = controller.current!.chat!;
      await controller.updateDraft(existing, 'Keep my existing draft');
      // A health diagnosis must not inherit the last browsed project's cwd.
      await controller.selectProject(controller.current!.projects.first);
      await fixture.pump(tester);
      expect(find.text('Ask Hermes'), findsNWidgets(3));
      for (var index = 0; index < 3; index++) {
        final action = find.text('Ask Hermes').at(index);
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        final chat = controller.current!.chat!;
        expect(chat.key.workspace.profileName, 'work');
        expect(chat.key.sessionId, 'doctor-${index + 1}');
        expect(chat.projectId, isNull);
        expect(
          chat.composer.observation.text,
          DoctorDiagnostic.fromLines(
            _lines,
          )!.findings[index].chatPrompt(_lines.join('\n')),
        );
        expect(chat.reading.messages, isEmpty);
        expect(chat.composer.observation.queue, isEmpty);
        expect(fixture.creates.last['profile'], 'work');
        expect(fixture.creates.last.containsKey('cwd'), isFalse);
        expect(fixture.creates.last.containsKey('messages'), isFalse);
      }
      expect(existing.composer.observation.text, 'Keep my existing draft');
      expect(fixture.opened.length, 3);
      expect(
        fixture.browser.calls.where(
          (call) => {
            'prompt.submit',
            'command.dispatch',
            'slash.exec',
          }.contains(call.$2),
        ),
        isEmpty,
      );
      expect(
        fixture.admin.requests.where((request) => request.$1 != 'GET'),
        isEmpty,
      );
      expect(fixture.admin.requests.first.$3['lines'], '2000');
      final savedDraft =
          await ComposerDraftStore(
            controller.preferences,
            connectionIdentity: controller.connectionIdentity,
          ).read(
            profileName: controller.current!.chat!.key.workspace.profileName,
            sessionId: controller.current!.chat!.key.sessionId,
          );
      expect(savedDraft!.text, contains('web workspace'));

      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final fields = tester.widgetList<EditableText>(find.byType(EditableText));
      expect(
        fields.any(
          (field) =>
              field.controller.text ==
              controller.current!.chat!.composer.observation.text,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending creation blocks repeat taps and follows the captured owner',
    (tester) async {
      fixture.creationGate = Completer<void>();
      await fixture.pump(tester);
      await tester.tap(find.text('Ask Hermes').first);
      await tester.pump();
      await tester.tap(find.text('Ask Hermes').first);
      await tester.pump();
      expect(fixture.creates.length, 1);
      final original = fixture.controller.current!;
      await fixture.controller.switchProfile('work');
      fixture.creationGate!.complete();
      await tester.pumpAndSettle();
      expect(fixture.controller.current!.scope.profileName, 'work');
      expect(fixture.controller.current!.chat, isNull);
      expect(
        original.chats['doctor-1']!.composer.observation.text,
        contains('state.db is large'),
      );
      expect(fixture.creates.single['profile'], 'personal');
      expect(fixture.opened, isEmpty);
      expect(
        find.text('Draft saved in personal. Open it from Chats.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('creation failure retains findings and allows retry', (
    tester,
  ) async {
    fixture.failCreation = true;
    await fixture.pump(tester);
    await tester.tap(find.text('Ask Hermes').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not open the chat.'), findsOneWidget);
    expect(find.text('state.db is large'), findsOneWidget);
    expect(fixture.opened, isEmpty);
    fixture.failCreation = false;
    await tester.tap(find.text('Ask Hermes').first);
    await tester.pumpAndSettle();
    expect(fixture.opened.length, 1);
    expect(find.textContaining('Could not open the chat.'), findsNothing);
  });

  testWidgets(
    'navigation failure retries the saved draft without creating another chat',
    (tester) async {
      fixture.failOpening = true;
      await fixture.pump(tester);
      await tester.tap(find.text('Ask Hermes').first);
      await tester.pumpAndSettle();
      final chat = fixture.controller.current!.chat!;
      expect(chat.composer.observation.text, contains('state.db is large'));
      expect(find.textContaining('Could not open the chat.'), findsOneWidget);
      fixture.failOpening = false;
      await tester.tap(find.text('Ask Hermes').first);
      await tester.pumpAndSettle();
      expect(fixture.creates.length, 1);
      expect(fixture.opened.single, chat.key);
    },
  );

  testWidgets('leaving Doctor while creating a chat does not navigate later', (
    tester,
  ) async {
    fixture.creationGate = Completer<void>();
    await fixture.pump(tester);
    await tester.tap(find.text('Ask Hermes').first);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Text('Elsewhere')));
    fixture.creationGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Elsewhere'), findsOneWidget);
    expect(fixture.opened, isEmpty);
    expect(
      fixture.controller.current!.chats['doctor-1']!.composer.observation.text,
      contains('state.db is large'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Health routes Doctor draft back to the chat destination', (
    tester,
  ) async {
    var chatDestination = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: chatDestination
                ? ProfileWorkspaceScreen(
                    createBotsSession: () => BotsSession((_) async => const []),
                    controller: fixture.controller,
                  )
                : HermesHealthContent(
                    controller: fixture.controller,
                    repository: fixture.admin.server,
                    onOpenMenu: () {},
                    onOpenSession: (key) async {
                      await fixture.controller.openSession(key);
                      setState(() => chatDestination = true);
                    },
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final health = fixture.controller.healthSession().health;
    restoreDiagnostic(
      health,
      'ops/doctor',
      AdminDiagnosticObservation(const AdministrationAction('doctor', 7), {
        'running': false,
        'exit_code': 0,
        'lines': _lines,
      }, DateTime.now()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doctor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Hermes').first);
    await tester.pumpAndSettle();
    expect(chatDestination, isTrue);
    expect(find.byType(AdminActionPage), findsNothing);
    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(
      fixture.controller.current!.chat!.composer.observation.text,
      contains('state.db is large'),
    );
    expect(tester.takeException(), isNull);
  });
}
