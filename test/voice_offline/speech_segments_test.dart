import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/language_guess.dart';
import 'package:wing/voice_offline/speech_segments.dart';

const acceptanceText =
    'Hier ist die kurze Vorstellung, um die du gebeten hast.\n\n'
    'Robo is a friendly assistant who lives on a small server. '
    'It helps with code reviews, calendars and long lists of tasks. '
    'When it is not working, it likes to read about old trains.\n\n'
    'Soll ich daraus noch eine kürzere Fassung machen? '
    'Den Pull Request für das Kanban-Board habe ich schon vorbereitet.';

void main() {
  test('acceptance text gives de, en, de', () {
    expect(speechSegments(acceptanceText), const [
      SpeechSegment(
        'Hier ist die kurze Vorstellung, um die du gebeten hast.',
        SpeechLanguage.de,
      ),
      SpeechSegment(
        'Robo is a friendly assistant who lives on a small server. '
        'It helps with code reviews, calendars and long lists of tasks. '
        'When it is not working, it likes to read about old trains.',
        SpeechLanguage.en,
      ),
      SpeechSegment(
        'Soll ich daraus noch eine kürzere Fassung machen? '
        'Den Pull Request für das Kanban-Board habe ich schon vorbereitet.',
        SpeechLanguage.de,
      ),
    ]);
  });

  test('unsure sentence takes the previous language, across paragraphs', () {
    expect(speechSegments('Robo is here and it works.\n\nKanban.'), const [
      SpeechSegment('Robo is here and it works.\nKanban.', SpeechLanguage.en),
    ]);
  });

  test('unsure first sentence takes the next decided language', () {
    expect(speechSegments('Bio\n\nRobo is here and it works.'), const [
      SpeechSegment('Bio\nRobo is here and it works.', SpeechLanguage.en),
    ]);
  });

  test('no evidence at all falls back to German', () {
    expect(speechSegments('Kanban.'), const [
      SpeechSegment('Kanban.', SpeechLanguage.de),
    ]);
  });

  test('merging stops at maxLength', () {
    // 12 + 1 + 17 = 30 characters.
    expect(speechSegments('Das ist gut. Das ist sehr gut.', maxLength: 30), const [
      SpeechSegment('Das ist gut. Das ist sehr gut.', SpeechLanguage.de),
    ]);
    expect(speechSegments('Das ist gut. Das ist sehr gut.', maxLength: 29), const [
      SpeechSegment('Das ist gut.', SpeechLanguage.de),
      SpeechSegment('Das ist sehr gut.', SpeechLanguage.de),
    ]);
  });

  test('empty text gives no segments', () {
    expect(speechSegments(''), isEmpty);
  });

  test('payload uses the channel wire format', () {
    expect(speechSegmentsPayload('Das ist gut.\n\nThis is the end.'), [
      {'text': 'Das ist gut.', 'lang': 'de'},
      {'text': 'This is the end.', 'lang': 'en'},
    ]);
  });
}
