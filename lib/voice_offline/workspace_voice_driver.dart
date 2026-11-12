import 'dart:async';

import 'package:flutter/material.dart';

import '../car_mode/car_mode_bridge.dart';
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
import 'barge_in_policy.dart';
import 'car_mic_session.dart';
import 'chat_voice_view.dart';
import 'headphone_route.dart';
import 'speech_queue.dart';
import 'turn_listener.dart';
import 'vad_voice_device.dart';
import 'voice_offline_prefs.dart';

/// What the workspace screen offers the fork voice driver. Implemented by
/// ProfileWorkspaceScreenState, so the screen keeps only one-line hooks.
///
/// The members from [run] on expose screen state and actions the voice code
/// reaches into: the screen's error wrapper, its composer and destination, and
/// the voice owner it keeps for its own read-aloud.
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

  bool get onChatsDestination;
  bool get routeIsCurrent;
  bool get appIsActive;

  /// The workspace has the focus of the chat on screen.
  bool get hasChatFocus;

  Map<ComposerAction, String?> composerActions(ProfileChat chat);
  TextEditingController get composer;
  Future<T?> runValue<T>(Future<T> Function() action);
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

  late final background = BackgroundVoice(
    backgroundHost ?? AndroidBackgroundVoiceHost.instance,
    onStopped: cancel,
  );

  /// Keeps a connected car kit's SCO link open for a whole hands-free
  /// conversation - dictation, listening-in and read-aloud barge-in -
  /// instead of per round (spec Birk decision 2026-10-19).
  late final carMic = CarMicSession(device);

  late final CarModeSession car = CarModeSession(
    device: device,
    bridge: CarModeBridge(
      changes: Listenable.merge([
        _controller,
        _controller.connectionStatus,
        _voiceInput,
        _voiceOutput,
        bargeIn,
      ]),
      read: () => carSnapshotOf(
        _controller,
        _voiceInput,
        _voiceOutput,
        bargeIn: bargeIn,
      ),
      preferences: _controller.preferences,
      appPreferences: _controller.appPreferences,
      talk: () async {
        final chat = _controller.notificationChat ?? _controller.current?.chat;
        if (chat != null) await host.run(() => host.dictate(chat));
      },
      sendNow: () {
        carSend = true;
        return _voiceInput.stopHandsFree();
      },
      stopSpeech: _voiceOutput.stop,
      retry: () => host.run(_controller.resumeConnection),
      sendHeld: () async {
        final chat = _controller.notificationChat ?? _controller.current?.chat;
        if (chat == null) return;
        conversation = chat.key;
        await host.run(() => sendConversationTurn(chat));
      },
      leave: cancel,
    ),
  );

  bool get carActive => car.active;

  Future<void> enterCarMode(BuildContext context) => car.enter(context);

  /// Car mode entry/exit changes the screen's chat focus without a dependency
  /// change the route system would notify on its own; resync here instead.
  void _carActiveChanged() {
    _controller.setRouteVisibility(host, host.hasChatFocus);
    syncMediaKeys();
  }

  /// Ends the voice session (the screen's cancel).
  void cancel() {
    endLoop();
    host.voiceOwner = null;
    autoSpeakQueue.clear();
    queuedUnsolicitedReplies.clear();
    unawaited(_voiceInput.cancel().catchError((Object _) {}));
    unawaited(_voiceOutput.stop().catchError((Object _) {}));
  }

  /// Listen rounds while Hermes works (spec 2026-10-14 barge-in).
  late final bargeIn = BargeInCoordinator(
    TurnListener(
      device: device,
      carMicSession: carMic,
      carKitConnected: carKitConnected,
    ),
  );

  bool carKitConnected() => isCarKitClass(headphones.bluetoothClass);

  /// Voice barge-in into read-aloud only with headphones, wired or Bluetooth
  /// (spec §3.4.1, D2; owner lifted the Bluetooth lock 2026-10-20 without an
  /// echo measurement, t_fabcb273). The car mode screen's "Interrupt by
  /// speaking" switch lifts the Wing car mode lock for the running session
  /// only (see [playbackBargeIn]).
  late final headphones = HeadphoneRoute(
    headphoneHost ?? AndroidHeadphoneRouteHost.instance,
    wingCarMode: () => car.active,
    bargeInOverride: () => car.bargeInOn,
  );

  /// initState part.
  void attach() {
    bargeIn.addListener(_bargeInChanged);
    _liveWorkspaces++;
    _autoSpeak = _controller.completedReplies.listen(_speakCompletedReply);
    _voiceInput.addListener(_voiceInputChanged);
    _voiceDeviceEvents = device.events.listen(_voiceDeviceEvent);
  }

  /// initState part, after [attach]: car mode and the output route.
  void attachRoute() {
    car.addListener(_carActiveChanged);
    car.addListener(headphones.carModeChanged);
    headphones.addListener(_headphoneRouteChanged);
  }

  /// dispose part, first: the car mode session and its microphone.
  void disposeCar() {
    car.removeListener(_carActiveChanged);
    car.removeListener(headphones.carModeChanged);
    car.dispose();
    carMic.dispose();
  }

  /// dispose part, after [disposeCar]. Also disposes the screen's voice
  /// controllers and the parts that follow them.
  void detach() {
    unawaited(_autoSpeak?.cancel());
    if (_conversationKey != null) {
      VoiceSwitchHolders.screenOn(device).set(host, false);
    }
    _voiceInput.removeListener(_voiceInputChanged);
    unawaited(_voiceDeviceEvents?.cancel());
    _voiceInput.dispose();
    _voiceOutput.dispose();
    background.dispose();
    bargeIn.dispose();
    headphones.dispose();
  }

  /// dispose part, after the screen dropped its route visibility.
  void releaseDevice() {
    if (_mediaKeysOn) {
      _mediaKeysOn = false;
      VoiceSwitchHolders.mediaKeys(device).set(host, false);
    }
    // A replacement workspace may already hold the model; release it only
    // when the last workspace goes away.
    if (--_liveWorkspaces <= 0 && vadRoute() == true) {
      unawaited(
        VadVoiceDevice.of(device).releaseVad().catchError((Object _) {}),
      );
    }
  }

  /// The app lifecycle part: whether a held background service keeps the
  /// voice session alive across [state].
  bool keepsVoice(AppLifecycleState state) => background.keepsVoice(state);

  void lifecycle(AppLifecycleState state) => background.lifecycle(state);

  static int _liveWorkspaces = 0;
  bool _mediaKeysOn = false;
  StreamSubscription<Map<String, dynamic>>? _voiceDeviceEvents;

  /// Chat focus for the conversation loop; a held hold also counts when the app is paused (spec 2026-10-14).
  bool get loopFocus =>
      (host.routeIsCurrent || car.active) &&
      host.onChatsDestination &&
      (host.appIsActive || background.held);

  /// Route vad: preload the phone model. Media keys are captured only while
  /// this workspace is the focused chat on the vad route (spec: foreground).
  void syncVadRoute() {
    final vad = vadRoute();
    if (vad == null) return;
    syncMediaKeys();
    if (vad) unawaited(VadVoiceDevice.of(device).prepareVad().catchError((Object _) {}));
  }

  bool? vadRoute() {
    final settings = tryReadVoicePreferences(_controller.preferences);
    return settings == null ? null : settings.input == VoiceInputRoute.vad;
  }

  void syncMediaKeys() {
    final want = (vadRoute() ?? false) && host.hasChatFocus;
    if (want == _mediaKeysOn) return;
    _mediaKeysOn = want;
    VoiceSwitchHolders.mediaKeys(device).set(host, want);
  }

  void _voiceDeviceEvent(Map<String, dynamic> event) {
    if (event['mediaKey'] != 'playPause' ||
        !host.mounted ||
        !host.hasChatFocus) {
      return;
    }
    if (vadRoute() != true) {
      return;
    }
    if (bargeIn.listening && _voiceOutput.owner == null) {
      unawaited(bargeIn.listener.endUtterance());
      return;
    }
    if (_voiceInput.phase == VoiceInputPhase.recording) {
      unawaited(_voiceInput.stopHandsFree());
      return;
    }
    if (_voiceInput.active) return;
    final chat = _controller.notificationChat ?? _controller.current?.chat;
    if (chat == null || _controller.switching || chat.needsUserInput) return;
    unawaited(host.run(() => host.dictate(chat)));
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
      unawaited(bargeIn.close('conversationEnd').catchError((Object _) {}));
      if (value == null) unawaited(carMic.end('end').catchError((Object _) {}));
    }
    _conversationKey = value;
    background.sync(
      want: value != null && vadRoute() == true && !car.active,
    );
  }

  /// True from the conversation's auto-send until its reply arrived. Only
  /// that reply may reopen the microphone, never a later or queued turn.
  bool awaitingReply = false;

  void _voiceInputChanged() {
    // Silence, no speech or a recognizer error ends the conversation.
    if (!_voiceInput.active && _voiceInput.error != null) conversation = null;
  }

  void _bargeInChanged() {
    background.listening(bargeIn.listening);
    if (!bargeIn.listening) _flushQueuedReplies();
  }

  StreamSubscription<({ProfileChat chat, String text})>? _autoSpeak;

  /// Serializes auto-spoken replies: a newer one waits for the one already
  /// playing instead of cutting it off (spec 2026-10-15 queue). Explicit
  /// actions (mic tap, stop, manual read-aloud, barge-in) clear it instead of
  /// going through it.
  final autoSpeakQueue = SpeechQueue();

  /// Unsolicited replies (e.g. a background job's own turn) that arrived
  /// while the mic or [autoSpeakQueue] was busy: an unsolicited reply never
  /// speaks over an open mic, and never shares [autoSpeakQueue] with another
  /// reply still playing (spec t_0179b15f), so it waits here one at a time
  /// until recording, the barge-in listen round and the speech queue are
  /// all clear.
  final queuedUnsolicitedReplies = <({ProfileChat chat, String text})>[];

  /// Hands-free voice chat: read a finished reply aloud when the user enabled
  /// "Spoken replies" or "Conversation mode", the chat is on screen and nobody
  /// is dictating. Replies queue behind each other in arrival order; the
  /// microphone only reopens once the queue drained after the last one.
  void _speakCompletedReply(({ProfileChat chat, String text}) reply) {
    if (!host.mounted || !loopFocus) {
      conversation = null;
      return;
    }
    final settings = VoicePreferences.read(_controller.preferences);
    final offline = VoiceOfflinePrefs.read(_controller.preferences);
    // Car mode's own loop switch overrides the saved setting while active.
    final conversationLoopOn = car.active ? car.loopOn : offline.conversation;
    if (!conversationLoopOn) conversation = null;
    if (!(offline.autoSpeak || offline.conversation || car.active)) {
      return;
    }
    final chat = reply.chat;
    if (host.currentChat != chat) {
      return;
    }
    // An unsolicited reply (e.g. a background job's own turn) must never end
    // a conversation loop it did not start, and it never speaks over an open
    // mic. It also never shares autoSpeakQueue with another reply still
    // playing - two entries resident there at once make the first one's own
    // settle null the conversation via the isEmpty check below - so it waits
    // in this side queue, flushed one at a time once the mic and the speech
    // queue are both clear (spec t_0179b15f).
    final unsolicited = !awaitingReply;
    if (unsolicited &&
        (_voiceInput.active || bargeIn.listening || !autoSpeakQueue.isEmpty)) {
      queuedUnsolicitedReplies.add(reply);
      return;
    }
    if (_voiceInput.active) return;
    awaitingReply = false;
    if (bargeIn.chat == chat.key && bargeIn.listener.speechInProgress) {
      // D3: the user is already talking; the reply stays in the chat and
      // the utterance becomes the next prompt.
      return;
    }
    if (playbackBargeIn(chat, offline)) {
      openListen(chat, playback: true);
    } else {
      unawaited(bargeIn.close('turnEnd').catchError((Object _) {}));
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
          if (!_voiceInput.active && !bargeIn.listening) conversation = null;
          return;
        }
        if (bargeIn.listening && bargeIn.chat == chat.key) {
          // Read-aloud ended: the open round replaces the reopened dictation
          // and uses the normal rules once no other reply waits to be read.
          if (autoSpeakQueue.isEmpty) bargeIn.setPlayback(false);
          if (chat.voiceBusy) awaitingReply = true;
          return;
        }
        if (conversation == chat.key && chat.voiceBusy && bargeIn.steered) {
          // The gateway runs a steer that arrived during the final answer as
          // a follow-up turn; its reply belongs to this conversation.
          awaitingReply = true;
          openListen(chat);
          return;
        }
        if (canContinueConversation(chat)) {
          unawaited(host.run(() => host.dictate(chat, resume: true)));
        }
      },
    );
  }

  /// Speaks the oldest reply a background turn pushed while the mic or the
  /// speech queue was busy, now that both have cleared; a no-op otherwise or
  /// with nothing queued (spec t_0179b15f: never speak over an open mic, and
  /// never alongside another reply in autoSpeakQueue).
  void _flushQueuedReplies() {
    if (queuedUnsolicitedReplies.isEmpty ||
        _voiceInput.active ||
        bargeIn.listening ||
        !autoSpeakQueue.isEmpty) {
      return;
    }
    _speakCompletedReply(queuedUnsolicitedReplies.removeAt(0));
  }

  /// The microphone never reopens unasked: only for the conversation's own
  /// chat, on screen, idle, with nothing waiting for the user's input, and
  /// with the auto-speak queue (spec 2026-10-15) fully drained — a reply
  /// still waiting its turn must finish before the mic opens. A queued
  /// unsolicited reply (spec t_0179b15f) takes that turn first instead,
  /// without ending the loop.
  bool canContinueConversation(ProfileChat chat) {
    if (queuedUnsolicitedReplies.isNotEmpty) {
      _flushQueuedReplies();
      return false;
    }
    final ok =
        host.mounted &&
        conversation == chat.key &&
        loopFocus &&
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
        (car.active
            ? car.loopOn
            : VoiceOfflinePrefs.read(_controller.preferences).conversation);
    if (!ok) conversation = null;
    return ok;
  }

  /// Conversation mode: send a dictation the recognizer ended on its own.
  /// A running turn gets the text steered in instead of losing it, a down
  /// connection queues it for once the connection returns; anything else
  /// that blocks a normal send ends the conversation instead.
  Future<void> sendConversationTurn(ProfileChat chat) async {
    final text = chat.voiceDraft.trim();
    // Car mode: offline, the draft waits on the device (spec §4.4).
    if (conversation == chat.key && text.isNotEmpty && car.holdForConnection()) {
      car.logDelivery(CarDelivery.queue);
      return;
    }
    // Car mode: speech while Hermes works steers the running turn (spec §6.4).
    // Barge-in (t_7e81e040) replaces this block with its decideDelivery hook;
    // keep the car.logDelivery call when it does.
    if (car.active &&
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
      car.logDelivery(delivery);
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
      if (accepted) openListen(chat);
      return;
    }
    if (actions[ComposerAction.send] != null) {
      conversation = null;
      return;
    }
    car.logDelivery(CarDelivery.send);
    awaitingReply = true;
    bargeIn.beginTurn();
    // Fresh route verdict for when this turn's reply is read aloud.
    unawaited(headphones.refresh());
    await host.performComposerAction(
      chat,
      ComposerAction.send,
      conversation: true,
    );
    if (chat.voiceBusy) openListen(chat);
    if (!chat.voiceBusy && !_voiceInput.active && _voiceOutput.owner == null) {
      conversation = null;
    }
  }

  ListenTarget _listenTarget(ProfileChat chat) => CallbackListenTarget(
    readState: () => chat.listenState,
    onSteer: (text) async =>
        await host.runValue(
          () => _controller.steer(chat, text, preserveComposer: true),
        ) ==
        true,
    onQueue: (text) => host.run(() => _controller.queuePrompt(chat, text)),
    onSend: (text) async {
      if (!host.mounted || conversation != chat.key) return;
      final value = insertVoiceTranscript(host.composer.value, text);
      host.composer.value = value;
      await host.run(() async {
        await _controller.updateDraft(chat, value.text);
        await sendConversationTurn(chat);
      });
    },
  );

  /// Opens a listen round for the conversation's chat (vad route only).
  void openListen(ProfileChat chat, {bool playback = false}) {
    final settings = tryReadVoicePreferences(_controller.preferences);
    if (settings == null) return;
    final offline = VoiceOfflinePrefs.read(_controller.preferences);
    if (!host.mounted ||
        conversation != chat.key ||
        settings.input != VoiceInputRoute.vad ||
        !offline.conversation ||
        !(offline.listenTurn || playback)) {
      return;
    }
    unawaited(
      bargeIn
          .open(
            chat.key,
            _listenTarget(chat),
            offline,
            playback: playback,
            onBarge: () {
              autoSpeakQueue.clear();
              queuedUnsolicitedReplies.clear();
              bargeLog(headphones.logLine);
              return _voiceOutput.stop();
            },
          )
          .catchError((Object _) {}),
    );
  }

  /// Voice barge-in into read-aloud (spec §3.4, D2): setting on, echo gate
  /// passed, the conversation's chat, output on headphones — wired or
  /// Bluetooth (owner lifted the Bluetooth lock 2026-10-20 without an echo
  /// measurement, t_fabcb273) — or the car mode screen's "Interrupt by
  /// speaking" switch lifted the carMode lock for this session.
  bool playbackBargeIn(ProfileChat chat, VoiceOfflinePrefs offline) =>
      bargeInPlaybackAvailable &&
      offline.bargeInPlayback &&
      conversation == chat.key &&
      (headphones.headphones || headphones.carModeOverridden);

  /// The output route changed while Wing reads aloud (spec §3.4.2): headphones
  /// gone closes a playback round, headphones back opens one.
  void _headphoneRouteChanged() {
    // Spec Birk decision 2026-10-19: the car kit itself is gone, so the held
    // SCO link means nothing any more - close it (reason=disconnect) instead
    // of waiting out the idle timeout.
    if (carMic.isOpen && !carKitConnected()) {
      unawaited(carMic.end('disconnect').catchError((Object _) {}));
    }
    final chat = _controller.notificationChat ?? _controller.current?.chat;
    if (!host.mounted ||
        chat == null ||
        conversation != chat.key ||
        _voiceOutput.owner == null) {
      return;
    }
    if (!headphones.headphones && !headphones.carModeOverridden) {
      if (bargeIn.listener.playback) {
        unawaited(bargeIn.close('route').catchError((Object _) {}));
      }
      return;
    }
    if (tryReadVoicePreferences(_controller.preferences) == null) return;
    final offline = VoiceOfflinePrefs.read(_controller.preferences);
    if (!bargeIn.listening && playbackBargeIn(chat, offline)) {
      openListen(chat, playback: true);
    }
  }

  /// The "Listening" row for barge-in capture, spread into the screen's
  /// voice activity column.
  List<Widget> listeningRows() => [
    if (bargeIn.listening && !_voiceInput.active)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                bargeIn.listener.phase == ListenPhase.transcribing
                    ? 'Transcribing…'
                    : 'Listening',
              ),
            ),
            TextButton(
              key: const ValueKey('voice-stop-listening'),
              onPressed: () => unawaited(bargeIn.close('stopButton')),
              child: const Text('Stop listening'),
            ),
          ],
        ),
      ),
  ];

  /// Cancel recording / Stop speech also end the conversation loop.
  void cancelRecording() {
    endLoop();
    unawaited(_voiceInput.cancel());
  }

  void stopSpeech() {
    endLoop();
    unawaited(_voiceOutput.stop());
  }
}
