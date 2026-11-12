import 'package:flutter_test/flutter_test.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  testWidgets('while Hermes works the microphone listens and steers', (
    tester,
  ) async {
    h.fixture.steerResult = {'status': 'queued', 'text': 'Testsatz eins'};
    await h.vadConversationTurn(tester);
    final chat = h.controller.current!.chat!;
    expect(chat.busy, isTrue);
    expect(h.vadStarts(), 2);
    expect(h.device.vadOptions!.keepPlayback, isTrue);
    expect(find.text('Listening'), findsOneWidget);
    h.device.vadTranscript = 'Testsatz eins';
    await h.windows(tester, 0.9, 30);
    await h.windows(tester, 0.1, 60);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
      'Testsatz eins',
    );
    expect(h.prompts(), 1);
    expect(chat.messages.last['display_kind'], 'steer');
    expect(h.vadStarts(), 3);
    await h.completeReply(tester, 'Fertig.');
    expect(find.text('Listening'), findsNothing);
    await tester.tap(find.text('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('words spoken as the turn ends become the next prompt (D3)', (
    tester,
  ) async {
    await h.vadConversationTurn(tester);
    h.device.vadTranscript = 'Testsatz zwei';
    await h.windows(tester, 0.9, 30);
    // The turn completes while the user is still speaking.
    await h.completeReply(tester, 'Antwort eins.');
    expect(h.device.spoken, isNull);
    await h.windows(tester, 0.1, 60);
    expect(h.prompts(), 2);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Testsatz zwei',
    );
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

  testWidgets('Stop listening closes the round but keeps the conversation', (
    tester,
  ) async {
    await h.vadConversationTurn(tester);
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
    expect(find.text('Listening'), findsNothing);
    await h.completeReply(tester, 'Antwort.');
    expect(h.device.spoken, 'Antwort.');
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.text('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('an approval ends the conversation and the listen round', (
    tester,
  ) async {
    await h.vadConversationTurn(tester);
    h.gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await h.settle(tester);
    expect(find.text('Listening'), findsNothing);
    expect(h.device.cancelled, isNotEmpty);
  });

  testWidgets('listening is off with the setting off', (tester) async {
    await h.listenTurn(false);
    await h.vadConversationTurn(tester);
    expect(h.vadStarts(), 1);
    expect(find.text('Listening'), findsNothing);
    await h.completeReply(tester);
    await tester.tap(find.text('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('media key ends a listen utterance and steers it', (tester) async {
    h.fixture.steerResult = {'status': 'queued', 'text': 'x'};
    await h.vadConversationTurn(tester);
    h.device.vadTranscript = 'Testsatz drei';
    await h.windows(tester, 0.9, 30);
    h.device.emitMediaKey();
    await h.settle(tester);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
      'Testsatz drei',
    );
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

}
