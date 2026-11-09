import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:flutter/foundation.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/recent_conversation_session.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/server_connection_status.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host()..running = false;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'resume-freshness',
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

  RecentConversationSession recentVisit(Iterable<ProfileChat> chats) {
    final activity = ValueNotifier<ChatNoticeActivity?>(null);
    final bots = BotsSession((_) async => const []);
    final recents = WorkspaceRecentsSession(controller, bots);
    final visit = controller.recentConversationSession(
      onOpenGroup: (_) async {},
      recents: recents,
      entries: chats.map(
        (chat) => RecentConversationEntry.chat(
          key: chat.key,
          title: chat.title,
          unread: false,
        ),
      ),
      activity: activity,
    );
    addTearDown(() {
      visit.dispose();
      recents.dispose();
      bots.dispose();
      activity.dispose();
    });
    return visit;
  }

  Future<void> refreshed(ProfileChat chat) async {
    final completion = Completer<void>();
    void changed() {
      if (!chat.refreshingConversation && !completion.isCompleted) {
        completion.complete();
      }
    }

    controller.addListener(changed);
    changed();
    try {
      await completion.future;
    } finally {
      controller.removeListener(changed);
    }
  }

  Future<void> resume(String path) async {
    switch (path) {
      case 'open':
        await controller.openSession(chat.key);
      case 'reconnect':
        await controller.reconnect(chat.key.workspace);
      case 'queue':
        await controller.resumeQueue(chat);
      case 'recents':
        await controller.refreshHistory(chat);
        await recentVisit([chat]).select(RecentConversationKey.chat(chat.key));
        await refreshed(chat);
    }
  }

  test('Recents reveals retained history before the server resumes', () async {
    await controller.refreshHistory(chat);
    final other = await controller.openSession(
      ProfileSessionKey(chat.key.workspace, 'other'),
    );
    expect(controller.current!.chat, other);
    final visit = recentVisit([chat]);
    final delay = Completer<void>();
    final historyDelay = Completer<void>();
    addTearDown(() {
      if (!delay.isCompleted) delay.complete();
      if (!historyDelay.isCompleted) historyDelay.complete();
    });
    host
      ..resumeStarted = Completer<void>()
      ..resumeDelay = delay;
    final selection = visit.select(RecentConversationKey.chat(chat.key));
    await host.resumeStarted!.future;
    expect(
      await selection,
      isTrue,
      reason: 'Retained history must not wait for the held resume RPC.',
    );
    expect(controller.current!.chat, same(chat));
    expect(chat.reading.messages.single['content'], 'a completed');
    expect(chat.refreshingConversation, isTrue);
    expect(chat.runtime.opening, isTrue);
    host
      ..heldHistoryStarted = Completer<void>()
      ..heldHistoryDelay = historyDelay
      ..historyMessages = [
        {'id': 1, 'role': 'assistant', 'content': 'a completed'},
        {'id': 2, 'role': 'assistant', 'content': 'New server reply'},
      ];
    delay.complete();
    await host.heldHistoryStarted!.future;
    expect(chat.refreshingConversation, isTrue);
    expect(chat.reading.messages, hasLength(1));
    historyDelay.complete();
    await refreshed(chat);
    expect(chat.reading.messages.last['content'], 'New server reply');
    expect(chat.runtime.opening, isFalse);
  });

  test(
    'Recents selects retained cross-profile reading without list I/O',
    () async {
      await controller.refreshHistory(chat);
      final personalScope = chat.key.workspace;
      await controller.switchProfile('b');
      final other = await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'same'),
      );
      final visit = recentVisit([chat, other!]);
      final delay = Completer<void>();
      addTearDown(() {
        if (!delay.isCompleted) delay.complete();
      });
      host
        ..resumeStarted = Completer<void>()
        ..resumeDelay = delay;
      final readsBefore = host.reads.length;
      expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
      await host.resumeStarted!.future;
      expect(controller.current!.scope, personalScope);
      expect(controller.current!.chat, same(chat));
      expect(host.reads, hasLength(readsBefore));
      expect(chat.refreshingConversation, isTrue);
      delay.complete();
      await refreshed(chat);
      expect(
        appPreferences
            .profileSelectionFor('resume-freshness')
            .value
            .selectedName,
        'a',
      );
    },
  );

  test('failed background resume retains reading and can recover', () async {
    await controller.refreshHistory(chat);
    final visit = recentVisit([chat]);
    host.resumeFailures = 1;
    expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
    await refreshed(chat);
    expect(chat.reading.messages.single['content'], 'a completed');
    expect(chat.refreshingConversation, isFalse);
    expect(chat.runtime.openingError, contains('could not be refreshed'));
    expect(visit.error, isNull);
    await controller.resumeConnection();
    expect(chat.runtime.openingError, isNull);
    expect(chat.runtime.opening, isFalse);
  });

  test(
    'failed background history keeps cached messages and clears progress',
    () async {
      await controller.refreshHistory(chat);
      final visit = recentVisit([chat]);
      final delay = Completer<void>();
      addTearDown(() {
        if (!delay.isCompleted) delay.complete();
      });
      host
        ..heldHistoryStarted = Completer<void>()
        ..heldHistoryDelay = delay
        ..heldHistoryFailure = const FormatException(
          'Invalid refreshed history',
        );
      expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
      await host.heldHistoryStarted!.future;
      delay.complete();
      await refreshed(chat);
      expect(chat.reading.messages.single['content'], 'a completed');
      expect(chat.reading.historyError, isNotNull);
      expect(chat.runtime.openingError, isNotNull);
      host.heldHistoryFailure = null;
      expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
      await refreshed(chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.runtime.openingError, isNull);
    },
  );

  test(
    'rapid Recents selection fences older refresh and loading completion',
    () async {
      host.historyMessages = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'Recent saved reply',
          'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
        },
      ];
      await controller.refreshHistory(chat);
      final other = (await controller.openSession(
        ProfileSessionKey(chat.key.workspace, 'other'),
      ))!;
      final visit = recentVisit([chat, other]);
      final olderDelay = Completer<void>();
      final newerDelay = Completer<void>();
      addTearDown(() {
        if (!olderDelay.isCompleted) olderDelay.complete();
        if (!newerDelay.isCompleted) newerDelay.complete();
      });
      host
        ..running = true
        ..resumeStarted = Completer<void>()
        ..resumeDelay = olderDelay;
      expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
      await host.resumeStarted!.future;
      expect(await visit.select(RecentConversationKey.chat(other.key)), isTrue);
      await refreshed(other);
      host
        ..running = false
        ..resumeStarted = Completer<void>()
        ..resumeDelay = newerDelay;
      expect(await visit.select(RecentConversationKey.chat(chat.key)), isTrue);
      await host.resumeStarted!.future;
      olderDelay.complete();
      await Future<void>.delayed(Duration.zero);
      expect(chat.refreshingConversation, isTrue);
      expect(controller.current!.chat, same(chat));
      expect(chat.runtime.execution, ChatExecution.idle);
      newerDelay.complete();
      await refreshed(chat);
      expect(chat.runtime.execution, ChatExecution.idle);
    },
  );

  test('only the latest started resume may publish a snapshot', () async {
    final olderDelay = Completer<void>();
    host
      ..running = true
      ..resumeStarted = Completer<void>()
      ..resumeDelay = olderDelay;
    final older = controller.openSession(chat.key);
    await host.resumeStarted!.future;
    final newerDelay = Completer<void>();
    host
      ..running = false
      ..resumeStarted = Completer<void>()
      ..resumeDelay = newerDelay;
    final newer = controller.openSession(chat.key);
    await host.resumeStarted!.future;
    olderDelay.complete();
    await older;
    expect(chat.runtime.execution, ChatExecution.idle);
    newerDelay.complete();
    await newer;
    expect(chat.runtime.execution, ChatExecution.idle);
  });

  test('a delayed resume cannot rebind an already replaced runtime', () async {
    final delay = Completer<void>();
    host
      ..resumeStarted = Completer<void>()
      ..resumeDelay = delay;
    final opening = controller.openSession(chat.key);
    await host.resumeStarted!.future;
    host.runtimeForResume['a'] = 'newer-runtime';
    await controller.openSession(chat.key);
    delay.complete();
    expect(await opening, isNull);
    expect(chat.runtime.runtimeId, 'newer-runtime');
  });

  test('usage observations do not prevent execution recovery', () async {
    host.event('a', 'message.start');
    controller
        .browserResource(chat.key.workspace.profileName)
        .gateway
        .onConnectionChanged!(false);
    final delay = Completer<void>();
    host
      ..running = false
      ..resumeStarted = Completer<void>()
      ..resumeDelay = delay;
    final recovering = controller.reconnect(chat.key.workspace);
    await host.resumeStarted!.future;
    host.event('a', 'session.usage', {
      'usage': {'input_tokens': 42},
    });
    delay.complete();
    await recovering;

    expect(chat.runtime.blocksTurnAdmission, isFalse);
    expect(chat.runtime.execution, ChatExecution.completed);
    expect(controller.current!.recovering, isFalse);
    expect(controller.current!.reconnectScheduled, isFalse);
  });

  testWidgets('live updates during resume recover without a manual retry', (
    tester,
  ) async {
    await controller.updateDraft(chat, 'Keep my draft');
    final delay = Completer<void>();
    host
      ..resumeStarted = Completer<void>()
      ..resumeDelay = delay;
    final recovering = controller.reconnect(chat.key.workspace);
    await host.resumeStarted!.future;
    final gateway = controller.current!.gateway;
    // The server captured revision 0 for resume, then a live observation
    // advanced authority before that response reached the client.
    host.canonicalRevisions['a:${chat.runtime.runtimeId}'] = 1;
    gateway.onEvent!(
      StreamEvent(
        type: 'session.usage',
        sessionId: chat.runtime.runtimeId,
        data: {
          'revision': 1,
          'usage': {'input_tokens': 42},
        },
      ),
    );
    delay.complete();
    await recovering;
    expect(controller.error, isNull);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    expect(controller.current!.recovering, isFalse);
    expect(gateway.canonical.session(chat.runtime.runtimeId)!.revision, 1);
    expect(chat.composer.observation.text, 'Keep my draft');
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('overlapping resume reads cannot strand profile recovery', (
    tester,
  ) async {
    final delay = Completer<void>();
    host
      ..resumeStarted = Completer<void>()
      ..resumeDelay = delay;
    final recovering = controller.reconnect(chat.key.workspace);
    await host.resumeStarted!.future;
    await controller.current!.gateway.resume(chat.key.sessionId);
    delay.complete();
    await recovering;
    expect(controller.error, isNull);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    expect(controller.current!.reconnectScheduled, isFalse);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  test('superseded history failure cannot fail a recovered profile', () async {
    final delay = Completer<void>();
    addTearDown(() {
      if (!delay.isCompleted) delay.complete();
    });
    host
      ..heldHistoryStarted = Completer<void>()
      ..heldHistoryDelay = delay
      ..heldHistoryFailure = const FormatException('Invalid older history');
    final recovering = controller.reconnect(chat.key.workspace);
    await host.heldHistoryStarted!.future;

    host.event('a', 'message.start');
    host.event('a', 'message.complete', {'text': 'Newer completed answer'});
    await controller.refreshHistory(chat);
    expect(chat.runtime.blocksTurnAdmission, isFalse);
    expect(chat.reading.historyError, isNull);
    delay.complete();
    await recovering;

    expect(chat.runtime.execution, ChatExecution.completed);
    expect(chat.reading.historyError, isNull);
    expect(controller.current!.reconnectError, isNull);
    expect(controller.current!.recovering, isFalse);
    expect(controller.connectionStatus.recoveryProblem, isNull);
    expect(controller.current!.reconnectScheduled, isFalse);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  test('current history failure still fails profile recovery', () async {
    final delay = Completer<void>();
    addTearDown(() {
      if (!delay.isCompleted) delay.complete();
    });
    host
      ..heldHistoryStarted = Completer<void>()
      ..heldHistoryDelay = delay
      ..heldHistoryFailure = const FormatException('Invalid current history');
    final recovering = controller.reconnect(chat.key.workspace);
    await host.heldHistoryStarted!.future;
    delay.complete();
    await recovering;

    expect(chat.reading.historyError, isNotNull);
    expect(controller.current!.reconnectError, isNotNull);
    expect(controller.connectionStatus.recoveryProblem, isNotNull);
    expect(controller.current!.reconnectScheduled, isFalse);
  });

  for (final path in ['open', 'reconnect', 'queue', 'recents']) {
    test(
      '$path: older idle resume cannot erase newer live text or input',
      () async {
        final delay = Completer<void>();
        host
          ..resumeStarted = Completer<void>()
          ..resumeDelay = delay;
        final opening = resume(path);
        await host.resumeStarted!.future;
        if (path == 'recents') expect(chat.refreshingConversation, isTrue);
        host.event('a', 'message.start');
        host.event('a', 'message.delta', {'text': 'New live answer'});
        host.event('a', 'clarify', {
          'request_id': 'new-question',
          'question': 'Which destination?',
          'choices': ['Home', 'Work'],
        });
        delay.complete();
        await opening;

        expect(chat.reading.streaming, 'New live answer');
        expect(chat.runtime.needsInput, isTrue);
        expect(
          chat.runtime.questions?.questions.first.requestId,
          'new-question',
        );
      },
    );

    test(
      '$path: older running resume cannot resurrect a completed turn',
      () async {
        host.running = true;
        host.event('a', 'message.start');
        final delay = Completer<void>();
        host
          ..resumeStarted = Completer<void>()
          ..resumeDelay = delay;
        final opening = resume(path);
        await host.resumeStarted!.future;
        if (path == 'recents') expect(chat.refreshingConversation, isTrue);
        host.event('a', 'message.complete', {'text': 'Final answer'});
        delay.complete();
        await opening;

        expect(chat.runtime.blocksTurnAdmission, isFalse);
        expect(chat.reading.streaming, isEmpty);
      },
    );
  }
}
