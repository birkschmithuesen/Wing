import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:uuid/uuid.dart';
import '../services/android_voice.dart';
import '../services/hermes_voice.dart';
import '../services/voice_preferences.dart';
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
  Object? owner;
  bool preparing = false;
  String? error;
  String? _id;
  bool _disposed = false;
  RemoteVoice? _remote;
  VoiceOutputController(this.device) {
    _events = device.events.listen((event) {
      if (_id != null && event['id'] == _id && event['playing'] == true) {
        preparing = false;
        _notify();
      }
    });
  }
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Completes when playback ends. True only when this utterance played to
  /// its end; a stop, a newer request or a failure yields false.
  Future<bool> speak(
    Object message,
    String content,
    VoicePreferences settings,
    RemoteVoice Function() createRemote,
  ) async {
    if (_disposed) return false;
    unawaited(stop().catchError((Object _) {}));
    final id = const Uuid().v4();
    _id = id;
    owner = message;
    preparing = true;
    error = null;
    _notify();
    var finished = false;
    try {
      final text = spokenReplyText(content);
      if (text.isEmpty) {
        throw StateError('This message has no prose to read aloud.');
      }
      if (settings.output == VoiceProcessing.hermes) {
        final remote = createRemote();
        _remote = remote;
        final audio = await remote.synthesize(text);
        if (_id != id || _disposed) return false;
        await device.play(id, audio);
      } else {
        await device.speak(
          id,
          text,
          voice: settings.voice,
          rate: settings.rate,
        );
      }
      finished = _id == id && !_disposed;
    } catch (failure) {
      if (_id == id && !_disposed) error = voiceFailureMessage(failure);
    } finally {
      if (_id == id && !_disposed) {
        _remote?.close();
        _remote = null;
        _id = null;
        owner = null;
        preparing = false;
        _notify();
      }
    }
    return finished;
  }

  Future<void> stop() async {
    error = null;
    final id = _id;
    _id = null;
    _remote?.close();
    _remote = null;
    owner = null;
    preparing = false;
    _notify();
    if (id != null) await device.stopPlayback(id);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop().catchError((Object _) {}));
    unawaited(_events.cancel());
    super.dispose();
  }
}
