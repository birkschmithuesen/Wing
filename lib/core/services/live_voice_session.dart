import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/profile_session_key.dart';
import '../models/live_voice_turn.dart';
import '../models/app_preferences.dart';
import 'live_voice_protocol.dart';

/// The canonical conversation owner supplies all work commands and observations.
/// A call never discovers or switches its target after start.
abstract interface class LiveVoiceConversation implements Listenable {
  ProfileSessionKey get key;
  LiveVoiceMode get mode;
  String get title;
  String get context;
  Map<String, String> get completedReplies;
  String get workStatus;
  bool get available;
  Future<Map<String, dynamic>> negotiate(String offer);
  Future<String> delegate(
    String action,
    String text, {
    String voiceContext = '',
    required String delegationId,
  });
  void release();
}

abstract interface class LiveVoiceTransport {
  Future<String> open({
    required void Function(Map<String, dynamic>) onEvent,
    required void Function() onReady,
    required void Function() onDisconnected,
  });
  Future<void> answer(String sdp);
  Future<void> send(Map<String, dynamic> event);
  Future<void> mute(bool muted);
  Future<void> speaker(bool enabled);
  Future<void> close();
}

abstract interface class LiveVoiceBackground {
  Future<void> start(
    String title,
    String payload,
    void Function(String) action,
  );
  Future<void> muted(bool value);
  Future<void> stop();
}

enum LiveVoicePhase { idle, connecting, listening, ending, failed }

/// A safe, client-authored explanation from the voice connection adapter.
class LiveVoiceStartException implements Exception {
  const LiveVoiceStartException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// App-lifetime owner. Releasing audio never interrupts canonical Hermes work.
class LiveVoiceSession extends ChangeNotifier {
  LiveVoiceSession({required this.createTransport, required this.background});
  final LiveVoiceTransport Function() createTransport;
  final LiveVoiceBackground background;
  LiveVoicePhase _phase = LiveVoicePhase.idle;
  LiveVoiceConversation? _conversation;
  LiveVoiceTransport? _transport;
  LiveVoiceConversation? get conversation => _conversation;
  LiveVoicePhase get phase => _phase;
  bool get muted => _muted;
  bool get speaker => _speaker;
  bool get audioChanging => _audioChanging;
  String? get error => _error;
  String get caption => _caption;
  DateTime? get connectedAt => _connectedAt;
  final _transcripts = <ProfileSessionKey, List<LiveVoiceTurn>>{};
  final _pendingSpeech = <bool, int>{};
  int _speechSequence = 0;
  List<LiveVoiceTurn> transcript(ProfileSessionKey key) =>
      List.unmodifiable(_transcripts[key] ?? const <LiveVoiceTurn>[]);

  String _recordSpeech(VoiceTranscript event) {
    final key = _conversation!.key;
    final turns = _transcripts.putIfAbsent(key, () => []);
    var index = _pendingSpeech[event.user];
    // API deltas have no turn.done. A speaker change closes its previous segment.
    if (_conversation!.mode == LiveVoiceMode.api) {
      final other = _pendingSpeech.remove(!event.user);
      if (other != null) {
        final turn = turns[other];
        turns[other] = LiveVoiceTurn(
          id: turn.id,
          user: turn.user,
          text: turn.text,
          timestamp: turn.timestamp,
          complete: true,
        );
      }
    }
    final previous = index == null ? null : turns[index];
    final accumulated = previous?.text ?? '';
    // Subscription turn.done may contain only a suffix of the spoken turn.
    final text = event.complete
        ? (event.text.length >= accumulated.length ? event.text : accumulated)
        : '$accumulated${event.text}';
    if (text.isEmpty && previous == null) return '';
    final turn = LiveVoiceTurn(
      id: previous?.id ?? 'voice-${++_speechSequence}',
      user: event.user,
      text: text,
      timestamp: previous?.timestamp ?? DateTime.now(),
      complete: event.complete,
    );
    if (index == null) {
      index = turns.length;
      turns.add(turn);
    } else {
      turns[index] = turn;
    }
    if (event.complete) {
      _pendingSpeech.remove(event.user);
    } else {
      _pendingSpeech[event.user] = index;
    }
    return text;
  }

  void _finishSpeech() {
    final turns = _transcripts[_conversation?.key];
    if (turns != null) {
      for (final index in _pendingSpeech.values) {
        final turn = turns[index];
        turns[index] = LiveVoiceTurn(
          id: turn.id,
          user: turn.user,
          text: turn.text,
          timestamp: turn.timestamp,
          complete: true,
        );
      }
    }
    _pendingSpeech.clear();
  }

  bool get active => _conversation != null;
  bool get busy =>
      _phase == LiveVoicePhase.connecting || _phase == LiveVoicePhase.ending;
  bool _muted = false;
  bool _speaker = true;
  bool _audioChanging = false;
  String? _error;
  String _caption = '';
  DateTime? _connectedAt;
  String _input = '', _output = '';
  String _recentSpeech = '';
  bool _hasUserSpeech = false;
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _starting;
  Future<void>? _ending;
  Future<void>? _audioOperation;
  Timer? _connectTimeout;
  late LiveVoiceProtocol _protocol;
  final _replies = <String, String>{};
  String _workStatus = '';
  Future<void> _sending = Future.value();
  final _pendingReplies = <String>{};

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(
    LiveVoiceConversation conversation, {
    Future<void> Function()? prepare,
  }) async {
    if (active || _ending != null) {
      conversation.release();
      return;
    }
    final generation = ++_generation;
    _conversation = conversation;
    _phase = LiveVoicePhase.connecting;
    _error = null;
    _caption = '';
    _connectedAt = null;
    _input = _output = _recentSpeech = '';
    _hasUserSpeech = false;
    _pendingReplies.clear();
    _muted = false;
    _speaker = true;
    _protocol = LiveVoiceProtocol(conversation.mode);
    _replies
      ..clear()
      ..addAll(conversation.completedReplies);
    _workStatus = conversation.workStatus;
    conversation.addListener(_observeConversation);
    _changed();
    final starting = _connect(generation, conversation, prepare);
    _starting = starting;
    await starting;
    if (identical(_starting, starting)) _starting = null;
  }

  Future<void> _connect(
    int generation,
    LiveVoiceConversation conversation,
    Future<void> Function()? prepare,
  ) async {
    bool current() => generation == _generation && !_disposed;
    var failureMessage =
        'Could not prepare voice. Stop any active recording or playback and try again.';
    try {
      await prepare?.call();
      if (!current()) return;
      final transport = createTransport();
      _transport = transport;
      failureMessage =
          'Could not open voice audio. Check microphone permission and the connected audio device.';
      final offer = await transport.open(
        onEvent: (event) {
          if (current()) _event(event);
        },
        onReady: () {}, // The channel alone does not confirm a voice session.
        onDisconnected: () {
          if (current()) {
            unawaited(
              end(
                failure: 'Voice disconnected. Start a new call to reconnect.',
              ),
            );
          }
        },
      );
      if (!current()) return;
      failureMessage =
          'Could not keep voice active. Allow Wing notifications and start the call while Wing is open.';
      await background.start(
        conversation.title,
        jsonEncode(conversation.key.toJson()),
        (action) {
          if (!current()) return;
          if (action == 'end') unawaited(end());
          if (action == 'audioInterrupted') {
            unawaited(
              end(
                failure:
                    'Voice ended because another app or phone call needed audio.',
              ),
            );
          }
          if (action == 'mute') unawaited(toggleMute());
        },
      );
      if (!current()) return;
      failureMessage =
          'Could not reach Hermes to start voice. Check the connection and try again.';
      final response = await conversation.negotiate(offer);
      if (!current()) return;
      if (response['mode'] != conversation.mode.name ||
          response['protocol'] !=
              (conversation.mode == LiveVoiceMode.api
                  ? 'openai-live'
                  : 'codex-live-v3') ||
          response['contractVersion'] != 2 ||
          response['handoff'] != 'client' ||
          response['answer'] is! String) {
        throw const LiveVoiceStartException(
          'Hermes returned an incompatible voice connection.',
        );
      }
      _connectTimeout = Timer(const Duration(seconds: 25), () {
        if (current()) {
          unawaited(
            end(
              failure:
                  'Voice could not connect. Check the network and try again.',
            ),
          );
        }
      });
      await transport.answer(response['answer'] as String);
    } catch (error) {
      if (current()) {
        // Do not await end here: teardown waits for this connection attempt.
        unawaited(
          end(
            failure: error is LiveVoiceStartException
                ? error.message
                : failureMessage,
          ),
        );
      }
    }
  }

  void _event(Map<String, dynamic> event) {
    final parsed = _protocol.accept(event);
    switch (parsed) {
      case VoiceReady():
        if (_phase != LiveVoicePhase.connecting) return;
        _connectTimeout?.cancel();
        _phase = LiveVoicePhase.listening;
        _connectedAt = DateTime.now();
        _replies
          ..clear()
          ..addAll(_conversation!.completedReplies);
        unawaited(_send(_protocol.begin(_conversation!.workStatus)));
        _changed();
      case VoiceTranscript():
        final spoken = _recordSpeech(parsed);
        _caption = _bounded(spoken);
        if (parsed.user && parsed.text.trim().isNotEmpty) _hasUserSpeech = true;
        var accumulated = parsed.user ? _input : _output;
        if (parsed.complete) {
          _recentSpeech = _speechTail(
            '$_recentSpeech\n${parsed.user ? 'User' : 'Voice'}: ${_bounded(spoken)}',
          );
          accumulated = '';
        } else {
          accumulated = _bounded(accumulated + parsed.text);
        }
        if (parsed.user) {
          _input = accumulated;
        } else {
          _output = accumulated;
        }
        _changed();
      case VoiceDelegation():
        unawaited(_delegate(parsed));
      case VoiceCommandError():
        _error =
            'Voice rejected an update. The call is still connected; check the chat for task results.';
        _changed();
      case VoiceClosed():
        final message = switch (parsed.reason) {
          'expired' =>
            'Voice reached its session duration limit. Start a new call to continue.',
          'content' => 'The voice provider ended this call for safety reasons.',
          'connection_lost' =>
            'Voice lost its connection. Start a new call to reconnect.',
          'close_requested' || 'remote_hangup' =>
            'The voice session ended. Start a new call to continue.',
          _ =>
            'The voice provider ended this session. Start a new call to reconnect.',
        };
        unawaited(end(failure: message));
      case null:
        break;
    }
  }

  static String _speechTail(String text) =>
      text.length > 6000 ? text.substring(text.length - 6000) : text;

  static String _bounded(String text) =>
      text.length > 12000 ? text.substring(text.length - 12000) : text;

  Future<void> _delegate(VoiceDelegation request) async {
    final generation = _generation, conversation = _conversation;
    if (conversation == null) return;
    if (!_hasUserSpeech) {
      await _send(
        _protocol.result(
          request.id,
          'No new user speech has been received in this call. Wait for the user to speak; saved history is context, not a request to repeat work.',
        ),
      );
      return;
    }
    var result = 'The request was not submitted. Please repeat it.';
    try {
      if (request.action == 'invalid' || request.text.trim().isEmpty) {
        throw const FormatException('Invalid voice request');
      }
      result = await conversation.delegate(
        request.action,
        request.text,
        delegationId: request.id,
        voiceContext: _speechTail(
          [
            _recentSpeech,
            if (_input.isNotEmpty) 'User: $_input',
            if (_output.isNotEmpty) 'Voice: $_output',
          ].join('\n'),
        ),
      );
    } catch (_) {
      result =
          'Hermes could not confirm that request. Check the chat before trying again; do not assume the task was completed.';
    }
    if (generation != _generation) return;
    await _send(_protocol.result(request.id, result));
  }

  void _observeConversation() {
    final conversation = _conversation;
    if (conversation == null) return;
    if (!conversation.available) {
      unawaited(end(failure: 'The original chat is no longer available.'));
      return;
    }
    if (_phase != LiveVoicePhase.listening) return;
    for (final reply in conversation.completedReplies.entries) {
      if (_replies[reply.key] == reply.value ||
          !_pendingReplies.add(reply.key)) {
        continue;
      }
      final generation = _generation;
      unawaited(
        _send(
          _protocol.result(
            reply.key,
            'Hermes replied in the current chat:\n${reply.value}',
          ),
        ).then((sent) {
          if (generation != _generation) return;
          _pendingReplies.remove(reply.key);
          if (sent) _replies[reply.key] = reply.value;
        }),
      );
    }
    final status = conversation.workStatus;
    if (status != _workStatus) {
      _workStatus = status;
      unawaited(_send(_protocol.context(status)));
    }
    _changed();
  }

  // Serialize appends across startup, task receipts and replies. A failed send
  // cannot silently acknowledge work, and old queued sends cannot enter a new call.
  Future<bool> _send(List<Map<String, dynamic>> events) {
    final generation = _generation, transport = _transport;
    final result = Completer<bool>();
    _sending = _sending.then((_) async {
      if (generation != _generation || transport == null) {
        result.complete(false);
        return;
      }
      try {
        for (final event in events) {
          if (generation != _generation) {
            result.complete(false);
            return;
          }
          await transport.send(event).timeout(const Duration(seconds: 5));
        }
        result.complete(true);
      } catch (_) {
        result.complete(false);
        if (generation == _generation) {
          unawaited(
            end(
              failure:
                  'Voice could not send an update. Check the chat for task results, then reconnect.',
            ),
          );
        }
      }
    });
    return result.future;
  }

  Future<void> toggleMute() => _audioChange(() async {
    final next = !_muted;
    await _transport?.mute(next);
    _muted = next;
    final event = _protocol.mute(next);
    if (event != null) await _send([event]);
    await background.muted(next);
  });
  Future<void> toggleSpeaker() => _audioChange(() async {
    final next = !_speaker;
    await _transport?.speaker(next);
    _speaker = next;
  });
  Future<void> _audioChange(Future<void> Function() change) {
    if (!active || busy || _audioChanging) return Future.value();
    return _audioOperation = _changeAudio(change);
  }

  Future<void> _changeAudio(Future<void> Function() change) async {
    _audioChanging = true;
    _changed();
    try {
      await change();
    } catch (_) {
      _error = 'Could not change voice audio. Try again.';
    } finally {
      _audioChanging = false;
      _changed();
    }
  }

  Future<void> end({String? failure}) {
    if (_ending != null) return _ending!;
    ++_generation;
    _finishSpeech();
    _connectTimeout?.cancel();
    _phase = LiveVoicePhase.ending;
    _changed();
    final ending = _close(failure);
    _ending = ending;
    return ending;
  }

  Future<void> _close(String? failure) async {
    // Revoke dispatch immediately, then release audio before waiting for I/O.
    _conversation?.removeListener(_observeConversation);
    _conversation?.release();
    try {
      await _transport?.close();
    } catch (_) {
      /* Continue releasing service and lease. */
    }
    await _starting;
    await _audioOperation;
    _audioOperation = null;
    _transport = null;
    try {
      await background.stop();
    } catch (_) {
      /* Audio has already closed. */
    }
    _conversation = null;
    _phase = failure == null ? LiveVoicePhase.idle : LiveVoicePhase.failed;
    _error = failure;
    _ending = null;
    _changed();
  }

  void dismissError() {
    _error = null;
    if (!active) _phase = LiveVoicePhase.idle;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(end());
    super.dispose();
  }
}
