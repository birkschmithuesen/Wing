/// Splits text for speech into paragraphs of sentences without cutting words.
library;

const _abbreviations = {
  'z.b', 'd.h', 'u.a', 'bzw', 'ca', 'usw', 'vgl', 'nr', 'dr', 'prof', //
  'e.g', 'i.e', 'etc', 'vs', 'mr', 'mrs', 'ms', 'st',
};

final _boundary = RegExp(r'[.!?…]+["“”„«»)\]]*\s+');
final _lastWord = RegExp(r'([\p{L}\d.]+)$', unicode: true);
final _singleLetter = RegExp(r'^\p{L}$', unicode: true);
final _lowercase = RegExp(r'\p{Ll}', unicode: true);

List<List<String>> splitSpeech(String text, {int maxLength = 1000}) {
  final paragraphs = <List<String>>[];
  for (final paragraph in text.split(RegExp(r'\n\s*\n'))) {
    final sentences = <String>[
      for (final line in paragraph.split('\n'))
        for (final sentence in _sentences(line.trim()))
          ..._limit(sentence, maxLength),
    ];
    if (sentences.isNotEmpty) paragraphs.add(sentences);
  }
  return paragraphs;
}

Iterable<String> _sentences(String line) sync* {
  var start = 0;
  for (final match in _boundary.allMatches(line)) {
    if (match.end >= line.length) break;
    if (_lowercase.hasMatch(line[match.end])) continue;
    if (line[match.start] == '.') {
      final word =
          _lastWord
              .firstMatch(line.substring(start, match.start))
              ?.group(1)
              ?.toLowerCase() ??
          '';
      if (_abbreviations.contains(word) || _singleLetter.hasMatch(word)) {
        continue;
      }
    }
    final sentence = line.substring(start, match.end).trim();
    if (sentence.isNotEmpty) yield sentence;
    start = match.end;
  }
  final rest = line.substring(start).trim();
  if (rest.isNotEmpty) yield rest;
}

Iterable<String> _limit(String sentence, int maxLength) sync* {
  var rest = sentence;
  while (rest.length > maxLength) {
    var cut = rest.substring(0, maxLength).lastIndexOf(RegExp(r'[,;:]\s'));
    if (cut > 0) {
      cut += 1;
    } else {
      cut = rest.substring(0, maxLength + 1).lastIndexOf(RegExp(r'\s'));
    }
    if (cut <= 0) cut = maxLength;
    yield rest.substring(0, cut).trim();
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) yield rest;
}
