/// Builds language segments for speech output: one entry per run of
/// sentences in the same language. Unsure sentences take the previous
/// decided language, else the next one, else German.
library;

import 'language_guess.dart';
import 'sentence_splitter.dart';

class SpeechSegment {
  final String text;
  final SpeechLanguage language;
  const SpeechSegment(this.text, this.language);

  Map<String, String> toChannel() => {'text': text, 'lang': language.name};

  @override
  bool operator ==(Object other) =>
      other is SpeechSegment &&
      other.text == text &&
      other.language == language;

  @override
  int get hashCode => Object.hash(text, language);

  @override
  String toString() => '${language.name}: $text';
}

List<SpeechSegment> speechSegments(String text, {int maxLength = 1000}) {
  final paragraphs = splitSpeech(text, maxLength: maxLength);
  final guesses = [
    for (final paragraph in paragraphs)
      for (final sentence in paragraph) guessLanguage(sentence),
  ];
  final segments = <SpeechSegment>[];
  var index = 0;
  for (final paragraph in paragraphs) {
    for (var position = 0; position < paragraph.length; position++, index++) {
      final sentence = paragraph[position];
      final language =
          guesses[index] ??
          _previous(guesses, index) ??
          _next(guesses, index) ??
          SpeechLanguage.de;
      final separator = position == 0 ? '\n' : ' ';
      if (segments.isNotEmpty &&
          segments.last.language == language &&
          segments.last.text.length + 1 + sentence.length <= maxLength) {
        segments.last = SpeechSegment(
          '${segments.last.text}$separator$sentence',
          language,
        );
      } else {
        segments.add(SpeechSegment(sentence, language));
      }
    }
  }
  return segments;
}

List<Map<String, String>> speechSegmentsPayload(String text) => [
  for (final segment in speechSegments(text)) segment.toChannel(),
];

SpeechLanguage? _previous(List<SpeechLanguage?> guesses, int index) {
  for (var i = index - 1; i >= 0; i--) {
    if (guesses[i] != null) return guesses[i];
  }
  return null;
}

SpeechLanguage? _next(List<SpeechLanguage?> guesses, int index) {
  for (var i = index + 1; i < guesses.length; i++) {
    if (guesses[i] != null) return guesses[i];
  }
  return null;
}
