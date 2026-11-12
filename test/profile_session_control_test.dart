import 'package:wing/core/services/profile_supervision_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/session_control.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

Map<String, dynamic> _control(String revision, {String status = 'active'}) => {
  'goal': {
    'title': 'Ship mobile client',
    'status': status,
    'turns_used': 2,
    'max_turns': 8,
    'contract': {
      'outcome': 'Release',
      'verification': 'Tests pass',
      'constraints': 'Scoped',
      'boundaries': 'Android',
      'stop_when': 'Verified',
    },
    'subgoals': <String>[],
    'gates': <Object>[],
  },
  'revision': revision,
  'updated_at': 100,
};

Map<String, dynamic> _actionResponse(
  String revision, {
  String type = 'exec',
  String? message,
  String? output = 'Goal updated on the server.',
}) => {
  'control': _control(revision),
  'dispatch': {
    'type': type,
    'output': output,
    'notice': null,
    'message': message,
    'display': type == 'send' ? 'Continue goal' : null,
  },
};

class _ControlHost extends Host {
  Map<String, dynamic> readResponse = {'control': _control('read-1')};
  Map<String, dynamic> actionResponse = _actionResponse('action-1');
  Completer<Map<String, dynamic>>? pendingRead;
  Completer<Map<String, dynamic>>? pendingAction;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      rpc: (method, params) {
        if (method == 'session.control.read' || method == 'session.control') {
          calls.add((scope.profileName, method, params));
          return method == 'session.control.read'
              ? pendingRead?.future ?? Future.value(readResponse)
              : pendingAction?.future ?? Future.value(actionResponse);
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }
}

void main() {
  late _ControlHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ControlHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'session-control-test',
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

  test('supervision retains detached readonly goal observations', () async {
    final supervision = ProfileSupervisionSession(
      controller: controller,
      chat: chat,
    );
    try {
      await supervision.refreshControl();
      final retained = supervision.state;
      expect(
        () => retained.sessionControl!.goal!.subgoals.add('local'),
        throwsUnsupportedError,
      );
      final next = _control('next');
      (next['goal'] as Map<String, dynamic>)['subgoals'] = ['From server'];
      host.readResponse = {'control': next};
      await supervision.refreshControl();
      expect(supervision.state.sessionControl!.goal!.subgoals, ['From server']);
      expect(retained.sessionControl!.goal!.subgoals, isEmpty);
    } finally {
      supervision.dispose();
    }
  });

  test(
    'supervision retirement during pending publication prevents control dispatch',
    () async {
      final supervision = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      supervision.addListener(() {
        if (supervision.state.actionBusy) supervision.dispose();
      });
      try {
        expect(
          await supervision.control(SessionControlAction.goalPause),
          isFalse,
        );
        expect(
          host.calls.where((call) => call.$2 == 'session.control'),
          isEmpty,
        );
      } finally {
        supervision.dispose();
      }
    },
  );

  test('ready events hydrate control once', () async {
    host.event('a', 'session.info');
    await Future<void>.delayed(Duration.zero);
    host.event('a', 'session.info');
    await Future<void>.delayed(Duration.zero);
    expect(
      host.calls.where((call) => call.$2 == 'session.control.read'),
      hasLength(1),
    );
  });

  test('a newer event wins a late control read', () async {
    host.pendingRead = Completer<Map<String, dynamic>>();
    final refresh = controller.refreshSessionControl(chat);
    host.event('a', 'session.control.update', {
      'control': _control('event-new'),
    });
    host.pendingRead!.complete({'control': _control('read-old')});
    await refresh;
    expect(chat.sessionControl!.revision, 'event-new');
  });

  test('action rejects a stale continuation', () async {
    host.pendingAction = Completer<Map<String, dynamic>>();
    final action = controller.controlSession(
      chat,
      SessionControlAction.goalPause,
      canDispatch: () => true,
    );
    host.event('a', 'session.control.update', {
      'control': _control('event-new', status: 'paused'),
    });
    host.pendingAction!.complete(
      _actionResponse(
        'response-old',
        type: 'send',
        message: 'Continue stale goal',
        output: null,
      ),
    );
    expect(await action, isFalse);
    expect(chat.sessionControl!.revision, 'event-new');
    expect(chat.sessionControlError, contains('state changed'));
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  test('action accepts the same event revision', () async {
    host.pendingAction = Completer<Map<String, dynamic>>();
    final same = controller.controlSession(
      chat,
      SessionControlAction.goalResume,
      canDispatch: () => true,
    );
    host.event('a', 'session.control.update', {'control': _control('shared')});
    host.pendingAction!.complete(_actionResponse('shared'));
    expect(await same, isTrue);
    expect(chat.sessionControl!.revision, 'shared');
    expect(chat.sessionControlNotice, 'Goal updated on the server.');
    expect(host.calls.last.$3, {
      'session_id': 'a-runtime',
      'action': 'goal.resume',
      'args': <String, dynamic>{},
      'profile': 'a',
    });
  });

  test(
    'continuation preserves composer state and reports partial failure',
    () async {
      await controller.updateDraft(chat, 'Unrelated draft');
      final attachment = AttachmentDraft(
        id: 'file',
        cachedPath: 'unused',
        name: 'notes.txt',
        byteLength: 1,
        mediaType: 'text/plain',
        kind: AttachmentDraftKind.genericFile,
      );
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [attachment],
      );
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendQueued: [QueuedPromptDraft(text: 'Later prompt')],
      );
      host.actionResponse = _actionResponse(
        'continued',
        type: 'send',
        message: 'Continue the goal',
        output: null,
      );

      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.goalResume,
          canDispatch: () => true,
        ),
        isTrue,
      );
      expect(chat.composer.observation.text, 'Unrelated draft');
      expect(chat.composer.observation.attachments.map((value) => value.id), [
        attachment.id,
      ]);
      expect(chat.composer.observation.queue.single.text, 'Later prompt');
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);

      emitChatEvent(controller, chat, 'message.start');
      host.actionResponse = _actionResponse(
        'changed-without-send',
        type: 'send',
        message: 'Continue again',
        output: null,
      );
      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.goalResume,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(chat.sessionControl!.revision, 'changed-without-send');
      expect(
        chat.sessionControlError,
        contains('continuation was not accepted'),
      );
      expect(chat.composer.observation.text, 'Unrelated draft');
    },
  );

  for (final (action, wireAction, args) in [
    (
      SessionControlAction.subgoalAdd,
      'subgoal.add',
      <String, dynamic>{'text': 'Verify hydration'},
    ),
    (
      SessionControlAction.subgoalRemove,
      'subgoal.remove',
      <String, dynamic>{'index': 1},
    ),
    (SessionControlAction.subgoalClear, 'subgoal.clear', <String, dynamic>{}),
  ]) {
    test('$wireAction sends its exact manager arguments', () async {
      expect(
        await controller.controlSession(
          chat,
          action,
          args: args,
          canDispatch: () => true,
        ),
        isTrue,
      );
      expect(host.calls.last.$3, {
        'session_id': 'a-runtime',
        'action': wireAction,
        'args': args,
        'profile': 'a',
      });
    });
  }

  test(
    'duplicate action is rejected while the accepted action retains profile ownership',
    () async {
      host.pendingAction = Completer<Map<String, dynamic>>();
      final first = controller.controlSession(
        chat,
        SessionControlAction.goalClear,
        canDispatch: () => true,
      );
      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.goalClear,
          canDispatch: () => true,
        ),
        isFalse,
      );
      await controller.switchProfile('b');
      host.pendingAction!.complete(_actionResponse('scoped'));
      expect(await first, isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'session.control').last.$1,
        'a',
      );
    },
  );

  test('action completion cannot publish into a replacement runtime', () async {
    host.pendingAction = Completer<Map<String, dynamic>>();
    final stale = controller.controlSession(
      chat,
      SessionControlAction.goalUnwait,
      canDispatch: () => true,
    );
    host.runtimeForResume['a'] = 'replacement-runtime';
    await controller.openSession(chat.key);
    host.pendingAction!.complete(_actionResponse('stale'));
    expect(await stale, isFalse);
  });

  test(
    'malformed dispatch does not claim the server action succeeded',
    () async {
      host.actionResponse = {
        'control': _control('changed'),
        'dispatch': {'type': 'exec'},
      };

      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.goalPause,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(chat.sessionControl, isNull);
      expect(chat.sessionControlError, contains('Refresh'));
    },
  );
}
