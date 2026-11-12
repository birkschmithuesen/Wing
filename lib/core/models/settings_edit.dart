/// Current stock settings metadata and edit intent; no UI or transport ownership.
enum AdminFieldKind { toggle, integer, decimal, text, lines, choice }

class AdminField {
  final String key;
  final String label;
  final String help;
  final AdminFieldKind kind;
  final List<String> choices;
  final bool modelCapability;
  final num? minimum;
  final num? maximum;
  AdminField(
    this.key,
    this.label,
    this.kind, {
    this.help = '',
    List<String> choices = const [],
    this.modelCapability = false,
    this.minimum,
    this.maximum,
  }) : choices = List.unmodifiable(choices);

  bool get percentage =>
      const {'compression.threshold', 'compression.target_ratio'}.contains(key);
  String format(Object? value) => value is List
      ? value.join('\n')
      : percentage && value is num
      ? shiftDecimal(value.toString(), 2)
      : value?.toString() ?? '';
  Object? parse(String text) => switch (kind) {
    AdminFieldKind.integer => int.tryParse(text),
    AdminFieldKind.decimal => double.tryParse(
      percentage ? shiftDecimal(text, -2) : text,
    ),
    AdminFieldKind.lines => List<String>.unmodifiable(
      text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty),
    ),
    _ => text,
  };
  String? describeChoice(Object? value) => key == 'approvals.mode'
      ? switch (value) {
          'manual' => 'Ask you when a flagged action requires approval.',
          'smart' =>
            'Hermes uses its approval model to assess flagged actions.',
          'off' =>
            'Skip the recoverable approval prompts. Hard blocks and explicit deny rules still apply.',
          _ => 'This approval mode was not recognized.',
        }
      : null;
  String? validate(Object? value) {
    if ((kind == AdminFieldKind.text || kind == AdminFieldKind.choice) &&
        value is! String) {
      return 'Enter a valid value';
    }
    if (kind == AdminFieldKind.lines &&
        (value is! List || value.any((entry) => entry is! String))) {
      return 'Enter one value per line';
    }
    if (kind == AdminFieldKind.toggle) {
      return value is bool ? null : 'Choose explicitly to set this value.';
    }
    if (kind == AdminFieldKind.integer || kind == AdminFieldKind.decimal) {
      if (value is! num ||
          !value.isFinite ||
          kind == AdminFieldKind.integer && value is! int) {
        return 'Enter a valid number';
      }
      if (minimum != null && value < minimum!) {
        return 'Minimum: ${format(minimum)}${percentage ? '%' : ''}';
      }
      if (maximum != null && value > maximum!) {
        return 'Maximum: ${format(maximum)}${percentage ? '%' : ''}';
      }
    }
    return null;
  }
}

final memoryFields = List<AdminField>.unmodifiable([
  AdminField('memory.memory_enabled', 'Retain memories', AdminFieldKind.toggle),
  AdminField(
    'memory.user_profile_enabled',
    'Remember user preferences',
    AdminFieldKind.toggle,
  ),
  AdminField(
    'memory.memory_char_limit',
    'Memory budget',
    AdminFieldKind.integer,
    help:
        'Characters retained for this profile; this is a budget, not current usage.',
    minimum: 1,
  ),
  AdminField(
    'memory.user_char_limit',
    'User preference budget',
    AdminFieldKind.integer,
    help:
        'Characters retained for this profile; this is a budget, not current usage.',
    minimum: 1,
  ),
]);
final executionFields = List<AdminField>.unmodifiable([
  AdminField(
    'agent.max_turns',
    'Maximum turns',
    AdminFieldKind.integer,
    help: 'Limit the model turns in one agent run.',
    minimum: 1,
  ),
  AdminField(
    'agent.run_budget_seconds',
    'Run time budget',
    AdminFieldKind.integer,
    help: 'Seconds per agent turn. 0 removes the time budget.',
    minimum: 0,
  ),
  AdminField(
    'agent.api_max_retries',
    'API retries',
    AdminFieldKind.integer,
    help: 'How many times Hermes may retry a failed model request.',
    minimum: 0,
  ),
  AdminField(
    'delegation.max_iterations',
    'Subagent iterations',
    AdminFieldKind.integer,
    help: 'Maximum iterations available to each child agent.',
    minimum: 1,
  ),
  AdminField(
    'delegation.max_concurrent_children',
    'Concurrent subagents',
    AdminFieldKind.integer,
    help: 'Maximum child agents working at the same time.',
    minimum: 1,
  ),
  AdminField(
    'delegation.max_spawn_depth',
    'Subagent depth',
    AdminFieldKind.integer,
    help:
        '1 allows one level of children. Extra levels allow children to delegate and can multiply cost.',
    minimum: 1,
  ),
  AdminField(
    'delegation.child_timeout_seconds',
    'Subagent timeout',
    AdminFieldKind.integer,
    help:
        'Seconds per child. 0 disables the timeout; positive values have a 30-second minimum on Hermes.',
    minimum: 0,
  ),
]);
final approvalFields = List<AdminField>.unmodifiable([
  AdminField(
    'approvals.mode',
    'Approval mode',
    AdminFieldKind.choice,
    choices: ['manual', 'smart', 'off'],
    help:
        'Controls the server approval policy. Explicit deny rules still apply.',
  ),
  AdminField(
    'approvals.timeout',
    'Approval timeout',
    AdminFieldKind.integer,
    help:
        'Seconds to wait for a decision. An unanswered gateway request times out; 0 gives no waiting time.',
    minimum: 0,
  ),
  AdminField(
    'command_allowlist',
    'Allowed commands',
    AdminFieldKind.lines,
    help: 'One command per line. These commands may run without asking.',
  ),
  AdminField(
    'approvals.mcp_reload_confirm',
    'Confirm connector reload',
    AdminFieldKind.toggle,
  ),
]);
final compressionFields = List<AdminField>.unmodifiable([
  AdminField(
    'compression.enabled',
    'Compress long conversations',
    AdminFieldKind.toggle,
  ),
  AdminField(
    'compression.threshold',
    'Compression threshold',
    AdminFieldKind.decimal,
    help: 'Percent of context capacity',
    minimum: 0,
    maximum: 1,
  ),
  AdminField(
    'compression.target_ratio',
    'Target after compression',
    AdminFieldKind.decimal,
    help: 'Percent of context capacity',
    minimum: 0,
    maximum: 1,
  ),
  AdminField(
    'compression.protect_last_n',
    'Protect recent messages',
    AdminFieldKind.integer,
    help: 'Number of recent messages kept during compression.',
    minimum: 0,
  ),
  AdminField(
    'compression.prepare_ahead',
    'Prepare compression ahead',
    AdminFieldKind.toggle,
    help:
        'Prepare a summary while Hermes works to reduce compression pauses. Off by default. A summary may use tokens even if it is not used.',
  ),
]);
final reachFields = List<AdminField>.unmodifiable([
  AdminField(
    'security.redact_secrets',
    'Redact secrets',
    AdminFieldKind.toggle,
  ),
  AdminField(
    'security.allow_private_urls',
    'Allow private URLs',
    AdminFieldKind.toggle,
    help: 'Allow backend requests to private network addresses.',
  ),
  AdminField(
    'checkpoints.enabled',
    'File checkpoints',
    AdminFieldKind.toggle,
    help: 'Keep supported file recovery checkpoints on the backend.',
  ),
]);
final voiceFields = List<AdminField>.unmodifiable([
  AdminField('stt.enabled', 'Speech recognition', AdminFieldKind.toggle),
  AdminField('stt.language', 'Recognition language', AdminFieldKind.text),
  AdminField(
    'tts.provider',
    'Speech provider',
    AdminFieldKind.text,
    help: 'Use a provider configured in Skills and tools.',
  ),
  AdminField('voice.auto_tts', 'Automatic speech', AdminFieldKind.toggle),
]);

Object? setting(Map<String, dynamic> config, String key) {
  Object? value = config;
  for (final part in key.split('.')) {
    if (value is! Map) {
      return null;
    }
    value = value[part];
  }
  return value;
}

void setSetting(Map<String, dynamic> config, String key, Object? value) {
  final parts = key.split('.');
  var node = config;
  for (final part in parts.take(parts.length - 1)) {
    node =
        node.putIfAbsent(part, () => <String, dynamic>{})
            as Map<String, dynamic>;
  }
  node[parts.last] = value;
}

bool sameSetting(Object? a, Object? b) {
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => sameSetting(a[i], b[i])).every((v) => v);
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && sameSetting(a[k], b[k]));
  }
  return a == b;
}

Object? immutableSetting(Object? value) => switch (value) {
  Map value => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: immutableSetting(entry.value),
  }),
  List value => List<Object?>.unmodifiable(value.map(immutableSetting)),
  null || String() || bool() || num() => value,
  _ => throw const FormatException('Invalid settings value'),
};

Map<String, Object?> settingsProjection(
  Map<String, dynamic> config,
  Iterable<String> keys,
) => Map<String, Object?>.unmodifiable({
  for (final key in keys) key: immutableSetting(setting(config, key)),
});

/// Opening observations never alias subsequent reads or mutable caller input.
/// Only changed fields participate in conflicts; invariants are explicit
/// operation preconditions such as an already captured speech-provider route.
class SettingsEditIntent {
  SettingsEditIntent({
    required Map<String, Object?> baseline,
    required Map<String, Object?> desired,
    Iterable<String> invariants = const [],
  }) : baseline = Map.unmodifiable({
         for (final entry in baseline.entries)
           entry.key: immutableSetting(entry.value),
       }),
       desired = Map.unmodifiable({
         for (final entry in desired.entries)
           entry.key: immutableSetting(entry.value),
       }),
       invariants = Set.unmodifiable(invariants) {
    if (desired.keys.any((key) => !baseline.containsKey(key)) ||
        this.invariants.any((key) => !baseline.containsKey(key)) ||
        desired.values.any(
          (value) =>
              value is num && !value.isFinite ||
              value != null &&
                  value is! String &&
                  value is! bool &&
                  value is! num &&
                  !(value is List && value.every((entry) => entry is String)),
        )) {
      throw ArgumentError(
        'Settings edits require captured scalar or text-list fields',
      );
    }
  }
  final Map<String, Object?> baseline, desired;
  final Set<String> invariants;
  SettingsEditResolution resolve(Map<String, dynamic> current) {
    final conflicts = <String, Object?>{};
    final updates = <String, Object?>{};
    for (final key in invariants) {
      if (!sameSetting(setting(current, key), baseline[key])) {
        conflicts[key] = setting(current, key);
      }
    }
    for (final entry in desired.entries) {
      if (sameSetting(entry.value, baseline[entry.key])) {
        continue;
      }
      final latest = setting(current, entry.key);
      if (!sameSetting(latest, baseline[entry.key]) &&
          !sameSetting(latest, entry.value)) {
        conflicts[entry.key] = latest;
      }
      if (!sameSetting(latest, entry.value)) {
        updates[entry.key] = entry.value;
      }
    }
    return SettingsEditResolution(updates, conflicts);
  }
}

class SettingsEditResolution {
  SettingsEditResolution(
    Map<String, Object?> updates,
    Map<String, Object?> conflicts,
  ) : updates = Map.unmodifiable({
        for (final entry in updates.entries)
          entry.key: immutableSetting(entry.value),
      }),
      conflicts = Map.unmodifiable({
        for (final entry in conflicts.entries)
          entry.key: immutableSetting(entry.value),
      });
  final Map<String, Object?> updates, conflicts;
}

/// Shift decimal text without introducing binary floating-point display noise.
/// Invalid input stays invalid for the field validator.
String shiftDecimal(String input, int places) {
  final match = RegExp(
    r'^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$',
  ).firstMatch(input.trim());
  if (match == null) {
    return input;
  }
  final whole = match[2]!;
  final digits = whole + (match[3] ?? '');
  if (digits.isEmpty) {
    return input;
  }
  final exponent = int.tryParse(match[4] ?? '0');
  if (exponent == null) {
    return input;
  }
  final position = whole.length + places + exponent;
  if (position.abs() > 1000) {
    return input;
  }
  var result = position <= 0
      ? '0.${'0' * -position}$digits'
      : position >= digits.length
      ? '$digits${'0' * (position - digits.length)}'
      : '${digits.substring(0, position)}.${digits.substring(position)}';
  result = result.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
  if (result.contains('.')) {
    result = result
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return '${match[1]}$result';
}
