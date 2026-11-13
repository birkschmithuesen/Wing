/// A compact heading derived from the supplied task, never a replacement for it.
String agentTaskHeading(String task) {
  final text = task.trim();
  // Periods within filenames, URLs or decimal values do not end a sentence.
  final end = RegExp(r'\.(?=\s|$)').firstMatch(text)?.start;
  return (end == null ? text : text.substring(0, end)).trim().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
}
