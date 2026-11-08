import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:uuid/uuid.dart';
import '../services/android_voice.dart';
import '../services/hermes_voice.dart';
import '../models/voice_processing_settings.dart';
import '../models/profile_session_key.dart';
import 'voice_input_controller.dart';

String spokenReplyText(String source) {
  final cleaned = source.replaceAll(
    RegExp(
      r'<think(?:ing)?>[\s\S]*?(?:</think(?:ing)?>|$)',
      caseSensitive: false,
    ),
    '',
  );
  final nodes = markdown.Document(
    extensionSet: markdown.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(cleaned.split('\n'));
  String text(markdown.Node node) {
    if (node is markdown.Text) return node.text;
    if (node is! markdown.Element ||
        {'pre', 'code', 'img', 'script', 'style'}.contains(node.tag)) {
      return '';
    }
    final contents = (node.children ?? []).map(text).join();
    return {
          'p',
          'li',
          'tr',
          'h1',
          'h2',
          'h3',
          'h4',
          'blockquote',
          'br',
        }.contains(node.tag)
        ? '$contents\n'
        : contents;
  }

  return nodes
      .map(text)
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

class VoiceOutputController extends ChangeNotifier {
  final VoiceDevice device;
  late final StreamSubscription<Map<String, dynamic>> _events;
  Object? _owner;
  bool _preparing = false;
  String? _error;
  String? _id;
  bool _disposed = false;
  int _commandGeneration = 0;
  int _notificationDepth = 0;
  ProfileSessionKey? _target;
  RemoteVoice? _remote;
  VoiceOutputController(this.device) {
    _events = device.events.listen((event) {
      if (_id != null && event['id'] == _id && event['playing'] == true) {
        _preparing = false;
        _notify();
      }
    });
  }
  Object? get owner => _owner;
  bool get preparing => _preparing;
  String? get error => _error;

  void _notify() {
    if (_disposed) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  void retainTarget(ProfileSessionKey? target) {
    if (_target != null && _target != target) {
      unawaited(stop().catchError((Object _) {}));
    }
  }

  Future<void> readAloud({
    required VoiceReply reply,
    required VoiceOutputSettings? Function() settings,
    required Future<void> Function() cancelDictation,
    required bool Function(ProfileSessionKey) admitsTarget,
    required bool Function() admitPresentation,
    required RemoteVoice Function(ProfileSessionKey) createRemote,
    required void Function(String) onNotice,
  }) async {
    if (_disposed) return;
    if (_owner == reply.key) {
      await stop();
      return;
    }
    final generation = ++_commandGeneration;
    _target = reply.key.session;
    bool current() =>
        !_disposed &&
        generation == _commandGeneration &&
        admitsTarget(reply.key.session);
    try {
      await cancelDictation();
    } catch (failure) {
      if (current() && admitPresentation()) {
        onNotice(voiceFailureMessage(failure));
      }
      return;
    }
    if (!current() || !admitPresentation()) return;
    final choice = settings();
    if (choice == null) {
      onNotice(
        'Repair voice output settings in App settings before reading aloud.',
      );
      return;
    }
    final pending = speak(
      reply.key,
      reply.text,
      choice,
      () => createRemote(reply.key.session),
    );
    if (_id != null) _target = reply.key.session;
    await pending;
  }

  Future<void> speak(
    Object message,
    String content,
    VoiceOutputSettings settings,
    RemoteVoice Function() createRemote,
  ) => _play(message, (id) async {
    final text = spokenReplyText(content);
    if (text.isEmpty) {
      throw StateError('This message has no prose to read aloud.');
    }
    switch (settings) {
      case HermesVoiceOutputSettings():
        final remote = createRemote();
        _remote = remote;
        final audio = await remote.synthesize(text);
        if (_id != id || _disposed) return;
        await device.play(id, audio);
      case LocalVoiceOutputSettings(:final voice, :final rate):
        await device.speak(id, text, voice: voice, rate: rate.multiplier);
    }
  });

  Future<void> playAudio(Object owner, Future<Uint8List> Function() load) =>
      _play(owner, (id) async {
        final audio = await load();
        if (_id != id || _disposed) return;
        await device.play(id, audio);
      });

  Future<void> _play(
    Object message,
    Future<void> Function(String id) play,
  ) async {
    if (_disposed) return;
    unawaited(stop().catchError((Object _) {}));
    final id = const Uuid().v4();
    _id = id;
    _owner = message;
    _preparing = true;
    _error = null;
    _notify();
    if (_disposed || _id != id) return;
    try {
      await play(id);
    } catch (failure) {
      if (_id == id && !_disposed) _error = voiceFailureMessage(failure);
    } finally {
      if (_id == id && !_disposed) {
        _remote?.close();
        _remote = null;
        _id = null;
        _target = null;
        _owner = null;
        _preparing = false;
        _notify();
      }
    }
  }

  Future<void> stop() async {
    _commandGeneration++;
    _target = null;
    _error = null;
    final id = _id;
    _id = null;
    _remote?.close();
    _remote = null;
    _owner = null;
    _preparing = false;
    _notify();
    if (id != null) await device.stopPlayback(id);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop().catchError((Object _) {}));
    unawaited(_events.cancel());
    if (_notificationDepth == 0) super.dispose();
  }
}
