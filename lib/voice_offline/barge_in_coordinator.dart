import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/services/voice_preferences.dart';
import 'barge_in_policy.dart';
import 'turn_listener.dart';

/// What the coordinator needs from one chat. The workspace screen adapts
/// its controller to this, so this file never imports the chat types.
abstract interface class ListenTarget {
  ListenChatState get state;

  /// True when the gateway queued the steer (`session.steer` → "queued").
  Future<bool> steer(String text);
  Future<void> queue(String text);

  /// Sends [text] as the conversation's next prompt.
  Future<void> send(String text);
}

class CallbackListenTarget implements ListenTarget {
  CallbackListenTarget({
    required this.readState,
    required this.onSteer,
    required this.onQueue,
    required this.onSend,
  });

  final ListenChatState Function() readState;
  final Future<bool> Function(String text) onSteer;
  final Future<void> Function(String text) onQueue;
  final Future<void> Function(String text) onSend;

  @override
  ListenChatState get state => readState();
  @override
  Future<bool> steer(String text) => onSteer(text);
  @override
  Future<void> queue(String text) => onQueue(text);
  @override
  Future<void> send(String text) => onSend(text);
}

/// Routes what the [listener] hears into one chat: steer while the turn
/// runs, otherwise queue or send (spec §4.3). Deliveries run one at a time.
class BargeInCoordinator extends ChangeNotifier {
  BargeInCoordinator(this.listener) {
    listener.onUtterance = _utterance;
    listener.addListener(notifyListeners);
  }

  final TurnListener listener;
  ListenTarget? _target;
  Object? _chat;
  Future<void> _deliveries = Future.value();

  /// A steer was accepted since [beginTurn]; the gateway may answer it with
  /// a follow-up turn after the current one (pending_steer).
  bool steered = false;

  Object? get chat => _chat;
  bool get listening => listener.isOpen;

  /// Completes when every delivery queued so far has finished.
  Future<void> get settled => _deliveries;

  /// The conversation sent a new prompt.
  void beginTurn() => steered = false;

  Future<void> open(
    Object chat,
    ListenTarget target,
    VoicePreferences settings, {
    bool playback = false,
    Future<void> Function()? onBarge,
  }) async {
    _chat = chat;
    _target = target;
    listener.onBarge = onBarge;
    await listener.open(settings, playback: playback);
  }

  void setPlayback(bool playing) => listener.setPlayback(playing);

  Future<void> close(String reason) async {
    _chat = null;
    _target = null;
    listener.onBarge = null;
    await listener.close(reason);
  }

  void _utterance(String text) {
    final target = _target;
    if (target == null) return;
    _deliveries = _deliveries
        .then((_) => _deliver(target, text))
        .catchError((Object _) => bargeLog('deliver failed'));
  }

  Future<void> _deliver(ListenTarget target, String text) async {
    var decision = decideDelivery(target.state, text);
    if (decision == ListenDelivery.steer) {
      if (await target.steer(text)) {
        steered = true;
        bargeLog('deliver kind=steer result=queued');
        return;
      }
      bargeLog('deliver kind=steer result=rejected');
      decision = decideDelivery(target.state, text, steerRejected: true);
    }
    switch (decision) {
      case ListenDelivery.drop:
        bargeLog(
          'deliver kind=drop result=${text.trim().isEmpty ? 'empty' : 'filler'}',
        );
      case ListenDelivery.queue:
        await target.queue(text);
        bargeLog('deliver kind=queue result=ok');
      case ListenDelivery.send:
        await target.send(text);
        bargeLog('deliver kind=send result=ok');
      case ListenDelivery.steer:
        // Unreachable: a rejected steer is re-decided with steerRejected.
        break;
    }
  }

  @override
  void dispose() {
    listener.removeListener(notifyListeners);
    listener.dispose();
    super.dispose();
  }
}
