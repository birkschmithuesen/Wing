import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/sentence_splitter.dart';

void main() {
  test('splits sentences at end punctuation followed by space', () {
    expect(splitSpeech('Hallo Welt. Wie geht es dir? Gut!'), [
      ['Hallo Welt.', 'Wie geht es dir?', 'Gut!'],
    ]);
  });

  test('keeps abbreviations, initials and decimals inside a sentence', () {
    expect(splitSpeech('Das ist z.B. ein Test. Dr. Müller kommt.'), [
      ['Das ist z.B. ein Test.', 'Dr. Müller kommt.'],
    ]);
    expect(splitSpeech('Ask J. Smith, e.g. today. Version 3.4 is out.'), [
      ['Ask J. Smith, e.g. today.', 'Version 3.4 is out.'],
    ]);
  });

  test('does not split before a lowercase word', () {
    expect(splitSpeech('Version 3.4 ist da. und weiter'), [
      ['Version 3.4 ist da. und weiter'],
    ]);
  });

  test('keeps closing quotes with their sentence', () {
    expect(splitSpeech('Er sagte: "Hello there." Dann ging er.'), [
      ['Er sagte: "Hello there."', 'Dann ging er.'],
    ]);
  });

  test('blank lines separate paragraphs, single lines separate sentences', () {
    expect(splitSpeech('Erster Absatz.\n\nZweiter Absatz.\nPunkt zwei'), [
      ['Erster Absatz.'],
      ['Zweiter Absatz.', 'Punkt zwei'],
    ]);
  });

  test('long sentences split at whitespace, never inside a word', () {
    expect(
      splitSpeech('eins zwei drei vier fuenf sechs sieben', maxLength: 20),
      [
        ['eins zwei drei vier', 'fuenf sechs sieben'],
      ],
    );
  });

  test('long sentences prefer a comma as split point', () {
    expect(splitSpeech('eins, zwei drei vier fuenf', maxLength: 20), [
      ['eins,', 'zwei drei vier fuenf'],
    ]);
  });

  test('only a single over-long token is cut hard', () {
    expect(splitSpeech('abcdefghij', maxLength: 5), [
      ['abcde', 'fghij'],
    ]);
  });

  test('empty and blank input give no paragraphs', () {
    expect(splitSpeech(''), isEmpty);
    expect(splitSpeech('  \n\n  '), isEmpty);
  });
}
