import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/controllers/voice_input_controller.dart';

/// What car mode shows. Exactly one phase at a time, see [carPhaseOf].
enum CarPhase { idle, listening, transcribing, thinking, speaking, waiting, attention, error }

/// The connection badge; never a phase of its own (spec §4.4).
enum CarConnection { ok, reconnecting, offline }

enum CarTapAction { talk, sendNow, ignore }

/// How a hands-free utterance reaches a busy chat (spec §6.4).
enum CarDelivery { send, steer, queue, end }

typedef CarText = ({String label, String? hint, String? detail});

/// Generic activity; the thinking label already says it (spec §4.6).
const String carWorking = 'Working';

/// Neutral facts about the chat on screen. Filled by `carSnapshotOf`; the
/// rest of car mode never reads chat or controller types.
class CarSnapshot {
  const CarSnapshot({
    required this.chatKey,
    this.title,
    this.input = VoiceInputPhase.idle,
    this.speaking = false,
    this.working = false,
    this.activity,
    this.needsInput = false,
    this.connection = CarConnection.ok,
    this.error,
  });

  /// Identity of the chat on screen; a change ends car mode.
  final Object? chatKey;

  /// Shown small on screen; never logged.
  final String? title;
  final VoiceInputPhase input;

  /// Read-aloud is playing or being prepared.
  final bool speaking;

  /// The chat's turn is submitting, running, waiting or reconnecting.
  final bool working;

  /// Status line: activity kind or tool display name only; never logged.
  final String? activity;

  /// Approval, clarification or secure prompt pending.
  final bool needsInput;
  final CarConnection connection;

  /// Short voice or turn error text; shown on screen, never logged.
  final String? error;
}

/// [held]: a finished recording waits for the connection (spec §4.4).
CarPhase carPhaseOf(CarSnapshot s, {bool held = false}) {
  if (s.needsInput) return CarPhase.attention;
  switch (s.input) {
    case VoiceInputPhase.starting || VoiceInputPhase.recording:
      return CarPhase.listening;
    case VoiceInputPhase.transcribing:
      return CarPhase.transcribing;
    case VoiceInputPhase.idle:
      break;
  }
  if (s.speaking) return CarPhase.speaking;
  if (held) return CarPhase.waiting;
  if (s.working) return CarPhase.thinking;
  if (s.error != null) return CarPhase.error;
  return CarPhase.idle;
}

/// Spec §4.3. Thinking → talk steers the running turn; waiting → talk adds to
/// the held text.
CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle ||
  CarPhase.error ||
  CarPhase.speaking ||
  CarPhase.thinking ||
  CarPhase.waiting => CarTapAction.talk,
  CarPhase.listening =>
    s.input == VoiceInputPhase.recording ? CarTapAction.sendNow : CarTapAction.ignore,
  CarPhase.transcribing || CarPhase.attention => CarTapAction.ignore,
};

CarText carTextFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle => (label: 'Tap to talk', hint: null, detail: null),
  CarPhase.listening => (label: 'Listening', hint: 'Tap to send', detail: null),
  CarPhase.transcribing => (label: 'Got it', hint: 'Transcribing…', detail: null),
  CarPhase.thinking => (label: 'Hermes is working', hint: 'Tap to add something', detail: null),
  CarPhase.speaking => (label: 'Reading aloud', hint: 'Tap to interrupt', detail: null),
  CarPhase.waiting => (label: 'Waiting for connection', hint: 'Sends when back online', detail: null),
  CarPhase.attention => (
    label: 'Needs you on screen',
    hint: 'Approval or question waiting. Look when parked.',
    detail: null,
  ),
  CarPhase.error => (label: "Didn't work", hint: 'Tap to try again', detail: s.error),
};

IconData carIconFor(CarPhase phase) => switch (phase) {
  CarPhase.idle => Icons.mic,
  CarPhase.listening => Icons.stop_rounded,
  CarPhase.transcribing => Icons.more_horiz,
  CarPhase.thinking => Icons.hourglass_empty,
  CarPhase.speaking => Icons.volume_up,
  CarPhase.waiting => Icons.schedule_send,
  CarPhase.attention => Icons.visibility,
  CarPhase.error => Icons.warning,
};

/// Upper-third status line (spec §4.6). Never arguments or output: the
/// adapter only ever passes a kind or a tool display name.
String? carStatusLine(CarPhase phase, CarSnapshot s) {
  final activity = s.activity;
  if (activity == null) return null;
  if (phase == CarPhase.thinking && activity == carWorking) return null;
  return activity;
}

({String label, IconData icon}) carConnectionText(CarConnection c) => switch (c) {
  CarConnection.ok => (label: 'Connected', icon: Icons.cloud_done),
  CarConnection.reconnecting => (label: 'Reconnecting', icon: Icons.sync),
  CarConnection.offline => (label: 'Offline', icon: Icons.cloud_off),
};

/// A horizontal drag leaves car mode when it is long or a fast flick
/// (spec §4.8). [dx] is measured from touch-down, [velocity] in dp/s.
bool carSwipeExits({required double dx, required double velocity, required double width}) {
  final distance = dx.abs();
  return distance >= math.min(96.0, width * .25) || (velocity.abs() >= 700 && distance >= 48);
}

/// A hands-free utterance on a busy chat: steer if Hermes accepts it, else
/// queue, else give up (spec §6.4; barge-in's decideDelivery replaces this).
CarDelivery carDeliveryFor({
  required bool working,
  required bool steerAvailable,
  required bool queueAvailable,
}) {
  if (!working) return CarDelivery.send;
  if (steerAvailable) return CarDelivery.steer;
  if (queueAvailable) return CarDelivery.queue;
  return CarDelivery.end;
}

/// Ignores a second hit within [gap] (bumpy road). Timer based, so widget
/// tests control it with `pump`.
class CarTapGate {
  CarTapGate({this.gap = const Duration(milliseconds: 600)});
  final Duration gap;
  Timer? _closed;

  bool accept() {
    if (_closed?.isActive ?? false) return false;
    _closed = Timer(gap, () {});
    return true;
  }

  void dispose() => _closed?.cancel();
}
