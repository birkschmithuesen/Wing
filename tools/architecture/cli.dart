import 'dart:convert';
import 'dart:io';

import 'model.dart';

Future<void> run(List<String> arguments, Map<String, Rule> rules) async {
  try {
    final options = <String, String>{};
    var strict = false;
    var json = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--strict':
          strict = true;
        case '--json':
          json = true;
        case '--root' || '--roles' || '--baseline' || '--baseline-reference':
          if (++i >= arguments.length) {
            throw const FormatException('Missing option value');
          }
          options[arguments[i - 1]] = arguments[i];
        default:
          throw const FormatException('Unknown architecture option');
      }
    }
    final root = Directory(options['--root'] ?? '.').absolute.path;
    final clock = Stopwatch()..start();
    final snapshot = Snapshot.load(
      root,
      options['--roles'] ?? '$root/tools/architecture/roles.json',
    );
    final parseMicros = clock.elapsedMicroseconds;
    final timings = <String, int>{};
    final findings = <Finding>[];
    for (final entry in rules.entries) {
      final started = clock.elapsedMicroseconds;
      findings.addAll(await entry.value(snapshot));
      timings[entry.key] = clock.elapsedMicroseconds - started;
    }
    findings.sort();
    final problems = strict
        ? findings
        : applyBaseline(
            findings,
            options['--baseline'] ?? '$root/tools/architecture/baseline.json',
            rules.keys.toSet(),
            reference: options['--baseline-reference'],
          );
    clock.stop();
    if (json) {
      stdout.writeln(
        jsonEncode({
          'files': snapshot.sources.length,
          'libraries': snapshot.graph.length,
          'findings': findings.map((finding) => finding.toJson()).toList(),
          'problems': problems.map((finding) => finding.toJson()).toList(),
          'parseMicros': parseMicros,
          'rulesMicros': timings,
          'totalMicros': clock.elapsedMicroseconds,
        }),
      );
    } else {
      for (final problem in problems) {
        stdout.writeln(problem);
      }
      stdout.writeln(
        '${rules.length} rules; ${snapshot.sources.length} files; '
        '${findings.length} findings; ${problems.length} blocking; '
        '${clock.elapsedMilliseconds} ms in process',
      );
    }
    exitCode = problems.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '[ARCH_INPUT] Invalid architecture input; inspect manifests, '
      'options and source syntax. Run flutter analyze for source errors.',
    );
    exitCode = 2;
  }
}

List<Finding> applyBaseline(
  List<Finding> findings,
  String path,
  Set<String> ids, {
  String? reference,
}) {
  final entries = readBaseline(path);
  final actual = {for (final finding in findings) finding.key: finding};
  final problems = [
    for (final finding in findings)
      if (!entries.containsKey(finding.key)) finding,
  ];
  for (final entry in entries.entries) {
    final value = entry.value;
    if (ids.contains(value['id']) && !actual.containsKey(entry.key)) {
      problems.add(
        Finding(
          'ARCH_BASELINE',
          value['file'] as String,
          1,
          entry.key,
          'Remove the stale migration entry; this violation no longer exists.',
        ),
      );
    }
  }
  if (reference != null) {
    final previous = readBaseline(reference);
    for (final entry in entries.entries) {
      if (!previous.containsKey(entry.key)) {
        problems.add(
          Finding(
            'ARCH_BASELINE',
            entry.value['file'] as String,
            1,
            entry.key,
            'Migration baselines may only shrink; remove the added exemption.',
          ),
        );
      }
    }
  }
  return problems..sort();
}

Map<String, Map<String, dynamic>> readBaseline(String path) {
  final data = jsonDecode(File(path).readAsStringSync());
  if (data is! Map || data['schema'] != 1 || data['entries'] is! List) {
    throw const FormatException('Invalid architecture baseline');
  }
  final entries = <String, Map<String, dynamic>>{};
  for (final entry in data['entries'] as List) {
    if (entry is! Map<String, dynamic> ||
        entry['id'] is! String ||
        entry['file'] is! String ||
        entry['subject'] is! String ||
        entry['reason'] is! String ||
        (entry['reason'] as String).trim().isEmpty) {
      throw const FormatException('Invalid architecture baseline entry');
    }
    final key = jsonEncode([entry['id'], entry['file'], entry['subject']]);
    if (entries.containsKey(key)) {
      throw const FormatException('Duplicate baseline entry');
    }
    entries[key] = entry;
  }
  return entries;
}
