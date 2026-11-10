import 'package:wing/core/models/health_alert.dart';
import 'package:wing/core/services/notification_delivery_ledger.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/screens/health_alert_settings_screen.dart';
import 'package:wing/core/widgets/health_alerts/health_alerts_scope.dart';
import 'support/host_resources_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/group_notification.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'support/bots_fixture.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'package:wing/core/services/native_notification_sink.dart';
import 'package:wing/core/services/background_monitoring_service.dart';
import 'support/recording_turn_notification_sink.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import '../integration_test/notification_revamp_device.dart'
    show prepareNotificationFixtureChats, notificationFixtureGateways;

typedef NotificationHarness = ({
  ConnectionManager manager,
  AppPreferences appPreferences,
  SavedConnection connection,
  String identity,
  Host host,
  ProfileWorkspaceController controller,
  ProfileWorkspaceRegistry registry,
});

Future<NotificationHarness> _harness({
  bool restoreCachedChat = false,
  bool customAdministration = false,
  List<Map<String, dynamic>>? indexedSessions,
  ProfileGateway Function(Host, WorkspaceScope)? makeGateway,
  Future<void> Function(GroupInputNotification)? onGroupInputs,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  addTearDown(appPreferences.dispose);
  final secrets = MemoryIdentityStore();
  final manager = await ConnectionManager.create(
    preferences,
    credentialStore: secrets,
  );
  await manager.importConnections(
    [identityTestConnection()],
    replaceExisting: false,
    canCommit: () => true,
  );
  final connection = (await manager.loadConnectionsWithSecrets()).single;
  final identities = ProfileConnectionIdentity(credentialStore: secrets);
  final identity = await identities.resolve(connection);
  final host = Host()..indexedSessions = indexedSessions;
  if (restoreCachedChat) {
    await WorkspaceSnapshotStore(preferences, identity).write({
      'selected': 'a',
      'profiles': [
        {
          'name': 'a',
          'sessions': [
            {'id': 'same', 'title': 'Cached chat'},
          ],
          'projects': [],
          'chats': [
            {'id': 'same', 'title': 'Cached chat', 'messages': []},
          ],
        },
      ],
    });
  }
  final registry = ProfileWorkspaceRegistry(
    identities: identities,
    create: (saved, resolvedIdentity) => ProfileWorkspaceController(
      access: ConnectionAccess(connection: saved, dashboardOAuth: null),
      connectionIdentity: resolvedIdentity,
      preferences: preferences,
      appPreferences: appPreferences,
      onGroupInputs: onGroupInputs,
      gatewayFactory: (scope) =>
          makeGateway?.call(host, scope) ?? host.gateway(scope),
    ),
  );
  addTearDown(registry.dispose);
  final controller = await registry.forConnection(connection);
  if (!customAdministration) {
    // WingApp discovers Bots through administration independently of the chat
    // gateway. Ordinary routing cases have an explicitly empty local roster.
    final resources = HostResourcesFixture(identity: identity);
    addTearDown(resources.server.close);
    final server = AdministrationRepository(
      connectionId: connection.id,
      connectionIdentity: identity,
      connectionLabel: connection.label,
      request: resources.server.request,
      settingsWrite: resources.server.settingsWrite,
      ownedMutation: resources.server.ownedMutation,
      gateway: (profile) => ProfileGateway(
        scope: WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: identity,
          profileName: profile,
        ),
        discover: host.discover,
        get: (path, query) async =>
            throw StateError('Unexpected administration read: $path'),
        rpc: (method, params) async => switch (method) {
          'profiles.list' => {
            'bot_mode_protocol': true,
            'install_id': identity,
            'profiles': <Map<String, dynamic>>[],
          },
          'groups.list' => {'rooms': <Map<String, dynamic>>[]},
          _ => throw StateError('Unexpected administration method: $method'),
        },
      ),
    );
    addTearDown(server.close);
    controller.healthSession(repository: server);
  }
  await controller.initialize();
  return (
    manager: manager,
    appPreferences: appPreferences,
    connection: connection,
    identity: identity,
    host: host,
    controller: controller,
    registry: registry,
  );
}

String _payload(
  NotificationHarness harness,
  String profile, {
  String session = 'same',
}) => jsonEncode(
  ProfileSessionKey(
    WorkspaceScope(
      connectionId: harness.connection.id,
      connectionIdentity: harness.identity,
      profileName: profile,
    ),
    session,
  ).toJson(),
);

int _resumeCount(NotificationHarness harness, String profile) => harness
    .host
    .calls
    .where((call) => call.$1 == profile && call.$2 == 'session.resume')
    .length;

Future<GlobalKey<WingAppState>> _pumpApp(
  WidgetTester tester,
  NotificationHarness harness, {
  AndroidShareIntentService? shareIntents,
  Future<void>? startupExternalNavigationReady,
}) async {
  final key = GlobalKey<WingAppState>();
  await tester.pumpWidget(
    WingApp(
      key: key,
      connManager: harness.manager,
      appPreferences: harness.appPreferences,
      profileControllers: harness.registry,
      shareIntents: shareIntents,
      startupExternalNavigationReady: startupExternalNavigationReady,
    ),
  );
  await tester.pump();
  return key;
}

Future<void> _expectRemovingWorkspaceReturnsHome(WidgetTester tester) async {
  expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
  final context = tester.element(find.byType(ProfileWorkspaceScreen));
  final route = ModalRoute.of(context)!;
  Navigator.of(context, rootNavigator: true).removeRoute(route);
  await _pumpNavigation(tester);
  expect(find.byType(ProfileWorkspaceScreen), findsNothing);
  expect(find.byType(HomeScreen), findsOneWidget);
}

Future<void> _pumpNavigation(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _nativeNotifications = MethodChannel(NativeNotificationSink.channelName);

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'answer notification opens long Markdown at its beginning ${brightness.name} $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearAllTestValues);
          if (const bool.fromEnvironment('CAPTURE_NOTIFICATION_READING')) {
            await tester.runAsync(() async {
              const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
              for (final font in {
                'Roboto': 'Roboto-Regular.ttf',
                'MaterialIcons': 'MaterialIcons-Regular.otf',
              }.entries) {
                await (FontLoader(font.key)..addFont(
                      File(
                        '$fonts/${font.value}',
                      ).readAsBytes().then(ByteData.sublistView),
                    ))
                    .load();
              }
            });
          }
          final harness = await _harness();
          harness.host.running = false;
          harness.host.historyMessages = [
            {'id': 1, 'role': 'user', 'content': 'Explain the result'},
            {
              'id': 2,
              'role': 'assistant',
              'content': [
                'The answer begins here.',
                for (var i = 0; i < 35; i++)
                  'Paragraph $i explains another part of the answer in detail.',
                'The answer ends here.',
              ].join('\n\n'),
            },
          ];
          final app = await _pumpApp(tester, harness);
          await app.currentState!.openProfileNotification(
            jsonEncode({
              ...jsonDecode(_payload(harness, 'a')) as Map<String, dynamic>,
              'focus': const NotificationFocus(
                'answer',
                'result',
                messageId: 2,
              ).toJson(),
            }),
          );
          await _pumpNavigation(tester);
          await tester.settleMarkdown();
          await _pumpNavigation(tester);
          final viewport = tester.getRect(
            find.byKey(const ValueKey('profile-transcript')),
          );
          final beginning = tester.getRect(
            find.text('The answer begins here.', findRichText: true),
          );
          expect(beginning.top, greaterThanOrEqualTo(viewport.top));
          expect(beginning.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(
            tester
                .getTopLeft(
                  find.text('The answer ends here.', findRichText: true),
                )
                .dy,
            greaterThan(viewport.bottom),
          );
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_NOTIFICATION_READING')) {
            final boundary = tester
                .element(find.byType(ProfileWorkspaceScreen))
                .findAncestorRenderObjectOfType<RenderRepaintBoundary>()!;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                'build/feature-verification/notification-reading',
              );
              await directory.create(recursive: true);
              await File(
                '${directory.path}/${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await _pumpNavigation(tester);
        },
      );
    }
  }

  test(
    'native notification bootstrap never borrows another profile session index',
    () async {
      final primary = Host()
        ..indexedSessions = [
          {'id': 'same', 'profile': 'a', 'title': 'Website refresh'},
        ];
      final secondary = Host()
        ..indexedSessions = [
          {'id': 'same', 'profile': 'b', 'title': 'Weekly report'},
        ];
      final gateway = notificationFixtureGateways(primary, secondary);
      for (final profile in ['default', 'a', 'b']) {
        final page = await gateway(
          WorkspaceScope(
            connectionId: 'fixture',
            connectionIdentity: 'fixture',
            profileName: profile,
          ),
        ).sessions();
        expect(page.rows.map((row) => row['profile']), everyElement(profile));
        expect(page.rows, profile == 'default' ? isEmpty : hasLength(1));
      }
    },
  );
  for (final choice in ['once', 'deny', 'stale', 'review']) {
    testWidgets(
      'group approval native interaction uses exact room authority: $choice',
      (tester) async {
        final fixture = BotsFixture();
        fixture.pending.add({
          'kind': 'approval',
          'task_id': 'task',
          'member_id': 'atlas',
          'request_id': 'request',
          'execution_generation': 2,
          'approval': {
            'command': '<write to AGENTS.md>',
            'description': 'Protected instructions',
            'choices': ['once', 'deny'],
          },
        });
        late ChatNotificationCoordinator notices;
        final harness = await _harness(
          onGroupInputs: (value) => notices.receiveGroupInputs(value),
          makeGateway: (host, scope) {
            final base = host.gateway(scope);
            return ProfileGateway(
              scope: scope,
              discover: host.discover,
              get: base.read,
              rpc: (method, params) => method == 'groups.approve'
                  ? fixture.command(
                      scope.profileName,
                      method,
                      params,
                      () => true,
                      () {},
                    )
                  : method.startsWith('groups.')
                  ? fixture.read(scope.profileName, method, params)
                  : base.call(method, params),
            );
          },
        );
        final sink = RecordingTurnNotificationSink();
        notices = ChatNotificationCoordinator(
          harness.manager.prefs,
          sink,
          appPreferences: harness.appPreferences,
        );
        final native = NativeNotificationSink(onInteraction: (_) async {});
        final monitoring = BackgroundMonitoringService(
          preferences: harness.appPreferences,
          hasActiveChats: () => false,
          notificationsEnabled: () async => true,
          supported: false,
        );
        addTearDown(monitoring.dispose);
        final statuses = <String>[];
        var opened = 0;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
          if (call.method == 'actionStatus') {
            statuses.add(call.arguments as String);
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(_nativeNotifications, null),
        );
        notices.bindApplication(
          manager: harness.manager,
          registry: harness.registry,
          native: native,
          deliveries: NotificationDeliveryLedger(harness.manager.prefs),
          ready: Future.value(),
          monitoring: monitoring,
          showChat: (_) async {},
          showGroup: (route) async {
            opened++;
          },
          reviewApproval: (_) async {},
          deferShare: () {},
          showOpenError: () {},
          beforeNavigation: () async {},
        );
        addTearDown(notices.closeApplication);
        await harness.controller.activateGroupNotifications();
        final notice = sink.shown.last;
        if (choice == 'stale') {
          fixture.pending.single['execution_generation'] = 3;
        }
        await notices.receiveInteraction(
          NativeNotificationInteraction.fromJson({
            'payload': notice.payload,
            'choice': choice == 'deny' ? 'deny' : 'once',
            'review': choice == 'review',
            'command': notice.expandedBody,
          }),
        );
        if (choice == 'stale' || choice == 'review') {
          expect(fixture.commands, isEmpty);
          expect(opened, choice == 'review' ? 1 : 0);
          if (choice == 'stale') {
            expect(statuses.single, contains('no longer pending'));
          }
        } else {
          expect(fixture.commands.single.$2, 'groups.approve');
          expect(fixture.commands.single.$3, {
            'room_id': 'room-1',
            'task_id': 'task',
            'member_id': 'atlas',
            'request_id': 'request',
            'execution_generation': 2,
            'choice': choice,
            'profile': 'default',
          });
        }
        expect(
          harness.host.calls.where((c) => c.$2 == 'session.resume'),
          isEmpty,
        );
        // Retire watcher timers inside the widget-test body.
        harness.registry.dispose();
      },
    );
  }

  for (final entry in [
    'direct',
    'native tap',
    'native startup',
    'covered group',
  ]) {
    testWidgets(
      'group notification opens the shared discussion without resuming a worker: $entry',
      (tester) async {
        final fixture = BotsFixture();
        for (final row in fixture.profiles) {
          row['canonical_session'] = null;
        }
        fixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': 1791818730.0,
          'actor': {
            'kind': 'member',
            'id': 'atlas',
            'profile': 'atlas',
            'display_name': 'Atlas',
          },
          'payload': {'text': 'Shared group answer'},
        });
        final harness = await _harness(
          customAdministration: true,
          makeGateway: (host, scope) {
            final base = host.gateway(scope);
            return ProfileGateway(
              scope: scope,
              discover: host.discover,
              get: base.read,
              rpc: (method, params) =>
                  method.startsWith('groups.') || method == 'profiles.list'
                  ? fixture.read(scope.profileName, method, params)
                  : base.call(method, params),
            );
          },
        );
        harness.host.profiles.addAll(['default', 'atlas', 'mira', 'forge']);
        final resources = HostResourcesFixture(identity: harness.identity);
        addTearDown(resources.server.close);
        final server = AdministrationRepository(
          connectionId: harness.connection.id,
          connectionIdentity: harness.identity,
          connectionLabel: harness.connection.label,
          request: resources.server.request,
          settingsWrite: resources.server.settingsWrite,
          ownedMutation: resources.server.ownedMutation,
          gateway: (profile) {
            final scope = WorkspaceScope(
              connectionId: harness.connection.id,
              connectionIdentity: harness.identity,
              profileName: profile,
            );
            final base = harness.host.gateway(scope);
            return ProfileGateway(
              scope: scope,
              discover: harness.host.discover,
              get: base.read,
              rpc: (method, params) =>
                  method.startsWith('groups.') || method == 'profiles.list'
                  ? fixture.read(profile, method, params)
                  : base.call(method, params),
            );
          },
        );
        addTearDown(server.close);
        harness.controller.healthSession(repository: server);
        final payload = jsonEncode({
          ...GroupNotificationTarget(
            WorkspaceScope(
              connectionId: harness.connection.id,
              connectionIdentity: harness.identity,
              profileName: 'default',
            ),
            'room-1',
          ).toJson(),
          'focus': const NotificationFocus('answer', '1').toJson(),
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const plugin = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        if (entry != 'direct') {
          AndroidFlutterLocalNotificationsPlugin.registerWith();
          messenger.setMockMethodCallHandler(
            plugin,
            (call) async => switch (call.method) {
              'initialize' => true,
              'getNotificationAppLaunchDetails' => {
                'notificationLaunchedApp': false,
              },
              'areNotificationsEnabled' => true,
              _ => null,
            },
          );
          messenger.setMockMethodCallHandler(
            _nativeNotifications,
            (call) async => call.method == 'initialize'
                ? [
                    if (entry == 'native startup') {'payload': payload},
                  ]
                : null,
          );
          addTearDown(() {
            messenger.setMockMethodCallHandler(plugin, null);
            messenger.setMockMethodCallHandler(_nativeNotifications, null);
          });
        }
        final app = await _pumpApp(tester, harness);
        final opening = switch (entry) {
          'direct' => app.currentState!.openProfileNotification(payload),
          'native tap' || 'covered group' => messenger.handlePlatformMessage(
            _nativeNotifications.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('interaction', {'payload': payload}),
            ),
            (_) {},
          ),
          _ => Future<void>.value(),
        };
        await _pumpNavigation(tester);
        await opening;
        await _pumpNavigation(tester);
        await tester.settleMarkdown();
        expect(find.byType(BotGroupScreen), findsOneWidget);
        expect(
          find.text('Shared group answer', findRichText: true),
          findsOneWidget,
        );
        expect(
          harness.host.calls.where((call) => call.$2 == 'session.resume'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        if (entry == 'covered group') {
          final context = tester.element(find.byType(BotGroupScreen));
          unawaited(
            Navigator.of(context, rootNavigator: true).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Covering editor')),
              ),
            ),
          );
          await _pumpNavigation(tester);
          expect(find.text('Covering editor'), findsOneWidget);
          await app.currentState!.openProfileNotification(payload);
          await _pumpNavigation(tester);
          await tester.settleMarkdown();
          await _pumpNavigation(tester);
          expect(find.byType(BotGroupScreen), findsOneWidget);
          expect(
            find.text('Shared group answer', findRichText: true),
            findsOneWidget,
          );
          expect(find.text('Covering editor'), findsNothing);
          expect(
            find.text('Covering editor', skipOffstage: false),
            findsOneWidget,
          );
          final groupContext = tester.element(find.byType(BotGroupScreen));
          final groupRoute = ModalRoute.of(groupContext)!;
          expect(groupRoute.isCurrent, isTrue);
          await app.currentState!.openProfileNotification(payload);
          await _pumpNavigation(tester);
          expect(
            ModalRoute.of(tester.element(find.byType(BotGroupScreen))),
            same(groupRoute),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpNavigation(tester);
      },
    );
  }
  testWidgets(
    'native cold tap wins over the remembered workspace and profile',
    (tester) async {
      final otherHost = Host()..running = false;
      final harness = await _harness(
        makeGateway: (host, scope) =>
            (scope.profileName == 'b' ? otherHost : host).gateway(scope),
      );
      harness.host.running = false;
      final seeded = await prepareNotificationFixtureChats(
        harness.controller,
        restarting: false,
      );
      await harness.appPreferences
          .admitWorkspaceEntry(harness.connection.id)
          .settled;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      messenger.setMockMethodCallHandler(
        plugin,
        (call) async => switch (call.method) {
          'initialize' => true,
          'getNotificationAppLaunchDetails' => {
            'notificationLaunchedApp': false,
          },
          'areNotificationsEnabled' => true,
          _ => null,
        },
      );
      messenger.setMockMethodCallHandler(
        _nativeNotifications,
        (call) async => call.method == 'initialize'
            ? [
                {'payload': _payload(harness, 'a')},
              ]
            : null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(plugin, null);
        messenger.setMockMethodCallHandler(_nativeNotifications, null);
      });
      await _pumpApp(tester, harness);
      final restored = await prepareNotificationFixtureChats(
        harness.controller,
        restarting: true,
      );
      await _pumpNavigation(tester);
      await tester.settleMarkdown();
      expect(harness.controller.current?.scope.profileName, 'a');
      expect(harness.controller.current?.chat?.key.sessionId, 'same');
      expect(restored.chat, same(seeded.chat));
      expect(restored.other, same(seeded.other));
      final destination = find.byWidgetPredicate(
        (widget) =>
            widget is ProfileWorkspaceScreen &&
            ModalRoute.of(tester.element(find.byWidget(widget)))!.isCurrent,
      );
      expect(destination, findsOneWidget);
      expect(
        find.descendant(
          of: destination,
          matching: find.text('a completed', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(find.text('b completed', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpNavigation(tester);
    },
  );

  test(
    'cold fixture restores send admission without changing selection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppPreferences(prefs);
      addTearDown(preferences.dispose);
      await WorkspaceSnapshotStore(prefs, 'fixture-owner').write({
        'selected': 'b',
        'profiles': [
          for (final name in ['a', 'b'])
            {
              'name': name,
              'sessions': [
                {'id': 'same', 'title': '$name chat', 'profile': name},
              ],
              'chats': [
                {'id': 'same', 'title': '$name chat', 'messages': []},
              ],
            },
        ],
      });
      final primary = Host()..running = false;
      final other = Host()..running = false;
      final notices = <ProfileNotification>[];
      final noticeReady = Completer<ProfileNotification>();
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'fixture-owner',
        preferences: prefs,
        appPreferences: preferences,
        onAttention: (notice) async {
          notices.add(notice);
          noticeReady.complete(notice);
        },
        gatewayFactory: (scope) =>
            (scope.profileName == 'b' ? other : primary).gateway(scope),
      );
      addTearDown(owner.dispose);
      final restored = await prepareNotificationFixtureChats(
        owner,
        restarting: true,
      );
      for (final (chat, host) in [
        (restored.chat, primary),
        (restored.other, other),
      ]) {
        chat.composer.editText('Produce a new reply after restart');
        await owner.send(chat);
        expect(
          host.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
      }
      primary.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: restored.chat.runtime.runtimeId,
          data: {'text': 'A new completed reply'},
        ),
      );
      final notice = await noticeReady.future.timeout(
        const Duration(seconds: 1),
      );
      expect(notices, hasLength(1));
      expect(notice.key, restored.chat.key);
      expect(owner.current!.scope.profileName, 'b');
      expect(owner.current!.offlineSnapshot, isFalse);
    },
  );

  testWidgets('Bot Chat navigation and human send start Android monitoring', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final harness = await _harness(
      indexedSessions: [
        {
          'id': 'same',
          'title': 'Bot Chat',
          'source': 'desktop',
          'hidden': true,
          'profile': 'a',
        },
      ],
    );
    harness.host.running = false;
    await harness.manager.prefs.setBool(
      'microphone_permission_requested',
      true,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    messenger.setMockMethodCallHandler(
      plugin,
      (call) async => switch (call.method) {
        'initialize' => true,
        'getNotificationAppLaunchDetails' => {'notificationLaunchedApp': false},
        'areNotificationsEnabled' => true,
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      _nativeNotifications,
      (call) async => call.method == 'initialize' ? [] : null,
    );
    final monitoring = <MethodCall>[];
    messenger.setMockMethodCallHandler(BackgroundMonitoringService.channel, (
      call,
    ) async {
      monitoring.add(call);
      return switch (call.method) {
        'start' => {'running': true, 'batteryUnrestricted': true},
        'batteryUnrestricted' => true,
        _ => null,
      };
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(plugin, null);
      messenger.setMockMethodCallHandler(_nativeNotifications, null);
      messenger.setMockMethodCallHandler(
        BackgroundMonitoringService.channel,
        null,
      );
    });
    await _pumpApp(tester, harness);
    final home = tester.state<HomeScreenState>(find.byType(HomeScreen));
    await home.selectBotChat(
      ProfileSessionKey(harness.controller.current!.scope, 'same'),
      () => true,
    );
    await _pumpNavigation(tester);
    final chat = harness.controller.current!.chat!;
    expect(chat.title, 'Bot Chat');
    expect(harness.registry.hasActiveChats, isFalse);
    monitoring.clear();
    chat.composer.editText('Please investigate this task');
    await harness.controller.send(chat);
    await _pumpNavigation(tester);
    expect(harness.registry.hasActiveChats, isTrue);
    expect(monitoring.where((call) => call.method == 'start'), isNotEmpty);
    expect(monitoring.last.arguments['text'], 'a · working');
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpNavigation(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final scenario in [
    (serverRecovers: true, opening: false, held: false),
    (serverRecovers: false, opening: false, held: false),
    (serverRecovers: true, opening: true, held: false),
    (serverRecovers: false, opening: true, held: false),
    (serverRecovers: true, opening: true, held: true),
  ]) {
    final serverRecovers = scenario.serverRecovers;
    testWidgets(
      'app foreground recovers beneath global alert settings: serverRecovers=$serverRecovers, opening=${scenario.opening}, held=${scenario.held}',
      (tester) async {
        final harness = await _harness(customAdministration: true);
        harness.host.running = false;
        final resources = HostResourcesFixture(identity: harness.identity);
        final repository = AdministrationRepository(
          connectionId: harness.connection.id,
          connectionIdentity: harness.identity,
          connectionLabel: harness.connection.label,
          request: resources.server.request,
          settingsWrite: resources.server.settingsWrite,
          ownedMutation: resources.server.ownedMutation,
          gateway: (name) => harness.host.gateway(
            WorkspaceScope(
              connectionId: harness.connection.id,
              connectionIdentity: harness.identity,
              profileName: name,
            ),
          ),
        );
        harness.controller.hostResources(repository: repository);
        addTearDown(resources.server.close);
        final app = await _pumpApp(tester, harness);
        if (scenario.opening) {
          harness.host.connectError = const SocketException(
            'Android APP_BACKGROUND',
          );
        }
        await app.currentState!.openProfileNotification(_payload(harness, 'a'));
        await _pumpNavigation(tester);
        final chat =
            harness.controller.notificationChat ??
            harness.controller.current!.chat!;
        await harness.controller.updateDraft(chat, 'Keep the unsent follow-up');
        final context = tester.element(find.byType(ProfileWorkspaceScreen));
        final alerts = HealthAlertsScope.maybeOf(context)!.alerts;
        await alerts.settings.update(
          (policy) => policy.copyWith(profile: false),
        );
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  HealthAlertSettingsScreen(session: alerts.settings),
            ),
          ),
        );
        await _pumpNavigation(tester);
        expect(find.byType(HealthAlertSettingsScreen), findsOneWidget);
        final healthyDisconnects = harness.host.disconnectCalls;
        if (!scenario.opening) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
          expect(harness.host.disconnectCalls, healthyDisconnects);
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        harness.host.connectError = const SocketException(
          'Android APP_BACKGROUND',
        );
        if (!scenario.opening) {
          harness.host.gateways['a']!.onConnectionChanged!(false);
        }
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        for (final seconds in [1, 2, 4, 8, 16]) {
          if (scenario.held && seconds == 16) harness.host.connectDelay = gate;
          await tester.pump(Duration(seconds: seconds));
        }
        expect(
          harness.controller.connectionStatus.phase,
          ServerConnectionPhase.reconnecting,
        );
        expect(
          harness.controller.connectionStatus.recoveryAttemptInProgress,
          scenario.held,
        );
        expect(alerts.alerts, hasLength(scenario.opening ? 1 : 0));
        final attempts = harness.host.connectCalls;
        harness.host.connectDelay = gate;
        if (serverRecovers) harness.host.connectError = null;
        if (scenario.held) harness.host.connectFailures = 1;
        final occurrences = <(String, int)>{};
        void observe() {
          expectSync(alerts.alerts.length, lessThanOrEqualTo(1));
          for (final alert in alerts.alerts) {
            expectSync(alert.scope, HealthAlertScope.connection);
            expectSync(alert.connectionIdentity, harness.identity);
            occurrences.add((alert.id, alert.occurrence));
          }
        }

        observe();
        alerts.addListener(observe);
        addTearDown(() => alerts.removeListener(observe));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(alerts.alerts, hasLength(1));
        final interrupted = alerts.alerts.single;
        expect(occurrences, {(interrupted.id, interrupted.occurrence)});
        expect(harness.host.connectCalls, attempts + (scenario.held ? 0 : 1));
        expect(
          harness.controller.connectionStatus.phase,
          ServerConnectionPhase.reconnecting,
        );
        final joinedRecovery = scenario.held
            ? harness.controller.resumeConnection()
            : null;
        gate.complete();
        await tester.pump();
        for (
          var i = 0;
          i < 100 &&
              serverRecovers &&
              (harness.controller.recovering ||
                  harness.controller.notificationChat != null);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        if (serverRecovers) {
          if (joinedRecovery != null) await joinedRecovery;
          if (scenario.held) expect(harness.host.connectCalls, attempts + 1);
          expect(occurrences, {(interrupted.id, interrupted.occurrence)});
          expect(harness.controller.notificationChat, isNull);
          expect(harness.controller.recovering, isFalse);
          expect(
            harness.controller.connectionStatus.liveAvailable('a'),
            isTrue,
          );
          expect(alerts.alerts, isEmpty);
        } else {
          for (final seconds in [1, 2, 4, 8, 16, 30, 30]) {
            await tester.pump(Duration(seconds: seconds));
          }
          expect(
            harness.controller.connectionStatus.phase,
            ServerConnectionPhase.reconnecting,
          );
          expect(
            harness.controller.connectionStatus.recoveryAttemptInProgress,
            isFalse,
          );
          expect(occurrences, {(interrupted.id, interrupted.occurrence)});
          expect(alerts.alerts, hasLength(1));
          expect(alerts.alerts.single.occurrence, interrupted.occurrence);
        }
        expect(chat.composer.observation.text, 'Keep the unsent follow-up');
        expect(
          harness.host.calls.where((call) => call.$2 == 'prompt.submit'),
          isEmpty,
        );
        expect(find.byType(HealthAlertSettingsScreen), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'retired opening recovery cannot clear its replacement admission',
    () async {
      final harness = await _harness();
      harness.host.running = false;
      final firstGate = Completer<void>();
      final replacementGate = Completer<void>();
      addTearDown(() {
        if (!firstGate.isCompleted) firstGate.complete();
        if (!replacementGate.isCompleted) replacementGate.complete();
      });
      ProfileSessionKey target(String profile) => ProfileSessionKey(
        WorkspaceScope(
          connectionId: harness.connection.id,
          connectionIdentity: harness.identity,
          profileName: profile,
        ),
        'same',
      );
      final initialCalls = harness.host.connectCalls;
      harness.host.connectDelay = firstGate;
      final firstOpening = harness.controller.openNotification(target('a'));
      for (
        var i = 0;
        i < 100 && harness.host.connectCalls == initialCalls;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(harness.host.connectCalls, initialCalls + 1);
      final firstResume = harness.controller.resumeConnection();
      harness.controller.cancelNotificationOpen();
      harness.host.connectDelay = replacementGate;
      final replacementOpening = harness.controller.openNotification(
        target('b'),
      );
      final replacementResume = harness.controller.resumeConnection();
      for (
        var i = 0;
        i < 100 && harness.host.connectCalls < initialCalls + 2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(harness.host.connectCalls, initialCalls + 2);
      firstGate.complete();
      await Future.wait([firstOpening, firstResume]);
      expect(harness.controller.notificationChat!.key, target('b'));
      expect(
        harness.controller.connectionStatus.phase,
        ServerConnectionPhase.reconnecting,
      );
      replacementGate.complete();
      await Future.wait([replacementOpening, replacementResume]);
      expect(harness.controller.notificationChat, isNull);
      expect(harness.controller.current!.scope.profileName, 'b');
      expect(harness.controller.connectionStatus.liveAvailable('b'), isTrue);
    },
  );

  for (final scenario in [
    'once',
    'cached-once',
    'session',
    'deny',
    'deny-hidden',
    'always',
    'changed',
    'expired',
  ]) {
    testWidgets(
      'cold notification action $scenario checks the current request',
      (tester) async {
        final harness = await _harness(
          restoreCachedChat: scenario == 'cached-once',
        );
        harness.host.running = false;
        ProfileChat? cachedChat;
        if (scenario == 'cached-once') {
          cachedChat = harness.controller.browserResource('a').chats['same']!;
          await harness.controller.updateDraft(cachedChat, 'Unsent follow-up');
        }
        final request = <String, dynamic>{
          'request_id': 'cold-approval',
          'command': scenario == 'changed' ? 'echo changed' : 'echo ready',
          'choices': ['once', 'session', 'always', 'deny'],
        };
        harness.host.pendingApprovals = scenario == 'expired' ? [] : [request];
        final prefs = harness.manager.prefs;
        await prefs.setBool('notification_permission_requested', true);
        await prefs.setBool('microphone_permission_requested', true);
        if (scenario == 'deny-hidden') {
          await harness.appPreferences.setNotificationPreviews(false);
        }
        final choice = {'changed', 'expired', 'cached-once'}.contains(scenario)
            ? 'once'
            : scenario == 'deny-hidden'
            ? 'deny'
            : scenario;
        final payload = jsonEncode({
          ...jsonDecode(_payload(harness, 'a')) as Map<String, dynamic>,
          'focus': {'kind': 'approval', 'id': 'cold-approval'},
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const plugin = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        messenger.setMockMethodCallHandler(
          plugin,
          (call) async => switch (call.method) {
            'initialize' => true,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': false,
            },
            'areNotificationsEnabled' => true,
            _ => null,
          },
        );
        final finished = <dynamic>[];
        final statuses = <dynamic>[];
        messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
          if (call.method == 'finishDirectAction') finished.add(call.arguments);
          if (call.method == 'actionStatus') statuses.add(call.arguments);
          return call.method == 'initialize'
              ? [
                  {
                    'payload': payload,
                    'choice': choice,
                    'review': false,
                    'command': 'echo ready',
                    'notification_id': 42,
                  },
                ]
              : null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(plugin, null);
          messenger.setMockMethodCallHandler(_nativeNotifications, null);
        });
        await _pumpApp(tester, harness);
        await tester.pumpAndSettle();
        final decisions = harness.host.calls
            .where((c) => c.$2 == 'approval.respond')
            .toList();
        if (scenario == 'always' || scenario == 'changed') {
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text(request['command'] as String), findsOneWidget);
          expect(decisions, isEmpty);
          expect(finished, isEmpty);
          await tester.tap(find.byTooltip('Cancel approval decision'));
          await tester.pumpAndSettle();
        } else {
          expect(find.byType(AlertDialog), findsNothing);
          if (scenario == 'expired') {
            expect(decisions, isEmpty);
            expect(statuses, ['This approval is no longer pending.']);
          } else {
            expect(decisions, hasLength(1));
            expect(decisions.single.$3['prompt_id'], 'cold-approval');
            expect(decisions.single.$3['choice'], choice);
          }
        }
        expect(finished, [42]);
        expect(find.byType(ProfileWorkspaceScreen), findsNothing);
        expect(harness.controller.current?.chat, isNull);
        if (cachedChat != null) {
          expect(
            harness.controller.findNotificationChat(cachedChat.key),
            same(cachedChat),
          );
        }
        if (cachedChat != null) {
          expect(cachedChat.runtime.offline, isFalse);
          expect(cachedChat.runtime.runtimeId, 'a-runtime');
          expect(cachedChat.composer.observation.text, 'Unsent follow-up');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final state in [
    'unread',
    'native-dismissed',
    'removed connection',
    'changed credentials',
  ]) {
    testWidgets(
      'cold app launch handles $state notice without opening its chat',
      (tester) async {
        final harness = await _harness();
        final previous = RecordingTurnNotificationSink();
        final notices = ChatNotificationCoordinator(
          harness.manager.prefs,
          previous,
          appPreferences: harness.appPreferences,
        );
        await notices.result(
          chat: _payload(harness, 'a'),
          title: 'Result',
          scope: 'Home / a',
          focus: const NotificationFocus('answer', 'unread'),
          content: ChatNotificationContent.reply('Unread result'),
        );
        if (state == 'removed connection') {
          await harness.manager.deleteConnection(harness.connection.id);
        }
        if (state == 'changed credentials') {
          await harness.manager.updateConnection(
            harness.connection.id,
            harness.connection.label,
            Uri(
              scheme: harness.connection.useHttps ? 'https' : 'http',
              host: harness.connection.host,
            ).toString(),
            harness.connection.port,
            'changed-test-key',
            icon: harness.connection.icon,
            gatewayPrefix: harness.connection.gatewayPrefix,
            dashboardPrefix: harness.connection.dashboardPrefix,
            dashboardProxied: harness.connection.dashboardProxied,
            desktopGatewayUrl: harness.connection.desktopGatewayUrl,
            dashboardPort: harness.connection.dashboardPortOverride,
            dashboardUsername: harness.connection.dashboardUsername,
            dashboardPassword: harness.connection.dashboardPassword,
            cloudInstanceId: harness.connection.cloudInstanceId,
            cloudOrganization: harness.connection.cloudOrganization,
            dashboardGrant: harness.connection.dashboardGrant,
            gatewayHeaders: harness.connection.gatewayHeaders,
          );
        }
        final posted = <Map<dynamic, dynamic>>[];
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const plugin = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        messenger.setMockMethodCallHandler(
          plugin,
          (call) async => switch (call.method) {
            'initialize' => true,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': false,
            },
            'areNotificationsEnabled' => true,
            _ => null,
          },
        );
        messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
          if (call.method == 'show') posted.add(call.arguments as Map);
          return call.method == 'initialize'
              ? [
                  if (state == 'native-dismissed')
                    {
                      'dismiss': true,
                      'chat': _payload(harness, 'a'),
                      'revision': previous.shown.single.revision,
                      'interaction_id': 'queued-dismissal',
                    },
                ]
              : null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(plugin, null);
          messenger.setMockMethodCallHandler(_nativeNotifications, null);
        });
        await _pumpApp(tester, harness);
        await tester.pumpAndSettle();
        if (state == 'unread') {
          expect(posted, hasLength(1));
          expect(posted.single['body'], 'Unread result');
          expect(posted.single['alert'], isFalse);
          expect(posted.single['id'], previous.shown.single.id);
          expect(posted.single['revision'], previous.shown.single.revision);
        } else {
          expect(posted, isEmpty);
        }
        expect(harness.controller.current?.chat, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('notification taps open the named chat within the same profile', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final first = _payload(harness, 'a');
    final second = _payload(harness, 'a', session: 'second');

    await app.currentState!.openProfileNotification(first);
    await _pumpNavigation(tester);
    expect(harness.controller.current!.chat!.key.sessionId, 'same');

    await app.currentState!.openProfileNotification(second);
    await _pumpNavigation(tester);
    expect(harness.controller.current!.chat!.key.sessionId, 'second');
    expect(find.text('Chat'), findsOneWidget);

    await app.currentState!.openProfileNotification(first);
    await _pumpNavigation(tester);
    expect(harness.controller.current!.chat!.key.sessionId, 'same');
    expect(find.text('a chat'), findsOneWidget);
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets('notification tap leaves administration and shows its chat', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);

    await app.currentState!.openProfileNotification(_payload(harness, 'a'));
    await _pumpNavigation(tester);
    await tester.tap(find.byTooltip('Open navigation menu').hitTestable().last);
    await _pumpNavigation(tester);
    await tester.tap(find.byKey(const ValueKey('nav-administration')));
    await _pumpNavigation(tester);
    expect(find.byType(HermesAdministrationContent), findsOneWidget);

    await app.currentState!.openProfileNotification(
      _payload(harness, 'a', session: 'second'),
    );
    await _pumpNavigation(tester);

    expect(harness.controller.current!.chat!.key.sessionId, 'second');
    expect(find.byType(HermesAdministrationContent), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets('notification opens above a guarded administration editor', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    await app.currentState!.openProfileNotification(_payload(harness, 'a'));
    await _pumpNavigation(tester);

    final workspaceContext = tester.element(
      find.byType(ProfileWorkspaceScreen).last,
    );
    final workspaceRoute = ModalRoute.of(workspaceContext)!;
    final navigator = Navigator.of(workspaceContext);
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => const PopScope(
          canPop: false,
          child: Scaffold(body: Text('Unsaved administration editor')),
        ),
      ),
    );
    await _pumpNavigation(tester);
    expect(find.text('Unsaved administration editor'), findsOneWidget);
    expect(workspaceRoute.isCurrent, isFalse);

    await app.currentState!.openProfileNotification(
      _payload(harness, 'a', session: 'second'),
    );
    await _pumpNavigation(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(harness.controller.current!.chat!.key.sessionId, 'second');
    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(find.text('Unsaved administration editor'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);

    final chatRoute = ModalRoute.of(
      tester.element(find.byType(ProfileWorkspaceScreen).last),
    )!;
    navigator.removeRoute(chatRoute);
    await _pumpNavigation(tester);
    expect(find.text('Unsaved administration editor'), findsOneWidget);
  });

  testWidgets(
    'concurrent and later taps refresh once without duplicate routes',
    (tester) async {
      final harness = await _harness();
      final app = await _pumpApp(tester, harness);
      final payload = _payload(harness, 'a');
      final history = Completer<void>();
      harness.host.delays['a'] = history;

      final first = app.currentState!.openProfileNotification(payload);
      final duplicate = app.currentState!.openProfileNotification(payload);
      await tester.pump();
      // Saved history is read before attaching the one coalesced target.
      expect(_resumeCount(harness, 'a'), 0);
      history.complete();
      await Future.wait([first, duplicate]);
      await _pumpNavigation(tester);

      expect(_resumeCount(harness, 'a'), 1);
      await app.currentState!.openProfileNotification(payload);
      await _pumpNavigation(tester);
      expect(_resumeCount(harness, 'a'), 2);
      await _expectRemovingWorkspaceReturnsHome(tester);

      await app.currentState!.openProfileNotification(payload);
      await _pumpNavigation(tester);
      expect(_resumeCount(harness, 'a'), 3);
      await _expectRemovingWorkspaceReturnsHome(tester);
    },
  );

  testWidgets('notification opens its destination during a network outage', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final payload = _payload(harness, 'a');
    harness.host.resumeFailures = 1;

    await app.currentState!.openProfileNotification(payload);
    await _pumpNavigation(tester);
    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(
      find.text('This chat is unavailable on its original host or profile.'),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 1));
    await _pumpNavigation(tester);
    expect(_resumeCount(harness, 'a'), 2);
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets(
    'a cold notification tap defers camera intake until explicitly opened',
    (tester) async {
      const channel = MethodChannel(AndroidShareIntentService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final harness = await _harness();
      final shares = AndroidShareIntentService();
      addTearDown(shares.dispose);
      final pending = AndroidSharePayload(
        id: 'recovered-camera',
        text: 'Keep this camera intake',
        target: ProfileSessionKey(
          WorkspaceScope(
            connectionId: harness.connection.id,
            connectionIdentity: harness.identity,
            profileName: 'b',
          ),
          'expired-camera-chat',
        ).toJson(),
      );
      shares.pendingShare.value = pending;
      final shareLoad = Completer<void>();
      final notificationHistory = Completer<void>();
      final startupReady = Completer<void>();
      harness.host.delays['b'] = shareLoad;
      harness.host.delays['a'] = notificationHistory;

      final app = await _pumpApp(
        tester,
        harness,
        shareIntents: shares,
        startupExternalNavigationReady: startupReady.future,
      );
      final opening = app.currentState!.openProfileNotification(
        _payload(harness, 'a'),
      );
      await tester.pump();
      startupReady.complete();
      await tester.pump();
      shareLoad.complete();
      await tester.pump();
      notificationHistory.complete();
      await opening;
      await _pumpNavigation(tester);

      expect(harness.controller.current!.scope.profileName, 'a');
      expect(harness.controller.current!.chat!.key.sessionId, 'same');
      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      expect(find.text('Add shared content'), findsNothing);
      expect(shares.pendingShare.value, same(pending));
      expect(
        find.text('This chat is unavailable on its original host or profile.'),
        findsNothing,
      );

      await _expectRemovingWorkspaceReturnsHome(tester);
      await tester.tap(find.text('Review'));
      await _pumpNavigation(tester);
      expect(find.text('Add shared content'), findsNothing);
      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      expect(harness.controller.current!.scope.profileName, 'b');
      expect(
        harness.controller.current!.chat!.key.sessionId,
        'expired-camera-chat',
      );
      expect(
        harness.controller.current!.chat!.composer.observation.text,
        pending.text,
      );
      expect(shares.pendingShare.value, isNull);
    },
  );

  testWidgets('one controller route is reused across profiles', (tester) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);

    await app.currentState!.openProfileNotification(_payload(harness, 'a'));
    await _pumpNavigation(tester);
    await app.currentState!.openProfileNotification(_payload(harness, 'b'));
    await _pumpNavigation(tester);

    expect(harness.controller.current!.scope.profileName, 'b');
    expect(_resumeCount(harness, 'a'), 1);
    expect(_resumeCount(harness, 'b'), 1);
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets('a stale connection identity cannot reach the gateway', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final payload = jsonEncode(
      ProfileSessionKey(
        WorkspaceScope(
          connectionId: harness.connection.id,
          connectionIdentity: 'stale-owner',
          profileName: 'a',
        ),
        'same',
      ).toJson(),
    );

    await app.currentState!.openProfileNotification(payload);
    await tester.pump();

    expect(_resumeCount(harness, 'a'), 0);
    expect(find.byType(ProfileWorkspaceScreen), findsNothing);
    expect(
      find.text('This chat is unavailable on its original host or profile.'),
      findsOneWidget,
    );
  });

  testWidgets('a malformed newer tap cannot keep an older target coalescible', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final payload = _payload(harness, 'a');
    final history = Completer<void>();
    harness.host.delays['a'] = history;

    final first = app.currentState!.openProfileNotification(payload);
    await tester.pump();
    await app.currentState!.openProfileNotification('{invalid');
    final retry = app.currentState!.openProfileNotification(payload);
    await tester.pump();
    // Neither request may attach before its saved-history read completes.
    expect(_resumeCount(harness, 'a'), 0);

    history.complete();
    await Future.wait([first, retry]);
    await _pumpNavigation(tester);
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets('a newer target wins when an older target finishes last', (
    tester,
  ) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final history = Completer<void>();
    harness.host.delays['a'] = history;

    final a = app.currentState!.openProfileNotification(_payload(harness, 'a'));
    await tester.pump();
    await app.currentState!.openProfileNotification(_payload(harness, 'b'));
    await _pumpNavigation(tester);
    history.complete();
    await a;
    await _pumpNavigation(tester);

    expect(harness.controller.current!.scope.profileName, 'b');
    expect(
      find.text('This chat is unavailable on its original host or profile.'),
      findsNothing,
    );
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets('A-B-A makes the final A tap authoritative', (tester) async {
    final harness = await _harness();
    final app = await _pumpApp(tester, harness);
    final history = Completer<void>();
    harness.host.delays['a'] = history;

    final firstA = app.currentState!.openProfileNotification(
      _payload(harness, 'a'),
    );
    await tester.pump();
    await app.currentState!.openProfileNotification(_payload(harness, 'b'));
    await _pumpNavigation(tester);
    final finalA = app.currentState!.openProfileNotification(
      _payload(harness, 'a'),
    );
    await tester.pump();
    history.complete();
    await Future.wait([firstA, finalA]);
    await _pumpNavigation(tester);

    // The retired first A never reaches attachment after its held read.
    expect(_resumeCount(harness, 'a'), 1);
    expect(harness.controller.current!.scope.profileName, 'a');
    expect(
      find.text('This chat is unavailable on its original host or profile.'),
      findsNothing,
    );
    await _expectRemovingWorkspaceReturnsHome(tester);
  });

  testWidgets('slow cold initialization cannot reopen an obsolete target', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final secrets = MemoryIdentityStore();
    final manager = await ConnectionManager.create(
      preferences,
      credentialStore: secrets,
    );
    final firstConnection = identityTestConnection();
    final secondConnection = SavedConnection(
      id: 'second-id',
      label: 'Second host',
      host: 'second-host',
      port: 4321,
      dashboardPortOverride: 4321,
      apiKey: 'second-key',
    );
    await manager.importConnections(
      [firstConnection, secondConnection],
      replaceExisting: false,
      canCommit: () => true,
    );
    final saved = await manager.loadConnectionsWithSecrets();
    final first = saved.singleWhere((item) => item.id == firstConnection.id);
    final second = saved.singleWhere((item) => item.id == secondConnection.id);
    final identities = ProfileConnectionIdentity(credentialStore: secrets);
    final firstIdentity = await identities.resolve(first);
    final secondIdentity = await identities.resolve(second);
    final firstHost = Host();
    final secondHost = Host();
    final registry = ProfileWorkspaceRegistry(
      identities: identities,
      create: (connection, identity) => ProfileWorkspaceController(
        access: manager.accessFor(connection),
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: connection.id == first.id
            ? firstHost.gateway
            : secondHost.gateway,
      ),
    );
    addTearDown(registry.dispose);
    final secondController = await registry.forConnection(second);
    await secondController.initialize();
    final firstHistory = Completer<void>();
    firstHost.delays['a'] = firstHistory;
    final app = await _pumpApp(tester, (
      manager: manager,
      appPreferences: appPreferences,
      connection: first,
      identity: firstIdentity,
      host: firstHost,
      controller: await registry.forConnection(first),
      registry: registry,
    ));
    String payload(SavedConnection connection, String identity) => jsonEncode(
      ProfileSessionKey(
        WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: identity,
          profileName: 'a',
        ),
        'same',
      ).toJson(),
    );

    final obsolete = app.currentState!.openProfileNotification(
      payload(first, firstIdentity),
    );
    await tester.pump();
    await app.currentState!.openProfileNotification(
      payload(second, secondIdentity),
    );
    await _pumpNavigation(tester);
    firstHistory.complete();
    await obsolete;
    await _pumpNavigation(tester);

    expect(
      firstHost.calls.where((call) => call.$2 == 'session.resume'),
      isEmpty,
    );
    expect(
      secondController.current!.chat!.key.workspace.connectionId,
      second.id,
    );
    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    await _expectRemovingWorkspaceReturnsHome(tester);
  });
}
