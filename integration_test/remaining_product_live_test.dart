import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/core/models/session_control.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

const _port = int.fromEnvironment('HERMES_TEST_PORT');
const _repo = String.fromEnvironment('QA_APPROVAL_REPO');

void evidence(String scenario, Map<String, Object?> result) {
  // Only test identifiers, counts and status. Never print config or credentials.
  debugPrint('REMAINING_QA ${jsonEncode({'case': scenario, ...result})}');
}

Future<ProfileWorkspaceController> connect(
  String profile,
  SharedPreferences preferences,
  AppPreferences appPreferences,
) async {
  final client = ProfileWorkspaceController(
    connectionIdentity: 'remaining-qa-$profile',
    access: ConnectionAccess(
      connection: SavedConnection(
        id: 'remaining-qa-$profile',
        label: 'Local acceptance',
        host: '127.0.0.1',
        port: _port,
        dashboardPortOverride: _port,
        apiKey: '',
      ),
      dashboardOAuth: null,
    ),
    preferences: preferences,
    appPreferences: appPreferences,
  );
  await client.initialize();
  expect(client.error, isNull);
  expect(await client.switchProfile(profile), isTrue);
  return client;
}

Future<void> until(
  WidgetTester tester,
  bool Function() ready,
  String reason, {
  int seconds = 75,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(ready(), isTrue, reason: reason);
}

Future<void> send(
  ProfileWorkspaceController client,
  ProfileChat chat,
  String prompt,
) async {
  await client.updateDraft(chat, prompt);
  await client.send(chat);
}

Future<void> settled(WidgetTester tester, ProfileChat chat) async {
  await until(
    tester,
    () => !chat.runtime.blocksTurnAdmission,
    'Real Hermes turn must settle',
  );
  expect(chat.runtime.error, isNull);
  expect(chat.runtime.execution, ChatExecution.completed);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_port == 0) {
    test(
      'local Hermes acceptance requires HERMES_TEST_PORT',
      () {},
      skip: true,
    );
    return;
  }

  final fixtureStates = <String, bool>{};
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    try {
      for (final profile in ['android-qa-a', 'android-qa-b']) {
        final client = await connect(profile, preferences, appPreferences);
        try {
          final config = await client.current!.gateway.read('config');
          final disabled = config['skills']?['disabled'] as List? ?? [];
          fixtureStates[profile] = !disabled.contains(
            'android-mobile-slash-qa',
          );
          final mutationOwner = client.current!;
          await mutationOwner.gateway.putOwned(
            'skills/toggle',
            {'name': 'android-mobile-slash-qa', 'enabled': false},
            canDispatch: () => identical(client.current, mutationOwner),
            onDispatched: () {},
          );
        } finally {
          client.dispose();
        }
      }
    } finally {
      appPreferences.dispose();
    }
  });
  tearDownAll(() async {
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    try {
      for (final entry in fixtureStates.entries) {
        final client = await connect(entry.key, preferences, appPreferences);
        try {
          final mutationOwner = client.current!;
          await mutationOwner.gateway.putOwned(
            'skills/toggle',
            {'name': 'android-mobile-slash-qa', 'enabled': entry.value},
            canDispatch: () => identical(client.current, mutationOwner),
            onDispatched: () {},
          );
          final config = await client.current!.gateway.read('config');
          final disabled = config['skills']?['disabled'] as List? ?? [];
          expect(!disabled.contains('android-mobile-slash-qa'), entry.value);
        } finally {
          client.dispose();
        }
      }
      evidence('skill_cleanup', {'fixture_states_restored': true});
    } finally {
      appPreferences.dispose();
    }
  });

  testWidgets(
    'real local vault save and code forms submit and cancel safely',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final client = await connect('android-qa-b', preferences, appPreferences);
      final gateway = client.current!.gateway;
      final label =
          'android-vault-acceptance-${DateTime.now().millisecondsSinceEpoch}';
      const password = 'DummyOnly-VaultAcceptance-6842';
      const code = '684219';
      final chat = await client.createChat(canDispatch: () => true);
      Future<List<Map>> ownItems() async =>
          ((await gateway.call('vault.list'))['items'] as List)
              .whereType<Map>()
              .where((item) => item['label'] == label)
              .toList();
      try {
        expect(await ownItems(), isEmpty);
        await tester.pumpWidget(
          MaterialApp(home: ProfileWorkspaceScreen(controller: client)),
        );
        Future<void> request(
          String prompt,
          GatewaySensitivePromptKind kind,
        ) async {
          await send(client, chat, prompt);
          await until(
            tester,
            () =>
                chat.runtime.secureInput != null ||
                !chat.runtime.blocksTurnAdmission,
            'Expected a real vault request',
            seconds: 60,
          );
          if (chat.runtime.secureInput?.kind != kind) {
            evidence('vault_request_failure', {
              'session': chat.key.sessionId,
              'status': chat.runtime.execution.name,
              'error': chat.runtime.error,
              'tools': chat.runtime.toolActivities
                  .map(
                    (t) => {
                      'name': t.name,
                      'result': t.result
                          ?.replaceAll(password, '<dummy-redacted>')
                          .replaceAll(code, '<dummy-redacted>'),
                    },
                  )
                  .toList(),
            });
          }
          expect(
            chat.runtime.secureInput?.kind,
            kind,
            reason: 'Real gateway must emit the requested form',
          );
          await tester.pump();
        }

        Future<void> tap(String text, {bool submit = false}) async {
          final button = submit
              ? find.widgetWithText(FilledButton, text)
              : find.widgetWithText(TextButton, text);
          await tester.ensureVisible(button);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(button);
          await settled(tester, chat);
          expect(chat.runtime.secureInput, isNull);
          expect(find.byKey(const Key('sensitive-prompt-field')), findsNothing);
        }

        await request(
          'Use browser_exec with only code and timeout_s arguments. Omit the session argument entirely; use the default browser session. '
          'Set code to new_tab("http://127.0.0.1:51165/"); wait_for_load(); print(page_info()) and timeout_s to 20. '
          'Then call browser_vault_save_login with label "$label". Wait for its UI response, '
          'report the tool outcome and stop. Do not use skill_view, clarify or any other tools.',
          GatewaySensitivePromptKind.vaultSaveLogin,
        );
        await tap("Don't save");
        expect(await ownItems(), isEmpty);
        await request(
          'Call browser_vault_save_login again on the same page with label "$label". '
          'Wait for its UI response, report the tool outcome and stop. No other tools.',
          GatewaySensitivePromptKind.vaultSaveLogin,
        );
        await tester.enterText(
          find.byKey(const Key('sensitive-prompt-field')),
          'qa@example.invalid',
        );
        await tester.enterText(
          find.byKey(const Key('sensitive-prompt-password')),
          password,
        );
        await tester.pump();
        await tap('Save login', submit: true);
        expect(
          await ownItems(),
          hasLength(1),
          reason: 'The dummy login must be saved on Hermes',
        );
        expect((await ownItems()).single['origin'], 'http://127.0.0.1:51165');
        await request(
          'Call browser_vault_enter_code on the same page, with no handle. '
          'Wait for its UI response, report the tool outcome and stop. No other tools.',
          GatewaySensitivePromptKind.vaultCode,
        );
        await tap('Cancel');
        await request(
          'Call browser_vault_enter_code again on the same page, with no handle. '
          'Wait for its UI response, report the tool outcome and stop. No other tools.',
          GatewaySensitivePromptKind.vaultCode,
        );
        await tester.enterText(
          find.byKey(const Key('sensitive-prompt-field')),
          code,
        );
        await tester.pump();
        await tap('Continue', submit: true);
        final results = chat.runtime.toolActivities
            .where(
              (tool) =>
                  tool.name == 'browser_vault_enter_code' && tool.isTerminal,
            )
            .map((tool) => tool.result)
            .whereType<String>()
            .toList();
        expect(results, isNotEmpty);
        expect(jsonDecode(results.last)['success'], isTrue);
        expect(jsonDecode(results.last)['filled_fields'], greaterThan(0));
        final persisted =
            '${jsonEncode(chat.reading.messages)} ${chat.composer.observation.text} '
            '${preferences.getKeys().map(preferences.get).toList()}';
        expect(persisted, isNot(contains(password)));
        expect(persisted, isNot(contains(code)));
        final sources =
            (await gateway.call('vault.sources'))['sources'] as List;
        evidence('vault_forms', {
          'outcome': 'passed',
          'save_cancel': true,
          'save_submit': true,
          'code_cancel': true,
          'code_submit': true,
          'secrets_in_history_or_drafts': false,
          'configured_external_managers': sources
              .where((row) => row['name'] != 'local' && row['enabled'] == true)
              .length,
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        try {
          if (chat.runtime.blocksTurnAdmission) await client.stop(chat);
          for (final item in await ownItems()) {
            expect(
              (await gateway.call('vault.remove', {
                'id': item['id'],
              }))['removed'],
              isTrue,
            );
          }
          expect(await ownItems(), isEmpty);
          await gateway.call('session.close', {
            'session_id': chat.runtime.runtimeId,
          });
          evidence('vault_cleanup', {'owned_login_removed': true});
        } finally {
          client.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'real Session and Always approval buttons retain correct scope',
    (tester) async {
      expect(_port, greaterThan(0));
      expect(
        _repo.replaceAll('\\', '/'),
        contains('/build/qa-approval-scope-'),
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final clients = <ProfileWorkspaceController>[];
      final originals = <ProfileWorkspaceController, Map<String, dynamic>>{};
      final chats = <(ProfileWorkspaceController, ProfileChat)>[];
      try {
        for (final profile in ['android-qa-a', 'android-qa-b']) {
          final client = await connect(profile, preferences, appPreferences);
          clients.add(client);
          final config = await client.current!.gateway.read('config');
          originals[client] = {
            'approvals': {'mode': config['approvals']?['mode'] ?? 'manual'},
            'command_allowlist': config['command_allowlist'] ?? <String>[],
          };
          expect(
            originals[client]!['command_allowlist'],
            isEmpty,
            reason: 'Use dedicated QA profiles without existing approval rules',
          );
          final mutationOwner = client.current!;
          await mutationOwner.gateway.putOwned(
            'config',
            {
              'config': {
                'approvals': {'mode': 'manual'},
              },
            },
            canDispatch: () => identical(client.current, mutationOwner),
            onDispatched: () {},
          );
        }
        final a = clients[0];
        final b = clients[1];
        Future<ProfileChat> newChat(ProfileWorkspaceController client) async {
          await tester.pumpWidget(const SizedBox.shrink());
          final chat = await client.createChat(canDispatch: () => true);
          chats.add((client, chat));
          await tester.pumpWidget(
            MaterialApp(home: ProfileWorkspaceScreen(controller: client)),
          );
          await tester.pump();
          return chat;
        }

        final prompt =
            'I explicitly authorize this controlled test. Use terminal exactly once with command "git reset --hard" '
            'and workdir exactly "$_repo". This is my empty disposable repository. '
            'Do not call skill_view. '
            'Do not put -C in the command, use the workdir tool argument. '
            'Do not call clarify or ask a separate question. The terminal approval '
            'system will ask me if needed. Do no other work; if denied, stop. '
            'After the tool result reply only APPROVAL_CHECK_DONE.';
        Future<void> submitTerminal(
          ProfileWorkspaceController client,
          ProfileChat chat,
        ) async {
          await send(client, chat, prompt);
          await until(
            tester,
            () =>
                chat.runtime.approval != null ||
                chat.runtime.pendingQuestion != null ||
                !chat.runtime.blocksTurnAdmission,
            'Terminal must run or request permission',
          );
          if (chat.runtime.pendingQuestion != null) {
            await client.clarify(
              chat,
              'Approved, only in the specified empty QA repository. Invoke terminal now; its approval system handles permission.',
            );
          }
        }

        void verifyTerminal(ProfileChat chat) {
          final results = chat.reading.messages
              .where((row) => row['role'] == 'tool')
              .map((row) => row['content'])
              .whereType<String>()
              .where((text) => text.contains('"exit_code"'))
              .map(jsonDecode)
              .toList();
          expect(
            results,
            isNotEmpty,
            reason: 'A real terminal result must be saved',
          );
          expect(
            results.last['exit_code'],
            0,
            reason: 'The owned Git action must succeed',
          );
        }

        Future<void> choose(ProfileChat chat, String label) async {
          await until(
            tester,
            () =>
                chat.runtime.approval != null ||
                !chat.runtime.blocksTurnAdmission,
            'Expected real approval request',
          );
          expect(
            chat.runtime.approval,
            isNotNull,
            reason: 'Model must invoke the requested terminal action',
          );
          await tester.pump();
          final button = find.widgetWithText(FilledButton, label);
          expect(button, findsOneWidget);
          await tester.ensureVisible(button);
          await tester.pump(const Duration(milliseconds: 250));
          await tester.tap(button, warnIfMissed: true);
          await settled(tester, chat);
          expect(chat.runtime.approval, isNull);
          verifyTerminal(chat);
        }

        final session = await newChat(a);
        await submitTerminal(a, session);
        await choose(session, 'Allow for session');
        var repeatedPrompt = false;
        void observeRepeat() {
          repeatedPrompt |= session.runtime.approval != null;
        }

        a.addListener(observeRepeat);
        await submitTerminal(a, session);
        await settled(tester, session);
        verifyTerminal(session);
        a.removeListener(observeRepeat);
        expect(
          repeatedPrompt,
          isFalse,
          reason: 'Session approval should cover the repeat',
        );

        final permanent = await newChat(a);
        await submitTerminal(a, permanent);
        await choose(permanent, 'Always allow');
        final rules = (await a.current!.gateway.read(
          'config',
        ))['command_allowlist'];
        expect(
          rules,
          isNotEmpty,
          reason: 'Always approval must be saved by Hermes',
        );
        final later = await newChat(a);
        var laterPrompt = false;
        void observeLater() {
          laterPrompt |= later.runtime.approval != null;
        }

        a.addListener(observeLater);
        await submitTerminal(a, later);
        await settled(tester, later);
        verifyTerminal(later);
        a.removeListener(observeLater);
        expect(
          laterPrompt,
          isFalse,
          reason: 'Saved approval should cover a new session',
        );

        final other = await newChat(b);
        await submitTerminal(b, other);
        await until(
          tester,
          () => other.runtime.approval != null,
          'Other profile must still require approval',
        );
        await tester.pump();
        final deny = find.widgetWithText(OutlinedButton, 'Deny');
        await tester.ensureVisible(deny);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(deny);
        await settled(tester, other);
        final denied = other.reading.messages
            .where((row) => row['role'] == 'tool')
            .map((row) => row['content'])
            .whereType<String>()
            .where((text) => text.contains('"exit_code"'))
            .map(jsonDecode)
            .toList();
        expect(denied, hasLength(1));
        expect(denied.single['exit_code'], -1);
        expect(denied.single['status'], 'blocked');
        expect(
          (await b.current!.gateway.read('config'))['command_allowlist'] ?? [],
          isEmpty,
        );
        evidence('approval_scopes', {
          'outcome': 'passed',
          'sessions': chats.length,
          'session_repeat_prompted': repeatedPrompt,
          'new_session_prompted': laterPrompt,
          'other_profile_prompted': true,
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        try {
          for (final (client, chat) in chats) {
            if (chat.runtime.blocksTurnAdmission) await client.stop(chat);
          }
        } finally {
          for (final client in clients) {
            try {
              final original = originals[client];
              if (original != null) {
                final mutationOwner = client.current!;
                await mutationOwner.gateway.putOwned(
                  'config',
                  {'config': original},
                  canDispatch: () => identical(client.current, mutationOwner),
                  onDispatched: () {},
                );
                final restored = await client.current!.gateway.read('config');
                expect(
                  restored['approvals']?['mode'],
                  original['approvals']['mode'],
                );
                expect(
                  restored['command_allowlist'] ?? [],
                  original['command_allowlist'],
                );
              }
            } finally {
              client.dispose();
            }
          }
          evidence('approval_cleanup', {'settings_restored': true});
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'unopened parent with actual child work is compared with global status',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final producer = await connect(
        'android-qa-a',
        preferences,
        appPreferences,
      );
      final observer = await connect(
        'android-qa-b',
        preferences,
        appPreferences,
      );
      final chat = await producer.createChat(canDispatch: () => true);
      try {
        await send(
          producer,
          chat,
          'Delegate exactly one background task: use terminal '
          'to run python -c "import time; time.sleep(35)" once and then reply CHILD_CHECK_DONE. '
          'The child must not access files or do other work. As the parent, immediately '
          'reply DELEGATED_CHECK without waiting for the child.',
        );
        await until(
          tester,
          () =>
              chat.subagents.any((child) => !child.isTerminal) &&
              !chat.runtime.blocksTurnAdmission,
          'Need a real running child after its parent settles',
          seconds: 90,
        );
        await observer.refreshActivity();
        final row = observer.liveActivity
            .where((item) => item.sessionId == chat.key.sessionId)
            .firstOrNull;
        final active = await producer.current!.gateway.call(
          'session.active_list',
        );
        final parent = (active['sessions'] as List)
            .where((item) => item['id'] == chat.runtime.runtimeId)
            .firstOrNull;
        evidence('child_only_activity', {
          'outcome': row != null ? 'passed' : 'backend_limited',
          'parent_status': parent?['status'],
          'server_child_count': parent?['side_tasks_running'],
          'active_children_in_open_chat': chat.subagents
              .where((child) => !child.isTerminal)
              .length,
          'unopened_parent_visible': row != null,
        });
        expect(
          row,
          isNotNull,
          reason:
              'An unopened parent with running child work must be visible in Activity',
        );
        await until(
          tester,
          () => chat.subagents.every((child) => child.isTerminal),
          'Child should finish',
          seconds: 80,
        );
        for (var attempt = 0; attempt < 40; attempt++) {
          await observer.refreshActivity();
          if (!observer.liveActivity.any(
            (item) => item.sessionId == chat.key.sessionId,
          )) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          observer.liveActivity.any(
            (item) => item.sessionId == chat.key.sessionId,
          ),
          isFalse,
        );
        evidence('child_cleanup', {'active_children': 0});
      } finally {
        for (final child
            in chat.subagents.where((child) => !child.isTerminal).toList()) {
          await producer.interruptSubagent(
            chat,
            child.id,
            canDispatch: () => true,
          );
        }
        if (chat.runtime.blocksTurnAdmission) await producer.stop(chat);
        producer.dispose();
        observer.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'nondefault loop command and controls address the same local work',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final client = await connect('android-qa-a', preferences, appPreferences);
      final chat = await client.createChat(canDispatch: () => true);
      final gateway = client.current!.gateway;
      Future<Map<String, dynamic>> loop(String arg) => gateway.call(
        'command.dispatch',
        {'session_id': chat.runtime.runtimeId, 'name': 'loop', 'arg': arg},
      );
      try {
        final started = await loop(
          '30s Reply exactly LOOP_SCOPE_CHECK --times 2',
        );
        final status = await loop('status');
        expect(started['output'], contains('Loop set'));
        expect(status['output'], contains('Loop (active'));
        await client.refreshSessionControl(chat);
        expect(chat.sessionControlError, isNull);
        final present = chat.sessionControl?.loop != null;
        evidence('profile_loop', {
          'outcome': present ? 'controls_available' : 'backend_limited',
          'start': started,
          'slash_status': status,
          'structured_loop_present': present,
        });
        expect(
          present,
          isTrue,
          reason:
              'This acceptance case requires the stock structured loop controls',
        );
        {
          expect(
            await client.controlSession(
              chat,
              SessionControlAction.loopPause,
              canDispatch: () => true,
            ),
            isTrue,
          );
          expect(
            await client.controlSession(
              chat,
              SessionControlAction.loopResume,
              canDispatch: () => true,
            ),
            isTrue,
          );
          expect(
            await client.controlSession(
              chat,
              SessionControlAction.loopStop,
              canDispatch: () => true,
            ),
            isTrue,
          );
        }
      } finally {
        try {
          final stopped = await loop('stop');
          final status = await loop('status');
          evidence('loop_cleanup', {'stop': stopped, 'status': status});
          expect(status['output'], contains('No loop set'));
          if (chat.runtime.blocksTurnAdmission) await client.stop(chat);
        } finally {
          client.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
