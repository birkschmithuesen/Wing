import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/chat_browser_preferences.dart';
import 'package:wing/core/models/chat_list_view.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'support/profile_paging_fixture.dart';

class ReaderFixture extends ProfilePagingFixture {
  final opened = <int>{}, closed = <int>{};
  final ready = <int>{};
  final prematureCanonicalReads = <String>[];
  final connectionDelays = <String, Completer<void>>{};
  Completer<void>? connectionEntered;
  bool requireReadySocket = false;
  final owners = <int, String>{};
  bool failNextPage = false;
  bool failNextTree = false;
  bool failWorkIndex = false;
  bool failWorkSearch = false;
  bool permanentSearchFailure = false;
  Completer<void>? workSearchGate;
  final attempts = <(String, String, String?)>[];
  final omittedRows = <(String, String)>{};
  final rowUpdates = <(String, String), Map<String, dynamic>>{};
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (final row in super.sessions(profile))
      if (!omittedRows.contains((profile, row['id'] as String)))
        {...row, ...?rowUpdates[(profile, row['id'] as String)]},
  ];
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final id = owners.length;
    owners[id] = scope.profileName;
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        opened.add(id);
        final delay = connectionDelays[scope.profileName];
        if (delay != null) {
          connectionEntered?.complete();
          await delay.future;
        }
        await base.connect();
        ready.add(id);
      },
      close: () {
        closed.add(id);
        base.close();
      },
      get: (path, query) async {
        attempts.add((scope.profileName, path, query['q']));
        if (scope.profileName == 'work') {
          if (path == 'sessions/search') {
            final gate = workSearchGate;
            workSearchGate = null;
            await gate?.future;
          }
          if (failWorkIndex && path == 'sessions') {
            throw TimeoutException('Index offline');
          }
          if (failWorkSearch && path == 'sessions/search') {
            if (permanentSearchFailure) {
              throw const DashboardHttpException(403, 'sessions/search');
            }
            throw TimeoutException('Search offline');
          }
        }
        if (failNextPage && path == 'sessions' && query['offset'] == '100') {
          failNextPage = false;
          throw TimeoutException('Temporary page timeout');
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        if (requireReadySocket &&
            method == 'session.list' &&
            (!ready.contains(id) || closed.contains(id))) {
          prematureCanonicalReads.add(scope.profileName);
          throw JsonRpcError(
            method,
            'Connection unavailable',
            reason: 'connection_closed',
          );
        }
        if (failNextTree && method == 'projects.tree') {
          failNextTree = false;
          throw TimeoutException('Temporary tree timeout');
        }
        return base.call(method, params);
      },
    );
  }
}

void main() {
  late ReaderFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ChatBrowserData data;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = ReaderFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    data = ChatBrowserData(
      controller,
      readBotAppearances: fixture.botAppearances,
    );
  });
  tearDown(() {
    data.dispose();
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'suspended search resumes without retaining a late blocked failure',
    () async {
      await data.refresh(archivedOnly: false);
      final held = Completer<void>();
      fixture.workSearchGate = held;
      final pending = data.search('chat 1');
      await Future<void>.delayed(Duration.zero);
      final healthy = data.state.profiles['personal']!.searchMatches;
      expect(healthy, isNotEmpty);
      data.setReadActive(false);
      fixture.attempts.clear();
      await data.recover();
      expect(fixture.attempts, isEmpty);
      data.setReadActive(true);
      await data.recover();
      await Future<void>.delayed(Duration.zero);
      expect(data.state.searching, isFalse);
      expect(data.state.profiles['work']!.searchMatches, isNotEmpty);
      expect(data.state.profiles['personal']!.searchMatches, healthy);
      expect(fixture.attempts, isNotEmpty);
      expect(fixture.attempts.every((read) => read.$1 == 'work'), isTrue);
      held.completeError(TimeoutException('Retired blocked search'));
      await pending;
      expect(data.state.searchError, isNull);
      expect(data.needsRecovery, isFalse);
    },
  );

  test(
    'suspended refreshes coalesce into the requested archive read on return',
    () async {
      await data.refresh(archivedOnly: false);
      final entries = data.entries;
      data.setReadActive(false);
      fixture.attempts.clear();
      await data.refresh(archivedOnly: false);
      await data.refresh(archivedOnly: true);
      expect(fixture.attempts, isEmpty);
      expect(data.entries, entries);
      data.setReadActive(true);
      await data.refresh(archivedOnly: true);
      expect(data.state.archived, isTrue);
      expect(data.state.loading, isFalse);
      expect(data.readFailure, isNull);
      expect(data.entries, isEmpty);
      expect(fixture.attempts.where((read) => read.$2 == 'sessions').length, 2);
    },
  );

  test(
    'a failed foreground recovery still exposes an actionable error',
    () async {
      fixture.failWorkIndex = true;
      await data.refresh(archivedOnly: false);
      expect(data.readFailure, isNotNull);
      data.setReadActive(false);
      data.setReadActive(true);
      expect(data.readFailure, isNull);
      expect(data.state.loading, isTrue);
      // Calling refresh joins the already admitted foreground read.
      await data.refresh(archivedOnly: false);
      expect(data.readFailure, isNotNull);
      expect(data.state.profiles['work']!.error, isNotNull);
      expect(
        data.entries.where((entry) => entry.profile == 'personal'),
        isNotEmpty,
      );
    },
  );
  test(
    'retired canonical read closes its reader without sending an RPC',
    () async {
      final live = {...fixture.opened};
      final gate = Completer<void>();
      fixture.connectionDelays['work'] = gate;
      fixture.connectionEntered = Completer<void>();
      var active = true;
      final pending = controller.browserCanonicalBotChat(
        'work',
        canRead: () => active,
      );
      final checked = expectLater(pending, throwsStateError);
      await fixture.connectionEntered!.future;
      active = false;
      gate.complete();
      await checked;
      expect(
        fixture.calls.where(
          (call) => call.$1 == 'work' && call.$2 == 'session.list',
        ),
        isEmpty,
      );
      expect(fixture.closed.intersection(live), isEmpty);
      expect(fixture.opened.difference(live), fixture.closed);
    },
  );
  test(
    'canonical browsing opens and retires readers without losing live chats',
    () async {
      fixture.requireReadySocket = true;
      final live = {...fixture.opened};
      for (final profile in ['personal', 'work']) {
        fixture.hiddenSessions[profile] = [
          {
            'id': 'bot-chat',
            'title': 'Bot Chat',
            'profile': profile,
            'hidden': 1,
            'last_active': fixture.now,
          },
        ];
      }
      await data.chooseVisibility(SessionVisibility.all);
      expect(
        fixture.prematureCanonicalReads,
        isEmpty,
        reason: 'Browsing must not fail an unopened conversation socket',
      );
      expect(
        data.state.profiles.values.every((profile) => profile.complete),
        isTrue,
      );
      expect(
        data.state.profiles.values.every((profile) => profile.error == null),
        isTrue,
      );
      expect(
        data.entries
            .where((entry) => entry.isBotChat)
            .map((entry) => entry.profile)
            .toSet(),
        {'personal', 'work'},
      );
      expect(fixture.closed.intersection(live), isEmpty);
      expect(fixture.opened.difference(live), fixture.closed);
      expect(controller.current!.reconnectScheduled, isFalse);
    },
  );
  test(
    'hidden Bot Chats obey visibility before and after opening and re-entry',
    () async {
      for (final profile in ['personal', 'work']) {
        fixture.hiddenSessions[profile] = [
          {
            'id': 'bot-chat',
            'title': 'Bot Chat',
            'profile': profile,
            'source': 'tui',
            'hidden': 1,
            'archived': 0,
            'last_active': fixture.now,
            'input_tokens': 15000,
            'output_tokens': 500,
            'message_count': 4,
          },
        ];
      }
      List<ChatListEntry> bots() => data
          .project('')
          .entries
          .where((row) => row.id == 'bot-chat')
          .toList();
      await data.refresh(archivedOnly: false);
      expect(bots(), isEmpty);
      await controller.openSession(
        ProfileSessionKey(
          controller.browserResource('personal').scope,
          'bot-chat',
        ),
      );
      await data.refresh(archivedOnly: false);
      expect(
        bots(),
        isEmpty,
        reason: 'Opening a hidden canonical chat must not admit it to Chats',
      );
      await data.chooseVisibility(SessionVisibility.all);
      expect(bots().map((row) => row.profile).toSet(), {'personal', 'work'});
      expect(bots().every((row) => row.isBotChat), isTrue);
      expect(bots().every((row) => row.tokens == 15500), isTrue);
      for (final row in bots()) {
        final bot = data.botAppearance(row.sessionKey)!;
        expect(bot.profile.name, row.profile);
        expect(bot.shape, 'circle');
        expect(bot.color, '#65c7bc');
      }
      await controller.openSession(
        ProfileSessionKey(controller.browserResource('work').scope, 'bot-chat'),
      );
      await data.refresh(archivedOnly: false);
      expect(bots(), hasLength(2));
      await data.chooseVisibility(SessionVisibility.chats);
      expect(bots(), isEmpty);
      data.dispose();
      data = ChatBrowserData(
        controller,
        readBotAppearances: fixture.botAppearances,
      );
      await data.refresh(archivedOnly: false);
      expect(bots(), isEmpty);
    },
  );

  test(
    'production appearance reader borrows the captured server without closing it',
    () async {
      final server = AdministrationRepository(
        connectionId: 'host',
        connectionIdentity: 'test',
        connectionLabel: 'Test',
        gateway: (profile) => fixture.gateway(
          WorkspaceScope(
            connectionId: 'host',
            connectionIdentity: 'test',
            profileName: profile,
          ),
        ),
        request: (_, _, _, _) async => throw StateError('RPC only'),
        settingsWrite: (_, _, _, _) async => throw StateError('Read only'),
        ownedMutation: (_, _, _, _, _, _) async =>
            throw StateError('Read only'),
      );
      controller.healthSession(repository: server);
      data.dispose();
      data = ChatBrowserData(controller);
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'bot-chat',
          'title': 'Bot Chat',
          'profile': 'personal',
          'hidden': 1,
          'last_active': fixture.now,
        },
      ];
      await data.chooseVisibility(SessionVisibility.all);
      final key = ProfileSessionKey(controller.current!.scope, 'bot-chat');
      expect(data.botAppearance(key)!.shape, 'circle');
      expect(
        fixture.calls.where((call) => call.$2 == 'profiles.list'),
        hasLength(1),
      );
      data.dispose();
      expect(controller.administration(), same(server));
      final roster = await server.gateway('default').call('profiles.list');
      expect(roster['profiles'], isNotEmpty);
    },
  );

  test(
    'appearance failure keeps a readable canonical row and its saved avatar',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'bot-chat',
          'title': 'Bot Chat',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'last_active': fixture.now,
        },
      ];
      fixture.botMetadata['personal'] = {
        'shape': 'hexagon',
        'color': '#ed895b',
      };
      await data.chooseVisibility(SessionVisibility.all);
      final key = ProfileSessionKey(controller.current!.scope, 'bot-chat');
      final saved = data.botAppearance(key);
      expect(saved!.shape, 'hexagon');
      expect(saved.color, '#ed895b');
      fixture.failBotAppearance = true;
      await data.refresh(archivedOnly: false);
      expect(data.botAppearance(key), same(saved));
      expect(
        data.project('').entries.any((row) => row.sessionKey == key),
        true,
      );
      expect(
        data.state.profiles.values.every((profile) => profile.error == null),
        true,
      );
      fixture.failBotAppearance = false;
      fixture.botMetadata['personal'] = {
        'shape': 'triangle',
        'color': '#8b5cf6',
      };
      await data.refresh(archivedOnly: false);
      expect(data.botAppearance(key)!.shape, 'triangle');
      expect(data.botAppearance(key)!.color, '#8b5cf6');
      expect(fixture.calls.where((call) => call.$2 == 'groups.list'), isEmpty);
    },
  );

  test(
    'late avatar read cannot restore a hidden row after a visibility change',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'bot-chat',
          'title': 'Bot Chat',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'last_active': fixture.now,
        },
      ];
      final held = fixture.botAppearanceDelay = Completer<void>();
      final pending = data.chooseVisibility(SessionVisibility.all);
      for (var turn = 0; turn < 100; turn++) {
        if (fixture.calls.any((call) => call.$2 == 'profiles.list')) break;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(fixture.calls.any((call) => call.$2 == 'profiles.list'), true);
      await data.chooseVisibility(SessionVisibility.chats);
      held.complete();
      await pending;
      final key = ProfileSessionKey(controller.current!.scope, 'bot-chat');
      expect(data.botAppearance(key), isNull);
      expect(data.project('').entries.where((row) => row.isBotChat), isEmpty);
      expect(
        fixture.calls.where((call) => call.$2 == 'profiles.list'),
        hasLength(1),
      );
    },
  );

  test(
    'a later desktop hide wins over an already opened canonical runtime',
    () async {
      fixture.rowUpdates[('personal', 'chat-0')] = {'title': 'Bot Chat'};
      await controller.refresh();
      await data.refresh(archivedOnly: false);
      final key = ProfileSessionKey(controller.current!.scope, 'chat-0');
      await controller.openSession(key);
      expect(controller.current!.chats[key.sessionId]!.title, 'Bot Chat');
      expect(
        data
            .project('')
            .entries
            .singleWhere((row) => row.sessionKey == key)
            .isBotChat,
        isTrue,
      );
      fixture.omittedRows.add(('personal', 'chat-0'));
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'chat-0',
          'title': 'Bot Chat',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'last_active': fixture.now,
        },
      ];
      await data.refresh(archivedOnly: false);
      expect(
        data.project('').entries.where((row) => row.sessionKey == key),
        isEmpty,
      );
      await data.chooseVisibility(SessionVisibility.all);
      expect(
        data
            .project('')
            .entries
            .singleWhere((row) => row.sessionKey == key)
            .hidden,
        isTrue,
      );
    },
  );

  test(
    'canonical Bot Chat rejects a different root even when its tip is named Bot Chat',
    () async {
      final base = fixture.gateway(controller.current!.scope);
      final gateway = ProfileGateway(
        scope: base.scope,
        discover: base.discover,
        get: base.read,
        rpc: (method, params) async => method == 'session.list'
            ? {
                'sessions': [
                  {
                    'id': 'ordinary-root',
                    'resolved_id': 'ordinary-tip',
                    'title': 'Bot Chat',
                    'root_title': 'Ordinary conversation',
                  },
                ],
              }
            : base.call(method, params),
      );
      addTearDown(gateway.close);
      await expectLater(gateway.canonicalBotChat(), throwsFormatException);
    },
  );

  test(
    'canonical Bot Chat uses tip accounting without duplicating an open tip',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'bot-root',
          'title': 'Bot Chat',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'input_tokens': 10,
          'last_active': fixture.now - 3600,
        },
        {
          'id': 'bot-tip',
          'title': 'Compressed conversation',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'input_tokens': 23000,
          'output_tokens': 700,
          'last_active': fixture.now,
        },
      ];
      fixture.compressionTips['bot-root'] = 'bot-tip';
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'bot-tip'),
      );
      await data.chooseVisibility(SessionVisibility.all);
      final bots = data.project('').entries.where((row) => row.isBotChat);
      expect(bots, hasLength(1));
      expect(bots.single.id, 'bot-root');
      expect(bots.single.tokens, 23700);
      expect(bots.single.updatedAt, fixture.now);
      expect(
        data.project('').entries.where((row) => row.id == 'bot-tip'),
        isEmpty,
      );
      await data.search('compressed');
      expect(data.project('compressed').entries.map((row) => row.id), [
        'bot-root',
      ]);
      await data.chooseVisibility(SessionVisibility.chats);
      expect(data.project('').entries.where((row) => row.isBotChat), isEmpty);
    },
  );

  test(
    'an opened hidden ordinary chat remains hidden without a bot marker',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'hidden-chat',
          'title': 'Private conversation',
          'profile': 'personal',
          'source': 'tui',
          'hidden': true,
          'last_active': fixture.now,
        },
      ];
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'hidden-chat'),
      );
      await data.refresh(archivedOnly: false);
      expect(
        data.project('').entries.where((row) => row.id == 'hidden-chat'),
        isEmpty,
      );
      await controller.setSessionVisibility(SessionVisibility.all);
      await data.refresh(archivedOnly: false);
      final row = data
          .project('')
          .entries
          .singleWhere((row) => row.id == 'hidden-chat');
      expect(row.isBotChat, isFalse);
    },
  );

  test(
    'search cannot bypass hidden visibility when its wire result omits the flag',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'hidden-search',
          'title': 'Secret result',
          'profile': 'personal',
          'source': 'tui',
          'hidden': 1,
          'last_active': fixture.now,
        },
      ];
      await data.refresh(archivedOnly: false);
      await data.search('secret');
      expect(data.project('secret').entries, isEmpty);
      await data.chooseVisibility(SessionVisibility.all);
      expect(data.project('secret').entries.map((row) => row.id), [
        'hidden-search',
      ]);
      await data.chooseVisibility(SessionVisibility.chats);
      expect(data.project('secret').entries, isEmpty);
    },
  );
  test(
    'retirement from pending observation starts no browser page read',
    () async {
      fixture.attempts.clear();
      data.addListener(() {
        if (data.state.loading) data.dispose();
      });
      await data.refresh(archivedOnly: false);
      expect(fixture.attempts.where((read) => read.$2 == 'sessions'), isEmpty);
    },
  );

  test(
    'projection borrows shared filter facts and keeps row ordering stable',
    () async {
      await data.refresh(archivedOnly: false);
      final before = data
          .project('')
          .groups
          .expand((group) => group.entries)
          .map((entry) => entry.sessionKey)
          .toList();
      expect(
        await data.chooseView(
          BrowserPreferenceIntent.toggle(BrowserFilter.profile, 'work'),
        ),
        BrowserPreferencesSaveOutcome.saved,
      );
      final work = data.project('');
      expect(work.entries, isNotEmpty);
      expect(work.entries.every((entry) => entry.profile == 'work'), isTrue);
      expect(
        work.groups
            .expand((group) => group.entries)
            .map((entry) => entry.sessionKey),
        before.where((key) => key.workspace.profileName == 'work'),
      );
      expect(() => work.entries.clear(), throwsUnsupportedError);
      expect(() => work.groups.first.entries.clear(), throwsUnsupportedError);
      await data.chooseView(const BrowserPreferenceIntent.clearFilters());
      expect(
        data
            .project('')
            .groups
            .expand((group) => group.entries)
            .map((entry) => entry.sessionKey),
        before,
      );
    },
  );

  test(
    'menu catalog owns canonical profile and status choice intents',
    () async {
      await data.refresh(archivedOnly: false);
      final choice = data
          .filterChoices(BrowserFilter.profile)
          .singleWhere((value) => value.id == 'personal');
      expect(choice.selected, isFalse);
      expect(choice.decoration, BrowserChoiceDecoration.profile);
      await data.chooseView(choice.intent);
      expect(
        data
            .filterChoices(BrowserFilter.profile)
            .singleWhere((value) => value.id == 'personal')
            .selected,
        isTrue,
      );
      final status = data.filterChoices(BrowserFilter.status).first;
      expect(status.status, isNotNull);
      expect(status.intent.filter, BrowserFilter.status);
      expect(status.intent.value, status.status!.name);
      final project = data
          .filterChoices(BrowserFilter.project)
          .singleWhere((value) => value.id == 'personal/home');
      expect(project.decoration, BrowserChoiceDecoration.home);
      expect(project.label, '< personal >');
    },
  );

  for (final status in ['unread', 'draft']) {
    test('canonical refresh publishes $status filter membership', () async {
      fixture.rowUpdates[('personal', 'chat-0')] = {
        'unread': status == 'unread',
        'message_count': status == 'draft' ? 0 : 2,
      };
      await data.refresh(archivedOnly: false);
      await data.chooseView(
        BrowserPreferenceIntent.toggle(BrowserFilter.status, status),
      );
      final before = data.project('');
      final key = before.entries.single.sessionKey;
      final published = <List<ChatListEntry>>[];
      data.addListener(() => published.add(data.project('').entries));

      fixture.rowUpdates[('personal', 'chat-0')] = {
        'unread': false,
        'message_count': 2,
      };
      await controller.switchProfile('personal');

      expect(
        data.entries.singleWhere((entry) => entry.sessionKey == key).status,
        isNot(before.entries.single.status),
      );
      expect(data.project('').entries, isEmpty);
      expect(published, isNotEmpty);
      expect(published.last, isEmpty);

      fixture.rowUpdates[('personal', 'chat-0')] = {
        'unread': status == 'unread',
        'message_count': status == 'draft' ? 0 : 2,
      };
      published.clear();
      await controller.switchProfile('personal');
      expect(published, isNotEmpty);
      expect(published.last.map((entry) => entry.sessionKey), [key]);
    });
  }

  for (final field in ['title', 'preview']) {
    test('canonical refresh publishes local $field query membership', () async {
      fixture.rowUpdates[('personal', 'chat-0')] = {field: 'needle match'};
      await data.refresh(archivedOnly: false);
      final key = data.project('needle').entries.single.sessionKey;
      final published = <List<ChatListEntry>>[];
      data.addListener(() => published.add(data.project('needle').entries));

      fixture.rowUpdates[('personal', 'chat-0')] = {field: 'different text'};
      await controller.switchProfile('personal');

      expect(data.entries.any((entry) => entry.sessionKey == key), isTrue);
      expect(data.project('needle').entries, isEmpty);
      expect(published, isNotEmpty);
      expect(published.last, isEmpty);
    });
  }

  test('canonical row changes retain a stable filtered arrangement', () async {
    fixture.rowUpdates[('personal', 'chat-0')] = {
      'title': 'needle before',
      'unread': true,
      'message_count': 2,
    };
    await data.refresh(archivedOnly: false);
    await data.chooseView(
      BrowserPreferenceIntent.toggle(BrowserFilter.status, 'unread'),
    );
    final before = data.project('needle');
    final key = before.entries.single.sessionKey;
    final row = data.row(key);
    var publications = 0;
    var rowPublications = 0;
    data.addListener(() => publications++);
    row.addListener(() => rowPublications++);
    final indexReads = fixture.reads
        .where((read) => read.$1 == 'sessions' && read.$2['limit'] == '100')
        .length;

    fixture.rowUpdates[('personal', 'chat-0')] = {
      'title': 'needle after',
      'unread': true,
      'message_count': 2,
      'input_tokens': 1234,
    };
    await controller.switchProfile('personal');

    expect(data.row(key), same(row));
    expect(row.value.title, 'needle after');
    expect(row.value.tokens, 1234);
    expect(rowPublications, greaterThan(0));
    expect(publications, 0);
    expect(
      data.project('needle').groups.map((group) => group.key),
      before.groups.map((group) => group.key),
    );
    expect(
      fixture.reads
          .where((read) => read.$1 == 'sessions' && read.$2['limit'] == '100')
          .length,
      indexReads,
      reason: 'Canonical refresh adds no browser index read',
    );
  });

  test(
    'project choices follow single, multiple and cleared profile filters',
    () async {
      await data.refresh(archivedOnly: false);
      Set<String> projectIds() => data
          .filterChoices(BrowserFilter.project)
          .map((choice) => choice.id)
          .toSet();
      final all = projectIds();
      expect(all.where((id) => id.startsWith('personal/')), isNotEmpty);
      expect(all.where((id) => id.startsWith('work/')), isNotEmpty);

      await data.chooseView(BrowserPreferenceIntent.exclusiveProfile('work'));
      expect(projectIds(), all.where((id) => id.startsWith('work/')).toSet());
      expect(projectIds(), contains('work/home'));

      await data.chooseView(
        BrowserPreferenceIntent.exclusiveProfile('personal'),
      );
      expect(
        projectIds(),
        all.where((id) => id.startsWith('personal/')).toSet(),
      );

      await data.chooseView(
        BrowserPreferenceIntent.toggle(BrowserFilter.profile, 'work'),
      );
      expect(projectIds(), all);

      await data.chooseView(
        const BrowserPreferenceIntent.clear(BrowserFilter.profile),
      );
      expect(projectIds(), all);
    },
  );

  test(
    'invalid saved view has a neutral projection and explicit reset',
    () async {
      await data.refresh(archivedOnly: false);
      final key = ChatBrowserPreferencesCodec.storageKey('test');
      await controller.preferences.setString(key, '{');
      await appPreferences.reload();
      final projection = data.project('');
      expect(data.viewPreferences.validity, BrowserPreferencesValidity.invalid);
      expect(data.viewPreferences.display, isNull);
      expect(projection.entries.length, data.entries.length);
      expect(projection.groups.single.key, 'all');
      expect(projection.groups.single.label, 'Chats');
      expect(controller.preferences.getString(key), '{');
      expect(
        await data.chooseView(const BrowserPreferenceIntent.reset()),
        BrowserPreferencesSaveOutcome.saved,
      );
      expect(data.viewPreferences.display!.grouping, ChatGrouping.project);
      expect(
        data.project('').groups.map((group) => group.key),
        isNot(contains('all')),
      );
    },
  );

  test(
    'disposing browser consumer leaves borrowed preference owner usable',
    () async {
      final channel = appPreferences.browserPreferencesFor('test');
      data.dispose();
      expect(
        await appPreferences.chooseBrowserPreferences(
          'test',
          BrowserPreferenceIntent.toggle(BrowserFilter.profile, 'work'),
        ),
        BrowserPreferencesSaveOutcome.saved,
      );
      expect(channel.value.confirmed!.profiles, {'work'});
      data = ChatBrowserData(
        controller,
        readBotAppearances: fixture.botAppearances,
      );
      await data.refresh(archivedOnly: false);
      expect(
        data.project('').entries.every((entry) => entry.profile == 'work'),
        isTrue,
      );
    },
  );

  test(
    'query matching belongs to the projection without mutating saved filters',
    () async {
      await data.refresh(archivedOnly: false);
      final before = data.viewPreferences.confirmed;
      final matches = data.project('chat 1').entries;
      expect(matches, isNotEmpty);
      expect(
        matches.every(
          (entry) => '${entry.title} ${entry.preview}'.toLowerCase().contains(
            'chat 1',
          ),
        ),
        isTrue,
      );
      expect(data.viewPreferences.confirmed, same(before));
      expect(
        controller.preferences.containsKey(
          ChatBrowserPreferencesCodec.storageKey('test'),
        ),
        isFalse,
      );
    },
  );
  test(
    'removed rows retire after listeners detach and reappearing keys reuse them',
    () async {
      await data.refresh(archivedOnly: false);
      final key = data.entries.first.sessionKey;
      final row = data.row(key);
      void listener() {}
      row.addListener(listener);
      fixture.omittedRows.add((key.workspace.profileName, key.sessionId));
      await controller.switchProfile('personal');
      await data.refresh(archivedOnly: false);
      expect(data.entries.any((entry) => entry.sessionKey == key), isFalse);
      expect(data.retainedRowCount, data.entries.length + 1);
      fixture.omittedRows.remove((key.workspace.profileName, key.sessionId));
      await controller.switchProfile('personal');
      await data.refresh(archivedOnly: false);
      expect(data.row(key), same(row));
      row.removeListener(listener);
      fixture.omittedRows.add((key.workspace.profileName, key.sessionId));
      await controller.switchProfile('personal');
      await data.refresh(archivedOnly: false);
      expect(data.retainedRowCount, data.entries.length);
    },
  );

  test('increasing replacement datasets retain only current rows', () async {
    for (var cycle = 0; cycle < 12; cycle++) {
      fixture.count = 125 + cycle * 25;
      await data.refresh(archivedOnly: false);
      final keys = data.entries.map((entry) => entry.sessionKey).toList();
      fixture.omittedRows.addAll([
        for (final key in keys) (key.workspace.profileName, key.sessionId),
      ]);
      await controller.switchProfile('personal');
      await data.refresh(archivedOnly: false);
      expect(data.entries, isEmpty);
      expect(data.retainedRowCount, 0);
      fixture.omittedRows.clear();
    }
  });
  test(
    'recovery reads only failed profiles and retains healthy search results',
    () async {
      fixture.failWorkIndex = true;
      await data.refresh(archivedOnly: false);
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.error != null)
            .map((entry) => entry.key),
        ['work'],
      );
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet(),
        {'personal'},
      );
      fixture.failWorkSearch = true;
      await data.search('chat 1');
      final healthyMatches = data.state.profiles['personal']?.searchMatches;
      expect(healthyMatches, isNotEmpty);
      final healthyEntries = data
          .project('chat 1')
          .entries
          .where((entry) => entry.profile == 'personal')
          .map((entry) => (entry.sessionKey, entry.title, entry.preview))
          .toList();
      expect(healthyEntries, isNotEmpty);
      expect(data.needsRecovery, isTrue);
      fixture.failWorkIndex = false;
      fixture.failWorkSearch = false;
      fixture.attempts.clear();
      await data.recover();
      expect(fixture.attempts, isNotEmpty);
      expect(fixture.attempts.every((r) => r.$1 == 'work'), isTrue);
      expect(
        data.state.profiles['personal']?.searchMatches,
        equals(healthyMatches),
      );
      expect(data.state.profiles['work']?.searchMatches, isNotEmpty);
      expect(
        data
            .project('chat 1')
            .entries
            .where((entry) => entry.profile == 'personal')
            .map((entry) => (entry.sessionKey, entry.title, entry.preview)),
        healthyEntries,
      );
      expect(
        data.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
      expect(data.state.searchError, isNull);
      expect(data.needsRecovery, isFalse);
    },
  );

  test(
    'new query supersedes an in-flight recovery and permanent errors do not recover',
    () async {
      fixture.failWorkSearch = true;
      await data.search('chat 1');
      fixture.failWorkSearch = false;
      final gate = Completer<void>();
      fixture.searchDelays['chat 1'] = gate;
      final recovery = data.recover();
      await data.search('chat 2');
      final latest = data.state.profiles['work']?.searchMatches;
      final latestEntries = data
          .project('chat 2')
          .entries
          .where((entry) => entry.profile == 'work')
          .map((entry) => (entry.sessionKey, entry.title, entry.preview))
          .toList();
      expect(latestEntries, isNotEmpty);
      gate.complete();
      await recovery;
      expect(data.state.profiles['work']?.searchMatches, equals(latest));
      expect(
        data
            .project('chat 2')
            .entries
            .where((entry) => entry.profile == 'work')
            .map((entry) => (entry.sessionKey, entry.title, entry.preview)),
        latestEntries,
      );
      expect(
        data
            .project('chat 2')
            .entries
            .where((entry) => entry.profile == 'work')
            .every((entry) => entry.title.contains('chat 2')),
        isTrue,
      );
      fixture.failWorkSearch = true;
      fixture.permanentSearchFailure = true;
      await data.search('chat 3');
      expect(data.state.searchError, isNotNull);
      expect(data.needsRecovery, isFalse);
      fixture.attempts.clear();
      await data.recover();
      expect(fixture.attempts, isEmpty);
    },
  );

  test(
    'paging deduplicates pin backfills without touching navigation or live sockets',
    () async {
      final live = {...fixture.opened};
      final owner = controller.current;
      await data.refresh(archivedOnly: false);
      expect(data.entries.length, 250);
      expect(data.entries.map((e) => e.key).toSet().length, 250);
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet(),
        {'personal', 'work'},
      );
      expect(controller.current, same(owner));
      expect(fixture.closed.intersection(live), isEmpty);
      expect(fixture.opened.difference(live), fixture.closed);
      expect(
        fixture.reads
            .where((r) => r.$1 == 'sessions' && r.$2['limit'] == '100')
            .length,
        4,
      );
    },
  );
  test('overlapping refreshes share the same profile reads', () async {
    final gate = Completer<void>();
    fixture.pageDelays[('personal', 0)] = gate;
    fixture.pageDelays[('work', 0)] = gate;
    final first = data.refresh(archivedOnly: false);
    final second = data.refresh(archivedOnly: false);
    await Future<void>.delayed(Duration.zero);
    final initialReads = fixture.reads
        .where(
          (r) =>
              r.$1 == 'sessions' &&
              r.$2['limit'] == '100' &&
              r.$2['offset'] == '0',
        )
        .length;
    gate.complete();
    await Future.wait([first, second]);
    expect(initialReads, 2, reason: 'one request per profile while refreshing');
    expect(
      data.state.profiles.entries
          .where((entry) => entry.value.complete)
          .map((entry) => entry.key)
          .toSet(),
      {'personal', 'work'},
    );
  });

  test(
    'refresh retains the complete list until replacement pages are ready',
    () async {
      await data.refresh(archivedOnly: false);
      final previous = data.entries
          .where((entry) => entry.profile == 'personal')
          .map((entry) => entry.sessionKey)
          .toList();
      final gate = Completer<void>();
      fixture.pageDelays[('personal', 100)] = gate;
      fixture.prepend = true;
      final refreshing = data.refresh(archivedOnly: false);
      await Future<void>.delayed(Duration.zero);
      final during = data.entries
          .where((entry) => entry.profile == 'personal')
          .map((entry) => entry.sessionKey)
          .toList();
      gate.complete();
      await refreshing;
      expect(
        during,
        equals(previous),
        reason: 'do not collapse and regrow the list during refresh',
      );
      expect(
        data.entries.where((entry) => entry.profile == 'personal').length,
        126,
      );
    },
  );

  test('refresh publication does not grow with the number of pages', () async {
    await data.refresh(archivedOnly: false);
    var publications = 0;
    data.addListener(() => publications++);
    await data.refresh(archivedOnly: false);
    final baseline = publications;
    expect(baseline, greaterThan(0));
    publications = 0;
    fixture.count = 1000;
    await data.refresh(archivedOnly: false);
    expect(data.entries.length, 2000);
    expect(
      publications,
      lessThanOrEqualTo(baseline),
      reason: 'more pages must not produce per-page publications',
    );
  });

  test(
    'temporary page and project failures recover without manual refresh',
    () async {
      fixture.failNextPage = true;
      fixture.failNextTree = true;
      await data.refresh(archivedOnly: false);
      expect(fixture.failNextPage, isFalse);
      expect(fixture.failNextTree, isFalse);
      expect(
        data.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet(),
        {'personal', 'work'},
      );
      expect(data.entries.length, 250);
    },
  );

  test(
    'failed later page leaves readable data but never a complete total',
    () async {
      fixture.pageFailures.add(('personal', 100));
      await data.refresh(archivedOnly: false);
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.error != null)
            .map((entry) => entry.key),
        contains('personal'),
      );
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet(),
        isNot(contains('personal')),
      );
      expect(data.entries.where((e) => e.profile == 'personal'), isNotEmpty);
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet(),
        contains('work'),
      );
      fixture.pageFailures.clear();
      await data.refresh(archivedOnly: false);
      expect(
        data.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
      expect(
        data.state.profiles.entries
            .where((entry) => entry.value.complete)
            .map((entry) => entry.key)
            .toSet()
            .length,
        2,
      );
    },
  );
  test(
    'an old page cannot repopulate the active list after switching to archive',
    () async {
      final gate = Completer<void>();
      fixture.pageDelays[('personal', 0)] = gate;
      final old = data.refresh(archivedOnly: false);
      await Future<void>.delayed(Duration.zero);
      fixture.pageDelays.remove(('personal', 0));
      await data.refresh(archivedOnly: true);
      gate.complete();
      await old;
      expect(data.state.archived, isTrue);
      expect(data.entries, isEmpty);
    },
  );
  test('a stale search cannot replace newer results', () async {
    await data.refresh(archivedOnly: false);
    final gate = Completer<void>();
    fixture.searchDelays['old'] = gate;
    final old = data.search('old');
    await data.search('chat 110');
    gate.complete();
    await old;
    expect(data.state.profiles['personal']?.searchMatches, {'chat-110'});
    expect(data.state.profiles['work']?.searchMatches, {'chat-110'});
  });
  test(
    'disposing prevents late publication and still closes temporary readers',
    () async {
      final live = {...fixture.opened};
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      fixture.connectionDelays['work'] = gate;
      fixture.connectionEntered = Completer<void>();
      final pending = data.refresh(archivedOnly: false);
      await fixture.connectionEntered!.future;
      final temporary = fixture.opened.difference(live);
      expect(temporary, isNotEmpty);
      final retainedKeys = data.entries.map((entry) => entry.key).toList();
      final completedProfiles = {
        for (final entry in data.state.profiles.entries)
          if (entry.value.complete) entry.key,
      };
      data.dispose();
      gate.complete();
      await pending;
      expect(data.entries.map((entry) => entry.key), retainedKeys);
      expect({
        for (final entry in data.state.profiles.entries)
          if (entry.value.complete) entry.key,
      }, completedProfiles);
      expect(fixture.closed, containsAll(temporary));
      expect(fixture.closed.intersection(live), isEmpty);
      // Replace only for the common teardown, after checking retirement.
      data = ChatBrowserData(
        controller,
        readBotAppearances: fixture.botAppearances,
      );
      expect(controller.current!.scope.profileName, 'personal');
    },
  );
}
