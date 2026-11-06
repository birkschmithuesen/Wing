import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/transcript_reading.dart';
import 'package:wing/core/models/user_message_content.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/hermes_profile.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';

class _PresentationHost extends ProfileHistoryFixture {
  bool freshChatPersisted = false;
  List<Map<String, dynamic>> rows = [
    {'id': 1, 'role': 'user', 'content': 'Original prompt'},
  ];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final delegate = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: delegate.discover,
      get: (endpoint, query) async {
        if (endpoint == 'sessions/new-chat/messages' && !freshChatPersisted) {
          throw DashboardHttpException(404, endpoint);
        }
        return delegate.read(endpoint, query);
      },
      rpc: (method, params) async {
        if (method == 'session.history' && params['session_id'] == 'runtime') {
          throw StateError('Fresh runtime history temporarily unavailable');
        }
        return delegate.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => rows;
}

Future<void> _historyFinished(
  ProfileWorkspaceController controller,
  ProfileChat chat,
) async {
  if (!chat.reading.historyLoading) return;
  final finished = Completer<void>();
  void observe() {
    if (!chat.reading.historyLoading && !finished.isCompleted) {
      finished.complete();
    }
  }

  controller.addListener(observe);
  try {
    await finished.future;
  } finally {
    controller.removeListener(observe);
  }
}

void main() {
  late _PresentationHost host;
  late ProfileWorkspaceController controller;
  late WorkspaceRuntimeFixture runtimes;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ChatRuntime runtime;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    runtimes = WorkspaceRuntimeFixture();
    host = _PresentationHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'message-presentation',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      runtimeFactory: runtimes.create,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    chat = await openFixtureChat(
      controller: controller,
      key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
      title: 'Presentation test',
    );
    runtime = runtimes.forChat(chat);
  });

  void emit(String type, Map<String, dynamic> data) {
    controller.current!.gateway.onEvent!(
      StreamEvent(
        type: type,
        sessionId: chat.runtime.runtimeId,
        data: stockChatReply(controller.current!.gateway, type, data),
      ),
    );
  }

  Completer<void> pauseHistory() {
    final gate = Completer<void>();
    host.historyDelays[('chat-0', 0)] = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    return gate;
  }

  Map<String, dynamic> receipt(int id, {bool complete = true}) => {
    'row_ids': [id],
    'complete': complete,
    'final_assistant_row_id': id,
  };

  test('reading adoption freezes nested input and retained observations', () {
    final nested = <String, dynamic>{
      'items': <Object?>['original'],
    };
    final source = <String, dynamic>{
      'id': 1,
      'role': 'assistant',
      'content': 'Original',
      'metadata': nested,
    };
    chat.reading.installSavedHistory([source]);
    final retained = chat.reading.messages;
    final row = retained.single;
    final token = chat.reading.messagePresentationId(row);
    source['content'] = 'Caller rewrite';
    (nested['items'] as List).add('Caller rewrite');
    expect(row['content'], 'Original');
    expect((row['metadata'] as Map)['items'], ['original']);
    expect(() => retained.clear(), throwsUnsupportedError);
    expect(() => row['content'] = 'View rewrite', throwsUnsupportedError);
    expect(
      () => ((row['metadata'] as Map)['items'] as List).clear(),
      throwsUnsupportedError,
    );
    chat.reading.appendPrompt(text: 'Next prompt');
    expect(retained, hasLength(1));
    expect(chat.reading.messages, hasLength(2));
    expect(
      chat.reading.messagePresentationId(chat.reading.messages.first),
      same(token),
    );
  });

  test(
    'reading preserves immutable submitted attachment metadata through admission',
    () {
      chat.reading.installSavedHistory([]);
      final attachments = <UserMessageAttachment>[
        const UserMessageAttachment(
          name: 'Report.pdf',
          target: '/files/report.pdf',
          isImage: false,
        ),
      ];
      chat.reading.appendSubmittedPrompt(
        inputId: 'attachment-input',
        text: 'Read this',
        displayText: 'Read my report',
        attachments: attachments,
      );
      final appended = chat.reading.messages.single;
      final presentation = chat.reading.messagePresentationId(appended);
      // Prepared text can include reference/upload expansion. The start event
      // must keep the original authored bubble and its attachments.
      chat.reading.appendSubmittedPrompt(
        inputId: 'attachment-input',
        text: 'Read this\n\n[file:/files/report.pdf]',
      );
      expect(chat.reading.messages.single, same(appended));
      expect(appended['display_content'], 'Read my report');
      expect(chat.reading.messagePresentationId(appended), same(presentation));
      final submitted =
          appended['submitted_attachments'] as List<UserMessageAttachment>;
      attachments.clear();
      expect(submitted.single.name, 'Report.pdf');
      expect(() => submitted.clear(), throwsUnsupportedError);
      expect(
        UserMessageContent.fromMessage(appended).attachments.single.target,
        '/files/report.pdf',
      );

      final saved = <String, dynamic>{
        'role': 'user',
        'content': 'Read this',
        'submitted_attachments': submitted,
      };
      final snapshot = TranscriptReadingSnapshot(
        messages: [saved],
        historySessionId: 'history',
      );
      final admitted =
          snapshot.messages.single['submitted_attachments']
              as List<UserMessageAttachment>;
      expect(admitted, isNot(same(submitted)));
      expect(() => admitted.clear(), throwsUnsupportedError);
      chat.reading.installSnapshot(snapshot);
      expect(
        UserMessageContent.fromMessage(
          chat.reading.messages.single,
        ).attachments.single.name,
        'Report.pdf',
      );
      chat.reading.installSavedHistory([saved]);
      expect(
        UserMessageContent.fromMessage(
          chat.reading.messages.single,
        ).attachments.single.target,
        '/files/report.pdf',
      );
    },
  );

  test(
    'snapshot capture shares frozen content and freezes fixed-field projections',
    () {
      final parts = <Object?>[
        <String, dynamic>{'type': 'text', 'text': 'Original'},
      ];
      chat.reading.installSavedHistory([
        {
          'role': 'user',
          'content': parts,
          'display_kind': 'async_delegation_complete',
          'display_metadata': {'task_count': 2, 'private': 'excluded'},
          'submitted_attachments': <UserMessageAttachment>[
            const UserMessageAttachment(
              name: 'Report.pdf',
              target: '/files/report.pdf',
              isImage: false,
            ),
          ],
        },
      ]);
      final retained = chat.reading.messages.single;
      final captured = chat.reading.captureSnapshot();
      final row = captured.messages.single;
      expect(row['content'], same(retained['content']));
      parts.clear();
      expect(row['content'], [
        {'type': 'text', 'text': 'Original'},
      ]);
      expect(row['display_metadata'], {'task_count': 2});
      expect(row['submitted_attachments'], [
        {
          'name': 'Report.pdf',
          'target': '/files/report.pdf',
          'is_image': false,
        },
      ]);
      expect(() => captured.messages.clear(), throwsUnsupportedError);
      expect(() => row['content'] = 'Rewrite', throwsUnsupportedError);
      expect(() => (row['content'] as List).clear(), throwsUnsupportedError);
      expect(
        () => (row['display_metadata'] as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (row['submitted_attachments'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => ((row['submitted_attachments'] as List).single as Map).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'interim seals its live segment and the next segment gets a new token',
    () {
      chat.reading.installSavedHistory([]);
      emit('message.start', {});
      emit('message.delta', {'text': 'Tool commentary'});
      final first = chat.reading.streamingMessage!;
      final firstToken = chat.reading.messagePresentationId(first);

      emit('message.interim', {
        'text': 'Tool commentary',
        'already_streamed': true,
      });

      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(firstToken),
      );
      expect(first['content'], 'Tool commentary');
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(firstToken),
      );
      expect(chat.reading.streamingMessage, isNull);
      expect(chat.reading.messages.single['id'], isNull);
      emit('message.delta', {'text': 'Final answer'});
      expect(chat.reading.streamingMessage, isNot(same(first)));
      expect(
        chat.reading.messagePresentationId(chat.reading.streamingMessage!),
        isNot(same(firstToken)),
      );
    },
  );

  for (final complete in [true, false]) {
    test('final receipt retains identity with complete=$complete', () async {
      await controller.refreshHistory(chat);
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Streamed prefix');
      final live = chat.reading.streamingMessage!;
      final retainedLive = Map<String, dynamic>.from(live);
      final token = chat.reading.messagePresentationId(live);
      host.rows = [
        host.rows.first,
        {'id': 2, 'role': 'assistant', 'content': 'Authoritative replacement'},
      ];
      final gate = pauseHistory();

      emit('message.complete', {
        'status': 'complete',
        'text': 'Authoritative replacement',
        'response_transformed': true,
        'persisted_turn': receipt(2, complete: complete),
      });

      expect(live, retainedLive);
      expect(
        chat.reading.messages.last['content'],
        'Authoritative replacement',
      );
      expect(live['content'], 'Streamed prefix');
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        same(token),
      );
      expect(chat.reading.streamingMessage, isNull);
      gate.complete();
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.last['id'], 2);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        same(token),
      );
    });
  }

  test('first saved history preserves a fresh chat receipt identity', () async {
    chat = await controller.createChat(canDispatch: () => true);
    runtime = runtimes.forChat(chat);
    expect(chat.key.sessionId, 'new-chat');
    // Creation reads history. Keep its first transport attempt unavailable so
    // this receipt precedes the first successful canonical history adoption.
    expect(chat.reading.historyError, isNotNull);
    expect(chat.reading.messages, isEmpty);
    expect(chat.reading.historySessionId, isNull);
    runtime.beginTurn(submitting: false);
    chat.reading.updateStreaming('New answer');
    final token = chat.reading.messagePresentationId(
      chat.reading.streamingMessage!,
    );
    host.freshChatPersisted = true;
    host.rows = [
      {'id': 2, 'role': 'assistant', 'content': 'New answer'},
    ];
    emit('message.complete', {
      'status': 'complete',
      'text': 'New answer',
      'persisted_turn': receipt(2, complete: false),
    });
    await _historyFinished(controller, chat);
    expect(chat.reading.historyError, isNull);
    expect(chat.reading.historySessionId, 'new-chat');
    expect(chat.reading.messages.single['id'], 2);
    expect(
      chat.reading.messagePresentationId(chat.reading.messages.single),
      same(token),
    );
  });

  test(
    'receipt binds its row without stealing an equal older answer',
    () async {
      host.rows = [
        {'id': 1, 'role': 'assistant', 'content': 'Repeated answer'},
        {'id': 2, 'role': 'user', 'content': 'Ask again'},
      ];
      await controller.refreshHistory(chat);
      final oldToken = chat.reading.messagePresentationId(
        chat.reading.messages.first,
      );
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Repeated answer');
      final newToken = chat.reading.messagePresentationId(
        chat.reading.streamingMessage!,
      );
      host.rows = [
        ...host.rows,
        {'id': 3, 'role': 'assistant', 'content': 'Repeated answer'},
      ];
      emit('message.complete', {
        'status': 'complete',
        'text': 'Repeated answer',
        'persisted_turn': receipt(3),
      });
      await _historyFinished(controller, chat);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.first),
        same(oldToken),
      );
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        same(newToken),
      );
      expect(newToken, isNot(same(oldToken)));
    },
  );

  test(
    'a final ID absent from receipt row IDs cannot prove presentation ownership',
    () async {
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Unproven receipt');
      final token = chat.reading.messagePresentationId(
        chat.reading.streamingMessage!,
      );
      host.rows = [
        {'id': 2, 'role': 'assistant', 'content': 'Unproven receipt'},
      ];
      emit('message.complete', {
        'status': 'complete',
        'text': 'Unproven receipt',
        'persisted_turn': {
          'row_ids': [3],
          'complete': false,
          'final_assistant_row_id': 2,
        },
      });
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.single['id'], 2);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        isNot(same(token)),
      );
    },
  );

  // Stock e1fdf003a668f97bf5a53d7675c1e70b1dcfec34:
  // apps/desktop/src/app/session/hooks/use-message-stream/
  // reused-final-after-tool.test.tsx. These are its actual event sequences.
  test(
    'reused final retains the already visible buffer across tool rounds',
    () async {
      chat.reading.installSavedHistory([]);
      emit('message.start', {});
      emit('message.delta', {'text': 'Let me look.'});
      emit('tool.start', {'name': 'terminal', 'tool_id': 't', 'args': {}});
      emit('tool.complete', {
        'name': 'terminal',
        'tool_id': 't',
        'result': 'ok',
      });
      emit('message.delta', {'text': '\n\nHere is the answer.'});
      emit('tool.start', {'name': 'todo_list', 'tool_id': 'm', 'args': {}});
      emit('tool.complete', {
        'name': 'todo_list',
        'tool_id': 'm',
        'result': 'ok',
      });
      final live = chat.reading.streamingMessage!;
      final retainedLive = Map<String, dynamic>.from(live);
      final token = chat.reading.messagePresentationId(live);
      const visible = 'Let me look.\n\nHere is the answer.';
      expect(live['content'], visible);
      host.rows = [
        {'id': 2, 'role': 'assistant', 'content': 'Let me look.'},
        {'id': 3, 'role': 'assistant', 'content': 'Here is the answer.'},
      ];
      final gate = pauseHistory();
      emit('message.complete', {
        'status': 'complete',
        'text': 'Here is the answer.',
        'response_previewed': true,
        'response_reused': true,
        'persisted_turn': {
          'row_ids': [2, 3],
          'complete': true,
          'final_assistant_row_id': 3,
        },
      });
      expect(chat.reading.messages, hasLength(1));
      expect(chat.reading.messages.single['content'], visible);
      expect(live, retainedLive);
      expect(chat.reading.streamingMessage, isNull);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(token),
      );
      gate.complete();
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.map((row) => row['content']), [
        'Let me look.',
        'Here is the answer.',
      ]);
      expect(chat.reading.messages.last['id'], 3);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        same(token),
      );
    },
  );

  for (final sealed in [false, true]) {
    test(
      'reused final after a ${sealed ? 'sealed memory' : 'silent todo'} tool settles once',
      () async {
        chat.reading.installSavedHistory([]);
        emit('message.start', {});
        emit('message.delta', {'text': 'Here is the answer.'});
        final token = chat.reading.messagePresentationId(
          chat.reading.streamingMessage!,
        );
        if (sealed) {
          emit('message.interim', {
            'text': 'Here is the answer.',
            'already_streamed': true,
          });
        }
        final tool = sealed ? 'memory' : 'todo_list';
        emit('tool.start', {'name': tool, 'tool_id': 'm', 'args': {}});
        emit('tool.complete', {'name': tool, 'tool_id': 'm', 'result': 'ok'});
        host.rows = [
          {'id': 2, 'role': 'assistant', 'content': 'Here is the answer.'},
        ];
        final gate = pauseHistory();
        emit('message.complete', {
          'status': 'complete',
          'text': 'Here is the answer.',
          'response_previewed': true,
          'response_reused': true,
          'persisted_turn': receipt(2),
        });
        expect(chat.reading.messages, hasLength(1));
        expect(chat.reading.messages.single['content'], 'Here is the answer.');
        expect(
          chat.reading.messagePresentationId(chat.reading.messages.single),
          same(token),
        );
        gate.complete();
        await _historyFinished(controller, chat);
        expect(chat.reading.historyError, isNull);
        expect(chat.reading.messages, hasLength(1));
        expect(chat.reading.messages.single['id'], 2);
        expect(
          chat.reading.messagePresentationId(chat.reading.messages.single),
          same(token),
        );
      },
    );
  }

  test(
    'reused final with no received deltas still paints the answer',
    () async {
      chat.reading.installSavedHistory([]);
      emit('message.start', {});
      emit('tool.start', {'name': 'todo_list', 'tool_id': 'm', 'args': {}});
      emit('tool.complete', {
        'name': 'todo_list',
        'tool_id': 'm',
        'result': 'ok',
      });
      expect(chat.reading.streamingMessage, isNull);
      host.rows = [
        {'id': 2, 'role': 'assistant', 'content': 'Here is the answer.'},
      ];
      final gate = pauseHistory();
      emit('message.complete', {
        'status': 'complete',
        'text': 'Here is the answer.',
        'response_previewed': true,
        'response_reused': true,
        'persisted_turn': receipt(2),
      });
      expect(chat.reading.messages, hasLength(1));
      expect(chat.reading.messages.single['content'], 'Here is the answer.');
      final token = chat.reading.messagePresentationId(
        chat.reading.messages.single,
      );
      gate.complete();
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.single['id'], 2);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(token),
      );
    },
  );

  test(
    'an unmarked final remains authoritative even when its text was streamed',
    () async {
      chat.reading.installSavedHistory([]);
      emit('message.start', {});
      emit('message.delta', {'text': 'Let me look.\n\nHere is the answer.'});
      final token = chat.reading.messagePresentationId(
        chat.reading.streamingMessage!,
      );
      host.rows = [
        {'id': 2, 'role': 'assistant', 'content': 'Here is the answer.'},
      ];
      final gate = pauseHistory();
      // The current stock schema declares response_reused optional, not implied
      // by text equality or the independently meaningful preview flag.
      emit('message.complete', {
        'status': 'complete',
        'text': 'Here is the answer.',
        'response_previewed': true,
        'persisted_turn': receipt(2),
      });
      expect(chat.reading.messages, hasLength(1));
      expect(chat.reading.messages.single['content'], 'Here is the answer.');
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(token),
      );
      gate.complete();
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.single['content'], 'Here is the answer.');
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(token),
      );
    },
  );

  test('previewed completion keeps the already sealed final segment', () async {
    chat.reading.installSavedHistory([]);
    emit('message.start', {});
    emit('message.delta', {'text': 'Previewed final'});
    final live = chat.reading.streamingMessage!;
    final retainedLive = Map<String, dynamic>.from(live);
    final token = chat.reading.messagePresentationId(live);
    emit('message.interim', {
      'text': 'Previewed final',
      'already_streamed': true,
    });
    expect(live, retainedLive);
    host.rows = [
      {'id': 2, 'role': 'assistant', 'content': 'Previewed final'},
    ];
    final gate = pauseHistory();
    emit('message.complete', {
      'status': 'complete',
      'text': 'Previewed final',
      'response_previewed': true,
      'persisted_turn': receipt(2),
    });
    expect(chat.reading.messages, hasLength(1));
    expect(live, retainedLive);
    expect(
      chat.reading.messagePresentationId(chat.reading.messages.single),
      same(token),
    );
    gate.complete();
    await _historyFinished(controller, chat);
    expect(chat.reading.messages, hasLength(1));
    expect(chat.reading.messages.single['id'], 2);
    expect(
      chat.reading.messagePresentationId(chat.reading.messages.single),
      same(token),
    );
  });

  test(
    'preview flag cannot claim an equal interim from a previous turn',
    () async {
      chat.reading.installSavedHistory([]);
      emit('message.start', {});
      emit('message.delta', {'text': 'Repeated final'});
      emit('message.interim', {
        'text': 'Repeated final',
        'already_streamed': true,
      });
      final previous = chat.reading.messages.single;
      final oldToken = chat.reading.messagePresentationId(previous);
      runtime.completeTurn(failed: false, cancelled: false, error: null);
      emit('message.start', {});
      final gate = pauseHistory();
      emit('message.complete', {
        'status': 'complete',
        'text': 'Repeated final',
        'response_previewed': true,
      });
      expect(chat.reading.messages, hasLength(2));
      expect(chat.reading.messages.first, same(previous));
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        isNot(same(oldToken)),
      );
      gate.complete();
      await _historyFinished(controller, chat);
    },
  );

  test(
    'an omitted receipt row retains its proof for a later history page',
    () async {
      await controller.refreshHistory(chat);
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Saved answer');
      final token = chat.reading.messagePresentationId(
        chat.reading.streamingMessage!,
      );
      // The first successful history response does not yet include the row.
      emit('message.complete', {
        'status': 'complete',
        'text': 'Saved answer',
        'persisted_turn': receipt(2),
      });
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages, isNotEmpty);
      expect(chat.reading.messages.every((row) => row['id'] != 2), isTrue);
      host.rows = [
        ...host.rows,
        {'id': 2, 'role': 'assistant', 'content': 'Saved answer'},
      ];
      await controller.refreshHistory(chat);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        same(token),
      );
    },
  );

  for (final status in ['interrupted', 'error']) {
    test(
      '$status retains the local partial segment without a fake row ID',
      () async {
        chat.reading.installSavedHistory([]);
        runtime.beginTurn(submitting: false);
        chat.reading.updateStreaming('Partial answer');
        final live = chat.reading.streamingMessage!;
        final retainedLive = Map<String, dynamic>.from(live);
        final token = chat.reading.messagePresentationId(live);
        host.failHistory = true;
        emit('message.complete', {'status': status, 'text': 'Partial answer'});
        await _historyFinished(controller, chat);
        expect(live, retainedLive);
        expect(
          chat.reading.messagePresentationId(chat.reading.messages.single),
          same(token),
        );
        expect(chat.reading.messages.single['id'], isNull);
        expect(chat.reading.streamingMessage, isNull);
        expect(
          chat.runtime.execution,
          status == 'error' ? ChatExecution.failed : ChatExecution.cancelled,
        );
        expect(chat.reading.historyError, isNotNull);
      },
    );
  }

  test(
    'optional missing receipt keeps local identity but does not invent proof',
    () async {
      chat.reading.installSavedHistory([]);
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Unreceipted answer');
      final live = chat.reading.streamingMessage!;
      final retainedLive = Map<String, dynamic>.from(live);
      final token = chat.reading.messagePresentationId(live);
      host.rows = [
        {'id': 2, 'role': 'assistant', 'content': 'Unreceipted answer'},
      ];
      final gate = pauseHistory();
      emit('message.complete', {
        'status': 'complete',
        'text': 'Unreceipted answer',
      });
      expect(live, retainedLive);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        same(token),
      );
      gate.complete();
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.single['id'], 2);
      // No preceding durable boundary or receipt proves this row's identity.
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.single),
        isNot(same(token)),
      );
    },
  );

  test(
    'an unproven segment does not bind equal text across history rotation',
    () async {
      await controller.refreshHistory(chat);
      runtime.beginTurn(submitting: false);
      chat.reading.updateStreaming('Same body');
      final token = chat.reading.messagePresentationId(
        chat.reading.streamingMessage!,
      );
      host.historySessionIdOverride = 'rotated-chat';
      host.rows = [
        {'id': 10, 'role': 'user', 'content': 'Different turn'},
        {'id': 11, 'role': 'assistant', 'content': 'Same body'},
      ];
      emit('message.complete', {'status': 'complete', 'text': 'Same body'});
      await _historyFinished(controller, chat);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.historySessionId, 'rotated-chat');
      expect(chat.reading.messages.last['id'], 11);
      expect(
        chat.reading.messagePresentationId(chat.reading.messages.last),
        isNot(same(token)),
      );
    },
  );
}
