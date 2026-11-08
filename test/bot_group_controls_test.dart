import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';

import 'support/bots_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BotsFixture fixture;
  late BotsPreferences preferences;
  late BotGroup group;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await BotsPreferences.load();
    fixture = BotsFixture();
    group = (await fixture.repository.groupCatalog()).single;
  });
  BotGroupSession owner() => BotGroupSession(
    fixture.repository,
    group,
    reads: BotGroupReadState(),
    preferences: preferences,
    groupMessages: null,
    appearances: FixedGroupAppearances(const []),
  );
  Map<String, dynamic> event(
    int seq,
    String id,
    String kind,
    Map<String, dynamic> payload,
  ) => {
    'room_id': group.id,
    'seq': seq,
    'event_id': id,
    'kind': kind,
    'actor': {'kind': 'gateway', 'id': 'gateway-1'},
    'payload': payload,
    'created_at': 1791756000.0 + seq,
  };
  void bounded({int grants = 0}) {
    fixture.events.add(
      event(1, 'discussion-1', 'message.user', {
        'text': 'Explore',
        'thread_id': 'thread-1',
      }),
    );
    for (var i = 1; i <= grants; i++) {
      fixture.events.add(
        event(i + 1, 'continued-$i', 'room.continued', {
          'discussion_event_id': 'discussion-1',
          'thread_id': 'thread-1',
          'grant': i,
        }),
      );
    }
    fixture.events.add(
      event(grants + 2, 'bounded', 'room.activity', {
        'discussion_event_id': 'discussion-1',
        'thread_id': 'thread-1',
        'status': 'bounded',
      }),
    );
  }

  test(
    'reply keeps the selected thread and mention through refusal and reopen',
    () async {
      fixture.events.add({
        ...event(1, 'member-answer', 'message.member', {
          'text': 'First answer\nMore detail',
          'thread_id': 'original-thread',
        }),
        'actor': {'kind': 'member', 'id': 'atlas', 'display_name': 'Atlas'},
      });
      var session = owner();
      await session.refresh();
      await session.editMentions('Follow up');
      await session.replyTo(session.events.single);
      expect(session.reply!.threadId, 'original-thread');
      expect(session.reply!.quote, 'First answer');
      expect(session.draftText, '@Atlas Follow up');
      await session.replyTo(session.events.single);
      expect(session.draftText, '@Atlas Follow up');
      expect(fixture.commands, isEmpty);
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.send') {
          throw JsonRpcError(method, 'Refused', data: {'admitted': false});
        }
        return null;
      };
      expect(await session.send(session.draftText), false);
      expect(session.canChooseReply, true);
      expect(session.reply!.threadId, 'original-thread');
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.send') throw StateError('Connection lost');
        return null;
      };
      expect(await session.send(session.draftText), false);
      final attempt = fixture.commands.last.$3;
      expect((attempt['payload'] as Map)['thread_id'], 'original-thread');
      expect(session.canChooseReply, false);
      await session.cancelReply();
      expect(session.reply, isNotNull);
      session.dispose();
      SharedPreferences.resetStatic();
      preferences = await BotsPreferences.load();
      session = owner();
      addTearDown(session.dispose);
      expect(session.reply!.threadId, 'original-thread');
      expect(session.draftText, '@Atlas Follow up');
      fixture.commandHook = null;
      expect(await session.send(session.draftText), true);
      expect(fixture.commands.last.$3, attempt);
      expect(session.reply, isNull);
      expect(session.draftText, isEmpty);
      expect(
        preferences.messageDraft(group.scope.connectionIdentity, group.id),
        isNull,
      );
    },
  );

  test(
    'cancel reply returns to a new thread and rejects foreign message targets',
    () async {
      fixture.events.add(
        event(1, 'question', 'message.user', {
          'text': 'Question',
          'thread_id': 'original-thread',
        }),
      );
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      await session.replyTo(session.events.single);
      expect(session.draftText, isEmpty);
      expect(session.reply, isNotNull);
      expect(
        preferences.messageDraft(
          group.scope.connectionIdentity,
          'another-room',
        ),
        isNull,
      );
      final foreign = BotGroupEvent(
        sequence: 1,
        eventId: 'foreign',
        kind: 'message.user',
        actor: 'gateway',
        actorId: 'other',
        actorName: 'Other',
        timestamp: DateTime(2026),
        text: 'Other',
      );
      await session.replyTo(foreign);
      expect(session.reply!.threadId, 'original-thread');
      await session.cancelReply();
      expect(session.reply, isNull);
      await session.editMentions('New discussion');
      expect(await session.send(session.draftText), true);
      final command = fixture.commands.last.$3;
      expect((command['payload'] as Map)['thread_id'], command['event_id']);
    },
  );

  test(
    'definite refusal restores editable persisted draft; unknown keeps same identity',
    () async {
      await preferences.writeMessageDraft(
        group.scope.connectionIdentity,
        group.id,
        'First draft',
        const [],
        attachments: const [
          BotGroupAttachment(
            id: 'att_00000000000000000000000000000001',
            kind: 'file',
            name: 'notes.txt',
            mime: 'text/plain',
            size: 5,
          ),
        ],
      );
      final session = owner();
      addTearDown(session.dispose);
      await session.editMentions('First draft');
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.send') {
          throw JsonRpcError(
            method,
            'Attachment expired',
            data: {'admitted': false},
          );
        }
        return null;
      };
      expect(await session.send('First draft'), isFalse);
      final refusedId = fixture.commands.last.$3['event_id'];
      expect(session.pendingText, isNull);
      expect(session.canAddAttachments, isTrue);
      expect(session.attachments.single.name, 'notes.txt');
      expect(
        preferences
            .messageDraft(group.scope.connectionIdentity, group.id)!
            .pendingEventId,
        isNull,
      );
      await session.editMentions('Edited draft');
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.send') throw StateError('Connection lost');
        return null;
      };
      await session.send('Edited draft');
      final unknownId = fixture.commands.last.$3['event_id'];
      expect(unknownId, isNot(refusedId));
      expect(session.pendingText, 'Edited draft');
      expect(session.canAddAttachments, isFalse);
      await session.send('Edited draft');
      expect(fixture.commands.last.$3['event_id'], unknownId);
    },
  );

  test(
    'discard preserves exact attempt and obeys method capabilities',
    () async {
      fixture.pending.add({
        'kind': 'discard',
        'member_id': 'atlas',
        'task_id': 'uncertain',
        'execution_generation': 7,
      });
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      final action = session.runtime!.actions.single;
      fixture.commandHook = (_, method, params) async {
        if (method == 'groups.discard') {
          return {
            'discarded': true,
            'task': {'room_id': group.id, 'task_id': 'uncertain'},
          };
        }
        return null;
      };
      await session.discard(action);
      await session.refresh();
      expect(fixture.commands.last.$2, 'groups.discard');
      expect(fixture.commands.last.$3, {
        'room_id': group.id,
        'member_id': 'atlas',
        'task_id': 'uncertain',
        'execution_generation': 7,
      });
      fixture.readHook = (_, method, _) async => method == 'groups.capabilities'
          ? {
              'driver': true,
              'seatable_profiles': ['atlas', 'mira'],
              'methods': ['groups.state'],
            }
          : null;
      await session.refresh();
      final count = fixture.commands.length;
      await session.discard(action);
      expect(fixture.commands.length, count);
      expect(session.canStopGroupWork, isFalse);
    },
  );

  test(
    'bounded Continue is discussion-bound and refuses exhausted, superseded and stopped discussions',
    () async {
      bounded();
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.continuations.single.discussionEventId, 'discussion-1');
      fixture.commandHook = (_, method, params) async {
        if (method != 'groups.continue') return null;
        final continued = event(3, 'continued-1', 'room.continued', {
          'discussion_event_id': params['discussion_event_id'],
          'thread_id': 'thread-1',
          'grant': 1,
        });
        fixture.events.add(continued);
        return {'continued': true, 'event': continued};
      };
      await session.continueDiscussion(session.continuations.single);
      expect(fixture.commands.last.$3, {
        'room_id': group.id,
        'discussion_event_id': 'discussion-1',
      });
      expect(session.continuations, isEmpty);
      fixture.events.add(
        event(4, 'bounded-again', 'room.activity', {
          'discussion_event_id': 'discussion-1',
          'thread_id': 'thread-1',
          'status': 'bounded',
        }),
      );
      fixture.events.add(
        event(5, 'stop', 'room.stop_requested', {'cancel_id': 'external'}),
      );
      await session.refresh();
      expect(session.continuations, isEmpty);
    },
  );

  test(
    'continuation budget and newer same-thread message are authoritative',
    () async {
      bounded(grants: 5);
      final session = owner();
      await session.refresh();
      expect(session.continuations, isEmpty);
      session.dispose();
      // Independent owner replays the revised fixture from the beginning.
      fixture.events.clear();
      bounded();
      fixture.events.add(
        event(3, 'new-message', 'message.user', {
          'text': 'New',
          'thread_id': 'thread-1',
        }),
      );
      final next = owner();
      addTearDown(next.dispose);
      await next.refresh();
      expect(next.continuations, isEmpty);
    },
  );

  test(
    'Stop remains available during send and waits for its own durable fence',
    () async {
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      final send = Completer<void>();
      fixture.commandHook = (_, method, params) async {
        if (method == 'groups.send') {
          await send.future;
          throw StateError('Lost response');
        }
        if (method == 'groups.stop') return {'cancelled': 0};
        return null;
      };
      await session.editMentions('Explore');
      final sending = session.send('Explore');
      await Future<void>.delayed(Duration.zero);
      expect(session.canStopGroupWork, isTrue);
      await session.stop();
      expect(session.awaitingStopFence, isTrue);
      final cancelId = fixture.commands
          .where((c) => c.$2 == 'groups.stop')
          .single
          .$3['cancel_id'];
      fixture.events.add(
        event(1, 'fence', 'room.stop_requested', {'cancel_id': cancelId}),
      );
      await session.refresh();
      expect(session.awaitingStopFence, isFalse);
      send.complete();
      await sending;
    },
  );

  Future<BotGroupSession> workingOwner() async {
    final state = await fixture.read('default', 'groups.state', {
      'room_id': group.id,
    });
    (state['driver_status'] as Map<String, dynamic>)['working'] = true;
    fixture.readHook = (_, method, _) async =>
        method == 'groups.state' ? state : null;
    final session = owner();
    addTearDown(session.dispose);
    await session.refresh();
    return session;
  }

  for (final refusal in [
    'preflight',
    'permission_denied',
    'profile_mismatch',
    'runtime_coordination_required',
  ]) {
    test('Stop $refusal failure permits a later natural Continue', () async {
      final session = await workingOwner();
      if (refusal == 'preflight') {
        fixture.beforeCommand = () async => throw StateError('Offline');
      } else {
        fixture.commandHook = (_, method, _) async =>
            throw JsonRpcError(method, 'Stop refused', reason: refusal);
      }
      await session.stop();
      expect(session.error, 'Stop could not be confirmed.');
      expect(session.awaitingStopFence, isFalse);
      expect(fixture.commands.length, refusal == 'preflight' ? 0 : 1);
      fixture.readHook = null;
      bounded();
      await session.refresh();
      expect(session.canStopGroupWork, isFalse);
      expect(session.continuations.single.discussionEventId, 'discussion-1');
    });
  }

  for (final failure in ['timeout', 'unknown', 'malformed', 'wrong method']) {
    test('Stop retains its dispatched fence after $failure', () async {
      final session = await workingOwner();
      fixture.commandHook = (_, method, _) async {
        if (failure == 'malformed') return {};
        if (failure == 'unknown') throw StateError('Lost response');
        throw JsonRpcError(
          failure == 'wrong method' ? 'groups.state' : method,
          'Unconfirmed',
          reason: failure == 'timeout'
              ? 'request_timeout'
              : 'permission_denied',
        );
      };
      await session.stop();
      expect(session.awaitingStopFence, isTrue);
      fixture.readHook = null;
      bounded();
      await session.refresh();
      expect(session.boundedDiscussions, hasLength(1));
      expect(session.continuations, isEmpty);
      final cancelId = fixture.commands.single.$3['cancel_id'];
      fixture.events.add(
        event(3, 'confirmed-stop', 'room.stop_requested', {
          'cancel_id': cancelId,
        }),
      );
      await session.refresh();
      expect(session.awaitingStopFence, isFalse);
    });
  }

  for (final secondFailure in ['preflight', 'refused', 'prior observed']) {
    test('Stop preserves prior uncertainty after $secondFailure', () async {
      final session = await workingOwner();
      fixture.commandHook = (_, _, _) async =>
          throw StateError('Lost response');
      await session.stop();
      final priorId = fixture.commands.single.$3['cancel_id'];
      final second = Completer<void>();
      if (secondFailure == 'preflight') {
        fixture.beforeCommand = () async => throw StateError('Offline');
      } else {
        fixture.commandHook = (_, method, _) async {
          await second.future;
          throw JsonRpcError(method, 'Refused', reason: 'permission_denied');
        };
      }
      final stopping = session.stop();
      await Future<void>.delayed(Duration.zero);
      if (secondFailure == 'prior observed') {
        fixture.events.add(
          event(1, 'prior-stop', 'room.stop_requested', {'cancel_id': priorId}),
        );
        await session.refresh();
      }
      second.complete();
      await stopping;
      expect(session.awaitingStopFence, secondFailure != 'prior observed');
      if (secondFailure != 'prior observed') {
        fixture.events.add(
          event(1, 'prior-stop', 'room.stop_requested', {'cancel_id': priorId}),
        );
        await session.refresh();
        expect(session.awaitingStopFence, isFalse);
      }
    });
  }

  test(
    'Stop keeps an older uncertain request fenced after a newer Stop settles',
    () async {
      final session = await workingOwner();
      fixture.commandHook = (_, method, _) async => throw JsonRpcError(
        method,
        'Timed out before the fence was observed',
        reason: 'request_timeout',
      );
      await session.stop();
      final olderId = fixture.commands.single.$3['cancel_id'];
      fixture.commandHook = (_, _, params) async {
        fixture.events.add(
          event(1, 'newer-stop', 'room.stop_requested', {
            'cancel_id': params['cancel_id'],
          }),
        );
        return {'cancelled': 0};
      };
      await session.stop();
      expect(fixture.commands, hasLength(2));
      expect(session.awaitingStopFence, isTrue);
      fixture.readHook = null;
      fixture.events.addAll([
        event(2, 'new-discussion', 'message.user', {
          'text': 'New discussion after the confirmed Stop',
          'thread_id': 'new-thread',
        }),
        event(3, 'new-bounded', 'room.activity', {
          'discussion_event_id': 'new-discussion',
          'thread_id': 'new-thread',
          'status': 'bounded',
        }),
      ]);
      await session.refresh();
      expect(
        session.boundedDiscussions.single.discussionEventId,
        'new-discussion',
      );
      expect(session.continuations, isEmpty);
      fixture.events.add(
        event(4, 'older-stop-arrives', 'room.stop_requested', {
          'cancel_id': olderId,
        }),
      );
      await session.refresh();
      expect(session.awaitingStopFence, isFalse);
      expect(session.boundedDiscussions, isEmpty);
    },
  );

  test(
    'context validates byte limit and retries the same uncertain write identity',
    () async {
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      expect(
        await session.saveContext(BotGroupContext(notes: '😀' * 1025)),
        isFalse,
      );
      expect(fixture.commands, isEmpty);
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.context') {
          throw StateError('Lost acknowledgement');
        }
        return null;
      };
      const value = BotGroupContext(
        purpose: 'Review Wing',
        notes: 'Check source',
        routing: 'auto',
      );
      expect(await session.saveContext(value), isFalse);
      final id = fixture.commands.last.$3['event_id'];
      fixture.commandHook = (_, method, params) async =>
          method == 'groups.context'
          ? {
              'context': value.toJson(),
              'event': event(
                1,
                params['event_id'] as String,
                'room.context_set',
                value.toJson(),
              ),
            }
          : null;
      expect(await session.saveContext(value), isTrue);
      expect(fixture.commands.last.$3['event_id'], id);
      expect(session.context, value);
    },
  );

  test(
    'read begun during settings save cannot overwrite its confirmed context',
    () async {
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      final oldState = await fixture.read('default', 'groups.state', {
        'room_id': group.id,
      });
      const value = BotGroupContext(purpose: 'Confirmed purpose');
      final saveGate = Completer<void>();
      final oldRead = Completer<Map<String, dynamic>>();
      var firstRead = true;
      fixture.readHook = (_, method, _) async {
        if (method != 'groups.state') return null;
        if (firstRead) {
          firstRead = false;
          return oldRead.future;
        }
        return {...oldState, 'context': value.toJson()};
      };
      fixture.commandHook = (_, method, params) async {
        if (method != 'groups.context') return null;
        await saveGate.future;
        return {
          'context': value.toJson(),
          'event': event(
            1,
            params['event_id'] as String,
            'room.context_set',
            value.toJson(),
          ),
        };
      };
      final saving = session.saveContext(value);
      final reading = session.refresh();
      await Future<void>.delayed(Duration.zero);
      saveGate.complete();
      expect(await saving, isTrue);
      oldRead.complete(oldState);
      await reading;
      expect(session.context, value);
    },
  );

  const capture = bool.fromEnvironment('CAPTURE_GROUP_CONTROLS');
  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      WingTypography.sans: 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$fonts/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  Future<void> render(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.pump(const Duration(milliseconds: 300));
    for (var attempt = 0; attempt < 200; attempt++) {
      final pending = tester
          .stateList<BackgroundMarkdownContentState>(
            find.byType(BackgroundMarkdownContent, skipOffstage: false),
          )
          .any((state) => state.pending);
      if (!pending) break;
      if (attempt == 199) fail('Group Markdown did not settle for capture');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/hermes023-groups/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  test(
    'member progress retains backend timestamps and drops missing retry progress',
    () async {
      final state = await fixture.read('default', 'groups.state', {
        'room_id': group.id,
      });
      final status = state['driver_status'] as Map<String, dynamic>;
      status['member_activity'] = [
        {
          'member_id': 'atlas',
          'status': 'running',
          'thread_id': 'discussion-thread',
          'round_index': 2,
          'tool': 'terminal',
          'started_at': 1791756000.0,
          'progress_at': 1791756012.0,
        },
      ];
      fixture.readHook = (_, method, _) async =>
          method == 'groups.state' ? state : null;
      final session = owner();
      addTearDown(session.dispose);
      await session.refresh();
      var activity = session.runtime!.memberActivity.single;
      expect(activity.tool, 'terminal');
      expect(activity.threadId, 'discussion-thread');
      expect(activity.roundIndex, 2);
      expect(
        activity.progressAt!.difference(activity.startedAt!),
        const Duration(seconds: 12),
      );
      status['member_activity'] = [
        {
          'member_id': 'atlas',
          'status': 'queued',
          'thread_id': 'discussion-thread',
        },
      ];
      await session.refresh();
      activity = session.runtime!.memberActivity.single;
      expect(activity.tool, isNull);
      expect(activity.startedAt, isNull);
      expect(activity.progressAt, isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('reply selection and held send ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        fixture.events.add({
          ...event(1, 'answer', 'message.member', {
            'text': 'Check the trend over the last week.',
            'thread_id': 'health-thread',
          }),
          'actor': {'kind': 'member', 'id': 'atlas', 'display_name': 'Atlas'},
        });
        final session = owner();
        final frame = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: BotGroupScreen(
                createSession: () => session,
                stopVoicePlayback: () async {},
                voiceInputSettings: () => null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reply to message'));
        await tester.pump();
        final input = find.byKey(const ValueKey('group-message-composer'));
        expect(find.text('Replying to Atlas'), findsOneWidget);
        expect(tester.widget<TextField>(input).controller!.text, '@Atlas ');
        expect(fixture.commands, isEmpty);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await render(tester, frame, 'reply-keyboard-${brightness.name}-$scale');
        await tester.tap(find.byTooltip('Cancel reply'));
        await tester.pump();
        expect(find.text('Replying to Atlas'), findsNothing);
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reply to message'));
        await tester.pumpAndSettle();
        await tester.enterText(input, '@Atlas Explain the trend');
        final held = Completer<void>();
        fixture.commandHook = (_, method, _) async {
          if (method == 'groups.send') {
            await held.future;
            throw StateError('Connection lost');
          }
          return null;
        };
        await tester.tap(find.byTooltip('Send group message'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(session.sending, true, reason: session.error);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.text('Replying to Atlas'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == 'Cancel reply',
                ),
              )
              .onPressed,
          isNull,
        );
        await render(tester, frame, 'reply-pending-${brightness.name}-$scale');
        held.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Message not confirmed · Retry the same message'),
          findsOneWidget,
        );
        expect(find.text('Replying to Atlas'), findsOneWidget);
        await render(tester, frame, 'reply-failed-${brightness.name}-$scale');
        final attempt = fixture.commands.last.$3;
        expect((attempt['payload'] as Map)['thread_id'], 'health-thread');
        fixture.commandHook = null;
        await tester.tap(find.byTooltip('Retry same message'));
        await tester.pumpAndSettle();
        expect(fixture.commands.last.$3, attempt);
        expect(find.text('Replying to Atlas'), findsNothing);
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
        'discard and bounded Continue controls ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          bounded();
          fixture.pending.add({
            'kind': 'discard',
            'task_id': 'uncertain',
            'member_id': 'atlas',
            'execution_generation': 7,
          });
          final baseState = await fixture.read('default', 'groups.state', {
            'room_id': group.id,
          });
          fixture.readHook = (_, method, _) async => method == 'groups.state'
              ? {
                  ...baseState,
                  'room': {
                    ...fixture.room,
                    'latest_seq': fixture.events.last['seq'],
                  },
                  'driver_status': {
                    ...baseState['driver_status'] as Map<String, dynamic>,
                    'working': true,
                    'blocked': fixture.pending.isNotEmpty,
                    'member_activity': [
                      {
                        'member_id': 'mira',
                        'status': 'running',
                        'tool': 'terminal',
                        'started_at': 1791756000.0,
                        'progress_at': 1791756012.0,
                        'thread_id': 'thread-another-discussion',
                        'round_index': 1,
                      },
                    ],
                  },
                }
              : null;
          final frame = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: BotGroupScreen(
                  createSession: owner,
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () => null,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Member activity'));
          await tester.pumpAndSettle();
          expect(find.text('Using terminal'), findsWidgets);
          await render(
            tester,
            frame,
            'member-activity-${brightness.name}-$scale',
          );
          await tester.tap(find.text('Raw details'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.textContaining('Thread: thread-another-discussion'),
          );
          await render(
            tester,
            frame,
            'member-activity-raw-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Close member activity'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byTooltip('Discard unknown group attempt'),
          );
          await tester.pump();
          await tester.tap(find.byTooltip('Discard unknown group attempt'));
          await tester.pumpAndSettle();
          expect(find.text('Discard unknown attempt?'), findsOneWidget);
          await render(
            tester,
            frame,
            'discard-confirm-${brightness.name}-$scale',
          );
          final held = Completer<void>();
          fixture.commandHook = (_, method, params) async {
            if (method == 'groups.discard') {
              await held.future;
              fixture.pending.clear();
              return {
                'discarded': true,
                'task': {'room_id': group.id, 'task_id': 'uncertain'},
              };
            }
            return null;
          };
          await tester.tap(find.byTooltip('Discard unknown attempt'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(StudioLoading), findsOneWidget);
          await render(
            tester,
            frame,
            'discard-pending-${brightness.name}-$scale',
          );
          held.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.ensureVisible(find.byTooltip('Continue discussion'));
          await tester.pump();
          await render(
            tester,
            frame,
            'continue-ready-${brightness.name}-$scale',
          );
          final continuing = Completer<void>();
          fixture.commandHook = (_, method, params) async {
            if (method == 'groups.continue') {
              await continuing.future;
              final saved = event(3, 'continued', 'room.continued', {
                'discussion_event_id': params['discussion_event_id'],
                'thread_id': 'thread-1',
                'grant': 1,
              });
              fixture.events.add(saved);
              return {'continued': true, 'event': saved};
            }
            return null;
          };
          await tester.tap(find.byTooltip('Continue discussion'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          await render(
            tester,
            frame,
            'continue-pending-${brightness.name}-$scale',
          );
          continuing.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byTooltip('Continue discussion'), findsNothing);
          expect(
            find.descendant(
              of: find.byType(StudioLoadingSlot),
              matching: find.byType(StudioLoading),
            ),
            findsNothing,
          );
          expect(find.byType(StudioWorkingIndicator), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'member activity stays readable with long and missing observations ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final members = fixture.room['members'] as List;
          members.first['display_name'] = 'Atlas research and release planning';
          group = (await fixture.repository.groupCatalog()).single;
          final state = await fixture.read('default', 'groups.state', {
            'room_id': group.id,
          });
          fixture.readHook = (_, method, _) async => method == 'groups.state'
              ? {
                  ...state,
                  'driver_status': {
                    ...state['driver_status'] as Map<String, dynamic>,
                    'working': true,
                    'member_activity': [
                      {
                        'member_id': 'atlas',
                        'status': 'running',
                        'tool': 'web_search_with_a_long_backend_tool_name',
                        'started_at': 1791756000.0,
                        'progress_at': 1791756012.0,
                        'thread_id': 'exact-long-discussion-thread',
                        'round_index': 2,
                      },
                      {
                        'member_id': 'mira',
                        'status': 'queued',
                        'thread_id': 'queued-discussion',
                      },
                    ],
                  },
                }
              : null;
          final frame = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                theme: wingTheme(brightness),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: BotGroupScreen(
                  createSession: owner,
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () => null,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Member activity'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Running'), findsOneWidget);
          expect(find.text('Queued'), findsOneWidget);
          final tool = find.text(
            'Using web_search_with_a_long_backend_tool_name',
          );
          expect(tool, findsOneWidget);
          // The reported defect was uniform oversized text. Assert the resolved
          // hierarchy rather than just the row's declared theme tokens.
          final timing = find.textContaining('Last activity');
          expect(
            tester.widget<Text>(timing).style!.fontSize!,
            lessThan(tester.widget<Text>(tool).style!.fontSize!),
          );
          final close = find.byTooltip('Close member activity');
          final closeRect = tester.getRect(close);
          expect(closeRect.width, greaterThanOrEqualTo(48));
          expect(closeRect.height, greaterThanOrEqualTo(48));
          await render(tester, frame, 'member-panel-${brightness.name}-$scale');
          final details = find.text('Raw details').first;
          await tester.ensureVisible(details);
          await tester.tap(details);
          await tester.pumpAndSettle();
          final raw = find.textContaining(
            'Thread: exact-long-discussion-thread',
          );
          await tester.ensureVisible(raw);
          expect(raw, findsOneWidget);
          expect(tester.takeException(), isNull);
          await render(
            tester,
            frame,
            'member-panel-expanded-${brightness.name}-$scale',
          );
          final expandedCloseRect = tester.getRect(close);
          final last = find.text('Queued');
          await tester.ensureVisible(last);
          expect(tester.getRect(close), expandedCloseRect);
          await tester.tap(close);
          // Closing returns to a working group's continuously animated status.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Member activity'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'shared settings preserve failed draft and show pending ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final frame = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                theme: wingTheme(brightness),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: BotGroupScreen(
                  createSession: owner,
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () => null,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Shared settings'));
          await tester.pumpAndSettle();
          final purpose = find.widgetWithText(TextField, 'Purpose');
          await tester.enterText(
            purpose,
            'Review Wing source and report concrete defects',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await render(tester, frame, 'settings-${brightness.name}-$scale');
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pump(const Duration(milliseconds: 300));
          await render(
            tester,
            frame,
            'settings-keyboard-${brightness.name}-$scale',
          );
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pump(const Duration(milliseconds: 300));
          final held = Completer<void>();
          fixture.commandHook = (_, method, _) async {
            if (method == 'groups.context') {
              await held.future;
              throw StateError('Server refused');
            }
            return null;
          };
          await tester.tap(find.byTooltip('Save shared settings'));
          await tester.pump();
          expect(
            tester
                .widget<StudioFormActions>(find.byType(StudioFormActions))
                .busy,
            isTrue,
          );
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          await render(
            tester,
            frame,
            'settings-pending-${brightness.name}-$scale',
          );
          held.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.ensureVisible(
            find
                .text(
                  'Shared settings could not be confirmed. Review your draft and retry.',
                )
                .last,
          );
          expect(
            find.text('Review Wing source and report concrete defects'),
            findsOneWidget,
          );
          await render(
            tester,
            frame,
            'settings-failed-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
