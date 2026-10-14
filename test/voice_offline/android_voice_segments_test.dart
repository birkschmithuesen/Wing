import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/android_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(AndroidVoice.channel, null),
  );

  test('speak sends language segments next to the text', () async {
    MethodCall? sent;
    messenger.setMockMethodCallHandler(AndroidVoice.channel, (call) async {
      sent = call;
      return null;
    });
    await AndroidVoice().speak(
      'utterance',
      'Das ist gut.\n\nThis is the end.',
      voice: '',
      rate: 1,
    );
    expect(sent?.method, 'speak');
    final arguments = Map<String, Object?>.from(sent!.arguments as Map);
    expect(arguments['text'], 'Das ist gut.\n\nThis is the end.');
    expect(arguments['segments'], [
      {'text': 'Das ist gut.', 'lang': 'de'},
      {'text': 'This is the end.', 'lang': 'en'},
    ]);
  });
}
