import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/live_voice_session.dart';

class VoiceChatFixture extends ChangeNotifier implements LiveVoiceConversation {
  VoiceChatFixture({
    this.mode = LiveVoiceMode.subscription,
    this.profile = 'work',
  });
  final String profile;
  final calls = <String>[];
  final replies = <String, String>{};
  bool released = false;
  Completer<Map<String, dynamic>>? negotiation;
  Completer<String>? delegation;
  @override
  ProfileSessionKey get key => ProfileSessionKey(
    WorkspaceScope(
      connectionId: 'local',
      connectionIdentity: 'identity',
      profileName: profile,
    ),
    'chat1',
  );
  @override
  String get title => 'Voice task';
  @override
  final LiveVoiceMode mode;
  @override
  String get context => 'Earlier chat history';
  @override
  Map<String, String> get completedReplies => replies;
  @override
  String get workStatus => 'Hermes is working.';
  @override
  bool get available => !released;
  @override
  Future<Map<String, dynamic>> negotiate(String offer) =>
      negotiation?.future ??
      Future.value({
        'mode': mode.name,
        'protocol': mode == LiveVoiceMode.api ? 'openai-live' : 'codex-live-v3',
        'contractVersion': 2,
        'handoff': 'client',
        'answer': 'answer',
      });
  @override
  Future<String> delegate(
    String action,
    String text, {
    String voiceContext = '',
    required String delegationId,
  }) async {
    calls.add('$action:$text');
    return delegation == null ? 'Accepted' : await delegation!.future;
  }

  @override
  void release() {
    released = true;
  }

  void completeReply(String id, String text) {
    replies[id] = text;
    notifyListeners();
  }
}

class VoiceTransportFixture implements LiveVoiceTransport {
  late void Function(Map<String, dynamic>) event;
  late void Function() ready;
  late void Function() disconnected;
  final sent = <Map<String, dynamic>>[];
  Completer<String>? opening;
  bool closed = false, isMuted = false;
  int answers = 0;
  bool failSend = false;
  @override
  Future<String> open({
    required void Function(Map<String, dynamic>) onEvent,
    required void Function() onReady,
    required void Function() onDisconnected,
  }) async {
    event = onEvent;
    ready = onReady;
    disconnected = onDisconnected;
    return opening == null ? 'offer' : await opening!.future;
  }

  @override
  Future<void> answer(String sdp) async {
    answers++;
    ready();
    event({'type': 'session.started'});
  }

  @override
  Future<void> send(Map<String, dynamic> event) async {
    if (failSend) throw StateError('channel failed');
    sent.add(event);
  }

  @override
  Future<void> mute(bool muted) async {
    isMuted = muted;
  }

  @override
  Future<void> speaker(bool enabled) async {}
  @override
  Future<void> close() async {
    closed = true;
  }

  void delegate(String id, String text) {
    event({
      'type': 'input_transcript.added',
      'item': {'text': text},
    });
    event({
      'type': 'delegation.created',
      'item': {
        'id': id,
        'type': 'delegation',
        'target': 'client',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
  }
}

class VoiceBackgroundFixture implements LiveVoiceBackground {
  bool running = false;
  late void Function(String) action;
  @override
  Future<void> start(
    String title,
    String payload,
    void Function(String) action,
  ) async {
    this.action = action;
    running = true;
  }

  @override
  Future<void> muted(bool value) async {}
  @override
  Future<void> stop() async {
    running = false;
  }
}

Future<void> settleVoice() => Future<void>.delayed(Duration.zero);
