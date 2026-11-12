import 'dart:async';

import 'package:flutter/foundation.dart';

import '../car_mode/car_mode_session.dart';
import '../car_mode/car_mode_state.dart';
import '../core/controllers/voice_input_controller.dart';
import '../core/controllers/voice_output_controller.dart';
import '../core/models/composer_action.dart';
import '../core/services/android_voice.dart';
import '../core/services/hermes_voice.dart';
import '../core/services/profile_workspace_controller.dart';
import '../core/services/voice_preferences.dart';
import 'background_voice.dart';
import 'barge_in_coordinator.dart';
import 'car_mic_session.dart';
import 'chat_voice_view.dart';
import 'headphone_route.dart';
import 'speech_queue.dart';
import 'vad_voice_device.dart';
import 'voice_offline_prefs.dart';

/// What the workspace screen offers the fork voice driver. Implemented by
/// ProfileWorkspaceScreenState, so the screen keeps only one-line hooks.
///
/// The members from [car] on are temporary: they expose screen state the
/// not-yet-moved voice code still owns (Tasks 14-16 move it into the driver
/// and drop them).
abstract interface class WorkspaceVoiceHost {
  bool get mounted;
  ProfileWorkspaceController get controller;

  /// The chat on screen: the notification chat, else the current one.
  ProfileChat? get currentChat;
  VoiceInputController get voiceInput;
  VoiceOutputController get voiceOutput;
  Future<void> dictate(ProfileChat chat, {bool resume = false});
  Future<void> performComposerAction(
    ProfileChat chat,
    ComposerAction action, {
    bool conversation = false,
  });

  /// The screen's error-handling wrapper around async user actions.
  Future<void> run(Future<void> Function() action);

  // Screen-owned voice state, until the tasks that move it.
  CarModeSession get car;
  BargeInCoordinator get bargeIn;
  CarMicSession get carMic;
  BackgroundVoice get background;
  HeadphoneRoute get headphones;
  bool get loopFocus;
  bool get onChatsDestination;
  bool? vadRoute();
  Map<ComposerAction, String?> composerActions(ProfileChat chat);
  void openListen(ProfileChat chat, {bool playback = false});
  bool playbackBargeIn(ProfileChat chat, VoiceOfflinePrefs offline);
  set voiceOwner(ProfileSessionKey? key);
}

/// The fork's workspace voice logic. The workspace screen holds one instance
/// and calls it from one-line hooks.
class WorkspaceVoiceDriver extends ChangeNotifier {
  WorkspaceVoiceDriver({
    required this.host,
    required this.device,
    this.backgroundHost,
    this.headphoneHost,
  });

  final WorkspaceVoiceHost host;
  final VoiceDevice device;
  final BackgroundVoiceHost? backgroundHost;
  final HeadphoneRouteHost? headphoneHost;

  ProfileWorkspaceController get _controller => host.controller;
  VoiceInputController get _voiceInput => host.voiceInput;
  VoiceOutputController get _voiceOutput => host.voiceOutput;
  CarModeSession get _car => host.car;
  BargeInCoordinator get _bargeIn => host.bargeIn;
  CarMicSession get _carMic => host.carMic;
  BackgroundVoice get _background => host.background;

  /// initState part.
  void attach() {
    _autoSpeak = _controller.completedReplies.listen(_speakCompletedReply);
    _voiceInput.addListener(_voiceInputChanged);
  }

  /// dispose part.
  void detach() {
    unawaited(_autoSpeak?.cancel());
    if (_conversationKey != null) {
      VoiceSwitchHolders.screenOn(device).set(host, false);
    }
    _voiceInput.removeListener(_voiceInputChanged);
  }

  /// Anything that ends the hands-free conversation loop.
  void endLoop() => conversation = null;

  /// Car mode (docs/CAR_MODE.md). [carSend] makes the next transcript count
  /// as hands-free, so the big button sends on every input route.
  bool carSend = false;

  /// Chat of the running hands-free conversation (Conversation mode). Set when
  /// the user starts dictating with the mode on; cleared by anything that ends
  /// the loop. The microphone only reopens while this still names the chat.
  ProfileSessionKey? _conversationKey;
  ProfileSessionKey? get conversation => _conversationKey;

  /// Keeps the display on while a hands-free conversation runs: a screen
  /// timeout would pause the activity and end any capture.
  set conversation(ProfileSessionKey? value) {
    if ((_conversationKey == null) != (value == null)) {
      VoiceSwitchHolders.screenOn(device).set(host, value != null);
    }
    if (value != _conversationKey) {
      unawaited(_bargeIn.close('conversationEnd').catchError((Object _) {}));
      if (value == null) unawaited(_carMic.end('end').catchError((Object _) {}));
    }
    _conversationKey = value;
    _background.sync(
      want: value != null && host.vadRoute() == true && !_car.active,
    );
  }

  /// True from the conversation's auto-send until its reply arrived. Only
  /// that reply may reopen the microphone, never a later or queued turn.
  bool awaitingReply = false;

  void _voiceInputChanged() {
    // Silence, no speech or a recognizer error ends the conversation.
    if (!_voiceInput.active && _voiceInput.error != null) conversation = null;
  }

  StreamSubscription<({ProfileChat chat, String text})>? _autoSpeak;

  /// Serializes auto-spoken replies: a newer one waits for the one already
  /// playing instead of cutting it off (spec 2026-10-15 queue). Explicit
  /// actions (mic tap, stop, manual read-aloud, barge-in) clear it instead of
  /// going through it.
  final autoSpeakQueue = SpeechQueue();

  /// Hands-free voice chat: read a finished reply aloud when the user enabled
  /// "Spoken replies" or "Conversation mode", the chat is on screen and nobody
  /// is dictating. Replies queue behind each other in arrival order; the
  /// microphone only reopens once the queue drained after the last one.
  void _speakCompletedReply(({ProfileChat chat, String text}) reply) {
    if (!host.mounted || !host.loopFocus) {
      conversation = null;
      return;
    }
    final settings = VoicePreferences.read(_controller.preferences);
    final offline = VoiceOfflinePrefs.read(_controller.preferences);
    // Car mode's own loop switch overrides the saved setting while active.
    final conversationLoopOn = _car.active ? _car.loopOn : offline.conversation;
    if (!conversationLoopOn) conversation = null;
    if (!(offline.autoSpeak || offline.conversation || _car.active) ||
        _voiceInput.active) {
      return;
    }
    final chat = reply.chat;
    if (host.currentChat != chat) {
      return;
    }
    if (!awaitingReply) conversation = null;
    awaitingReply = false;
    if (_bargeIn.chat == chat.key && _bargeIn.listener.speechInProgress) {
      // D3: the user is already talking; the reply stays in the chat and
      // the utterance becomes the next prompt.
      return;
    }
    if (host.playbackBargeIn(chat, offline)) {
      host.openListen(chat, playback: true);
    } else {
      unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));
    }
    host.voiceOwner = chat.key;
    final connection = _controller.connection;
    final profile = chat.key.workspace.profileName;
    autoSpeakQueue.add(
      () => _voiceOutput.speak(
        (chat.key, 'auto-reply'),
        reply.text,
        settings,
        () => HermesVoice.forConnection(connection, profile),
      ),
      (finished) {
        if (!finished) {
          // Stop speech, a newer playback or a failure ends the conversation,
          // unless the user already tapped the microphone again or a barge-in
          // stopped the reply (its listen round keeps the conversation).
          if (!_voiceInput.active && !_bargeIn.listening) conversation = null;
          return;
        }
        if (_bargeIn.listening && _bargeIn.chat == chat.key) {
          // Read-aloud ended: the open round replaces the reopened dictation
          // and uses the normal rules once no other reply waits to be read.
          if (autoSpeakQueue.isEmpty) _bargeIn.setPlayback(false);
          if (chat.voiceBusy) awaitingReply = true;
          return;
        }
        if (conversation == chat.key && chat.voiceBusy && _bargeIn.steered) {
          // The gateway runs a steer that arrived during the final answer as
          // a follow-up turn; its reply belongs to this conversation.
          awaitingReply = true;
          host.openListen(chat);
          return;
        }
        if (canContinueConversation(chat)) {
          unawaited(host.run(() => host.dictate(chat, resume: true)));
        }
      },
    );
  }

  /// The microphone never reopens unasked: only for the conversation's own
  /// chat, on screen, idle, with nothing waiting for the user's input, and
  /// with the auto-speak queue (spec 2026-10-15) fully drained — a reply
  /// still waiting its turn must finish before the mic opens.
  bool canContinueConversation(ProfileChat chat) {
    final ok =
        host.mounted &&
        conversation == chat.key &&
        host.loopFocus &&
        host.currentChat == chat &&
        !_controller.switching &&
        !chat.voiceBusy &&
        !chat.opening &&
        !chat.commandRunning &&
        !chat.changingAnswer &&
        chat.editingQueuedPrompt == null &&
        !chat.needsUserInput &&
        !_voiceInput.active &&
        _voiceOutput.owner == null &&
        autoSpeakQueue.isEmpty &&
        (_car.active
            ? _car.loopOn
            : VoiceOfflinePrefs.read(_controller.preferences).conversation);
    if (!ok) conversation = null;
    return ok;
  }

  /// The post-dictation send of a conversation-mode dictation.
  Future<void> onDictated(ProfileChat chat) => sendConversationTurn(chat);

  /// Conversation mode: send a dictation the recognizer ended on its own.
  /// A running turn gets the text steered in instead of losing it, a down
  /// connection queues it for once the connection returns; anything else
  /// that blocks a normal send ends the conversation instead.
  Future<void> sendConversationTurn(ProfileChat chat) async {
    final text = chat.voiceDraft.trim();
    // Car mode: offline, the draft waits on the device (spec §4.4).
    if (conversation == chat.key && text.isNotEmpty && _car.holdForConnection()) {
      _car.logDelivery(CarDelivery.queue);
      return;
    }
    // Car mode: speech while Hermes works steers the running turn (spec §6.4).
    // Barge-in (t_7e81e040) replaces this block with its decideDelivery hook;
    // keep the _car.logDelivery call when it does.
    if (_car.active &&
        host.mounted &&
        chat.voiceBusy &&
        conversation == chat.key &&
        text.isNotEmpty &&
        !text.startsWith('/')) {
      final actions = host.composerActions(chat);
      final delivery = carDeliveryFor(
        working: true,
        steerAvailable: actions[ComposerAction.steer] == null,
        queueAvailable: actions[ComposerAction.queue] == null,
      );
      _car.logDelivery(delivery);
      if (delivery != CarDelivery.end) {
        awaitingReply = true;
        await host.performComposerAction(
          chat,
          delivery == CarDelivery.steer ? ComposerAction.steer : ComposerAction.queue,
          conversation: true,
        );
        return;
      }
    }
    if (!host.mounted ||
        conversation != chat.key ||
        _controller.current?.chat != chat ||
        !host.onChatsDestination ||
        text.isEmpty ||
        text.startsWith('/')) {
      conversation = null;
      return;
    }
    if (_controller.recovering || chat.opening || chat.offlineSnapshot) {
      awaitingReply = true;
      await _controller.queuePrompt(chat, text);
      return;
    }
    final actions = host.composerActions(chat);
    if (chat.voiceBusy) {
      if (actions[ComposerAction.steer] != null) {
        conversation = null;
        return;
      }
      awaitingReply = true;
      final accepted = await _controller.steer(chat, text);
      if (accepted && chat.voiceDraft.trim() == text) {
        await _controller.updateDraft(chat, '');
      }
      // Listen while Hermes works (spec 2026-10-14 barge-in): keep
      // listening for a follow-up turn the gateway may start after a steer.
      if (accepted) host.openListen(chat);
      return;
    }
    if (actions[ComposerAction.send] != null) {
      conversation = null;
      return;
    }
    _car.logDelivery(CarDelivery.send);
    awaitingReply = true;
    _bargeIn.beginTurn();
    // Fresh route verdict for when this turn's reply is read aloud.
    unawaited(host.headphones.refresh());
    await host.performComposerAction(
      chat,
      ComposerAction.send,
      conversation: true,
    );
    if (chat.voiceBusy) host.openListen(chat);
    if (!chat.voiceBusy && !_voiceInput.active && _voiceOutput.owner == null) {
      conversation = null;
    }
  }
}
