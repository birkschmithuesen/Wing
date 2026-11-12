// Pure synthetic workload shared by host diagnostics and the profile replay.
const streamingReplayPresentations = 60;
const streamingReplayDeltasPerPresentation = 10;

String streamingReplaySection(int index, {bool fences = true}) {
  final section =
      '''### Section $index

${List.generate(45, (word) => 'Synthetic${index}_$word').join(' ')} with **strong text**, *emphasis*, `inline code`, and [a link](https://example.test/$index).

- First item with **detail**
- Second item
  - Nested item

> A quoted observation for synthetic section $index.

| Field | Value |
| --- | --- |
| alpha | **one** |
| beta | two |

```dart
final synthetic$index = $index;
```

''';
  return fences
      ? section
      : section.replaceAll(
          '```dart\nfinal synthetic$index = $index;\n```\n\n',
          '',
        );
}

String streamingReplayInitial({bool fences = true}) => List.generate(
  6,
  (index) => streamingReplaySection(index, fences: fences),
).join();

String streamingReplayGrowth({bool fences = true}) => List.generate(
  6,
  (index) => streamingReplaySection(index + 6, fences: fences),
).join();

String streamingReplayDraft(int presentation, int delta) =>
    'Synthetic draft $presentation/$delta';

int streamingReplayGrowthEnd(int presentation, int length) =>
    ((presentation + 1) * length / streamingReplayPresentations).floor();

int streamingReplayDeltaEnd(int presentation, int delta, int length) {
  final start = presentation == 0
      ? 0
      : streamingReplayGrowthEnd(presentation - 1, length);
  final end = streamingReplayGrowthEnd(presentation, length);
  return start +
      ((end - start) * (delta + 1) / streamingReplayDeltasPerPresentation)
          .floor();
}
