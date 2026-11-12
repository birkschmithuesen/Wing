const chatReasoningEffortLabels = <String, String>{
  'none': 'Off',
  'minimal': 'Minimal',
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
  'xhigh': 'Extra High',
  'max': 'Max',
  'ultra': 'Ultra',
};

String chatReasoningEffortLabel(String effort) {
  final normalized = effort.trim().toLowerCase();
  if (normalized == 'default' || normalized.isEmpty) return 'Default';
  return chatReasoningEffortLabels[normalized] ?? effort;
}

/// Passive composer badge; full effort names remain in accessibility text.
String compactChatReasoningLabel(String effort) =>
    switch (effort.trim().toLowerCase()) {
      'none' => 'O',
      'minimal' => 'Min',
      'low' => 'L',
      'medium' => 'Med',
      'high' => 'H',
      'xhigh' => 'X',
      'max' => 'Max',
      'ultra' => 'U',
      'default' || '' => 'D',
      _ => effort.trim().substring(0, 1).toUpperCase(),
    };

/// Shortens common model IDs for the composer without changing the value sent
/// to Hermes. The full ID remains visible in the picker and context header.
String compactChatModelLabel(String model) {
  var value = model.trim();
  if (value.contains('/')) value = value.split('/').last;
  if (value.toLowerCase().startsWith('gpt-')) value = value.substring(4);
  final words = value.split(RegExp(r'[-_]+')).where((word) => word.isNotEmpty);
  return words
      .map((word) {
        if (RegExp(r'^\d').hasMatch(word)) return word;
        return '${word[0].toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}

String catalogModelLabel(String model) {
  final id = model.split('/').last;
  final label = compactChatModelLabel(model);
  return id.toLowerCase().startsWith('gpt-') ? 'GPT-$label' : label;
}
