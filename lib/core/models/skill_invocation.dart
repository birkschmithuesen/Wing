import 'slash_command.dart';

/// Client fallback from Hermes Desktop's shared skill-scaffold.ts.
String? skillInvocationText(String text) {
  final match = RegExp(
    r'^\[IMPORTANT: The user has invoked the "([^"]*)"',
  ).firstMatch(text);
  final name = match?.group(1)?.trim();
  if (name == null || name.isEmpty) return null;
  final label = name.startsWith('/') ? name : '/$name';
  String between(String marker, String end, {bool fromEnd = false}) {
    final index = fromEnd ? text.lastIndexOf(marker) : text.indexOf(marker);
    if (index < 0) return '';
    final tail = text.substring(index + marker.length);
    final stop = tail.indexOf(end);
    return (stop < 0 ? tail : tail.substring(0, stop)).trim();
  }

  final instruction = text.contains(' skill bundle,')
      ? between('\nUser instruction: ', '\n\n[Loaded as part of the ')
      : text.contains('The full skill content is loaded below.]')
      ? between(
          'The user has provided the following instruction alongside the skill invocation: ',
          '\n\n[Runtime note:',
          fromEnd: true,
        )
      : '';
  if (SlashSkillReference.inText(instruction, [
    label,
  ]).any((r) => r.start > 0)) {
    return instruction;
  }
  return instruction.isEmpty
      ? label
      : '$label ${instruction.replaceAll(RegExp(r'\s+'), ' ')}';
}
