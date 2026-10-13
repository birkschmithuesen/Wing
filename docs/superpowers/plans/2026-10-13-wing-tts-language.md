# Wing TTS language detection (DE/EN) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wing reads each sentence of a reply in its own language (German or English) through the phone's
offline system TTS, with German as the fallback, and never cuts a word between speech chunks.

**Architecture:** Dart splits the spoken text into sentences, guesses DE/EN per sentence with a stopword
heuristic, resolves unsure sentences from their neighbours and merges runs of one language into segments.
`AndroidVoice.speak` sends the segments next to the text. Kotlin queues one utterance per segment and calls
`setLanguage` before each, which SherpaTTS honours per request. An English Piper model is installed into
SherpaTTS on the phone (no Wing download code).

**Tech Stack:**
- Flutter 3.44 / Dart 3.12. Tests run only on GitHub Actions via `bash tools/factory/ci-suite.sh`; there is no
  Flutter SDK on the vServer.
- Kotlin (Android `TextToSpeech`). It is compiled only by `.github/workflows/voice-apk.yml`; there are no Kotlin
  unit tests in this repo.
- Phone: SherpaTTS 3.4 (`org.woheller69.ttsengine`), driven by the Hermes worker via `hadb`.

**Spec:** `docs/superpowers/specs/2026-10-13-wing-tts-language-design.md`. Read sections 2 (facts), 4 (design)
and 6 (overlap) before any task.

## Basis / Rebase (do this before Task 1)

- **Start only after the VAD chain is merged:** card `t_24ef9c3d`, merged into `voice-offline` by card
  `t_145c5731`. Also wait for the max-dictation card `t_d3a672fe` if it is still open. Strategy rule 3
  (`/home/birk/hermes-shared/hermes-entities/tools/technik/wing-fork-upstream-strategie.md`): never merge into
  a running voice chain. If the upstream merge `t_d1d49ff1` has landed by then, start after it as well.
  Branch from `voice-offline` at that point.
  Check that the merge is in:
  `git log --oneline voice-offline | grep -i -m1 vad`
  Expected: a merge or feat commit of the VAD chain. If there is no output, stop; the VAD chain is not merged.
- **Plan-time base:** `voice-offline` = `7bf6c3547d6cc7be934634a86106bdfe0b674afd`. All file:line references
  below are from that commit.
- **Overlap with other chains:**
  - The VAD plan modifies `lib/core/services/android_voice.dart`, `android/.../VoiceChannel.kt`,
    `test/support/voice_fixture.dart`, `voice-apk.yml` and more; max dictation (`t_d3a672fe`) modifies
    `voice_input_controller.dart`, `profile_workspace_screen.dart`, `voice_processing_test.dart`,
    `VoiceCapture.kt`.
  - This plan modifies only `lib/core/services/android_voice.dart` (2 lines), `VoiceChannel.kt` (1 call site),
    `VoicePlayback.kt` (signature + 5 lines). Everything else is new files.
  - **Do not touch** `voice_output_controller.dart`, `voice_fixture.dart`, `voice_processing_test.dart`,
    `build.gradle.kts`, `pubspec.yaml` or any workflow file.
- **Re-verify every cited line against the start commit** before Task 1:
  - `grep -n "text.chunked" android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt`
    Expected: one hit (line 118 at plan time).
  - `grep -n "fun speak" android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt`
    Expected: one hit (line 104 at plan time) with parameters `(owner: String, text: String, voiceName: String, rate: Float, response: MethodChannel.Result)`.
  - `grep -n "playback.speak" android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
    Expected: one hit (line 53 at plan time).
  - `grep -n "'rate': rate," lib/core/services/android_voice.dart`
    Expected: one hit (line 93 at plan time) inside `AndroidVoice.speak`.
  - `ls tools/factory/dispatch-check.sh`
    Expected: the file exists (created by VAD Task 9). If it does not, Kotlin compile checks happen only after
    merge, in Task 6 Step 1; note that on the card.
  If line numbers moved, use the new ones. If the text no longer exists, stop and report.

## Global Constraints

- Offline only: no cloud TTS, no cloud language ID, no new dependency (`pubspec.yaml` and Gradle stay unchanged).
- Default when unsure: German (`de`).
- Own code in own files: Dart in `lib/voice_offline/`, tests in `test/voice_offline/`, Kotlin in
  `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/`. Upstream files get only thin hooks.
- Logs never contain reply text: only language, status, timing, length.
- Test texts are synthetic. No session data or personal text in the repo.
- `flutter analyze --fatal-infos` must stay clean (lints: `package:flutter_lints/flutter.yaml`).
- One command per shell call in factory runs; long commands with a 900000 ms timeout, never in the background.
- Commit after every task on the current branch. No merge, no push except the throwaway refs that
  `ci-suite.sh` / `dispatch-check.sh` push and delete themselves.
- Phone steps (install, adb, listening test) are done by the **Hermes worker via `hadb`**, never by a Claude
  Code subagent. They are marked **[Hermes worker]**.
- `ANNAHME:` marks an unverified assumption with the check that settles it.

## File map

| File | Status | Responsibility |
|---|---|---|
| `lib/voice_offline/sentence_splitter.dart` | create | `splitSpeech`: paragraphs → sentences, no word cut. |
| `lib/voice_offline/language_guess.dart` | create | `SpeechLanguage`, `guessLanguage`: DE/EN/unsure per sentence. |
| `lib/voice_offline/speech_segments.dart` | create | `SpeechSegment`, `speechSegments`, `speechSegmentsPayload`. |
| `lib/core/services/android_voice.dart` | modify | `AndroidVoice.speak` sends `segments`. |
| `test/voice_offline/sentence_splitter_test.dart` | create | Splitter tests. |
| `test/voice_offline/language_guess_test.dart` | create | Guess tests. |
| `test/voice_offline/speech_segments_test.dart` | create | Segment tests incl. the acceptance text. |
| `test/voice_offline/android_voice_segments_test.dart` | create | Channel hook test. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/LanguageSpeech.kt` | create | Queue one utterance per segment in its language, log decisions. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` | modify | `speak` takes `segments`, delegates queueing. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | modify | Pass `segments` from the channel. |
| `docs/VOICE_LANGUAGE.md` | create | How detection works, phone setup, how to swap the English voice, log format. |

Task order: 1 → 2 → 3 → 4 → 5 (code, Claude Code coder) → 6 (phone setup, Hermes worker) → 7 (on-device
acceptance, Hermes worker + Birk). Tasks 1-4 are verified by `ci-suite.sh`; Task 5 by `dispatch-check.sh`
(Kotlin compile) and `ci-suite.sh`.

The acceptance text (synthetic, used in Task 3 tests and Task 7 on the device):

```
Hier ist die kurze Vorstellung, um die du gebeten hast.

Robo is a friendly assistant who lives on a small server. It helps with code reviews, calendars and long lists of tasks. When it is not working, it likes to read about old trains.

Soll ich daraus noch eine kürzere Fassung machen? Den Pull Request für das Kanban-Board habe ich schon vorbereitet.
```

Expected segments: `de`, `en`, `de`.

---

### Task 1: Sentence splitter

**Files:**
- Create: `lib/voice_offline/sentence_splitter.dart`
- Test: `test/voice_offline/sentence_splitter_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `List<List<String>> splitSpeech(String text, {int maxLength = 1000})`. Outer list = paragraphs,
  inner list = trimmed, non-empty sentences; every sentence has `length <= maxLength`; words are cut only if a
  single token is longer than `maxLength`.

- [ ] **Step 1: Write the failing test**

`test/voice_offline/sentence_splitter_test.dart`:

```dart
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 1; the last line reads `ci-suite: run <id> conclusion=failure …`, with a failed step under
analyze or test (`sentence_splitter.dart` does not exist yet).

- [ ] **Step 3: Write the implementation**

`lib/voice_offline/sentence_splitter.dart`:

```dart
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
```

Notes for the implementer:
- `"Ask J. Smith, e.g. today."`: the boundary after `J.` is skipped (single letter), the one after `e.g.` is
  skipped (abbreviation `e.g`).
- `"3.4"` has no whitespace after the dot, so `_boundary` never matches inside it.
- In `_limit`, the comma search window is `maxLength` chars and the whitespace window `maxLength + 1`, so a
  chunk is never longer than `maxLength`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 0; last line `ci-suite: run <id> conclusion=success …`.

- [ ] **Step 5: Commit**

```bash
git add lib/voice_offline/sentence_splitter.dart test/voice_offline/sentence_splitter_test.dart
git commit -m "feat(voice): sentence splitter for speech output (no word cuts)"
```

---

### Task 2: Language guess (DE/EN)

**Files:**
- Create: `lib/voice_offline/language_guess.dart`
- Test: `test/voice_offline/language_guess_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum SpeechLanguage { de, en }` and `SpeechLanguage? guessLanguage(String sentence)`
  (`null` = unsure). `SpeechLanguage.name` (`'de'`, `'en'`) is the wire value used in Tasks 3-5.

- [ ] **Step 1: Write the failing test**

`test/voice_offline/language_guess_test.dart`:

```dart
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 1, `conclusion=failure` (`language_guess.dart` does not exist yet).

- [ ] **Step 3: Write the implementation**

`lib/voice_offline/language_guess.dart`:

```dart
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
  if (en >= 2 && en >= 2 * de) return SpeechLanguage.en;
  if (de >= 1 && de >= en) return SpeechLanguage.de;
  return null;
}
```

Hand-check for the implementer (matches the test table):
- "Den Pull Request für das Kanban-Board habe ich schon vorbereitet." → de: den, für (+1 umlaut), das, habe,
  ich, schon = 7; en 0 → `de`.
- "Das ist the best." → de 2, en 1 → `de`.
- "Er sagte: the fix is fine and it works." → de 1 (`er`), en 4 (`the is and it`) → `en`.
- "It’s done, isn’t it?" → `it's`, `isn't`, `it` = 3 → `en`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 0, `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/voice_offline/language_guess.dart test/voice_offline/language_guess_test.dart
git commit -m "feat(voice): offline de/en guess per sentence (stopword heuristic)"
```

---

### Task 3: Speech segments

**Files:**
- Create: `lib/voice_offline/speech_segments.dart`
- Test: `test/voice_offline/speech_segments_test.dart`

**Interfaces:**
- Consumes: `splitSpeech` (Task 1), `SpeechLanguage`, `guessLanguage` (Task 2).
- Produces:
  - `class SpeechSegment { final String text; final SpeechLanguage language; Map<String, String> toChannel(); }`
    with value equality.
  - `List<SpeechSegment> speechSegments(String text, {int maxLength = 1000})`.
  - `List<Map<String, String>> speechSegmentsPayload(String text)` → `[{'text': …, 'lang': 'de'|'en'}]`
    (wire format of Task 4/5).

- [ ] **Step 1: Write the failing test**

`test/voice_offline/speech_segments_test.dart`:

```dart
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 1, `conclusion=failure` (`speech_segments.dart` does not exist yet).

- [ ] **Step 3: Write the implementation**

`lib/voice_offline/speech_segments.dart`:

```dart
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
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 0, `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/voice_offline/speech_segments.dart test/voice_offline/speech_segments_test.dart
git commit -m "feat(voice): build de/en speech segments from reply text"
```

---

### Task 4: Dart hook: send segments over the voice channel

**Files:**
- Modify: `lib/core/services/android_voice.dart` (imports at L1-2; `AndroidVoice.speak` at L84-94)
- Test: `test/voice_offline/android_voice_segments_test.dart`

**Interfaces:**
- Consumes: `speechSegmentsPayload(String text)` (Task 3).
- Produces: the `speak` channel call now carries `'segments': List<Map<String, String>>` next to
  `id`, `text`, `voice`, `rate`. The `VoiceDevice` interface, `VoiceOutputController` and
  `test/support/voice_fixture.dart` stay unchanged.

- [ ] **Step 1: Write the failing test**

`test/voice_offline/android_voice_segments_test.dart`:

```dart
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 1, `conclusion=failure` (`arguments['segments']` is null).

- [ ] **Step 3: Add the hook**

In `lib/core/services/android_voice.dart`, add after `import 'package:flutter/services.dart';` (L2):

```dart
import '../../voice_offline/speech_segments.dart';
```

In `AndroidVoice.speak`, add one entry after `'rate': rate,` (L93):

```dart
  }) => channel.invokeMethod('speak', {
    'id': id,
    'text': text,
    'voice': voice,
    'rate': rate,
    'segments': speechSegmentsPayload(text),
  });
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 0, `conclusion=success`. Existing voice tests (`voice_processing_test.dart`,
`voice_workspace_test.dart`) still pass because they use `VoiceDeviceFixture`, not `AndroidVoice`.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/android_voice.dart test/voice_offline/android_voice_segments_test.dart
git commit -m "feat(voice): send de/en speech segments with every local speak call"
```

---

### Task 5: Kotlin: speak each segment in its language; docs

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/LanguageSpeech.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` (imports L1-19, `speak` at L104,
  chunk loop L118-122)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt:53-54`
- Create: `docs/VOICE_LANGUAGE.md`

**Interfaces:**
- Consumes: channel argument `segments: List<Map<String, String>>?` with keys `text`, `lang` (`"de"`/`"en"`)
  from Task 4.
- Produces:
  - `object LanguageSpeech { fun enqueue(tts: TextToSpeech, owner: String, text: String, segments: List<Map<String, String>>?, voice: Voice?) }`.
    It queues utterances with ids `"$owner:$index"` and `"$owner:last"` (unchanged contract with
    `VoicePlayback`'s listener) and throws `IllegalStateException("Could not generate speech.")` if
    `speak()` fails.
  - Logcat tag `WingTtsLang`, line format
    `segment <i>/<n> lang=<de|en|default> status=<int> ms=<int> chars=<int>` and
    `fallback=de lang=<lang> status=<int>`. Task 7 relies on this format.

- [ ] **Step 1: Create `LanguageSpeech.kt`**

`android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/LanguageSpeech.kt`:

```kotlin
package com.tarkilhk.wing.voiceoffline

import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import android.util.Log
import java.util.Locale

/**
 * Queues one utterance per Dart-built language segment and sets the engine language before each one.
 * SherpaTTS reads the language of every request, so German and English alternate without a manual switch.
 * Logs carry language, status, timing and length only, never reply text.
 */
object LanguageSpeech {
    private const val TAG = "WingTtsLang"
    private val locales = mapOf("de" to Locale.GERMANY, "en" to Locale.US)

    fun enqueue(tts: TextToSpeech, owner: String, text: String, segments: List<Map<String, String>>?, voice: Voice?) {
        val parts = segments.orEmpty()
            .filter { !it["text"].isNullOrBlank() }
            .flatMap { segment -> limit(segment.getValue("text")).map { it to (segment["lang"] ?: "de") } }
            .ifEmpty { limit(text).map { it to "" } }
        parts.forEachIndexed { index, (part, lang) ->
            val started = SystemClock.elapsedRealtime()
            val status = if (lang.isEmpty()) TextToSpeech.SUCCESS else select(tts, lang, voice)
            val elapsed = SystemClock.elapsedRealtime() - started
            Log.i(TAG, "segment ${index + 1}/${parts.size} lang=${lang.ifEmpty { "default" }} status=$status ms=$elapsed chars=${part.length}")
            val tag = if (index == parts.lastIndex) "$owner:last" else "$owner:$index"
            check(tts.speak(part, TextToSpeech.QUEUE_ADD, null, tag) == TextToSpeech.SUCCESS) { "Could not generate speech." }
        }
    }

    private fun select(tts: TextToSpeech, lang: String, voice: Voice?): Int {
        val locale = locales[lang] ?: Locale.GERMANY
        if (voice != null && sameLanguage(voice.locale, locale)) return tts.setVoice(voice)
        val status = tts.setLanguage(locale)
        if (status >= TextToSpeech.LANG_AVAILABLE) return status
        Log.w(TAG, "fallback=de lang=$lang status=$status")
        return if (voice != null) tts.setVoice(voice) else tts.setLanguage(Locale.GERMANY)
    }

    private fun sameLanguage(a: Locale, b: Locale) =
        runCatching { a.isO3Language == b.isO3Language }.getOrDefault(a.language == b.language)

    /** Splits only text longer than the engine limit, at whitespace; a single over-long token is cut. */
    private fun limit(text: String): List<String> {
        val max = TextToSpeech.getMaxSpeechInputLength() - 1
        val parts = mutableListOf<String>()
        var rest = text.trim()
        while (rest.length > max) {
            var cut = rest.lastIndexOfAny(charArrayOf(' ', '\n', '\t'), max)
            if (cut <= 0) cut = max
            parts.add(rest.substring(0, cut).trim())
            rest = rest.substring(cut).trim()
        }
        if (rest.isNotEmpty()) parts.add(rest)
        return parts
    }
}
```

- [ ] **Step 2: Hook into `VoicePlayback.kt`**

Add the import after `import android.speech.tts.UtteranceProgressListener` (L16):

```kotlin
import com.tarkilhk.wing.voiceoffline.LanguageSpeech
```

Change the signature at L104 from
`fun speak(owner: String, text: String, voiceName: String, rate: Float, response: MethodChannel.Result) {`
to:

```kotlin
    fun speak(owner: String, text: String, voiceName: String, rate: Float, segments: List<Map<String, String>>?, response: MethodChannel.Result) {
```

Replace L118-122:

```kotlin
                val chunks = text.chunked(TextToSpeech.getMaxSpeechInputLength() - 1)
                chunks.forEachIndexed { index, chunk ->
                    val tag = if (index == chunks.lastIndex) "$owner:last" else "$owner:$index"
                    check(tts!!.speak(chunk, TextToSpeech.QUEUE_ADD, null, tag) == TextToSpeech.SUCCESS) { "Could not generate speech." }
                }
```

with:

```kotlin
                LanguageSpeech.enqueue(tts!!, owner, text, segments, voice)
```

Leave everything else in `speak` (voice lookup L110-115, `setSpeechRate` L116, the blank check L117, the
`catch`) unchanged.

- [ ] **Step 3: Hook into `VoiceChannel.kt`**

Replace L53-54:

```kotlin
                "speak" -> playback.speak(id, call.argument<String>("text").orEmpty(),
                    call.argument<String>("voice").orEmpty(), call.argument<Number>("rate")?.toFloat() ?: 1f, result)
```

with:

```kotlin
                "speak" -> playback.speak(id, call.argument<String>("text").orEmpty(),
                    call.argument<String>("voice").orEmpty(), call.argument<Number>("rate")?.toFloat() ?: 1f,
                    call.argument<List<Map<String, String>>>("segments"), result)
```

Check that `speak` has no other caller:
Run: `grep -rn "playback.speak\|\.speak(id" android/app/src/main/kotlin`
Expected: exactly the one hit in `VoiceChannel.kt`.

- [ ] **Step 4: Write `docs/VOICE_LANGUAGE.md`**

```markdown
# Voice output language (DE/EN)

Wing reads replies sentence by sentence in German or English. Detection runs on the phone, offline.

## How it works
- `lib/voice_offline/sentence_splitter.dart` splits the spoken text into paragraphs and sentences; no word is cut.
- `lib/voice_offline/language_guess.dart` counts German and English function words per sentence
  (plus umlauts for German). English needs at least 2 hits and twice the German count. Nouns never count, so
  "Pull Request" or "Kanban" inside a German sentence stays German.
- Unsure sentences take the previous decided language, else the next, else German.
- `lib/voice_offline/speech_segments.dart` merges neighbours of the same language; `AndroidVoice.speak` sends
  them as `segments`.
- `android/.../voiceoffline/LanguageSpeech.kt` calls `setLanguage(de_DE | en_US)` before each segment and
  queues it. If English is not installed in the TTS engine, the segment is spoken with the German voice.
- The gateway output route (Hermes TTS) is not affected.

## Phone setup (SherpaTTS)
- SherpaTTS keeps one model per language. Install English via SherpaTTS → Manage languages.
- Installing a language makes it SherpaTTS's current language. Set German back as current language so other
  apps stay German. Wing sets the language per sentence and does not depend on it.
- Default English voice: Piper `en_GB-alba-medium`. To change it, delete English in SherpaTTS and install
  another English model. Wing needs no change.

## Logs
`adb logcat -s WingTtsLang` shows one line per segment:
`segment 2/3 lang=en status=0 ms=4 chars=187`. `status` is the `setLanguage`/`setVoice` result (≥ 0 = ok);
`fallback=de` means the language was not available. Logs never contain reply text.
```

- [ ] **Step 5: Commit and compile**

```bash
git add android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/LanguageSpeech.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt docs/VOICE_LANGUAGE.md
git commit -m "feat(voice): speak each segment in its language via the system tts engine"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false` (timeout 900000 ms)
Expected: exit 0, last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
If `tools/factory/dispatch-check.sh` does not exist (see Basis), skip this command and write on the card
"Kotlin compile check deferred to Task 7 Step 1"; the reviewer must then read the Kotlin carefully.

Run: `bash tools/factory/ci-suite.sh` (timeout 900000 ms)
Expected: exit 0, `conclusion=success`.

---

### Task 6: Phone setup: English model in SherpaTTS **[Hermes worker]**

Not for a Claude Code subagent. Skill `android-phone-remote-ops`. No repo files change.

- [ ] **Step 1: Record the state before**

Run: `hadb shell settings get secure tts_default_locale`
Expected: `org.woheller69.ttsengine:de`.

Run: `hadb shell dumpsys package org.woheller69.ttsengine | grep -m1 versionName`
Expected: `versionName=3.4`. If it is different, read the engine's `TtsService.kt` at that version before
continuing (the per-request language behaviour of spec 2.3 must still hold).

- [ ] **Step 2: Install the English model**

On the phone (UI via `hadb` or with Birk): SherpaTTS → Manage languages → `en_GB` `alba` `medium` → download.
The phone needs internet (download from Hugging Face, ~63 MB).

ANNAHME: the license of `en_GB-alba-medium` is CC BY 4.0 (CSTR Alba). Check: open
`https://huggingface.co/rhasspy/piper-voices/blob/main/en/en_GB/alba/medium/MODEL_CARD` from a machine with web
access and record dataset + license on the card. If it is non-commercial or unclear, that is acceptable for
private use (the model is not redistributed), but note it.

- [ ] **Step 3: Set German back as SherpaTTS's current language**

Installing sets `current_language` to English (`Downloader.java:118`). In SherpaTTS's main screen, select
German again.

Check:
Run: `hadb shell su -c 'grep -h current_language /data/data/org.woheller69.ttsengine/shared_prefs/*.xml'`
Expected: a line containing `deu`.
ANNAHME: root via `su` works as on 13.10. when the prefs were read; if not, use the same method as then.

Run: `hadb shell su -c 'ls /data/data/org.woheller69.ttsengine/files /storage/emulated/0/Android/data/org.woheller69.ttsengine/files'`
Expected: one of the two lists contains `deuDE` and `engGB` (the model dir is `getExternalFilesDir`, spec 2.3).

Run: `hadb shell settings get secure tts_default_locale`
Expected: still `org.woheller69.ttsengine:de`.

- [ ] **Step 4: Engine-level smoke test (independent of Wing)**

SherpaTTS → its own test field, or Android Settings → Text-to-speech → "Listen to an example" with English
selected. Expected: an English voice. Then switch back to German. Record on the card: model dir names, prefs
line, and that both languages play.

---

### Task 7: On-device acceptance **[Hermes worker + Birk]**

Preconditions: Tasks 1-5 merged into `voice-offline` by the merger card; Task 6 done.
**Files:** none (verification only). Record the results as a card comment.

- [ ] **Step 1: Build the APK**

CI `voice-apk.yml` builds the unsigned APK for `voice-offline` and pushes it to branch `voice-apk-bin`. Check that
the build used the right commit:

```bash
gh run list -R birkschmithuesen/Wing --workflow voice-apk.yml --branch voice-offline --limit 1 --json headSha,conclusion
```

Expected: `headSha` equals `git rev-parse voice-offline` and `conclusion` is `success`. If not, dispatch it:
`gh workflow run voice-apk.yml -R birkschmithuesen/Wing --ref voice-offline` (after the VAD merge:
`bash tools/factory/dispatch-check.sh voice-apk.yml publish=true` from a checkout of `voice-offline`).

- [ ] **Step 2: Sign**

```bash
bash /home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh
```

Expected: `source commit: <sha of voice-offline>` and a signed APK under `~/handy-builds/wing-voice/`.

- [ ] **Step 3: Install**

Follow skill `android-phone-remote-ops` (`references/voice-self-test.md`, "Phone on mobile data", and
`references/xperia-vserver-adb-build.md`): transfer in 2-MB parts over the tailnet HTTP route, compare sha256 per
part and in total, `pm install -r /data/local/tmp/wing.apk`, `am force-stop com.tarkilhk.wing.voice`, relaunch
Wing, delete `/data/local/tmp/wing.*`.

Check:

```bash
hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep -m2 -E "versionName|lastUpdateTime"'
```

Expected: `lastUpdateTime` is today.

- [ ] **Step 4: Play the mixed test text**

1. Clear the log: `hadb logcat -c`
2. Birk (or the worker on Birk's go) sends in a Wing chat whose voice output route is the local Android voice:
   `Antworte ausschließlich mit dem folgenden Text, unverändert:` followed by the acceptance text from the top of
   this plan.
3. Tap read-aloud on the reply (or let conversation mode read it).
4. Read the log:
   Run: `hadb logcat -d -s WingTtsLang`
   Expected (if the reply equals the text): three lines in this order, all `status` ≥ 0, no `fallback=de`:

   ```
   I WingTtsLang: segment 1/3 lang=de status=0 ms=<n> chars=55
   I WingTtsLang: segment 2/3 lang=en status=0 ms=<n> chars=179
   I WingTtsLang: segment 3/3 lang=de status=0 ms=<n> chars=115
   ```

   If Robo adds a German lead-in, it merges into segment 1; the language order `de, en, de` is what counts.
   `ms` is the `setLanguage` call duration on Wing's main thread. ANNAHME (spec 2.4): it stays below 100 ms
   because SherpaTTS loads the model in its own queue. If a line shows `ms` ≥ 500, record it; that is a follow-up
   (move the switch off the main thread or warm up English), not a blocker.

- [ ] **Step 5: Birk listens**

Birk confirms by ear:
- sentence 1 and the last two sentences in the German voice, the three middle sentences in the English voice;
- English is intelligible; "Pull Request" and "Kanban-Board" are read inside the German sentence (German voice);
- the gap before the first English sentence. Record it as "none / short / long (> 1 s)". A long gap only on the
  first English use after a restart is the expected model load (spec 2.3); if it recurs on every reply, record
  it as a follow-up.

Play the same reply a second time and record whether the first-switch gap disappears (model cached).

- [ ] **Step 6: Voice choice (B4) and side effects**

1. Ask Birk whether `en_GB-alba-medium` is fine. If he wants to compare, the worker swaps the English model in
   SherpaTTS (delete English, install `en_US-amy-medium` or `en_GB-cori-medium`, set German back as current,
   Task 6 Step 3) and repeats Steps 4-5 with the same text. Wing needs no new build.
2. Run: `hadb shell settings get secure tts_default_locale`
   Expected: `org.woheller69.ttsengine:de`.
3. Optional: `hadb shell dumpsys meminfo org.woheller69.ttsengine | grep -m1 TOTAL` after an English reply;
   record the value (spec 4.8 ANNAHME, two cached models).

Card comment: logcat lines, Birk's verdict per check, gap observation, chosen English voice, the license note
from Task 6 Step 2.

## Follow-ups (not in this plan)

- Warm up the English model at session start, if Task 7 shows a long first-switch gap on every reply.
- Pronunciation lexicon and number expansion (concept B2), streaming by sentence (concept B3).
- Offer the sentence splitter upstream (rule 4 of the fork strategy), only on Birk's go.
