import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_gestures.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_preview.dart';
import 'package:wing/core/widgets/recent_conversations/recent_conversation_switcher.dart';
import 'package:wing/core/widgets/source_code_block.dart';

import '../test/support/profile_browser_fixture.dart';
import '../test/support/bots_fixture.dart';
import '../test/support/recording_turn_notification_sink.dart';

Future<HttpServer> _drawerDashboard() async {
  // DrawerVersions owns its own production HTTP adapter, independently of
  // the injected chat/Bots repositories. Keep those reads on this owned
  // loopback endpoint, with unexpected transport requests failing the test.
  final unexpectedReads = <String>[];
  final dashboard = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  dashboard.listen((request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final scopedRead =
        query['profile'] == 'default' &&
        (path == '/api/hermes/update/check'
            ? query.length == 2 && query['force'] == 'true'
            : query.length == 1);
    if (request.method != 'GET' ||
        (path == '/' ? query.isNotEmpty : !scopedRead)) {
      unexpectedReads.add('${request.method} ${request.uri}');
      request.response.statusCode = HttpStatus.badRequest;
    } else if (path == '/' && query.isEmpty) {
      request.response.write(
        'window.__HERMES_SESSION_TOKEN__="native-recents-fixture";',
      );
    } else if (request.headers.value('X-Hermes-Session-Token') !=
        'native-recents-fixture') {
      unexpectedReads.add('Unauthenticated ${request.uri}');
      request.response.statusCode = HttpStatus.unauthorized;
    } else {
      final body = switch (path) {
        '/api/health' => {'ok': true, 'version': '1.2.3'},
        '/api/profiles' => {
          'profiles': [
            {'name': 'default', 'is_default': true},
          ],
        },
        '/api/hermes/update/check' => {
          'current_version': '1.2.3',
          'update_available': false,
          'can_apply': false,
        },
        _ => null,
      };
      if (body == null) {
        unexpectedReads.add('${request.method} ${request.uri}');
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
      }
    }
    await request.response.close();
  });
  addTearDown(() async {
    await dashboard.close(force: true);
    expect(unexpectedReads, isEmpty);
  });
  return dashboard;
}

class _NativeEventChats extends ProfileBrowserFixture {
  final groups = BotsFixture();
  final messages = <(String, String), List<Map<String, dynamic>>>{};
  final watermarks = <(String, String), double>{};
  final patched = <ProfileSessionKey>[];
  int sequence = 0;
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    if (profile == 'personal')
      {
        'id': 'anchor',
        'title': 'My open conversation',
        'profile': profile,
        'last_active': now - 100,
        'last_read_at': now - 10,
        'unread': false,
      },
    {
      'id': 'recipient',
      'title': profile == 'work' ? 'Bot Chat' : 'Ordinary recipient',
      'profile': profile,
      'source': profile == 'work' ? 'desktop' : 'wing',
      'last_active': now - 200,
      'last_read_at': watermarks[(profile, 'recipient')] ?? now - 10,
      'unread':
          messages.containsKey((profile, 'recipient')) &&
          (watermarks[(profile, 'recipient')] ?? now - 10) <
              (messages[(profile, 'recipient')]!.last['timestamp'] as num),
    },
  ];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      messages[(profile, id)] ??
      [
        if (profile != 'personal' || id != 'recipient')
          {
            'id': 1,
            'role': 'assistant',
            'timestamp': now - (id == 'anchor' ? 100 : 200),
            'content':
                'Earlier saved reply. Keep my draft and reading position.',
          },
      ];
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    final gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) => method.startsWith('groups.')
          ? groups.read(scope.profileName, method, params)
          : base.call(method, params),
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        final id = path.startsWith('sessions/')
            ? Uri.decodeComponent(path.substring('sessions/'.length))
            : null;
        if (id == null ||
            !sessions(scope.profileName).any((row) => row['id'] == id) ||
            body.length != 5 ||
            body['request_id'] is! String ||
            (body['request_id'] as String).isEmpty ||
            body['expected_revision'] != 0 ||
            body['expected_generation'] != 0 ||
            body['profile'] != scope.profileName ||
            body['unread'] != false ||
            !canDispatch()) {
          throw StateError('Unexpected read acknowledgement: $path');
        }
        onDispatched();
        watermarks[(
          scope.profileName,
          id,
        )] = (historyRows(scope.profileName, id).last['timestamp'] as num)
            .toDouble();
        patched.add(ProfileSessionKey(scope, id));
        return {'ok': true};
      },
    );
    return gateway;
  }

  void reply(ProfileChat chat, String text, ProfileGateway gateway) {
    final key = chat.key;
    messages[(key.workspace.profileName, key.sessionId)] = [
      ...historyRows(key.workspace.profileName, key.sessionId),
      {
        'id': ++sequence + 1,
        'role': 'assistant',
        'content': text,
        'timestamp': now + sequence,
      },
    ];
    final turnId = 'native-turn-$sequence';
    gateway.onEvent!(
      StreamEvent(
        type: 'message.start',
        sessionId: chat.runtime.runtimeId,
        data: {'turn_id': turnId},
      ),
    );
    gateway.onEvent!(
      StreamEvent(
        type: 'message.delta',
        sessionId: chat.runtime.runtimeId,
        data: {'text': text, 'turn_id': turnId, 'segment': 0, 'offset': 0},
      ),
    );
    gateway.onEvent!(
      StreamEvent(
        type: 'message.complete',
        sessionId: chat.runtime.runtimeId,
        data: {'text': text, 'mobile_push_event_id': 'native-answer-$sequence'},
      ),
    );
  }

  void groupReply(int sequence) => groups.events.add({
    'room_id': 'room-1',
    'seq': sequence,
    'kind': 'message.member',
    'created_at': now + sequence,
    'actor': {'kind': 'member', 'id': 'atlas'},
    'payload': {'text': 'Incoming group answer $sequence'},
  });
}

Future<void> _readNewest(
  WidgetTester tester,
  String checkpoint, {
  bool Function()? acknowledged,
}) async {
  final latest = find.byKey(const ValueKey('jump-to-latest'));
  // Reveal an unseen tail through its actual control. An already visible
  // answer needs no further gesture to acknowledge it.
  await _native(
    tester,
    checkpoint,
    actions: [if (latest.evaluate().isNotEmpty) _tap(tester, latest)],
  );
  if (acknowledged != null) await _until(tester, acknowledged);
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? details,
}) async {
  for (var tick = 0; tick < 150 && !ready(); tick++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    ready(),
    isTrue,
    reason:
        'An incoming publication must not wait for the 30-second Recents timer${ready() ? '' : ' ${details?.call() ?? ''}'}',
  );
  await tester.pump();
}

Future<void> _incomingJourney(
  WidgetTester tester,
  Brightness brightness,
  bool large,
) async {
  final prefix = 'events-${brightness.name}-${large ? 'large' : 'normal'}';
  await _native(
    tester,
    '$prefix-configure',
    actions: [
      {'type': 'configure', 'large': large},
    ],
    capture: false,
  );
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final preferences = AppPreferences(prefs);
  final host = _NativeEventChats()
    ..botMetadata['work'] = {'title': 'Event bot'};
  host.groups.room['members'] = [
    {
      'member_id': 'atlas',
      'profile': 'personal',
      'handle': 'bot_personal',
      'display_name': 'Personal',
    },
    {
      'member_id': 'mira',
      'profile': 'work',
      'handle': 'bot_work',
      'display_name': 'Event bot',
    },
  ];
  final notices = ChatNotificationCoordinator(
    prefs,
    RecordingTurnNotificationSink()..permissionResult = false,
    appPreferences: preferences,
  );
  final dashboard = await _drawerDashboard();
  final controller = ProfileWorkspaceController(
    access: ConnectionAccess(
      connection: SavedConnection(
        id: 'native-events',
        label: 'Recents QA',
        host: InternetAddress.loopbackIPv4.address,
        port: 1,
        dashboardPortOverride: dashboard.port,
        apiKey: '',
      ),
      dashboardOAuth: null,
    ),
    connectionIdentity: 'native-events',
    preferences: prefs,
    appPreferences: preferences,
    gatewayFactory: host.gateway,
    onAttention: (notice) => notices.result(
      chat: jsonEncode(notice.key.toJson()),
      title: notice.title,
      scope: notice.connectionLabel,
      focus: notice.focus!,
      content: notice.content,
      alert: notice.alert,
    ),
    onGroupAnswer: notices.receiveGroupAnswer,
    onGroupAnswerRead: notices.readGroupAnswer,
    onNotificationRead: notices.readTarget,
    notificationResultFor: notices.focusFor,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    preferences.dispose();
  });
  await controller.initialize();
  final personal = controller.current!.scope;
  final ordinary = (await controller.openSession(
    ProfileSessionKey(personal, 'recipient'),
  ))!;
  final ordinaryGateway = controller.current!.gateway;
  final work = WorkspaceScope(
    connectionId: personal.connectionId,
    connectionIdentity: personal.connectionIdentity,
    profileName: 'work',
  );
  final bot = (await controller.openSession(
    ProfileSessionKey(work, 'recipient'),
  ))!;
  final botGateway = controller.current!.gateway;
  await controller.switchProfile('personal');
  controller.showList();
  // The explicit setup opens may acknowledge an unlisted profile's saved chat.
  // The assertions below count receipts only after Recents becomes visible.
  final setupReadReceipts = host.patched.length;
  host.patched.clear();
  final scope = controller.groupObservations.scope;
  final metadataGateway = host.gateway(scope);
  addTearDown(metadataGateway.close);
  ProfileGateway gatewayFor(String profile) => profile == 'default'
      ? metadataGateway
      : controller.browserResource(profile).gateway;
  final repository = BotsRepository(
    scope: scope,
    instance: 'Recents QA',
    groupObservations: controller.groupObservations,
    read: (profile, method, params) => gatewayFor(profile).call(method, params),
    command: (profile, method, params, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Retired fixture');
      onDispatched();
      return gatewayFor(profile).call(method, params);
    },
    ownership: (profile, ids) async => ids
        .where((id) => host.sessions(profile).any((row) => row['id'] == id))
        .toSet(),
  );
  host.groupReply(1);
  final bots = BotsSession((_) async => [repository]);
  await bots.refresh();
  await controller.activateGroupNotifications();
  await bots.groupReads.acknowledge(bots.observedGroups.single, 1);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: wingTheme(brightness),
      builder: (context, child) =>
          ChatNoticeActivityScope(activity: notices.activity, child: child!),
      home: ProfileWorkspaceScreen(
        controller: controller,
        createBotsSession: () => bots,
        initialDestination: AppDestination.activity,
      ),
    ),
  );
  await _until(
    tester,
    () => find.byType(WorkspaceActivityContent).evaluate().isNotEmpty,
  );
  final recents = tester
      .widget<WorkspaceActivityContent>(find.byType(WorkspaceActivityContent))
      .recents;
  await recents.refresh();
  await tester.pumpAndSettle();
  final group = bots.observedGroups.single;
  expect(recents.items().every((item) => !item.unread), isTrue);
  expect(
    recents.items().singleWhere((item) => item.chat?.key == bot.key).bot?.title,
    'Event bot',
  );
  final ordinaryCard = find.byKey(
    const ValueKey('activity-personal-recipient'),
  );
  expect(
    ordinaryCard,
    findsNothing,
    reason:
        'The empty conversation stays outside Recents until its first message',
  );
  await _native(tester, '$prefix-read-list');
  host.reply(ordinary, 'Incoming ordinary answer', ordinaryGateway);
  await _until(
    tester,
    () => recents.items().any(
      (item) => item.chat?.key == ordinary.key && item.unread,
    ),
    details: () => jsonEncode({
      'selected': controller.current?.chat?.key.sessionId,
      'patches': host.patched.map((key) => key.workspace.profileName).toList(),
      'loading': ordinary.reading.historyLoading,
      'error': ordinary.reading.historyError,
      'markReadFailed': ordinary.markReadFailed,
      'target': ordinary.reading.notificationReadTarget?.identity,
      'times': ordinary.reading.messages
          .map((row) => row['timestamp'])
          .toList(),
      'serverRead': host.watermarks[('personal', 'recipient')],
    }),
  );
  expect(
    find.descendant(of: ordinaryCard, matching: find.text('New answer')),
    findsOneWidget,
  );
  expect(find.text('Incoming ordinary answer'), findsOneWidget);
  expect(host.patched, isEmpty);
  final published = recents.catalog;
  ordinaryGateway.onEvent!(
    StreamEvent(
      type: 'message.complete',
      sessionId: ordinary.runtime.runtimeId,
      data: {
        'text': 'Incoming ordinary answer',
        'mobile_push_event_id': 'native-answer-1',
      },
    ),
  );
  await tester.pump(const Duration(milliseconds: 220));
  expect(recents.catalog, same(published));
  await _native(tester, '$prefix-ordinary-unread');
  expect(
    tester
        .widget<InkWell>(
          find.descendant(of: ordinaryCard, matching: find.byType(InkWell)),
        )
        .onTap,
    isNotNull,
  );
  await _native(
    tester,
    '$prefix-open-ordinary',
    actions: [_tap(tester, ordinaryCard)],
  );
  expect(
    find.byType(RecentConversationSwitcher),
    findsOneWidget,
    reason:
        'Native tap must enter the conversation; selected=${controller.current?.chat?.key.sessionId}, receipts=${host.patched.length}',
  );
  await _readNewest(tester, '$prefix-read-ordinary');
  await _until(
    tester,
    () => !recents
        .items()
        .singleWhere((item) => item.chat?.key == ordinary.key)
        .unread,
    details: () => jsonEncode({
      'selected': controller.current?.chat?.key.sessionId,
      'patches': host.patched.map((key) => key.workspace.profileName).toList(),
      'loading': ordinary.reading.historyLoading,
      'error': ordinary.reading.historyError,
      'markReadFailed': ordinary.markReadFailed,
      'target': ordinary.reading.notificationReadTarget?.identity,
      'times': ordinary.reading.messages
          .map((row) => row['timestamp'])
          .toList(),
      'serverRead': host.watermarks[('personal', 'recipient')],
    }),
  );
  expect(host.patched, [ordinary.key]);
  final switcher = tester.widget<RecentConversationSwitcher>(
    find.byType(RecentConversationSwitcher),
  );
  expect(controller.current!.chat!.key, ordinary.key);
  expect(find.byKey(const ValueKey('recent-conversation-nudge')), findsNothing);
  await _native(tester, '$prefix-live-chat');
  host.reply(bot, 'Incoming Bot Chat answer', botGateway);
  await _until(
    tester,
    () =>
        switcher.session.nudges.value?.key ==
        RecentConversationKey.chat(bot.key),
  );
  expect(
    recents.items().singleWhere((item) => item.chat?.key == bot.key).unread,
    isTrue,
  );
  expect(
    switcher.session.nudges.value!.direction,
    recentConversationDirection(
      switcher.session.entries,
      RecentConversationKey.chat(ordinary.key),
      RecentConversationKey.chat(bot.key),
    ),
  );
  expect(
    find.byKey(const ValueKey('recent-conversation-nudge')),
    findsOneWidget,
  );
  await tester.pump(const Duration(milliseconds: 500));
  final ripple = find.byKey(const ValueKey('recent-conversation-nudge'));
  expect(ripple, findsOneWidget);
  await _native(
    tester,
    '$prefix-bot-ripple',
    actions: [
      {'type': 'wait', 'milliseconds': 120},
    ],
    observation: {
      'kind': 'reply',
      'direction': switcher.session.nudges.value!.direction.name,
      'tickerEnabled': TickerMode.valuesOf(tester.element(ripple)).enabled,
    },
  );
  host.groupReply(2);
  await controller.refreshGroupNotifications();
  await _until(
    tester,
    () =>
        switcher.session.nudges.value?.key ==
        RecentConversationKey.group(group.key),
  );
  expect(
    recents.items().singleWhere((item) => item.group?.key == group.key).unread,
    isTrue,
  );
  expect(bots.groupReads.sequence(group), 1);
  expect(controller.current!.chat!.key, ordinary.key);
  await _native(
    tester,
    '$prefix-group-ripple',
    observation: {
      'kind': 'reply',
      'direction': switcher.session.nudges.value!.direction.name,
    },
  );
  final width = _chatRect(tester).width;
  final y = _gestureRow(tester, [
    .24,
    .76,
  ], transcript: find.byType(ProfileTranscript));
  await _native(
    tester,
    '$prefix-unread-stack',
    actions: [
      _touch(tester, 'two', [
        (Offset(width * .24, y), Offset(width * .41, y)),
        (Offset(width * .76, y), Offset(width * .59, y)),
      ]),
    ],
  );
  expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
  expect(controller.visible, isFalse);
  expect(host.patched, [ordinary.key]);
  expect(bots.groupReads.sequence(group), 1);
  await _native(
    tester,
    '$prefix-return',
    actions: [
      {'type': 'back'},
    ],
  );
  await _native(
    tester,
    '$prefix-recents',
    actions: [
      {'type': 'back'},
    ],
  );
  await _until(
    tester,
    () => find.byType(WorkspaceActivityContent).evaluate().isNotEmpty,
  );
  final botCard = find.byKey(const ValueKey('activity-work-recipient'));
  final groupCard = find.byKey(ValueKey('recent-group-${group.key}'));
  for (final card in [botCard, groupCard]) {
    await _revealRecent(
      tester,
      card,
      '$prefix-review-${card == botCard ? 'bot' : 'group'}',
    );
    expect(
      find.descendant(of: card, matching: find.text('New answer')),
      findsOneWidget,
    );
    await _native(
      tester,
      '$prefix-${card == botCard ? 'bot' : 'group'}-unread-list',
    );
  }
  expect(host.patched, [ordinary.key]);
  await _revealRecent(tester, botCard, '$prefix-select-bot');
  await _native(tester, '$prefix-open-bot', actions: [_tap(tester, botCard)]);
  expect(controller.current!.chat!.key, bot.key);
  await _readNewest(tester, '$prefix-read-bot');
  await _until(
    tester,
    () => !recents
        .items()
        .singleWhere((item) => item.chat?.key == bot.key)
        .unread,
  );
  expect(host.patched, [ordinary.key, bot.key]);
  host.reply(bot, 'A reply while I read Bot Chat', botGateway);
  await _readNewest(tester, '$prefix-read-new-bot-answer');
  await _until(
    tester,
    () =>
        host.patched.length == 3 &&
        !recents
            .items()
            .singleWhere((item) => item.chat?.key == bot.key)
            .unread,
  );
  expect(host.patched, [ordinary.key, bot.key, bot.key]);
  expect(find.byKey(const ValueKey('recent-conversation-nudge')), findsNothing);
  await _native(tester, '$prefix-current-bot-read');
  await _native(
    tester,
    '$prefix-bot-back',
    actions: [
      {'type': 'back'},
    ],
  );
  await _until(
    tester,
    () => find.byType(WorkspaceActivityContent).evaluate().isNotEmpty,
  );
  await _revealRecent(tester, groupCard, '$prefix-select-group');
  await _native(
    tester,
    '$prefix-open-group',
    actions: [_tap(tester, groupCard)],
  );
  await _readNewest(tester, '$prefix-read-group');
  await _until(tester, () => bots.groupReads.sequence(group) == 2);
  expect(
    recents.items().singleWhere((item) => item.group?.key == group.key).unread,
    isFalse,
  );
  await _native(tester, '$prefix-group-read');
  final groupSwitcher = tester.widget<RecentConversationSwitcher>(
    find.byType(RecentConversationSwitcher),
  );
  expect(
    groupSwitcher.session.modeEnabled,
    isTrue,
    reason: 'A group selected in Recents must admit arrival cues immediately',
  );
  host.reply(
    ordinary,
    'Incoming ordinary reply while reading the group',
    ordinaryGateway,
  );
  await _until(
    tester,
    () =>
        groupSwitcher.session.nudges.value?.key ==
        RecentConversationKey.chat(ordinary.key),
  );
  await tester.pump(const Duration(milliseconds: 500));
  expect(
    find.byKey(const ValueKey('recent-conversation-nudge')),
    findsOneWidget,
  );
  await _native(
    tester,
    '$prefix-ordinary-ripple-in-group',
    observation: {
      'kind': 'reply',
      'direction': groupSwitcher.session.nudges.value!.direction.name,
    },
  );
  final groupWidth = _chatRect(tester).width;
  final groupY = _gestureRow(tester, [
    .24,
    .76,
  ], transcript: find.byKey(ValueKey(('discussion', group.id))));
  await _native(
    tester,
    '$prefix-group-stack',
    actions: [
      _touch(tester, 'two', [
        (Offset(groupWidth * .24, groupY), Offset(groupWidth * .41, groupY)),
        (Offset(groupWidth * .76, groupY), Offset(groupWidth * .59, groupY)),
      ]),
    ],
  );
  expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
  host.groupReply(3);
  await controller.refreshGroupNotifications();
  await _until(
    tester,
    () => recents
        .items()
        .singleWhere((item) => item.group?.key == group.key)
        .unread,
  );
  expect(
    bots.groupReads.sequence(group),
    2,
    reason:
        'A passive group viewport cannot acknowledge its newly delivered answer',
  );
  await _native(tester, '$prefix-passive-group-unread');
  await _native(
    tester,
    '$prefix-group-stack-back',
    actions: [
      {'type': 'back'},
    ],
  );
  if (bots.groupReads.sequence(group) == 3) {
    expect(
      find.text('Incoming group answer 3', findRichText: true).hitTestable(),
      findsOneWidget,
    );
  }
  await _readNewest(tester, '$prefix-read-restored-group');
  await _until(tester, () => bots.groupReads.sequence(group) == 3);
  expect(
    recents.items().singleWhere((item) => item.group?.key == group.key).unread,
    isFalse,
  );
  await _native(
    tester,
    '$prefix-group-final-back',
    actions: [
      {'type': 'back'},
    ],
  );
  await _until(
    tester,
    () => find.byType(WorkspaceActivityContent).evaluate().isNotEmpty,
  );
  expect(
    recents
        .items()
        .singleWhere((item) => item.chat?.key == ordinary.key)
        .unread,
    isTrue,
  );
  expect(tester.takeException(), isNull);
  await _native(
    tester,
    '$prefix-complete',
    observation: {
      'conversationTypes': ['ordinary', 'canonical-bot', 'group'],
      'permission': 'denied',
      'backendMutations': 0,
      'unreadChats': recents.items().where((item) => item.unread).length,
      'readAcks': host.patched.length,
      'setupReadAcks': setupReadReceipts,
      'groupReadSequence': bots.groupReads.sequence(group),
    },
  );
}

Future<void> _revealRecent(
  WidgetTester tester,
  Finder card,
  String prefix,
) async {
  final content = find.byType(WorkspaceActivityContent);
  final viewport = tester.getRect(
    find.descendant(of: content, matching: find.byType(ListView)),
  );
  final scrolling = tester.state<ScrollableState>(
    find.descendant(of: content, matching: find.byType(Scrollable)),
  );
  final x = viewport.center.dx;
  Future<void> swipe(bool down, int step) => _native(
    tester,
    '$prefix-${down ? 'down' : 'up'}-$step',
    actions: [
      _touch(tester, 'one', [
        (
          Offset(x, down ? viewport.top + 70 : viewport.bottom - 70),
          Offset(x, down ? viewport.bottom - 70 : viewport.top + 70),
        ),
      ], milliseconds: 450),
    ],
    capture: false,
  );
  for (var step = 0; step < 6 && scrolling.position.pixels > 1; step++) {
    await swipe(true, step);
  }
  for (
    var step = 0;
    step < 6 && card.hitTestable().evaluate().isEmpty;
    step++
  ) {
    await swipe(false, step);
  }
  expect(
    card.hitTestable(),
    findsOneWidget,
    reason: 'Native scrolling must reveal the current Recents card',
  );
}

/// Only gateway responses and incoming journal projections are synthetic.
/// Android dispatches every tested touch through the installed production chat.
class _NativeChats extends ProfileBrowserFixture {
  final newReplies = <(String, String), List<Map<String, dynamic>>>{};
  final patched = <ProfileSessionKey>[];
  ProfileSessionKey? failedResume;
  int rejectedResumes = 0;
  bool deepHistory = false, showCode = false;
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (var index = 0; index < 3; index++)
      {
        'id': 'chat-$index',
        'title': '$profile task $index',
        'profile': profile,
        'last_active': now - index * 60,
        'unread': false,
      },
  ];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    if (deepHistory)
      for (var i = 0; i < 20; i++)
        {
          'id': 100 + i,
          'role': i.isEven ? 'user' : 'assistant',
          'content':
              'Saved message $i. Return to this reading position after checking another task. This history belongs to $profile.',
          'timestamp': now - 1000 + i,
        },
    {
      'id': 1,
      'role': 'user',
      'content': 'Keep my normal conversation in place.',
    },
    {
      'id': 2,
      'role': 'tool',
      'tool_name': 'Read project',
      'content': 'Inspect the existing conversation controls.',
    },
    {
      'id': 3,
      'role': 'assistant',
      'timestamp': now - 20,
      'content':
          '${showCode ? '```dart\nfinal value = 42;\n```\n\n' : ''}'
          '## Your conversation\n\nMove between tasks when you need to. '
          'Your draft and reading position stay with this chat.',
    },
    ...?newReplies[(profile, id)],
  ];
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        final id = path.startsWith('sessions/')
            ? Uri.decodeComponent(path.substring('sessions/'.length))
            : null;
        if (id == null ||
            !sessions(scope.profileName).any((row) => row['id'] == id) ||
            body.length != 5 ||
            body['request_id'] is! String ||
            (body['request_id'] as String).isEmpty ||
            body['expected_revision'] != 0 ||
            body['expected_generation'] != 0 ||
            body['profile'] != scope.profileName ||
            body['unread'] != false ||
            !canDispatch()) {
          throw StateError('Unexpected read acknowledgement: $path');
        }
        onDispatched();
        patched.add(ProfileSessionKey(scope, id));
        return {'ok': true};
      },
      rpc: (method, params) {
        if (method == 'session.resume' &&
            scope == failedResume?.workspace &&
            params['session_id'] == failedResume?.sessionId) {
          rejectedResumes++;
          throw StateError('Owned QA resume rejection');
        }
        return base.call(method, params);
      },
    );
  }

  int get resumes => calls.where((call) => call.$2 == 'session.resume').length;
}

/// Host receipts are unique and bounded. No gesture is synthesized by Flutter.
Future<void> _native(
  WidgetTester tester,
  String name, {
  List<Map<String, Object?>> actions = const [],
  Map<String, Object?> observation = const {},
  bool capture = true,
}) async {
  final cache = Directory.systemTemp.path;
  final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
  await File('$cache/wing-recents-stage.json').writeAsString(
    jsonEncode({
      'name': name,
      'token': token,
      'actions': actions,
      'observation': observation,
      'capture': capture,
      'devicePixelRatio': tester.view.devicePixelRatio,
    }),
  );
  final ack = File('$cache/wing-recents-ack');
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 40));
    if (await ack.exists() && await ack.readAsString() == token) {
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      return;
    }
  }
  throw StateError('Native Android driver did not complete $name');
}

Map<String, Object?> _touch(
  WidgetTester tester,
  String mode,
  List<(Offset, Offset)> contacts, {
  int? milliseconds,
}) => {
  'type': mode,
  'contacts': [
    for (final contact in contacts)
      [contact.$1.dx, contact.$1.dy, contact.$2.dx, contact.$2.dy],
  ],
  'milliseconds': milliseconds ?? (mode == 'one' ? 1000 : 320),
};

Map<String, Object?> _tap(WidgetTester tester, Finder finder) {
  expect(finder.hitTestable(), findsOneWidget);
  final center = tester.getCenter(finder.hitTestable());
  return {'type': 'tap', 'x': center.dx, 'y': center.dy};
}

Rect _chatRect(WidgetTester tester) =>
    tester.getRect(find.byType(RecentConversationSwitcher));

// Select a real admitted transcript row; text, controls and OS edges keep their
// production hit-test policy. Large native font settings can move these rows.
double _gestureRow(
  WidgetTester tester,
  List<double> fractions, {
  required Finder transcript,
}) {
  final rect = tester.getRect(transcript);
  for (var y = rect.top + 24; y < rect.bottom - 24; y += 12) {
    if (fractions.every(
      (fraction) => admitsConversationGesture(
        PointerDownEvent(
          position: Offset(rect.width * fraction, y),
          viewId: tester.view.viewId,
        ),
      ),
    )) {
      return y;
    }
  }
  throw StateError('No admitted transcript row');
}

Offset _blank(WidgetTester tester) {
  final rect = tester.getRect(find.byType(ProfileTranscript));
  for (var y = rect.top + 24; y < rect.bottom - 24; y += 12) {
    for (final x in [rect.width * .6, rect.width * .4, 28.0, rect.width - 28]) {
      final point = Offset(x, y);
      if (admitsConversationGesture(
        PointerDownEvent(position: point, viewId: tester.view.viewId),
      )) {
        return point;
      }
    }
  }
  throw StateError('No admitted blank transcript space');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..shouldPropagateDevicePointerEvents = true
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const enabled = bool.fromEnvironment('RECENTS_NATIVE_INPUT');
  const codeOnly = bool.fromEnvironment('RECENTS_CODE_ONLY');
  const momentumOnly = bool.fromEnvironment('RECENTS_MOMENTUM_ONLY');
  const eventsOnly = bool.fromEnvironment('RECENTS_EVENTS_ONLY');
  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final large in [false, true]) {
      if (eventsOnly) {
        testWidgets(
          'native incoming messages ${brightness.name} ${large ? 'large' : 'normal'}',
          (tester) => _incomingJourney(tester, brightness, large),
          skip: !enabled,
        );
        continue;
      }
      if (momentumOnly && (brightness != Brightness.dark || large)) continue;
      testWidgets(
        'native Recents ${brightness.name} ${large ? 'large' : 'normal'}${codeOnly ? ' code' : ''}',
        (tester) async {
          final prefix = '${brightness.name}-${large ? 'large' : 'normal'}';
          await _native(
            tester,
            '$prefix-configure',
            actions: [
              {'type': 'configure', 'large': large},
            ],
            capture: false,
          );
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final preferences = AppPreferences(prefs);
          final host = _NativeChats()..showCode = codeOnly;
          final readReceipts = <String>[];
          final dashboard = await _drawerDashboard();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'native-recents',
                label: 'Recents QA',
                host: InternetAddress.loopbackIPv4.address,
                port: 1,
                dashboardPortOverride: dashboard.port,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'native-recents',
            preferences: prefs,
            appPreferences: preferences,
            gatewayFactory: host.gateway,
            onNotificationRead: (_, identity) async =>
                readReceipts.add(identity),
          );
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            controller.dispose();
            preferences.dispose();
            activity.dispose();
          });
          await controller.initialize();
          await controller.refreshRecents();
          bool accessible = false, reduced = false;
          late StateSetter presentation;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => StatefulBuilder(
                builder: (context, setState) {
                  presentation = setState;
                  return MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      accessibleNavigation: accessible,
                      disableAnimations: reduced,
                    ),
                    child: ChatNoticeActivityScope(
                      activity: activity,
                      child: child!,
                    ),
                  );
                },
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
                initialDestination: AppDestination.activity,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 500));
          await _native(
            tester,
            '$prefix-enter',
            actions: [
              _tap(
                tester,
                find.byKey(const ValueKey('activity-personal-chat-0')),
              ),
            ],
          );
          expect(find.byType(RecentConversationSwitcher), findsOneWidget);
          expect(
            MediaQuery.textScalerOf(
              tester.element(find.byType(ProfileWorkspaceScreen)),
            ).scale(16),
            large ? greaterThan(25) : closeTo(16, 1),
          );
          final first = controller.current!.chat!;
          final layer = tester.widget<RecentConversationSwitcher>(
            find.byType(RecentConversationSwitcher),
          );
          final visit = layer.session;
          final ring = visit.entries;
          final origin = visit.selectedIndex;
          final rect = _chatRect(tester);
          final w = rect.width;
          final mid = Offset(w / 2, rect.center.dy - 28);
          Future<void> closeDrawerAndReturn() async {
            final scaffold = tester.state<ScaffoldState>(
              find
                  .ancestor(
                    of: find.byType(ProfileTranscript),
                    matching: find.byType(Scaffold),
                  )
                  .first,
            );
            if (scaffold.isDrawerOpen) {
              await _native(
                tester,
                '$prefix-drawer-back',
                actions: [
                  {'type': 'back'},
                ],
              );
              expect(scaffold.isDrawerOpen, isFalse);
              expect(find.byType(RecentConversationSwitcher), findsOneWidget);
            }
            await _native(
              tester,
              '$prefix-activity-back',
              actions: [
                {'type': 'back'},
              ],
            );
            expect(find.byType(WorkspaceActivityContent), findsOneWidget);
            expect(find.byType(RecentConversationSwitcher), findsNothing);
            expect(
              find.byKey(const ValueKey('activity-personal-chat-0')),
              findsOneWidget,
            );
            expect(controller.current!.chat, isNull);
          }

          if (codeOnly) {
            if (!large) {
              final code = tester.getRect(
                find.byType(SourceCodeBlock).hitTestable(),
              );
              await _native(
                tester,
                '$prefix-code-exclusion',
                actions: [
                  _touch(tester, 'two', [
                    (
                      Offset(code.left + 28, code.center.dy),
                      Offset(code.left + 70, code.center.dy),
                    ),
                    (
                      Offset(code.right - 28, code.center.dy),
                      Offset(code.right - 70, code.center.dy),
                    ),
                  ]),
                ],
              );
              expect(controller.current!.chat!.key, first.key);
              expect(find.text('Swipe to browse · tap to open'), findsNothing);
              await _native(
                tester,
                '$prefix-copy-code',
                actions: [_tap(tester, find.byTooltip('Copy code'))],
              );
              expect(
                (await Clipboard.getData('text/plain'))?.text,
                contains('final value = 42;'),
              );
            }
            final edgeY =
                tester.getRect(find.byType(ProfileTranscript)).top + 30;
            await _native(
              tester,
              '$prefix-code-system-edge',
              actions: [
                _touch(tester, 'two', [
                  (Offset(8, edgeY), Offset(68, edgeY)),
                  (Offset(20, edgeY), Offset(80, edgeY)),
                ]),
              ],
            );
            expect(controller.current!.chat!.key, first.key);
            expect(find.text('Swipe to browse · tap to open'), findsNothing);
            await closeDrawerAndReturn();
            expect(tester.takeException(), isNull);
            await _native(
              tester,
              '$prefix-code-complete',
              observation: {
                'scope': large
                    ? 'Android edge/drawer Back'
                    : 'code-copy/exclusion and Android edge/drawer Back',
                'modelSubmissions': 0,
              },
            );
            return;
          }
          Future<void> swipe(
            String name, {
            bool right = false,
            String type = 'two',
          }) async {
            final y = _gestureRow(
              tester,
              right ? [.16, .38] : [.62, .84],
              transcript: find.byType(ProfileTranscript),
            );
            final start = right ? [.16, .38] : [.62, .84];
            final dx = w * (right ? .5 : -.5);
            await _native(
              tester,
              '$prefix-$name',
              actions: [
                _touch(tester, type, [
                  for (final x in start)
                    (Offset(w * x, y), Offset(w * x + dx, y)),
                ]),
              ],
            );
          }

          Future<void> pinch(String name) async {
            final y = _gestureRow(tester, [
              .24,
              .76,
            ], transcript: find.byType(ProfileTranscript));
            await _native(
              tester,
              '$prefix-$name',
              actions: [
                _touch(tester, 'two', [
                  (Offset(w * .24, y), Offset(w * .41, y)),
                  (Offset(w * .76, y), Offset(w * .59, y)),
                ]),
              ],
            );
            expect(
              find.text(
                accessible
                    ? 'Choose a conversation'
                    : 'Swipe to browse · tap to open',
              ),
              findsOneWidget,
            );
            expect(controller.visible, isFalse);
          }

          if (momentumOnly) {
            await pinch('momentum-stack');
            final resumes = host.resumes;
            final flingEvents = <Map<String, Object?>>[];
            final visibleChoices = {
              for (var i = 0; i < ring.length; i++)
                '${ring[i].title}, conversation ${i + 1} of ${ring.length}':
                    ring[i].key.chat!,
            };
            // The footer announces a settled choice. Observe actual transformed
            // card contents during motion, independently of the motion/index state.
            String? focusedChoice() {
              String? nearest;
              var distance = double.infinity;
              for (final element
                  in find
                      .byWidgetPredicate(
                        (widget) =>
                            widget is ConversationCardPlaceholder ||
                            widget is RawImage,
                      )
                      .evaluate()) {
                final ProfileSessionKey? key = switch (element.widget) {
                  ConversationCardPlaceholder(:final card) =>
                    card.entry.key.chat,
                  RawImage(
                    key: ValueKey(
                      value: (RecentConversationKey key, 'snapshot'),
                    ),
                  ) =>
                    key.chat,
                  _ => null,
                };
                if (key == null) continue;
                final box = element.findRenderObject();
                if (box is! RenderBox || !box.hasSize || !box.attached) {
                  continue;
                }
                final center = box.localToGlobal(box.size.center(Offset.zero));
                final offset = (center.dx - mid.dx).abs();
                if (!rect.contains(center) || offset >= distance) continue;
                final label = visibleChoices.entries
                    .where((entry) => entry.value == key)
                    .firstOrNull
                    ?.key;
                if (label == null) continue;
                distance = offset;
                nearest = label;
              }
              return nearest;
            }

            final afterRelease = <String>[];
            final diagnosticFrames = <Map<String, Object?>>[];
            var released = false, recording = true;
            void observeFocus(Duration frame) {
              if (!recording) return;
              final label = focusedChoice();
              // Event timestamps alone cannot distinguish delayed input
              // delivery from missed rendered frames on a loaded emulator.
              if (diagnosticFrames.length < 500) {
                diagnosticFrames.add({
                  'wall': DateTime.now().microsecondsSinceEpoch,
                  'frame': frame.inMicroseconds,
                  'focus': label,
                  'released': released,
                });
              }
              if (released &&
                  label != null &&
                  (afterRelease.isEmpty || afterRelease.last != label)) {
                afterRelease.add(label);
              }
              tester.binding.addPostFrameCallback(observeFocus);
            }

            tester.binding.addPostFrameCallback(observeFocus);
            void recordFling(PointerEvent event) {
              if (event is PointerUpEvent) {
                released = true;
                final label = focusedChoice();
                if (label != null) afterRelease.add(label);
              }
              if (flingEvents.length >= 100) return;
              flingEvents.add({
                'kind': event.runtimeType.toString(),
                'pointer': event.pointer,
                'wall': DateTime.now().microsecondsSinceEpoch,
                'microseconds': event.timeStamp.inMicroseconds,
                'x': event.position.dx,
                'y': event.position.dy,
              });
            }

            tester.binding.pointerRouter.addGlobalRoute(recordFling);
            try {
              await _native(
                tester,
                '$prefix-momentum-fling',
                actions: [
                  _touch(tester, 'one', [
                    (Offset(w * .92, mid.dy), Offset(w * .08, mid.dy)),
                  ], milliseconds: 100),
                ],
              );
            } finally {
              recording = false;
              tester.binding.pointerRouter.removeGlobalRoute(recordFling);
            }
            expect(released, isTrue);
            expect(
              afterRelease.toSet().length,
              greaterThanOrEqualTo(3),
              reason:
                  'After finger release, one flick must continue through multiple visible conversation choices. '
                  '${jsonEncode({'focusedAfterRelease': afterRelease, 'events': flingEvents, 'frames': diagnosticFrames})}',
            );
            expect(host.resumes, resumes);
            expect(controller.current!.chat!.key, first.key);
            if (visibleChoices[focusedChoice()] == first.key) {
              await _native(
                tester,
                '$prefix-momentum-slow-browse',
                actions: [
                  _touch(tester, 'one', [
                    (Offset(w * .8, mid.dy), Offset(w * .2, mid.dy)),
                  ]),
                ],
              );
            }
            final chosen = visibleChoices[focusedChoice()];
            expect(chosen, isNotNull);
            expect(chosen, isNot(first.key));
            await _native(
              tester,
              '$prefix-momentum-select',
              observation: {
                'focusedAfterRelease': afterRelease,
                'diagnosticFrames': diagnosticFrames,
                'diagnosticEvents': flingEvents,
                'chosen': focusedChoice(),
              },
              actions: [
                {'type': 'tap', 'x': mid.dx, 'y': mid.dy},
              ],
            );
            expect(controller.current!.chat!.key, chosen);
            expect(find.text('Swipe to browse · tap to open'), findsNothing);
            expect(find.text('Opening conversation…'), findsNothing);
            expect(controller.visible, isTrue);
            expect(tester.takeException(), isNull);
            await _native(tester, '$prefix-momentum-complete');
            return;
          }

          final file = File('${Directory.systemTemp.path}/recents-qa.txt');
          await file.writeAsString(
            'Owned emulator attachment. Never submitted.',
          );
          addTearDown(() async {
            if (await file.exists()) await file.delete();
          });
          await first.composer.addFiles([
            (path: file.path, name: 'recents-qa.txt'),
          ]);
          await controller.updateDraft(first, 'Draft_');
          await tester.pumpAndSettle();
          await _native(
            tester,
            '$prefix-keyboard',
            actions: [
              _tap(tester, find.byKey(const Key('profile-message-composer'))),
              {'type': 'text', 'text': 'Native'},
            ],
          );
          expect(first.composer.observation.displayedText, contains('Native'));
          expect(tester.view.viewInsets.bottom, greaterThan(0));
          final draft = first.composer.observation.displayedText;
          final attachments = first.composer.observation.attachments
              .map((a) => a.id)
              .toList();
          await _native(
            tester,
            '$prefix-keyboard-back',
            actions: [
              {'type': 'back'},
            ],
          );
          expect(tester.view.viewInsets.bottom, 0);
          expect(controller.current!.chat!.key, first.key);
          await swipe('slide-next');
          expect(
            controller.current!.chat!.key,
            ring[(origin + 1) % ring.length].key.chat,
          );
          await swipe('slide-previous', right: true);
          expect(controller.current!.chat!.key, first.key);
          expect(first.composer.observation.displayedText, draft);
          expect(
            first.composer.observation.attachments.map((a) => a.id),
            attachments,
          );
          await swipe('interrupted-return', type: 'interrupt');
          expect(
            controller.current!.chat!.key,
            ring[(origin + 1) % ring.length].key.chat,
          );
          await swipe('return-after-interruption', right: true);
          final resumes = host.resumes;
          await pinch('pinch-persistent');
          await _native(
            tester,
            '$prefix-browse',
            actions: [
              _touch(tester, 'one', [
                (Offset(w * .8, mid.dy), Offset(w * .2, mid.dy)),
              ]),
            ],
          );
          expect(controller.current!.chat!.key, first.key);
          expect(
            host.resumes,
            resumes,
            reason: 'Browsing has no resume authority',
          );
          await _native(
            tester,
            '$prefix-open-center',
            actions: [
              {'type': 'tap', 'x': mid.dx, 'y': mid.dy},
            ],
          );
          expect(
            controller.current!.chat!.key,
            ring[(origin + 1) % ring.length].key.chat,
          );
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          await swipe('return-from-center', right: true);
          await pinch('pinch-peek');
          await _native(
            tester,
            '$prefix-open-peek',
            actions: [
              {'type': 'tap', 'x': w - 12, 'y': mid.dy},
            ],
          );
          expect(
            controller.current!.chat!.key,
            ring[(origin + 1) % ring.length].key.chat,
          );
          await swipe('return-from-peek', right: true);
          await pinch('circular-stack');
          final beforeLaps = host.resumes;
          await _native(
            tester,
            '$prefix-full-lap',
            actions: [
              for (var i = 0; i < ring.length; i++) ...[
                _touch(tester, 'one', [
                  (Offset(w * .8, mid.dy), Offset(w * .2, mid.dy)),
                ]),
                {'type': 'wait', 'milliseconds': 850},
              ],
            ],
          );
          expect(host.resumes, beforeLaps);
          final readsBeforeStackReturn = host.patched.length;
          host.newReplies[(
            first.key.workspace.profileName,
            first.key.sessionId,
          )] = [
            {
              'id': 1000,
              'role': 'assistant',
              'timestamp': host.now + 1,
              'content': 'New answer received while Recents is open.',
            },
          ];
          first.reading.recordNotificationResult(
            const NotificationFocus('answer', '1000'),
          );
          await controller.refreshHistory(first);
          await tester.pumpAndSettle();
          expect(
            readReceipts,
            isEmpty,
            reason: 'A hidden chat/card must not acknowledge a reply',
          );
          await _native(
            tester,
            '$prefix-stack-back',
            actions: [
              {'type': 'back'},
            ],
          );
          expect(controller.current!.chat!.key, first.key);
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          expect(controller.visible, isTrue);
          expect(
            tester.view.viewInsets.bottom,
            0,
            reason:
                'Stack Back must preserve a keyboard already hidden with Android Back',
          );
          if (readReceipts.isEmpty) {
            expect(host.patched, hasLength(readsBeforeStackReturn));
          } else {
            expect(
              find
                  .text(
                    'New answer received while Recents is open.',
                    findRichText: true,
                  )
                  .hitTestable(),
              findsOneWidget,
            );
          }
          await _readNewest(
            tester,
            '$prefix-read-restored-answer',
            acknowledged: () => readReceipts.isNotEmpty,
          );
          expect(readReceipts, ['answer:1000']);
          expect(host.patched.skip(readsBeforeStackReturn), [first.key]);
          expect(first.markReadFailed, isFalse);
          // The neighbor was already opened above and needs no resume RPC.
          // Move to it, then reject admission of the next unopened chat.
          await swipe('prepare-unopened-selection');
          final beforeRejectedSelection = controller.current!.chat!.key;
          expect(
            beforeRejectedSelection,
            ring[(origin + 1) % ring.length].key.chat,
          );
          host.failedResume = ring[(origin + 2) % ring.length].key.chat!;
          final rejectedBefore = host.rejectedResumes;
          await swipe('failed-selection');
          expect(host.rejectedResumes, rejectedBefore + 1);
          expect(controller.current!.chat!.key, host.failedResume);
          expect(controller.current!.chat!.reading.messages, isNotEmpty);
          expect(
            find.text(
              'Conversation could not be refreshed. Retry to check for new messages.',
            ),
            findsOneWidget,
          );
          expect(controller.current!.chat!.runtime.offline, isTrue);
          host.failedResume = null;
          await _native(
            tester,
            '$prefix-retry-selection',
            actions: [_tap(tester, find.byTooltip('Retry'))],
          );
          expect(controller.current!.chat!.runtime.openingError, isNull);
          expect(controller.current!.chat!.runtime.offline, isFalse);
          await swipe('return-to-neighbor-after-retry', right: true);
          await swipe('return-after-failed-selection', right: true);
          expect(controller.current!.chat!.key, first.key);
          var sequence = 0;
          for (final kind in ConversationActivityKind.values) {
            activity.value = ChatNoticeActivity(
              key: ring[(origin + 1) % ring.length].key,
              kind: kind,
              identity: 'native-${kind.name}',
              sequence: ++sequence,
            );
            await tester.pump(const Duration(milliseconds: 220));
            expect(
              find.byKey(const Key('recent-conversation-nudge')),
              findsOneWidget,
            );
            await _native(
              tester,
              '$prefix-nudge-${kind.name}',
              actions: [
                {'type': 'wait', 'milliseconds': 60},
              ],
            );
            await tester.pump(const Duration(milliseconds: 800));
          }
          await _native(
            tester,
            '$prefix-editing-arrival',
            actions: [
              _tap(tester, find.byKey(const Key('profile-message-composer'))),
            ],
            capture: false,
          );
          for (
            var tick = 0;
            tick < 150 && tester.view.viewInsets.bottom == 0;
            tick++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          final editingField = tester.widget<TextField>(
            find.byKey(const Key('profile-message-composer')),
          );
          expect(editingField.focusNode!.hasFocus, isTrue);
          expect(tester.view.viewInsets.bottom, greaterThan(0));
          final editingValue = editingField.controller!.value;
          final editingOwner = controller.current!.chat!.key;
          activity.value = ChatNoticeActivity(
            key: ring[(origin + 1) % ring.length].key,
            kind: ConversationActivityKind.reply,
            identity: 'editing',
            sequence: ++sequence,
          );
          await tester.pump(const Duration(milliseconds: 350));
          expect(
            find.byKey(const Key('recent-conversation-nudge')),
            findsOneWidget,
            reason:
                'Fresh activity remains visible without interrupting editing',
          );
          expect(editingField.focusNode!.hasFocus, isTrue);
          expect(editingField.controller!.value, editingValue);
          expect(controller.current!.chat!.key, editingOwner);
          await _native(
            tester,
            '$prefix-end-editing',
            actions: [
              {'type': 'back'},
            ],
          );
          final blank = _blank(tester);
          await _native(
            tester,
            '$prefix-double-tap-stays-in-chat',
            actions: [
              {'type': 'tap', 'x': blank.dx, 'y': blank.dy},
              {'type': 'tap', 'x': blank.dx, 'y': blank.dy},
            ],
          );
          expect(controller.current!.chat!.key, first.key);
          // Composer is a excluded region even when native touches use two fingers.
          final composer = tester.getRect(
            find.byKey(const Key('profile-message-composer')),
          );
          await _native(
            tester,
            '$prefix-composer-exclusion',
            actions: [
              _touch(tester, 'two', [
                (
                  Offset(composer.left + 30, composer.center.dy),
                  Offset(composer.left + 80, composer.center.dy),
                ),
                (
                  Offset(composer.right - 30, composer.center.dy),
                  Offset(composer.right - 80, composer.center.dy),
                ),
              ]),
            ],
          );
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          expect(controller.current!.chat!.key, first.key);
          if (tester.view.viewInsets.bottom > 0) {
            await _native(
              tester,
              '$prefix-dismiss-exclusion-keyboard',
              actions: [
                {'type': 'back'},
              ],
            );
          }
          presentation(() => accessible = true);
          await tester.pumpAndSettle();
          final beforeAccessibility = controller.current!.chat!.key;
          await swipe('accessibility-swipe');
          expect(controller.current!.chat!.key, isNot(beforeAccessibility));
          final beforeAccessibleSelection = controller.current!.chat!.key;
          await pinch('accessibility-stack');
          expect(find.byTooltip('Next conversation'), findsOneWidget);
          expect(
            tester.view.viewInsets.bottom,
            0,
            reason: 'The hidden composer must not regain focus',
          );
          await _native(
            tester,
            '$prefix-accessible-next',
            actions: [_tap(tester, find.byTooltip('Next conversation'))],
          );
          expect(tester.view.viewInsets.bottom, 0);
          await _native(
            tester,
            '$prefix-accessible-open',
            actions: [_tap(tester, find.byTooltip('Open conversation'))],
          );
          expect(
            controller.current!.chat!.key,
            isNot(beforeAccessibleSelection),
          );
          presentation(() {
            accessible = false;
            reduced = true;
          });
          await tester.pumpAndSettle();
          await pinch('reduced-stack');
          await _native(
            tester,
            '$prefix-reduced-back',
            actions: [
              {'type': 'back'},
            ],
          );
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          presentation(() => reduced = false);
          await tester.pumpAndSettle();
          if (!large) {
            final target = List.generate(ring.length, (i) => i).firstWhere(
              (i) =>
                  ring[i].key.chat!.workspace !=
                  controller.current!.chat!.key.workspace,
            );
            Future<void> browseToTarget() async {
              await pinch('cross-profile-stack');
              final focusedTarget = find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics &&
                    widget.properties.label ==
                        '${ring[target].title}, conversation ${target + 1} of ${ring.length}',
              );
              // Native fling velocity can browse more than one card. Observe the
              // focused card instead of assuming a fixed number of swipes.
              for (var step = 0; step < ring.length; step++) {
                if (focusedTarget.evaluate().isNotEmpty) break;
                await _native(
                  tester,
                  '$prefix-cross-profile-browse-$step',
                  actions: [
                    _touch(tester, 'one', [
                      (Offset(w * .8, mid.dy), Offset(w * .2, mid.dy)),
                    ], milliseconds: 600),
                    {'type': 'wait', 'milliseconds': 850},
                  ],
                );
              }
              expect(focusedTarget, findsOneWidget);
            }

            host.failedResume = ring[target].key.chat!;
            await browseToTarget();
            await _native(
              tester,
              '$prefix-cross-profile-rejected',
              actions: [
                {'type': 'tap', 'x': mid.dx, 'y': mid.dy},
              ],
            );
            expect(controller.current!.chat!.key, ring[target].key.chat);
            expect(controller.current!.chat!.reading.messages, isNotEmpty);
            expect(
              find.text(
                'Conversation could not be refreshed. Retry to check for new messages.',
              ),
              findsOneWidget,
            );
            expect(controller.current!.chat!.runtime.offline, isTrue);
            host.failedResume = null;
            await _native(
              tester,
              '$prefix-cross-profile-retry',
              actions: [_tap(tester, find.byTooltip('Retry'))],
            );
            expect(controller.current!.chat!.key, ring[target].key.chat);
            expect(controller.current!.chat!.runtime.openingError, isNull);
            expect(controller.current!.chat!.runtime.offline, isFalse);
            await _native(tester, '$prefix-cross-profile-settled');
            for (
              var i = 0;
              i < ring.length && visit.selectedIndex != origin;
              i++
            ) {
              await swipe('cross-profile-return-$i', right: true);
            }
            expect(controller.current!.chat!.key, first.key);
            host.deepHistory = true;
            await controller.refreshHistory(first);
            await tester.pumpAndSettle();
            final transcript = tester.getRect(find.byType(ProfileTranscript));
            await _native(
              tester,
              '$prefix-ordinary-scroll',
              actions: [
                _touch(tester, 'one', [
                  (
                    Offset(w / 2, transcript.top + 60),
                    Offset(w / 2, transcript.top + 260),
                  ),
                ], milliseconds: 500),
              ],
            );
            final offset = first.reading.readingPosition.resume;
            expect(offset, isNotNull);
            await swipe('reading-switch');
            await swipe('reading-return', right: true);
            expect(
              first.reading.readingPosition.resume?.messageId,
              offset?.messageId,
            );
            expect(first.composer.observation.displayedText, draft);
            expect(
              first.composer.observation.attachments.map((a) => a.id),
              attachments,
            );
            await _native(tester, '$prefix-reading-restored');
          }
          final beforeEdge = controller.current!.chat!.key;
          final edgeY = tester.getRect(find.byType(ProfileTranscript)).top + 30;
          await _native(
            tester,
            '$prefix-system-edge',
            actions: [
              _touch(tester, 'two', [
                (Offset(8, edgeY), Offset(68, edgeY)),
                (Offset(20, edgeY), Offset(80, edgeY)),
              ]),
            ],
          );
          expect(controller.current!.chat!.key, beforeEdge);
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          await closeDrawerAndReturn();
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            isEmpty,
          );
          await _native(
            tester,
            '$prefix-complete',
            observation: {
              'ringSize': ring.length,
              'resumes': host.resumes,
              'draftRetained':
                  first.composer.observation.displayedText == draft,
              'attachmentRetained': listEquals(
                first.composer.observation.attachments
                    .map((a) => a.id)
                    .toList(),
                attachments,
              ),
              'readReceipts': readReceipts,
              'modelSubmissions': 0,
            },
          );
          expect(tester.takeException(), isNull);
        },
        skip: !enabled,
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }
  }
}
