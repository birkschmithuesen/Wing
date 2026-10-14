/// Guesses German or English for one sentence from function words, offline.
///
/// Nouns never count, so English terms ("Pull Request", "Kanban") inside a
/// German sentence leave it German. Words common to both languages are in
/// neither list: in, an, so, was, will, also, man, am, a.
library;

enum SpeechLanguage { de, en }

const _german = {
  'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', //
  'einer', 'eines', 'und', 'oder', 'aber', 'nicht', 'kein', 'keine', 'ist',
  'sind', 'bin', 'bist', 'hat', 'habe', 'haben', 'hast', 'hatte', 'wird',
  'werden', 'wurde', 'ich', 'du', 'er', 'sie', 'wir', 'ihr', 'mich', 'mir',
  'dich', 'dir', 'uns', 'euch', 'sich', 'mit', 'von', 'zu', 'zum', 'zur',
  'für', 'auf', 'aus', 'bei', 'nach', 'über', 'unter', 'vor', 'wie', 'wenn',
  'dass', 'weil', 'auch', 'noch', 'schon', 'nur', 'sehr', 'hier', 'dort',
  'jetzt', 'heute', 'dann', 'doch', 'mal', 'ja', 'nein', 'gibt', 'kann',
  'können', 'muss', 'soll', 'diese', 'dieser', 'dieses', 'wieder', 'immer',
  'alle', 'alles', 'etwas', 'nichts', 'mehr', 'um', 'ob', 'oft', 'sein',
  'seine', 'ihre', 'ihren', 'unser',
};

const _english = {
  'the', 'and', 'or', 'but', 'not', 'is', 'are', 'were', 'be', 'been', //
  'being', 'has', 'have', 'had', 'do', 'does', 'did', 'i', 'you', 'he', 'she',
  'we', 'they', 'it', 'its', 'this', 'that', 'these', 'those', 'with', 'from',
  'for', 'of', 'to', 'on', 'at', 'by', 'as', 'if', 'than', 'what', 'which',
  'who', 'when', 'where', 'why', 'how', 'there', 'here', 'my', 'your', 'his',
  'her', 'our', 'their', 'me', 'him', 'us', 'them', 'can', 'could', 'would',
  'should', 'just', 'about', 'into', 'because', 'only', 'very', 'well',
  "don't", "doesn't", "didn't", "i'm", "i've", "you're", "we're", "they're",
  "isn't", "aren't", "wasn't", "it's", "that's", "there's", "let's",
};

final _word = RegExp(r"[a-zäöüß']+");
final _umlaut = RegExp('[äöüß]');
final _edgeQuotes = RegExp(r"^'+|'+$");

SpeechLanguage? guessLanguage(String sentence) {
  var de = 0;
  var en = 0;
  final text = sentence.toLowerCase().replaceAll('’', "'");
  for (final match in _word.allMatches(text)) {
    final word = match[0]!.replaceAll(_edgeQuotes, '');
    if (_german.contains(word)) de++;
    if (_umlaut.hasMatch(word)) de++;
    if (_english.contains(word)) en++;
  }
  if (en >= 1 && en >= 2 * de) return SpeechLanguage.en;
  if (de >= 1 && de >= en) return SpeechLanguage.de;
  return null;
}
