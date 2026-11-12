import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/group_notification.dart';
import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/background_monitoring_service.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'package:wing/core/services/group_notification_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'support/bots_fixture.dart';
import 'support/recording_turn_notification_sink.dart';

class _NotificationStorage extends InMemorySharedPreferencesStore {
  _NotificationStorage() : super.empty();
  bool rejectPending = false, rejectCursors = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if ((rejectPending &&
            key.startsWith('flutter.group_notification_pending_sends/')) ||
        (rejectCursors &&
            key.startsWith('flutter.group_notification_sequences/'))) {
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

class GroupHost {
  final states = <String, Map<String, dynamic>>{};
  final logs = <String, List<Map<String, dynamic>>>{};
  final calls = <String>[];
  bool fail = false;
  Completer<void>? heldState;
  void room(
    String id, {
    bool working = false,
    bool blocked = false,
    int latest = 0,
  }) {
    states[id] = {
      'room': {
        'room_id': id,
        'name': 'Group $id',
        'latest_seq': latest,
        'members': <Map<String, dynamic>>[],
      },
      'driver_status': {
        'working': working,
        'blocked': blocked,
        'pending_actions': <Map<String, dynamic>>[],
      },
    };
  }

  void event(
    String id,
    int seq,
    String kind,
    String text, {
    String? clientEventId,
  }) {
    logs.putIfAbsent(id, () => []).add({
      'room_id': id,
      'seq': seq,
      'created_at': 1791936000.0 + seq,
      'actor': {'id': 'member', 'kind': 'member', 'display_name': 'Member'},
      'event_id': clientEventId == null
          ? 'event-$seq'
          : BotsRepository.groupUserEventId(clientEventId),
      'kind': kind,
      'payload': {'text': text},
    });
    states[id]!['room']['latest_seq'] = seq;
  }

  Future<Map<String, dynamic>> read(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add(method);
    if (fail) throw StateError('Unavailable');
    if (method == 'groups.list') {
      return {
        'rooms': [
          for (final id in states.keys) {'room_id': id, 'name': 'Group $id'},
        ],
        'next_offset': null,
      };
    }
    final id = params['room_id'] as String;
    if (method == 'groups.state') {
      await heldState?.future;
      return states[id]!;
    }
    final since = params['since_seq'] as int;
    final events = (logs[id] ?? [])
        .where((e) => e['seq'] > since)
        .take(params['limit'] as int)
        .toList();
    final cursor = events.isEmpty ? since : events.last['seq'] as int;
    return {
      'events': events,
      'cursor': cursor,
      'latest_seq': states[id]!['room']['latest_seq'],
      'has_more': cursor < states[id]!['room']['latest_seq'],
      'authority': {'gateway_id': 'fixture', 'epoch': 1},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = WorkspaceScope(
    connectionId: 'host',
    connectionIdentity: 'owner',
    profileName: 'default',
  );
  late SharedPreferences prefs;
  late AppPreferences app;
  late RecordingTurnNotificationSink sink;
  late ChatNotificationCoordinator notices;
  late GroupHost host;
  late GroupNotificationSession watch;
  late _NotificationStorage storage;
  Completer<void>? delivery;
  bool failDelivery = false;
  var postsStarted = 0;
  final decisions = <Map<String, dynamic>>[];
  Completer<void>? heldDecision;
  late Completer<void> decisionStarted;
  late Completer<void> postStarted;
  bool failDecision = false;
  GroupNotificationSession create({WorkspaceScope? key}) =>
      GroupNotificationSession(
        observations: GroupObservations(key ?? scope),
        scope: key ?? scope,
        instance: 'Host',
        preferences: prefs,
        read: host.read,
        command: (method, params) async {
          expect(method, 'groups.approve');
          decisions.add(params);
          if (!decisionStarted.isCompleted) decisionStarted.complete();
          await heldDecision?.future;
          if (failDecision) throw StateError('Decision failed');
          host.states[params['room_id']]!['driver_status']['pending_actions'] =
              <Map<String, dynamic>>[];
          return {'approved': true};
        },
        publishInputs: notices.receiveGroupInputs,
        pollInterval: const Duration(days: 1),
        publish: (answer) async {
          postsStarted++;
          if (!postStarted.isCompleted) postStarted.complete();
          await delivery?.future;
          if (failDelivery) throw StateError('Posting failed');
          await notices.receiveGroupAnswer(answer);
        },
        clearRead: notices.readGroupAnswer,
      );
  Future<void> restartWatch() async {
    watch.dispose();
    SharedPreferences.resetStatic();
    prefs = await SharedPreferences.getInstance();
    watch = create();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = _NotificationStorage();
    SharedPreferencesStorePlatform.instance = storage;
    prefs = await SharedPreferences.getInstance();
    app = AppPreferences(prefs);
    sink = RecordingTurnNotificationSink();
    notices = ChatNotificationCoordinator(prefs, sink, appPreferences: app);
    host = GroupHost()..room('one');
    watch = create();
    delivery = null;
    failDelivery = false;
    postsStarted = 0;
    decisions.clear();
    heldDecision = null;
    decisionStarted = Completer<void>();
    postStarted = Completer<void>();
    failDecision = false;
  });
  tearDown(() {
    watch.dispose();
    app.dispose();
  });

  void approval({int generation = 1}) {
    host.states['one']!['driver_status'] = {
      'working': true,
      'blocked': true,
      'pending_actions': [
        {
          'kind': 'approval',
          'task_id': 'task',
          'member_id': 'atlas',
          'request_id': 'request',
          'execution_generation': generation,
          'approval': {
            'command': '<write to AGENTS.md>',
            'description': 'Protected agent instructions',
            'choices': ['once', 'deny'],
          },
        },
      ],
    };
  }

  test(
    'group approvals alert on discovery, survive replies and read receipts, and settle independently',
    () async {
      approval();
      await watch.activate();
      final notice = sink.shown.last;
      expect(notice.focus!.kind, 'approval');
      expect(notice.choices, ['once', 'deny']);
      expect(notice.expandedBody, '<write to AGENTS.md>');
      expect(
        BotsPreferences(
          prefs,
        ).questions(scope.connectionIdentity, 'one').questions.single.command,
        notice.expandedBody,
      );
      expect(watch.hasActiveGroups, true);
      final count = sink.shown.length;
      await watch.refresh();
      expect(sink.shown.length, lessThanOrEqualTo(count + 1));
      expect(sink.shown.last.alert, false);
      host.event('one', 1, 'message.member', 'Another bot has replied');
      await watch.refresh();
      expect(sink.shown.last.focus!.kind, 'approval');
      await notices.readGroupAnswer(GroupNotificationTarget(scope, 'one'), 1);
      expect(sink.shown.last.focus!.kind, 'approval');
      host.room('one', latest: 1);
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!), isNull);
      expect(
        BotsPreferences(
          prefs,
        ).questions(scope.connectionIdentity, 'one').questions,
        hasLength(1),
      );
    },
  );

  test(
    'native group decisions show retained progress, exclude repeats and submit exact authority',
    () async {
      approval();
      await watch.activate();
      final notice = sink.shown.last;
      heldDecision = Completer<void>();
      final decision = watch.resolveApproval(
        'one',
        notice.focus!.id,
        'once',
        notice.expandedBody,
      );
      await decisionStarted.future;
      expect(sink.shown.last.submitting, true);
      expect(
        await watch.resolveApproval(
          'one',
          notice.focus!.id,
          'once',
          notice.expandedBody,
        ),
        false,
      );
      expect(decisions.single, {
        'room_id': 'one',
        'task_id': 'task',
        'member_id': 'atlas',
        'request_id': 'request',
        'execution_generation': 1,
        'choice': 'once',
      });
      heldDecision!.complete();
      expect(await decision, true);
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!), isNull);
      expect(
        BotsPreferences(
          prefs,
        ).questions(scope.connectionIdentity, 'one').questions.single.status,
        HermesQuestionStatus.approved,
      );
    },
  );

  test('native group decisions reject stale generations', () async {
    approval();
    await watch.activate();
    final notice = sink.shown.last;
    approval(generation: 2);
    expect(
      await watch.resolveApproval(
        'one',
        notice.focus!.id,
        'once',
        notice.expandedBody,
      ),
      false,
    );
    expect(decisions, isEmpty);
  });

  test('native group decisions reject broad approval scopes', () async {
    approval();
    await watch.activate();
    final notice = sink.shown.last;
    expect(
      await watch.resolveApproval(
        'one',
        notice.focus!.id,
        'session',
        notice.expandedBody,
      ),
      false,
    );
    expect(decisions, isEmpty);
  });

  test('native group decisions reject changed commands', () async {
    approval();
    await watch.activate();
    final notice = sink.shown.last;
    await expectLater(
      watch.resolveApproval(
        'one',
        notice.focus!.id,
        'once',
        'different command',
      ),
      throwsStateError,
    );
    expect(decisions, isEmpty);
  });

  test(
    'failed native group decision clears progress and permits retry',
    () async {
      approval();
      await watch.activate();
      final notice = sink.shown.last;
      failDecision = true;
      await expectLater(
        watch.resolveApproval('one', notice.focus!.id, 'deny', null),
        throwsStateError,
      );
      expect(sink.shown.last.submitting, false);
      expect(sink.shown.last.actionError, contains('Decision not confirmed'));
      failDecision = false;
      expect(
        await watch.resolveApproval('one', notice.focus!.id, 'deny', null),
        true,
      );
      expect(decisions, hasLength(2));
    },
  );

  test(
    'desktop-cleared group approval cannot return as a notification on replay',
    () async {
      approval();
      await watch.activate();
      final notice = sink.shown.last;
      host.room('one');
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!), isNull);
      approval();
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!), isNull);
      expect(
        await watch.resolveApproval(
          'one',
          notice.focus!.id,
          'once',
          notice.expandedBody,
        ),
        false,
      );
      expect(decisions, isEmpty);
      approval(generation: 2);
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!), isNotNull);
    },
  );

  test(
    'unavailable group reads retain pending approval notification',
    () async {
      approval();
      await watch.activate();
      final notice = sink.shown.last;
      host.fail = true;
      await watch.refresh();
      expect(notices.inputFor(notice.chatIdentity!)!.focus, notice.focus);
      expect(watch.hasActiveGroups, true);
    },
  );

  test(
    'already-read replies publish timestamp and text without notifications or cues',
    () async {
      await watch.activate();
      await prefs.setString(
        'bots_group_read_sequences',
        jsonEncode({'owner/one': 1}),
      );
      host.event('one', 1, 'message.member', 'Read in discussion');
      await watch.refresh();
      final observed = watch.observations.forRoom('one')!;
      expect(observed.message!.text, 'Read in discussion');
      expect(observed.message!.timestamp.millisecondsSinceEpoch, 1791936001000);
      expect(observed.answer!.sequence, 1);
      expect(observed.gatewayId, 'fixture');
      expect(observed.epoch, 1);
      expect(sink.shown, isEmpty);
      expect(notices.activity.value, isNull);
    },
  );

  test(
    'malformed member text cannot advance delivery cursor or suppress replay',
    () async {
      await watch.activate();
      host.event('one', 1, 'message.member', 'Will recover');
      host.logs['one']!.single['payload'] = {'text': null};
      await watch.refresh();
      expect(watch.hasActiveGroups, isTrue);
      expect(sink.shown, isEmpty);
      expect(watch.observations.forRoom('one')!.answer, isNull);
      host.logs['one']!.single['payload'] = {'text': 'Recovered answer'};
      await watch.refresh();
      expect(sink.shown.single.body, contains('Recovered answer'));
      expect(
        watch.observations.forRoom('one')!.answer!.text,
        'Recovered answer',
      );
    },
  );

  test(
    'failed first-send journal admission releases its lease before physical dispatch',
    () async {
      storage.rejectPending = true;
      await expectLater(
        watch.beginSend('one', 'Group one', 'not-admitted'),
        throwsStateError,
      );
      expect(watch.hasActiveGroups, false);
      storage.rejectPending = false;
      host.event('one', 1, 'message.member', 'Historical');
      await watch.activate();
      expect(sink.shown, isEmpty);
    },
  );

  test(
    'failed accepted-sequence persistence retains first-send replay without revoking acknowledgement',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'accepted-send');
      await watch.activate();
      storage.rejectCursors = true;
      await watch.endSend(
        'one',
        'accepted-send',
        dispatched: true,
        sequence: 1,
      );
      expect(watch.hasActiveGroups, true);
      expect(sink.shown, isEmpty);
      storage.rejectCursors = false;
      host.fail = false;
      host.event(
        'one',
        1,
        'message.user',
        'Hello',
        clientEventId: 'accepted-send',
      );
      host.event('one', 2, 'message.member', 'Recovered answer');
      await watch.refresh();
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('Recovered answer'));
      expect(watch.hasActiveGroups, false);
      await restartWatch();
      await watch.activate();
      expect(sink.shown, hasLength(1));
    },
  );

  test(
    'known-unsent cleanup retries a failed pending journal write and stays quiet after restart',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'unsent');
      await watch.activate();
      storage.rejectPending = true;
      await watch.endSend('one', 'unsent', dispatched: false);
      expect(watch.hasActiveGroups, true);
      storage.rejectPending = false;
      host.fail = false;
      host.event('one', 1, 'message.member', 'Historical');
      await watch.refresh();
      expect(watch.hasActiveGroups, false);
      expect(sink.shown, isEmpty);
      await restartWatch();
      await watch.activate();
      expect(watch.hasActiveGroups, false);
      expect(sink.shown, isEmpty);
    },
  );

  test(
    'acknowledged first send alerts after a failed baseline and leaves historical answers quiet',
    () async {
      host.event('one', 1, 'message.member', 'Historical');
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'first-send');
      await watch.activate();
      expect(watch.hasActiveGroups, true);
      host.fail = false;
      host.event(
        'one',
        2,
        'message.user',
        'Hello',
        clientEventId: 'first-send',
      );
      host.event('one', 3, 'message.member', 'First new answer');
      await watch.endSend('one', 'first-send', dispatched: true, sequence: 2);
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('First new answer'));
      expect(watch.hasActiveGroups, false);
      await restartWatch();
      await watch.activate();
      expect(sink.shown, hasLength(1));
    },
  );

  test(
    'a lost first-send acknowledgement survives restart and finds its exact stock event across pages',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'lost-send');
      await watch.activate();
      await watch.endSend('one', 'lost-send', dispatched: true);
      watch.setForeground(false);
      expect(watch.hasActiveGroups, true);
      await restartWatch();
      expect(watch.hasActiveGroups, true);
      host.fail = false;
      for (var seq = 1; seq <= 120; seq++) {
        host.event('one', seq, 'message.member', 'Historical $seq');
      }
      host.event(
        'one',
        121,
        'message.user',
        'Hello',
        clientEventId: 'lost-send',
      );
      host.event('one', 122, 'message.member', 'Recovered new answer');
      await watch.activate();
      expect(
        host.calls.where((method) => method == 'groups.log'),
        hasLength(2),
      );
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('Recovered new answer'));
      expect(watch.hasActiveGroups, false);
      await restartWatch();
      await watch.activate();
      expect(sink.shown, hasLength(1));
    },
  );

  test(
    'unknown first-send acceptance retains work through unrelated answers and stops on exact recovery',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'pending-send');
      await watch.activate();
      await watch.endSend('one', 'pending-send', dispatched: true);
      host.fail = false;
      host.event(
        'one',
        1,
        'message.user',
        'Other send',
        clientEventId: 'other-send',
      );
      host.event('one', 2, 'message.member', 'Other answer');
      await watch.refresh();
      expect(watch.hasActiveGroups, true);
      expect(sink.shown, isEmpty);
      host.event(
        'one',
        3,
        'message.user',
        'Our send',
        clientEventId: 'pending-send',
      );
      host.event('one', 4, 'message.member', 'Our answer');
      await watch.refresh();
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('Our answer'));
      expect(watch.hasActiveGroups, false);
    },
  );

  test(
    'read receipts and delivery retry retain first-send recovery ordering',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'first-send');
      await watch.activate();
      host.fail = false;
      host.event(
        'one',
        1,
        'message.user',
        'Hello',
        clientEventId: 'first-send',
      );
      host.event('one', 2, 'message.member', 'Read new answer');
      failDelivery = true;
      await watch.endSend('one', 'first-send', dispatched: true);
      expect(sink.shown, isEmpty);
      expect(watch.hasActiveGroups, true);
      await prefs.setString(
        'bots_group_read_sequences',
        jsonEncode({'owner/one': 2}),
      );
      failDelivery = false;
      await watch.refresh();
      expect(sink.shown, isEmpty);
      expect(watch.hasActiveGroups, false);
      await restartWatch();
      await watch.activate();
      expect(sink.shown, isEmpty);
    },
  );

  test(
    'known-unsent first send removes durable uncertainty before quiet discovery',
    () async {
      host.fail = true;
      await watch.beginSend('one', 'Group one', 'unsent');
      await watch.activate();
      host.fail = false;
      host.event('one', 1, 'message.member', 'Historical');
      await watch.endSend('one', 'unsent', dispatched: false);
      expect(watch.hasActiveGroups, false);
      expect(sink.shown, isEmpty);
      await restartWatch();
      await watch.activate();
      expect(watch.hasActiveGroups, false);
      expect(sink.shown, isEmpty);
    },
  );

  test(
    'production group send passes its acknowledged stock sequence into notification recovery',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      host.states.clear();
      host.room(group.id);
      host.fail = true;
      fixture.commandHook = (_, method, params) async {
        if (method == 'groups.send') {
          host.fail = false;
          host.event(
            group.id,
            1,
            'message.user',
            'Hello',
            clientEventId: params['event_id'] as String,
          );
          host.event(group.id, 2, 'message.member', 'Fast stock answer');
        }
        return null;
      };
      final session = BotGroupSession(
        fixture.repository,
        group,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: BotsPreferences(prefs),
        groupMessages: null,
        beforeSend: (group, eventId) async {
          await watch.beginSend(group.id, group.name, eventId);
          await watch.activate();
        },
        afterSend: (group, outcome) => watch.endSend(
          group.id,
          outcome.eventId,
          dispatched: outcome.dispatched,
          sequence: outcome.sequence,
        ),
      );
      addTearDown(session.dispose);
      expect(await session.send('Hello'), true);
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('Fast stock answer'));
      expect(watch.hasActiveGroups, false);
    },
  );

  test(
    'working group survives idle bot gaps while backgrounded until its final notification',
    () async {
      var foreground = true, running = false;
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BackgroundMonitoringService.channel, (
            call,
          ) async {
            methods.add(call.method);
            if (call.method == 'stop') running = false;
            if (call.method == 'start' && foreground) running = true;
            return {'running': running, 'batteryUnrestricted': true};
          });
      final service = BackgroundMonitoringService(
        preferences: app,
        supported: true,
        hasActiveChats: () => watch.hasActiveGroups,
        notificationsEnabled: () async => true,
      );
      void changed() => unawaited(service.sync());
      watch.addListener(changed);
      addTearDown(() async {
        watch.removeListener(changed);
        service.dispose();
        await service.sync();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              BackgroundMonitoringService.channel,
              null,
            );
      });
      host.room('one', working: true);
      await watch.activate();
      await service.sync();
      expect(service.state.value, BackgroundMonitoringState.active);
      foreground = false;
      watch.setForeground(false);
      final starts = methods.where((m) => m == 'stop').length;
      await watch.refresh();
      await watch.refresh();
      await service.sync();
      expect(methods.where((m) => m == 'stop').length, starts);
      expect(running, isTrue);
      delivery = Completer<void>();
      host.room('one');
      host.event('one', 1, 'message.member', 'Shared final answer');
      final finishing = watch.refresh();
      await postStarted.future;
      expect(postsStarted, 1);
      expect(watch.hasActiveGroups, isTrue);
      await service.sync();
      expect(running, isTrue);
      delivery!.complete();
      await finishing;
      await service.sync();
      expect(watch.hasActiveGroups, isFalse);
      expect(running, isFalse);
      expect(sink.shown.single.body, contains('Shared final answer'));
    },
  );

  test(
    'new group replies replace one stable slot; room activity never becomes an answer',
    () async {
      await watch.activate();
      host.event('one', 1, 'message.member', 'First');
      await watch.refresh();
      host.event('one', 2, 'room.activity', 'Quiet status');
      await watch.refresh();
      host.event('one', 3, 'message.member', 'Latest');
      await watch.refresh();
      expect(sink.shown, hasLength(2));
      expect(sink.shown.first.id, sink.shown.last.id);
      expect(sink.shown.last.body, contains('Latest'));
      final target =
          jsonDecode(sink.shown.last.payload) as Map<String, dynamic>;
      expect(target['room'], 'one');
      expect(target.containsKey('session'), isFalse);
      await watch.refresh();
      expect(sink.shown, hasLength(2));
    },
  );

  test(
    'failed delivery retains monitoring and retries without duplicating a successful reply',
    () async {
      await watch.activate();
      host.room('one', working: true);
      await watch.refresh();
      host.room('one');
      host.event('one', 1, 'message.member', 'Final');
      failDelivery = true;
      await watch.refresh();
      expect(watch.hasActiveGroups, isTrue);
      expect(sink.shown, isEmpty);
      expect(watch.monitoringGroups.single.state, 'reconnecting');
      failDelivery = false;
      await watch.refresh();
      expect(watch.hasActiveGroups, isFalse);
      expect(sink.shown, hasLength(1));
      await watch.refresh();
      expect(sink.shown, hasLength(1));
    },
  );

  test('failed or missing room observations retain verified work', () async {
    host.room('one', working: true);
    await watch.activate();
    host.fail = true;
    await watch.refresh();
    expect(watch.hasActiveGroups, isTrue);
    host.fail = false;
    host.states.clear();
    await watch.refresh();
    expect(watch.hasActiveGroups, isTrue);
    host.room('one');
    await watch.refresh();
    expect(watch.hasActiveGroups, isFalse);
  });

  test('another group and blocked group retain their own lifetimes', () async {
    host.room('one', working: true);
    host.room('two', working: true);
    await watch.activate();
    host.room('one');
    await watch.refresh();
    expect(watch.monitoringGroups.single.title, 'Group two');
    host.room('two', blocked: true);
    await watch.refresh();
    expect(watch.hasActiveGroups, isTrue);
    expect(watch.monitoringGroups.single.state, 'needs input');
    host.room('two');
    await watch.refresh();
    expect(watch.hasActiveGroups, isFalse);
  });

  test(
    'quiet first baseline and persisted replay discover replies after restart',
    () async {
      host.event('one', 1, 'message.member', 'Historical');
      await watch.activate();
      expect(sink.shown, isEmpty);
      watch.dispose();
      host.event('one', 2, 'message.member', 'While away');
      watch = create();
      await watch.activate();
      expect(sink.shown, hasLength(1));
      await restartWatch();
      await watch.activate();
      expect(sink.shown, hasLength(1));
    },
  );

  test(
    'viewport receipts clear only reached replies and suppress read replay',
    () async {
      await watch.activate();
      host.event('one', 1, 'message.member', 'One');
      await watch.refresh();
      host.event('one', 2, 'message.member', 'Two');
      await watch.refresh();
      await watch.acknowledge('one', 1);
      expect(sink.cancelled, isEmpty);
      await watch.acknowledge('one', 2);
      expect(sink.cancelled.single, sink.shown.last.id);
      await prefs.setString(
        'bots_group_read_sequences',
        jsonEncode({'owner/one': 3}),
      );
      host.event('one', 3, 'message.member', 'Already read');
      await watch.refresh();
      expect(sink.shown, hasLength(2));
    },
  );

  test(
    'authenticated connection and group identity keep notification slots separate',
    () async {
      await watch.activate();
      host.event('one', 1, 'message.member', 'One');
      await watch.refresh();
      final other = create(
        key: WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'other-owner',
          profileName: 'default',
        ),
      );
      addTearDown(other.dispose);
      await other.activate();
      host.event('one', 2, 'message.member', 'Next');
      await other.refresh();
      expect(sink.shown.first.id, isNot(sink.shown.last.id));
    },
  );

  test(
    'send admission survives uncertain accepted-state reads and releases on recovery',
    () async {
      await watch.activate();
      await watch.beginSend('one', 'Group one', 'first-send');
      host.fail = true;
      await watch.endSend('one', 'first-send', dispatched: true);
      expect(watch.hasActiveGroups, isTrue);
      host.fail = false;
      await watch.refresh();
      expect(watch.hasActiveGroups, isFalse);
      await watch.beginSend('one', 'Group one', 'unsent');
      host.fail = true;
      await watch.endSend('one', 'unsent', dispatched: false);
      expect(watch.hasActiveGroups, isFalse);
    },
  );

  test(
    'wrong log owner cannot release work or publish another group answer',
    () async {
      host.room('one', working: true);
      await watch.activate();
      host.room('one');
      host.event('one', 1, 'message.member', 'Bad');
      host.logs['one']!.single['room_id'] = 'other';
      await watch.refresh();
      expect(watch.hasActiveGroups, isTrue);
      expect(sink.shown, isEmpty);
    },
  );
  test(
    'reading during held delivery clears the reply before monitoring is released',
    () async {
      await watch.activate();
      delivery = Completer<void>();
      host.event('one', 1, 'message.member', 'Read while posting');
      final posting = watch.refresh();
      await postStarted.future;
      await prefs.setString(
        'bots_group_read_sequences',
        jsonEncode({'owner/one': 1}),
      );
      await watch.acknowledge('one', 1);
      delivery!.complete();
      await posting;
      expect(sink.cancelled.single, sink.shown.single.id);
      expect(watch.hasActiveGroups, isFalse);
      expect(notices.chatsWithNotices, isEmpty);
    },
  );

  test(
    'confirmed disband releases work without treating a missing room as completion',
    () async {
      host.room('one', working: true);
      await watch.activate();
      host.states['one'] = {
        'room': {'room_id': 'one', 'disbanded_at': 1791819000.0},
      };
      await watch.refresh();
      expect(watch.hasActiveGroups, isFalse);
      expect(sink.shown, isEmpty);
    },
  );
}
