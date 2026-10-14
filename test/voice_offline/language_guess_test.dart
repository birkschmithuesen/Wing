import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/language_guess.dart';

void main() {
  const cases = <String, SpeechLanguage?>{
    // German frame
    'Hier ist die kurze Vorstellung, um die du gebeten hast.': SpeechLanguage.de,
    'Soll ich daraus noch eine kürzere Fassung machen?': SpeechLanguage.de,
    'Die App läuft.': SpeechLanguage.de,
    // English terms inside German sentences stay German
    'Den Pull Request für das Kanban-Board habe ich schon vorbereitet.':
        SpeechLanguage.de,
    'Das ist ein Update für dich.': SpeechLanguage.de,
    'Das ist the best.': SpeechLanguage.de,
    // English
    'Robo is a friendly assistant who lives on a small server.':
        SpeechLanguage.en,
    'It helps with code reviews, calendars and long lists of tasks.':
        SpeechLanguage.en,
    'When it is not working, it likes to read about old trains.':
        SpeechLanguage.en,
    'It’s done, isn’t it?': SpeechLanguage.en,
    // An English clause dominates a short German lead-in
    'Er sagte: the fix is fine and it works.': SpeechLanguage.en,
    // No evidence: unsure
    'Kanban.': null,
    'Thanks!': null,
    'Pull Request': null,
    '': null,
  };

  for (final entry in cases.entries) {
    test('"${entry.key}" -> ${entry.value?.name ?? 'unsure'}', () {
      expect(guessLanguage(entry.key), entry.value);
    });
  }

  test('ambiguous words count for neither language', () {
    // in, an, so, was, will, also, man, am are in both or neither list.
    expect(guessLanguage('so was in an also man will am'), isNull);
  });
}
