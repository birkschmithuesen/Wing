import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/gateway_todo.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/transcript_reading.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/models/transcript_reading.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/chat_runtime.dart' as execution;
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/chat_model_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_workspace_controller_test.dart' show Host;
import 'helpers/pump_markdown_widget.dart';

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_REASONING_TIMELINE')) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  ProfileGateway attachTiming(ProfileGateway gateway) {
    gateway.canonical.snapshot({
      ...canonicalSnapshotFields,
      'session_id': chat.runtime.runtimeId,
    });
    return gateway;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host();
    host.todoState = {
      'revision': 2,
      'todos': [
        {'id': 'one', 'content': 'Inspect contract', 'status': 'in_progress'},
      ],
    };
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      connectionIdentity: 'execution-test-host',
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
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'history recovers durations for tool completions missed while away',
    () async {
      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'missed',
          'tool_name': 'read_file',
          'content': 'Booking confirmed',
        },
      ];
      host.notificationReplay = {
        'replay_epoch': 'fixture-epoch',
        'events': [
          {
            'type': 'tool.complete',
            'session_id': chat.runtime.runtimeId,
            'seq': 7,
            'payload': {
              'tool_id': 'missed',
              'name': 'read_file',
              'args': {'path': 'trip/bookings.json'},
              'result': 'Booking confirmed',
              'duration_s': 0.195,
            },
          },
        ],
        'latest_seq': 7,
        'count': 1,
        'truncated': false,
        'epoch': 'server-process',
        'open_requests': [],
      };
      await controller.refreshHistory(chat);
      await Future<void>.delayed(Duration.zero);
      final timeline = TranscriptTimeline.project(
        chat.reading.messages,
        presentationId: chat.reading.messagePresentationId,
      );
      expect(timeline.entries.single.tool!.durationSeconds, 0.195);
      expect(
        timeline.entries.single.tool!.arguments,
        contains('trip/bookings.json'),
      );
      expect(chat.runtime.toolActivities, isEmpty);
      expect(
        chat.reading.captureSnapshot().messages.single['duration_s'],
        0.195,
      );
    },
  );

  test('truncated replay cannot invent timing or revive work', () async {
    const ids = ['measured', 'missing', 'zero', 'wrong-runtime', 'running'];
    host.historyMessages = [
      for (final (index, id) in ids.indexed)
        {
          'id': 21 + index,
          'role': 'tool',
          'tool_call_id': id,
          'tool_name': 'read_file',
          'content': 'File contents',
        },
    ];
    Map<String, dynamic> event(
      String id,
      Object? seconds, {
      String type = 'tool.complete',
      String? runtime,
    }) => {
      'type': type,
      'session_id': runtime ?? chat.runtime.runtimeId,
      'payload': {'tool_id': id, 'name': 'read_file', 'duration_s': seconds},
    };
    host.notificationReplay = {
      'replay_epoch': 'fixture-epoch',
      'events': [
        event('measured', 0.1),
        event('measured', 0.195),
        event('missing', -1),
        event('missing', '0.2'),
        event('zero', 0),
        event('wrong-runtime', 99, runtime: 'b-runtime'),
        event('running', 99, type: 'tool.start'),
        event('not-in-history', 99),
        {
          'type': 'turn.end',
          'session_id': chat.runtime.runtimeId,
          'payload': {},
        },
      ],
      'truncated': true,
    };
    final execution = chat.runtime.execution;
    await controller.refreshHistory(chat);
    await Future<void>.delayed(Duration.zero);
    expect(chat.reading.messages, hasLength(5));
    expect(
      chat.reading.messages.map((row) => row['duration_s']),
      everyElement(isNull),
    );
    expect(chat.runtime.toolActivities, isEmpty);
    expect(chat.runtime.execution, execution);
    expect(
      host.calls.lastWhere((call) => call.$2 == 'session.events.since').$3,
      {
        'session_id': chat.runtime.runtimeId,
        'replay_epoch': 'fixture-epoch',
        'last_sequence': 0,
        'profile': 'a',
      },
    );
  });

  test(
    'bounded recovery retains newest durations in a full replay ring',
    () async {
      host.historyMessages = [
        for (final id in [0, 511])
          {
            'id': id + 1,
            'role': 'tool',
            'tool_call_id': 'call-$id',
            'content': 'File contents',
          },
      ];
      host.notificationReplay = {
        'replay_epoch': 'fixture-epoch',
        'events': [
          for (var id = 0; id < 512; id++)
            {
              'type': 'tool.complete',
              'session_id': chat.runtime.runtimeId,
              'payload': {
                'tool_id': 'call-$id',
                'name': 'read_file',
                'duration_s': id / 1000,
              },
            },
        ],
      };
      await controller.refreshHistory(chat);
      await Future<void>.delayed(Duration.zero);
      expect(chat.reading.messages.first['duration_s'], isNull);
      expect(chat.reading.messages.last['duration_s'], .511);
    },
  );

  test('failed timing recovery keeps saved history readable', () async {
    host.historyMessages = [
      {
        'id': 21,
        'role': 'tool',
        'tool_call_id': 'missing',
        'content': 'File contents',
      },
    ];
    final base = host.gateway(chat.key.workspace);
    final reading = TranscriptReading(
      gateway: attachTiming(
        ProfileGateway(
          scope: chat.key.workspace,
          discover: base.discover,
          get: base.read,
          rpc: (method, params) async {
            if (method == 'session.events.since') {
              throw StateError('Connection lost');
            }
            return base.call(method, params);
          },
        ),
      ),
    );
    addTearDown(reading.dispose);
    expect(
      await reading.refresh(
        sessionId: chat.key.sessionId,
        runtimeId: chat.runtime.runtimeId,
        canPublish: () => true,
        onChanged: () {},
      ),
      isTrue,
    );
    expect(reading.messages.single['content'], 'File contents');
    expect(reading.messages.single['duration_s'], isNull);
    expect(reading.historyError, isNull);
  });

  test(
    'saved history publishes before held timing replay and late receipts persist',
    () async {
      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'measured',
          'content': 'File contents',
        },
      ];
      final held = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final enriched = Completer<void>();
      final base = host.gateway(chat.key.workspace);
      final reading = TranscriptReading(
        gateway: attachTiming(
          ProfileGateway(
            scope: chat.key.workspace,
            discover: base.discover,
            get: base.read,
            rpc: (method, params) async {
              if (method == 'session.events.since') {
                started.complete();
                return held.future;
              }
              return base.call(method, params);
            },
          ),
        ),
      );
      addTearDown(() {
        reading.dispose();
        if (!held.isCompleted) {
          held.complete({'replay_epoch': 'fixture-epoch', 'events': []});
        }
      });
      final refresh = reading.refresh(
        sessionId: chat.key.sessionId,
        runtimeId: chat.runtime.runtimeId,
        canPublish: () => true,
        onChanged: () {
          if (reading.messages.firstOrNull?['duration_s'] == .195) {
            enriched.complete();
          }
        },
      );
      await started.future;
      await Future<void>.delayed(Duration.zero);
      expect(reading.messages.single['content'], 'File contents');
      expect(reading.messages.single['duration_s'], isNull);
      expect(reading.historyLoading, isFalse);
      expect(await refresh, isTrue);
      final presentation = reading.messagePresentationId(
        reading.messages.single,
      );
      held.complete({
        'replay_epoch': 'fixture-epoch',
        'events': [
          {
            'type': 'tool.complete',
            'session_id': chat.runtime.runtimeId,
            'payload': {
              'tool_id': 'measured',
              'name': 'read_file',
              'duration_s': .195,
            },
          },
        ],
      });
      await enriched.future;
      expect(reading.messages.single['duration_s'], .195);
      expect(reading.historyLoading, isFalse);
      expect(reading.historyError, isNull);
      expect(
        reading.messagePresentationId(reading.messages.single),
        same(presentation),
      );
      expect(reading.captureToolDurations().single, {
        'id': 21,
        'tool_call_id': 'measured',
        'duration_s': .195,
      });
      expect(reading.captureSnapshot().messages.single['duration_s'], .195);
      expect(reading.toolDurationRevision, 1);
    },
  );

  test('controller persists late replay without another user action', () async {
    final preferences = await SharedPreferences.getInstance();
    final connection = controller.connection;
    controller.dispose();
    final held = Completer<Map<String, dynamic>>();
    var holdReplay = false;
    controller = ProfileWorkspaceController(
      connectionIdentity: 'late-replay-persistence',
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: (scope) {
        final base = host.gateway(scope);
        late final ProfileGateway gateway;
        gateway = attachTiming(
          ProfileGateway(
            scope: scope,
            discover: base.discover,
            get: base.read,
            rpc: (method, params) {
              if (holdReplay && method == 'session.events.since') {
                return held.future;
              }
              return base.call(method, params);
            },
            connect: () {
              base.onEvent = gateway.onEvent;
              base.onConnectionChanged = gateway.onConnectionChanged;
              return base.connect();
            },
            close: base.close,
            disconnect: base.disconnect,
          ),
        );
        return gateway;
      },
    );
    addTearDown(() {
      if (!held.isCompleted) {
        held.complete({'replay_epoch': 'fixture-epoch', 'events': []});
      }
    });
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    host.historyMessages = [
      {'id': 20, 'role': 'user', 'content': 'Read the file'},
      {
        'id': 21,
        'role': 'tool',
        'tool_call_id': 'late-measured',
        'content': 'File contents',
      },
    ];
    holdReplay = true;
    await controller.refreshHistory(chat);
    final store = WorkspaceSnapshotStore(
      preferences,
      'late-replay-persistence',
    );
    expect(chat.reading.historyLoading, isFalse);
    expect(chat.reading.messages.last['duration_s'], isNull);
    held.complete({
      'replay_epoch': 'fixture-epoch',
      'events': [
        {
          'type': 'tool.complete',
          'session_id': chat.runtime.runtimeId,
          'payload': {
            'tool_id': 'late-measured',
            'name': 'read_file',
            'duration_s': .195,
          },
        },
      ],
    });
    // Drain async storage work; no edit, navigation or disposal can flush it.
    for (
      var i = 0;
      i < 30 && store.readToolDurations('a', chat.key.sessionId).isEmpty;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.readToolDurations('a', chat.key.sessionId), [
      {'id': 21, 'tool_call_id': 'late-measured', 'duration_s': .195},
    ]);
    expect(chat.reading.messages.last['duration_s'], .195);
  });

  test(
    'disposal flushes throttled timings for every chat without pruning old facts',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final connection = controller.connection;
      controller.dispose();
      const identity = 'disposal-timing-retention';
      final store = WorkspaceSnapshotStore(preferences, identity);
      const oldTiming = {
        'id': 1,
        'tool_call_id': 'old-call',
        'duration_s': 1.25,
      };
      for (final profile in ['a', 'b']) {
        await store.writeToolDurations(profile, '$profile-runtime', [
          oldTiming,
        ]);
      }
      await store.write({
        'selected': 'a',
        'profiles': [
          for (final profile in ['a', 'b'])
            {
              'name': profile,
              'sessions': [],
              'projects': [],
              'chats': [
                {
                  'id': '$profile-runtime',
                  'title': 'Cached $profile chat',
                  'messages': [
                    for (var id = 100; id <= 160; id++)
                      {
                        'id': id,
                        'role': id == 160 ? 'tool' : 'assistant',
                        if (id == 160) 'tool_call_id': '$profile-new-call',
                        'content': 'Saved output $id',
                      },
                  ],
                },
              ],
            },
        ],
      });
      controller = ProfileWorkspaceController(
        connectionIdentity: identity,
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      await controller.initialize();
      await controller.browserResource('b').gateway.connect();
      final chats = controller.notificationChats.toList();
      expect(chats, hasLength(2));
      controller.showList();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      for (final profile in ['a', 'b']) {
        final preview =
            (store.read()['profiles'] as List)
                    .where((row) => row['name'] == profile)
                    .single['chats'][0]['messages']
                as List;
        expect(preview, hasLength(60));
        expect(preview.any((row) => row['id'] == 1), isFalse);
        host.event(profile, 'tool.complete', {
          'tool_id': '$profile-new-call',
          'name': 'read_file',
          'duration_s': profile == 'a' ? .195 : 0,
        });
        // The receipt is within the snapshot throttle; only shutdown can flush.
        expect(store.readToolDurations(profile, '$profile-runtime'), [
          oldTiming,
        ]);
      }
      for (final chat in chats) {
        expect(chat.reading.captureToolDurations(), hasLength(2));
        expect(
          chat.reading.messages.last['duration_s'],
          chat.key.workspace.profileName == 'a' ? .195 : 0,
        );
      }
      var publications = 0;
      controller.addListener(() => publications++);
      final revisions = [
        for (final chat in chats) chat.reading.toolDurationRevision,
      ];
      // Keep teardown valid even when a post-disposal regression assertion fails.
      final retiring = controller;
      controller = ProfileWorkspaceController(
        connectionIdentity: 'after-disposal-timing-retention',
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      retiring.dispose();
      // A retained passive index cannot grant a disposed owner new authority.
      for (final chat in chats) {
        chat.reading.observeTool(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': '${chat.key.workspace.profileName}-new-call',
            'name': 'read_file',
            'duration_s': 99,
          })!,
        );
      }
      host.event('a', 'tool.complete', {
        'tool_id': 'a-new-call',
        'name': 'read_file',
        'duration_s': 99,
      });
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(publications, 0);
      expect([
        for (final chat in chats) chat.reading.toolDurationRevision,
      ], revisions);
      for (final profile in ['a', 'b']) {
        expect(store.readToolDurations(profile, '$profile-runtime'), [
          oldTiming,
          {
            'id': 160,
            'tool_call_id': '$profile-new-call',
            'duration_s': profile == 'a' ? .195 : 0,
          },
        ]);
      }
    },
  );

  test(
    'confirmed deletion removes retained timing facts before shutdown',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = WorkspaceSnapshotStore(preferences, 'execution-test-host');
      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'deleted-call',
          'content': 'Saved output',
        },
      ];
      host.event('a', 'tool.complete', {
        'tool_id': 'deleted-call',
        'name': 'read_file',
        'duration_s': .4,
      });
      await controller.refreshHistory(chat);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store.readToolDurations('a', chat.key.sessionId), [
        {'id': 21, 'tool_call_id': 'deleted-call', 'duration_s': .4},
      ]);
      await controller.mutateSession(
        chat.key,
        delete: true,
        canDispatch: () => true,
      );
      expect(controller.current!.chats.containsValue(chat), isFalse);
      expect(store.readToolDurations('a', chat.key.sessionId), isEmpty);
      final retiring = controller;
      controller = ProfileWorkspaceController(
        connectionIdentity: 'after-deleted-timing-retention',
        access: ConnectionAccess(
          connection: retiring.connection,
          dashboardOAuth: null,
        ),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      retiring.dispose();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store.readToolDurations('a', chat.key.sessionId), isEmpty);
    },
  );

  test('failed held timing replay leaves published history intact', () async {
    host.historyMessages = [
      {'id': 21, 'role': 'assistant', 'content': 'Saved answer'},
    ];
    final held = Completer<Map<String, dynamic>>();
    final base = host.gateway(chat.key.workspace);
    final reading = TranscriptReading(
      gateway: attachTiming(
        ProfileGateway(
          scope: chat.key.workspace,
          discover: base.discover,
          get: base.read,
          rpc: (method, params) async {
            if (method == 'session.events.since') return held.future;
            return base.call(method, params);
          },
        ),
      ),
    );
    addTearDown(() {
      reading.dispose();
      if (!held.isCompleted) {
        held.complete({'replay_epoch': 'fixture-epoch', 'events': []});
      }
    });
    var publications = 0;
    expect(
      await reading.refresh(
        sessionId: chat.key.sessionId,
        runtimeId: chat.runtime.runtimeId,
        canPublish: () => true,
        onChanged: () => publications++,
      ),
      isTrue,
    );
    expect(reading.messages.single['content'], 'Saved answer');
    expect(reading.historyLoading, isFalse);
    final published = publications;
    held.completeError(StateError('Replay lost connection'));
    await Future<void>.delayed(Duration.zero);
    expect(reading.messages.single['content'], 'Saved answer');
    expect(reading.historyError, isNull);
    expect(publications, published);
  });

  test('late replay cannot overwrite a live measured completion', () async {
    for (final seconds in [0.0, .42]) {
      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'measured',
          'content': 'File contents',
        },
      ];
      final held = Completer<Map<String, dynamic>>();
      final base = host.gateway(chat.key.workspace);
      final reading = TranscriptReading(
        gateway: attachTiming(
          ProfileGateway(
            scope: chat.key.workspace,
            discover: base.discover,
            get: base.read,
            rpc: (method, params) async {
              if (method == 'session.events.since') return held.future;
              return base.call(method, params);
            },
          ),
        ),
      );
      addTearDown(() {
        reading.dispose();
        if (!held.isCompleted) {
          held.complete({'replay_epoch': 'fixture-epoch', 'events': []});
        }
      });
      var publications = 0;
      expect(
        await reading.refresh(
          sessionId: chat.key.sessionId,
          runtimeId: chat.runtime.runtimeId,
          canPublish: () => true,
          onChanged: () => publications++,
        ),
        isTrue,
      );
      reading.observeTool(
        GatewayToolActivity.fromGatewayEvent('tool.complete', {
          'tool_id': 'measured',
          'name': 'read_file',
          'duration_s': seconds,
        })!,
      );
      final published = publications;
      held.complete({
        'replay_epoch': 'fixture-epoch',
        'events': [
          {
            'type': 'tool.complete',
            'session_id': chat.runtime.runtimeId,
            'payload': {
              'tool_id': 'measured',
              'name': 'read_file',
              'duration_s': .195,
            },
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(reading.messages.single['duration_s'], seconds);
      expect(publications, published);
    }
  });

  test(
    'late replay rejects superseded, replaced, cancelled and disposed reads',
    () async {
      for (final retirement in [
        'superseded',
        'replaced',
        'cancelled',
        'disposed',
      ]) {
        host.historyMessages = [
          {
            'id': 21,
            'role': 'tool',
            'tool_call_id': 'measured',
            'content': 'File contents',
          },
        ];
        final held = Completer<Map<String, dynamic>>();
        final base = host.gateway(chat.key.workspace);
        var replayReads = 0;
        final reading = TranscriptReading(
          gateway: attachTiming(
            ProfileGateway(
              scope: chat.key.workspace,
              discover: base.discover,
              get: base.read,
              rpc: (method, params) async {
                if (method == 'session.events.since') {
                  if (replayReads++ == 0) return held.future;
                  return {'replay_epoch': 'fixture-epoch', 'events': []};
                }
                return base.call(method, params);
              },
            ),
          ),
        );
        addTearDown(() {
          reading.dispose();
          if (!held.isCompleted) {
            held.complete({'replay_epoch': 'fixture-epoch', 'events': []});
          }
        });
        var current = true;
        var publications = 0;
        Future<bool> refresh() => reading.refresh(
          sessionId: chat.key.sessionId,
          runtimeId: chat.runtime.runtimeId,
          canPublish: () => current,
          onChanged: () => publications++,
        );
        expect(await refresh(), isTrue);
        expect(reading.messages.single['duration_s'], isNull);
        switch (retirement) {
          case 'superseded':
            expect(await refresh(), isTrue);
          case 'replaced':
            current = false;
            reading.resetHistorySegment();
          case 'cancelled':
            reading.cancelReads();
          case 'disposed':
            reading.dispose();
        }
        final published = publications;
        held.complete({
          'replay_epoch': 'fixture-epoch',
          'events': [
            {
              'type': 'tool.complete',
              'session_id': chat.runtime.runtimeId,
              'payload': {
                'tool_id': 'measured',
                'name': 'read_file',
                'duration_s': .195,
              },
            },
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(reading.messages.single['duration_s'], isNull);
        expect(reading.captureToolDurations(), isEmpty);
        expect(publications, published);
      }
    },
  );

  test(
    'received durations survive cached reading and authoritative refresh',
    () async {
      host.event('a', 'tool.complete', {
        'tool_id': 'measured',
        'name': 'browser_exec',
        'args': {'code': 'open("https://example.org/rentals")'},
        'result': {'stdout': 'Rental terms'},
        'duration_s': 1.25,
      });
      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'measured',
          'content': 'Rental terms',
        },
        {
          'id': 22,
          'role': 'tool',
          'tool_call_id': 'unmeasured',
          'content': 'Other terms',
        },
      ];
      await controller.refreshHistory(chat);
      expect(chat.reading.messages.first['duration_s'], 1.25);
      final store = WorkspaceSnapshotStore(
        await SharedPreferences.getInstance(),
        'tool-timing',
      );
      await store.write({
        'profiles': [
          {
            'chats': [
              {'messages': chat.reading.captureSnapshot().messages},
            ],
          },
        ],
      });
      final rows = (store.read()['profiles'][0]['chats'][0]['messages'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final restored = TranscriptReading(
        gateway: host.gateway(chat.key.workspace),
      );
      addTearDown(restored.dispose);
      restored.installSnapshot(
        TranscriptReadingSnapshot(messages: rows, historySessionId: 'same'),
      );
      expect(restored.messages.first['duration_s'], 1.25);
      expect(restored.messages.first['args'], contains('example.org/rentals'));
      restored.installSavedPage(
        ProfileHistoryPage(
          'same',
          host.historyMessages!,
          0,
          500,
          isComplete: true,
        ),
      );
      final timeline = TranscriptTimeline.project(
        restored.messages,
        presentationId: restored.messagePresentationId,
      );
      expect(timeline.entries.first.tool!.durationSeconds, 1.25);
      expect(timeline.entries.first.tool!.callId, 'measured');
      expect(timeline.entries.last.tool!.durationSeconds, isNull);
      restored.installSavedPage(
        ProfileHistoryPage(
          'same',
          [
            // Same call text/ID with a different durable row is not the same result.
            {
              'id': 31,
              'role': 'tool',
              'tool_call_id': 'measured',
              'content': 'Rental terms',
            },
            {
              'id': 21,
              'role': 'tool',
              'tool_call_id': 'other-call',
              'content': 'Rental terms',
            },
          ],
          0,
          500,
          isComplete: true,
        ),
      );
      expect(restored.messages, hasLength(2));
      expect(
        restored.messages.every((row) => row['duration_s'] == null),
        isTrue,
      );
      restored.installSavedPage(
        ProfileHistoryPage(
          'same',
          [
            {
              'id': 21,
              'role': 'tool',
              'tool_call_id': 'measured',
              'content': 'Rental terms',
            },
          ],
          0,
          500,
          isComplete: true,
        ),
      );
      restored.observeTool(
        GatewayToolActivity.fromGatewayEvent('tool.complete', {
          'tool_id': 'measured',
          'name': 'browser_exec',
          'duration_s': 0,
          'result': 'Rental terms',
        })!,
      );
      expect(
        restored.messages.singleWhere((row) => row['id'] == 21)['duration_s'],
        0,
      );
      restored.installSavedPage(
        ProfileHistoryPage(
          'same',
          host.historyMessages!,
          0,
          500,
          isComplete: true,
        ),
      );
      expect(
        restored.messages.singleWhere((row) => row['id'] == 21)['duration_s'],
        0,
      );
    },
  );

  test('hydrates todos and rejects an older live revision', () {
    expect(chat.todoRevision, 2);
    expect(chat.todos.single.content, 'Inspect contract');
    expect(chat.todos.single.status, GatewayTodoStatus.inProgress);

    host.event('a', 'todo.updated', {
      'revision': 1,
      'todos': [
        {'id': 'old', 'content': 'Stale task', 'status': 'pending'},
      ],
    });
    expect(chat.todos.single.content, 'Inspect contract');
    expect(chat.todos.single.status, GatewayTodoStatus.inProgress);
  });

  test('task batches retire only after completion and parent settlement', () {
    host.event('a', 'message.start');
    expect(chat.currentTodos.single.status, GatewayTodoStatus.inProgress);
    final done = {
      'revision': 3,
      'todos': [
        {'id': 'one', 'content': 'Inspect contract', 'status': 'completed'},
        {'id': 'two', 'content': 'Unused approach', 'status': 'cancelled'},
      ],
    };
    host.event('a', 'todo.updated', done);
    expect(chat.currentTodos, hasLength(2));
    host.event('a', 'message.complete', {'text': 'Done'});
    expect(chat.currentTodos, isEmpty);
    expect(chat.todos, hasLength(2));
    host.event('a', 'message.start');
    host.event('a', 'todo.updated', done);
    expect(chat.currentTodos, isEmpty);
    host.event('a', 'todo.updated', {
      'revision': 4,
      'todos': [
        {'id': 'three', 'content': 'Next task', 'status': 'pending'},
      ],
    });
    expect(chat.currentTodos.single.content, 'Next task');
    host.event('a', 'message.complete', {'text': 'Paused'});
    expect(chat.currentTodos.single.content, 'Next task');
    host.event('a', 'todo.updated', {
      'revision': 5,
      'todos': [
        {'id': 'three', 'content': 'Next task', 'status': 'completed'},
      ],
    });
    expect(chat.currentTodos, isEmpty);
  });

  test(
    'hydrated completed tasks cannot attach to a later active turn',
    () async {
      host.todoState = {
        'revision': 4,
        'todos': [
          {'id': 'old', 'content': 'Earlier task', 'status': 'completed'},
        ],
      };
      chat = await controller.createChat(canDispatch: () => true);
      expect(chat.currentTodos, isEmpty);
      host.event('a', 'message.start');
      host.event('a', 'todo.updated', host.todoState!);
      expect(chat.currentTodos, isEmpty);
      expect(chat.todos.single.content, 'Earlier task');
    },
  );

  test('newer todo revision replaces the received task statuses', () {
    host.event('a', 'todo.updated', {
      'revision': 3,
      'todos': [
        {'id': 'one', 'content': 'Inspect contract', 'status': 'completed'},
        {'id': 'two', 'content': 'Render result', 'status': 'cancelled'},
      ],
    });
    expect(chat.todoRevision, 3);
    expect(chat.todos.map((todo) => todo.id), ['one', 'two']);
    expect(chat.todos.map((todo) => todo.status), [
      GatewayTodoStatus.completed,
      GatewayTodoStatus.cancelled,
    ]);
  });

  test(
    'upserts live tool events and authoritative refresh removes completion',
    () async {
      host.event('a', 'tool.generating', {'name': 'search_files'});
      expect(chat.runtime.tool, 'search_files');
      expect(chat.runtime.toolActivities, isEmpty);

      host.event('a', 'tool.start', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'args': {'query': 'gateway'},
        'context': 'Workspace',
      });
      expect(chat.runtime.toolActivities, hasLength(1));
      expect(chat.runtime.toolActivities.single.detail, 'Workspace');

      host.event('a', 'tool.complete', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'result': {'matches': 2},
        'duration_s': 1.5,
      });
      final completed = chat.runtime.toolActivities.single;
      expect(completed.phase, GatewayToolActivityPhase.completed);
      expect(completed.arguments, '{"query":"gateway"}');
      expect(completed.result, '{"matches":2}');
      expect(completed.statusLabel, 'Completed in 1.5 s');

      host.historyMessages = [
        {
          'id': 21,
          'role': 'tool',
          'tool_call_id': 'tool-1',
          'content': '{"matches":2}',
        },
        {
          'id': 22,
          'role': 'tool',
          'tool_call_id': 'unrelated',
          'content': 'other',
        },
      ];
      await controller.refreshHistory(chat);
      expect(chat.runtime.toolActivities, isEmpty);
      final saved = TranscriptTimeline.project(
        chat.reading.messages,
        presentationId: chat.reading.messagePresentationId,
      );
      expect(saved.entries.first.tool!.durationSeconds, 1.5);
      expect(saved.entries.first.tool!.arguments, '{"query":"gateway"}');
      expect(saved.entries.last.tool!.durationSeconds, isNull);
    },
  );

  test(
    'reasoning preserves streamed text and native preview with its runtime',
    () async {
      host.event('a', 'reasoning.delta', {'text': 'Check the '});
      host.event('a', 'reasoning.delta', {'text': 'contract.'});
      expect(
        chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
        'Check the contract.',
      );
      host.event('a', 'reasoning.available', {
        'text': 'Verified reasoning.',
        'verbose': true,
      });
      final reasoning = chat.runtime.activityEntries
          .whereType<ChatReasoningEntry>()
          .single;
      expect(reasoning.text, 'Check the contract.');
      expect(reasoning.availableText, 'Verified reasoning.');
      expect(reasoning.running, isFalse);

      await controller.switchProfile('b');
      final other = await controller.createChat(canDispatch: () => true);
      host.event('a', 'reasoning.delta', {'text': ' Owner A'});
      expect(
        chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
        ' Owner A',
      );
      expect(
        other.runtime.activityEntries.whereType<ChatReasoningEntry>(),
        isEmpty,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('task states remain readable in ${brightness.name} at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: ProfileTodoPanel(
                  embedded: true,
                  todos: [
                    GatewayTodo(
                      id: 'task-1',
                      content: 'Inspect the rental conditions',
                      status: GatewayTodoStatus.completed,
                    ),
                    GatewayTodo(
                      id: 'task-2',
                      content: 'Check the permitted travel area',
                      status: GatewayTodoStatus.inProgress,
                      parent: 'inspect',
                    ),
                    GatewayTodo(
                      id: 'task-3',
                      content:
                          'Compare the available pickup locations and opening hours',
                      status: GatewayTodoStatus.pending,
                    ),
                    GatewayTodo(
                      id: 'task-4',
                      content: 'Check an alternative supplier',
                      status: GatewayTodoStatus.cancelled,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            '1 of 4 completed · 1 in progress · 1 pending · 1 cancelled',
          ),
          findsOneWidget,
        );
        expect(find.text('Subtask · In progress'), findsOneWidget);
        expect(find.text('Pending'), findsOneWidget);
        expect(find.text('Cancelled'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.byTooltip('Expand task'), findsNWidgets(4));
        expect(find.byType(SelectableText), findsNothing);
        for (final id in ['task-1', 'task-2', 'task-3', 'task-4']) {
          final control = find.descendant(
            of: find.byKey(ValueKey(('todo', id))),
            matching: find.byTooltip('Expand task'),
          );
          await tester.ensureVisible(control);
          await tester.tap(control);
          await tester.pumpAndSettle();
        }
        expect(find.byType(SelectableText), findsNWidgets(4));
        final texts = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((w) => w.data ?? w.textSpan?.toPlainText())
            .toList();
        expect(texts.first, 'Inspect the rental conditions');
        expect(texts.last, 'Check an alternative supplier');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('tool details expose raw request and result', (tester) async {
    final tool = GatewayToolActivity.fromGatewayEvent('tool.complete', {
      'tool_id': 'tool-1',
      'name': 'search_files',
      'args': {'query': 'gateway'},
      'result': {'matches': 2},
      'duration_s': 0.4,
    })!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProfileLiveToolActivity(activities: [tool]),
              const ProfileTodoPanel(
                todos: [
                  GatewayTodo(
                    id: 'task-5',
                    content: 'Inspect contract',
                    status: GatewayTodoStatus.completed,
                  ),
                ],
              ),
              const ProfileReasoningDisclosure(text: 'Checked the contract.'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('400 ms'), findsOneWidget);
    await tester.tap(find.text('Searched files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raw details'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText && widget.text == '{"query":"gateway"}',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == '{"matches":2}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Raw details'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('task summary expands received tasks', (tester) async {
    final tool = GatewayToolActivity.fromGatewayEvent('tool.complete', {
      'tool_id': 'tool-1',
      'name': 'search_files',
      'args': {'query': 'gateway'},
      'result': {'matches': 2},
      'duration_s': 0.4,
    })!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProfileLiveToolActivity(activities: [tool]),
              const ProfileTodoPanel(
                todos: [
                  GatewayTodo(
                    id: 'task-5',
                    content: 'Inspect contract',
                    status: GatewayTodoStatus.completed,
                  ),
                ],
              ),
              const ProfileReasoningDisclosure(text: 'Checked the contract.'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Inspect contract'), findsNothing);
    await tester.tap(find.text('Tasks 1/1'));
    await tester.pumpAndSettle();
    expect(find.text('Inspect contract'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reasoning disclosure opens the complete text', (tester) async {
    final tool = GatewayToolActivity.fromGatewayEvent('tool.complete', {
      'tool_id': 'tool-1',
      'name': 'search_files',
      'args': {'query': 'gateway'},
      'result': {'matches': 2},
      'duration_s': 0.4,
    })!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProfileLiveToolActivity(activities: [tool]),
              const ProfileTodoPanel(
                todos: [
                  GatewayTodo(
                    id: 'task-5',
                    content: 'Inspect contract',
                    status: GatewayTodoStatus.completed,
                  ),
                ],
              ),
              const ProfileReasoningDisclosure(text: 'Checked the contract.'),
            ],
          ),
        ),
      ),
    );

    expect(
      find.text('Checked the contract.', findRichText: true),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Reasoning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(
      find.text('Checked the contract.', findRichText: true),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'running tool activity stays collapsed through draft rebuilds until tapped',
    (tester) async {
      final tool = GatewayToolActivity.fromGatewayEvent('tool.start', {
        'tool_id': 'tool-running',
        'name': 'search_files',
        'args': {'query': 'gateway'},
      })!;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  TextField(
                    key: const ValueKey('draft'),
                    onChanged: (_) => setState(() {}),
                  ),
                  ProfileLiveToolActivity(activities: [tool]),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Searching files'), findsOneWidget);
      expect(find.text('Raw details'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('draft')), 'typing');
      await tester.pump();
      expect(find.text('Searching files'), findsOneWidget);
      expect(find.text('Raw details'), findsNothing);

      await tester.tap(find.text('Searching files'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Raw details'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'typing more',
      );
      await tester.pump();
      expect(find.text('Raw details'), findsOneWidget);
    },
  );

  test('reads verified historical reasoning fields', () {
    expect(
      TranscriptTimeline.project([
        {'reasoning_content': 'Stored reasoning', 'content': 'Answer'},
      ], presentationId: (_) => Object()).entries.single.reasoning,
      'Stored reasoning',
    );
    expect(
      TranscriptTimeline.project([
        {
          'reasoning_details': {'hidden': true},
        },
      ], presentationId: (_) => Object()).entries.single.reasoning,
      '',
    );
  });

  test('saved reasoning-only messages remain between native tool rows', () {
    final timeline = TranscriptTimeline.project([
      {'id': 1, 'role': 'tool', 'tool_call_id': 'first', 'content': 'Read'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning_content': 'Review the first result.',
      },
      {'id': 3, 'role': 'tool', 'tool_call_id': 'second', 'content': 'Checked'},
      {'id': 4, 'role': 'assistant', 'content': 'Answer'},
    ], presentationId: (row) => row['id']!);
    expect(timeline.sections, hasLength(2));
    expect(timeline.sections.first.messages.map((entry) => entry.message.id), [
      1,
      2,
      3,
    ]);
    expect(timeline.sections.first.toolCount, 2);
  });

  test('live native reasoning stays between calls as completions arrive', () {
    host.event('a', 'message.start');
    host.event('a', 'reasoning.delta', {'text': 'First'});
    host.event('a', 'reasoning.delta', {'text': ' '});
    host.event('a', 'reasoning.delta', {'text': 'plan.'});
    final captured = chat.runtime.activityEntries;
    host.event('a', 'tool.start', {'tool_id': 'first', 'name': 'read_file'});
    host.event('a', 'reasoning.available', {'text': 'Review its output.'});
    host.event('a', 'tool.start', {
      'tool_id': 'second',
      'name': 'execute_code',
    });
    host.event('a', 'reasoning.delta', {'text': 'Check the result.'});
    final before = chat.runtime.activityEntries;
    host.event('a', 'tool.complete', {
      'tool_id': 'first',
      'name': 'read_file',
      'result': 'Native output',
      'duration_s': .4,
    });
    final after = chat.runtime.activityEntries;
    expect(
      after.map((entry) => entry.identity),
      before.map((entry) => entry.identity),
    );
    expect(
      after.map(
        (entry) => entry is ChatReasoningEntry
            ? entry.text
            : (entry as ChatToolEntry).activity.toolId,
      ),
      [
        'First plan.',
        'first',
        'Review its output.',
        'second',
        'Check the result.',
      ],
    );
    expect((after[1] as ChatToolEntry).activity.durationSeconds, .4);
    expect((before[1] as ChatToolEntry).activity.isTerminal, isFalse);
    expect((captured.single as ChatReasoningEntry).running, isTrue);
    expect((after.first as ChatReasoningEntry).running, isFalse);
    expect(() => after.clear(), throwsUnsupportedError);
    host.event('a', 'message.interim', {'text': 'An interim response'});
    expect(chat.runtime.activityEntries, hasLength(5));
    host.event('a', 'reasoning.delta', {'text': 'Continue after commentary.'});
    expect(chat.runtime.activityEntries, hasLength(6));
    expect(chat.reading.messages.last['_gateway_reasoning'], isNull);
  });

  test('live reasoning is exact and resets with turn and runtime lifetime', () {
    final owner = execution.ChatRuntime(runtimeId: 'native');
    owner.beginTurn(submitting: false);
    final text = 'Native reasoning\n' * 2000;
    owner.observeReasoning('reasoning.delta', {'text': text});
    owner.observeReasoning('reasoning.available', {
      'text': text.substring(0, 500),
    });
    final entry =
        owner.observation.activityEntries.single as ChatReasoningEntry;
    expect(entry.text, text);
    expect(entry.availableText, text.substring(0, 500));
    owner.beginTurn(submitting: false);
    expect(owner.observation.activityEntries, isEmpty);
    owner.observeReasoning('thinking.delta', {'text': 'Progress notification'});
    expect(owner.observation.activityEntries, isEmpty);
    owner.observeReasoning('reasoning.available', {
      'text': 'Standalone preview',
    });
    expect(
      (owner.observation.activityEntries.single as ChatReasoningEntry).running,
      isFalse,
    );
    owner.observeReasoning('reasoning.delta', {'text': 'Check the failure.'});
    owner.failTurn('Native turn error');
    expect(
      (owner.observation.activityEntries.last as ChatReasoningEntry).running,
      isFalse,
    );
    owner.replaceRuntime('replacement');
    expect(owner.observation.activityEntries, isEmpty);
  });

  test('saved structured reasoning selects readable native fields only', () {
    String project(Map<String, dynamic> fields) => TranscriptTimeline.project([
      {'id': 1, 'role': 'assistant', 'content': '', ...fields},
    ], presentationId: (row) => row['id']!).entries.single.reasoning;
    expect(
      project({
        'reasoning_details': [
          {
            'type': 'reasoning.text',
            'text': 'Native text',
            'signature': 'opaque',
          },
          {'type': 'reasoning.encrypted', 'data': 'opaque'},
          {'type': 'reasoning.summary', 'summary': 'Native summary'},
        ],
      }),
      'Native text\n\nNative summary',
    );
    expect(
      project({
        'codex_reasoning_items': [
          {
            'type': 'reasoning',
            'encrypted_content': 'opaque',
            'summary': [
              {'type': 'summary_text', 'text': 'Provider summary'},
              {'type': 'unknown', 'text': 'opaque'},
            ],
          },
        ],
      }),
      'Provider summary',
    );
    expect(
      project({
        'reasoning_details': [
          {'type': 'reasoning.encrypted', 'data': 'opaque'},
        ],
      }),
      isEmpty,
    );
    expect(
      project({
        'reasoning': 'Preferred native text',
        'reasoning_content': 'Duplicate native text',
      }),
      'Preferred native text',
    );
  });

  test('saved display reasoning is authoritative, including empty text', () {
    for (final display in ['Received reasoning', '', ' \n ']) {
      final row = <String, dynamic>{
        'id': 1,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Received reasoning\n\nPublic commentary',
        'reasoning_content': 'Received reasoning\n\nPublic commentary',
        'display_reasoning': display,
        'display_commentary': ['Public commentary'],
      };
      final timeline = TranscriptTimeline.project([
        row,
      ], presentationId: (row) => row['id']!);
      expect(timeline.entries.single.reasoning, display);
      expect(timeline.entries.single.hasReasoning, display.trim().isNotEmpty);
      expect(timeline.sections.isEmpty, display.trim().isEmpty);
      expect(row['reasoning'], 'Received reasoning\n\nPublic commentary');
    }
  });

  testWidgets('saved reasoning-only Find result opens its native payload', (
    tester,
  ) async {
    final timeline = TranscriptTimeline.project([
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Received reasoning',
      },
    ], presentationId: (row) => row['id']!);
    final focused = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProfileToolActivitySection(
                section: timeline.sections.single,
                expandedMessageId: 2,
                focusedMessageKey: focused,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(focused.currentContext, isNotNull);
    expect(
      find.text('Received reasoning', findRichText: true),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('native live timeline renders reasoning between tool calls', (
    tester,
  ) async {
    host.event('a', 'message.start');
    host.event('a', 'reasoning.delta', {'text': 'Inspect the contract.'});
    host.event('a', 'tool.start', {'tool_id': 'first', 'name': 'read_file'});
    host.event('a', 'reasoning.delta', {'text': 'Compare the results.'});
    host.event('a', 'tool.start', {
      'tool_id': 'second',
      'name': 'execute_code',
    });
    host.event('a', 'message.delta', {'text': 'The native response.'});
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    expect(
      find.text('The native response.', findRichText: true),
      findsOneWidget,
    );
    // Opening the compact stack reveals newest-first reasoning and tool runs.
    await tester.openLiveActivity(tools: false);
    expect(find.text('Activity · 1 tool'), findsNWidgets(2));
    expect(find.text('Inspect the contract.'), findsOneWidget);
    expect(find.text('Compare the results.'), findsOneWidget);
    expect(find.byType(ProfileToolCall), findsNothing);
    await tester.openLiveActivity();
    expect(find.byType(ProfileReasoningDisclosure), findsNWidgets(2));
    final first = find.byWidgetPredicate(
      (widget) => widget is ProfileToolCall && widget.call.callId == 'first',
    );
    final second = find.byWidgetPredicate(
      (widget) => widget is ProfileToolCall && widget.call.callId == 'second',
    );
    expect(
      tester.getTopLeft(find.text('Inspect the contract.')).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(
      tester.getTopLeft(first).dy,
      greaterThan(tester.getTopLeft(find.text('Compare the results.')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Compare the results.')).dy,
      greaterThan(tester.getTopLeft(second).dy),
    );
    expect(find.text('Timeline'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('native timeline renders ${brightness.name} at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        final owner = execution.ChatRuntime(runtimeId: 'render');
        owner.observeReasoning('reasoning.delta', {
          'text': 'Inspect the native API.',
        });
        owner.observeTool('tool.complete', {
          'tool_id': 'read',
          'name': 'hindsight_retain',
          'args': {'content': 'Remember the verified native API.'},
          'result': 'Memory retained',
          'duration_s': .195,
        });
        owner.observeReasoning('reasoning.available', {
          'text': 'Compare the reported result before proceeding.\n\n' * 30,
        });
        owner.observeTool('tool.complete', {
          'tool_id': 'code',
          'name': 'execute_code',
          'args': {'code': 'print(result)'},
          'result': {'error': 'The check failed'},
          'duration_s': .4,
        });
        owner.observeReasoning('reasoning.delta', {
          'text': 'Review the failure and choose the next step.',
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ProfileActivitySection(
                      label: 'Activity',
                      initiallyExpanded: true,
                      detailsBuilder: (_) => ProfileActivityTabs(
                        tabs: [
                          ProfileActivityTab(
                            id: 'timeline',
                            label: 'Timeline',
                            child: Column(
                              children: [
                                ProfileExecutionActivity(
                                  entries: owner.observation.activityEntries,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ProfileReasoningDisclosure), findsNWidgets(3));
        expect(find.byType(ProfileToolCall), findsNWidgets(2));
        final memoryIcon = ProfileToolCall.iconFor('hindsight_retain');
        expect(find.byIcon(memoryIcon), findsOneWidget);
        for (var i = 0; i < 3; i++) {
          final row = find.byType(ProfileReasoningDisclosure).at(i);
          expect(
            find.descendant(of: row, matching: find.byType(CircuitBrainIcon)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.byType(StudioLoading)),
            findsNothing,
          );
          expect(
            find.descendant(of: row, matching: find.byIcon(memoryIcon)),
            findsNothing,
          );
        }
        expect(find.text('—'), findsNothing);
        expect(tester.takeException(), isNull);
        Future<void> capture(String state) async {
          if (!const bool.fromEnvironment('CAPTURE_REASONING_TIMELINE')) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await render.toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/reasoning-timeline/${brightness.name}-${scale.toInt()}-$state.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
        }

        await capture('collapsed');
        final reason = find.byType(ProfileReasoningDisclosure).at(1);
        await tester.ensureVisible(reason);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: reason, matching: find.text('Reasoning')).first,
        );
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Copy Reasoning'), findsOneWidget);
        expect(find.byTooltip('Open Reasoning'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('expanded');
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final copy = find.byTooltip('Copy Reasoning');
        await tester.ensureVisible(copy);
        await tester.pumpAndSettle();
        await tester.tap(copy);
        await tester.pump();
        expect(
          copied,
          (owner.observation.activityEntries[2] as ChatReasoningEntry).text,
        );
        final open = find.byTooltip('Open Reasoning');
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(find.byTooltip('Show raw content'), findsOneWidget);
        expect(find.byTooltip('Copy Reasoning'), findsOneWidget);
        expect(find.byTooltip('Open Reasoning'), findsNothing);
        await tester.tap(find.byTooltip('Show raw content'));
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SourceCodeText &&
                widget.text ==
                    (owner.observation.activityEntries[2] as ChatReasoningEntry)
                        .text,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
