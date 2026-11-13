import 'support/canonical_gateway_fixture.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ColdDraftHost {
  int creates = 0;
  Object resumeError = JsonRpcError(
    'session.resume',
    'Session does not exist',
    code: 4001,
    reason: 'not_found',
  );
  Completer<void>? resumeStarted;
  Completer<void>? resumeDelay;
  final calls = <(String, Map<String, dynamic>)>[];

  Future<ProfileDiscovery> discover() async => const ProfileDiscovery(
    profiles: [HermesProfile(name: 'default')],
    currentName: 'default',
    activeName: 'default',
  );

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: discover,
    get: (endpoint, query) async {
      if (endpoint == 'sessions') {
        return {
          'sessions': <Map<String, dynamic>>[],
          'offset': int.parse(query['offset'] ?? '0'),
          'limit': int.parse(query['limit'] ?? '50'),
          'total': 0,
        };
      }
      if (endpoint == 'model/options') return {'providers': <Object>[]};
      if (endpoint == 'model/info') return {};
      if (endpoint == 'logs') return {'file': 'gui', 'lines': <String>[]};
      if (endpoint.endsWith('/messages')) {
        return {
          'session_id': endpoint.split('/')[1],
          'messages': <Map<String, dynamic>>[],
          'pagination': {
            'offset': 0,
            'limit': 50,
            'returned': 0,
            'order': 'latest',
          },
        };
      }
      throw StateError('Unexpected read: $endpoint');
    },
    rpc: (method, params) async {
      calls.add((method, params));
      switch (method) {
        case 'projects.tree':
          return {'projects': <Map<String, dynamic>>[]};
        case 'session.active_list':
          return {'sessions': <Map<String, dynamic>>[]};
        case 'session.create':
          creates++;
          final storedId = creates == 1
              ? 'orphan-draft'
              : creates == 2
              ? 'replacement-draft'
              : 'unexpected-replacement-$creates';
          return {
            ...canonicalSnapshotFields,
            'session_id': 'runtime-$storedId',
            'stored_session_id': storedId,
            'messages': <Map<String, dynamic>>[],
            'info': {'profile_name': scope.profileName},
          };
        case 'session.resume':
          if (params['session_id'] == 'orphan-draft') {
            resumeStarted?.complete();
            await resumeDelay?.future;
            throw resumeError;
          }
          throw StateError('Unexpected resume target');
        case 'session.history':
          return {'count': 0, 'messages': <Map<String, dynamic>>[]};
        default:
          return {};
      }
    },
  );
}

void main() {
  testWidgets('right click offers editing on a narrow screen with large text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final host = _ColdDraftHost()..creates = 1;
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'verified-host-auth',
    );
    await store.write(
      profileName: 'default',
      sessionId: 'orphan-draft',
      text:
          'A long draft preview that should wrap without hiding its actions on a small phone',
      attachments: const [],
    );
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'verified-host-auth',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('saved-draft-orphan-draft'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(
      row,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue editing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Continue editing'));
    await tester.pumpAndSettle();
    expect(
      controller.current!.chat!.composer.observation.text,
      startsWith('A long draft preview'),
    );
    expect(host.creates, 2);
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  test(
    'discard clears cached drafts and refuses stale or active work',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Host',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'verified-host-auth',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: _ColdDraftHost().gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Original');
      final owner = chat.key.workspace;
      final original = controller.savedDrafts(owner).single;
      await expectLater(
        controller.discardSavedDraft(owner, original),
        throwsStateError,
      );
      controller.showList();
      await controller.updateDraft(chat, 'Newer text');
      await expectLater(
        controller.discardSavedDraft(owner, original),
        throwsStateError,
      );
      expect((await controller.savedDraft(chat.key))!.text, 'Newer text');
      emitChatEvent(controller, chat, 'message.start');
      await expectLater(
        controller.discardSavedDraft(
          owner,
          controller.savedDrafts(owner).single,
        ),
        throwsStateError,
      );
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      await controller.discardSavedDraft(
        owner,
        controller.savedDrafts(owner).single,
      );
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.composer.observation.queue, isEmpty);
      expect(await controller.savedDraft(chat.key), isNull);
    },
  );

  testWidgets('draft actions discard only the chosen draft across restart', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'verified-host-auth',
    );
    for (final profile in ['default', 'other']) {
      for (final id in ['orphan-draft', 'keep-draft']) {
        await store.write(
          profileName: profile,
          sessionId: id,
          text: '$profile $id',
          attachments: const [],
        );
      }
    }
    final host = _ColdDraftHost();
    ProfileWorkspaceController buildController() => ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'verified-host-auth',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    var controller = buildController();
    addTearDown(() => controller.dispose());
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('saved-draft-orphan-draft'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Draft actions')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue editing'), findsOneWidget);
    await tester.tap(find.text('Discard draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(
      await store.read(profileName: 'default', sessionId: 'orphan-draft'),
      isNotNull,
    );
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Discard draft'));
    await tester.pumpAndSettle();
    expect(row, findsNothing);
    expect(
      await store.read(profileName: 'default', sessionId: 'orphan-draft'),
      isNull,
    );
    expect(
      await store.read(profileName: 'other', sessionId: 'orphan-draft'),
      isNotNull,
    );
    expect(
      await store.read(profileName: 'default', sessionId: 'keep-draft'),
      isNotNull,
    );
    expect(
      host.calls.where(
        (call) => call.$1 == 'session.delete' || call.$1 == 'prompt.submit',
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    controller = buildController();
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(row, findsNothing);
    expect(find.text('default keep-draft'), findsOneWidget);
  });

  testWidgets(
    'ordinary Chats startup double tap recovers an unlisted draft once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final host = _ColdDraftHost();
      final connection = SavedConnection(
        id: 'host',
        label: 'Host',
        host: 'localhost',
        port: 1,
        apiKey: '',
      );
      ProfileWorkspaceController buildController() =>
          ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: connection,
              dashboardOAuth: null,
            ),
            connectionIdentity: 'verified-host-auth',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );

      var controller = buildController();
      addTearDown(() => controller.dispose());
      await controller.initialize();
      final original = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(
        original,
        'Ordinary restart draft QA retained',
      );
      await ComposerDraftStore(
        preferences,
        connectionIdentity: 'verified-host-auth',
      ).write(
        profileName: 'default',
        sessionId: original.key.sessionId,
        text: original.composer.observation.text,
        attachments: const [],
        submissionUncertain: true,
      );
      controller.dispose();

      controller = buildController();
      await controller.initialize();
      expect(controller.current!.visibleSessions, isEmpty);
      expect(
        (await ComposerDraftStore(
          preferences,
          connectionIdentity: 'verified-host-auth',
        ).read(profileName: 'default', sessionId: 'orphan-draft'))?.text,
        'Ordinary restart draft QA retained',
      );

      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Saved drafts'), findsOneWidget);
      expect(find.text('Ordinary restart draft QA retained'), findsOneWidget);
      host
        ..resumeStarted = Completer<void>()
        ..resumeDelay = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('saved-draft-orphan-draft')));
      await tester.tap(find.byKey(const ValueKey('saved-draft-orphan-draft')));
      await tester.pump();
      await host.resumeStarted!.future;
      host.resumeDelay!.complete();
      await tester.pumpAndSettle();

      expect(host.creates, 2);
      expect(controller.current!.chat!.key.sessionId, 'replacement-draft');
      expect(
        controller.current!.chat!.composer.observation.text,
        'Ordinary restart draft QA retained',
      );
      expect(
        controller.current!.chat!.composer.observation.submissionUncertain,
        isTrue,
      );
      expect(find.text('Ordinary restart draft QA retained'), findsOneWidget);
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'verified-host-auth',
      );
      expect(
        await store.read(profileName: 'default', sessionId: 'orphan-draft'),
        isNull,
      );
      expect(
        (await store.read(
          profileName: 'default',
          sessionId: 'replacement-draft',
        ))?.text,
        'Ordinary restart draft QA retained',
      );
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets(
    'saved drafts stay profile scoped and ambiguous resume preserves the source',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'verified-host-auth',
      );
      await store.write(
        profileName: 'default',
        sessionId: 'orphan-draft',
        text: 'Keep on ambiguous failure',
        attachments: const [],
      );
      await store.write(
        profileName: 'other',
        sessionId: 'other-draft',
        text: 'Other profile secret draft',
        attachments: const [],
      );
      await store.write(
        profileName: 'default',
        sessionId: 'queued-draft',
        text: '',
        attachments: const [],
        queuedPrompts: [QueuedPromptDraft(text: 'Follow up later')],
      );
      final host = _ColdDraftHost()
        ..creates = 1
        ..resumeError = TimeoutException('lost response');
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Host',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'verified-host-auth',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep on ambiguous failure'), findsOneWidget);
      expect(find.text('1 queued message'), findsOneWidget);
      expect(find.text('Other profile secret draft'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('saved-draft-orphan-draft')));
      await tester.pumpAndSettle();

      expect(controller.current!.chat, isNull);
      expect(host.creates, 1);
      expect(
        (await store.read(
          profileName: 'default',
          sessionId: 'orphan-draft',
        ))?.text,
        'Keep on ambiguous failure',
      );
      expect(
        (await store.read(
          profileName: 'other',
          sessionId: 'other-draft',
        ))?.text,
        'Other profile secret draft',
      );
    },
  );
}
