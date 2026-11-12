import 'dart:io';

import '../rules/public_owner_state.dart' as rule;
import '../proof_process.dart';

void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

const foundation = "import 'package:flutter/foundation.dart';\n";
const tasks = 'lib/core/services/scheduled_tasks_controller.dart';
const overview = 'lib/core/services/administration_overview.dart';

String owner(
  String name,
  Set<String> members, {
  Map<String, String> replace = const {},
}) {
  final value = name == 'AdministrationObservation';
  return 'class $name ${value ? '' : 'extends ChangeNotifier'} {\n'
      '${members.map((member) => replace[member] ?? (value ? 'final Object? $member = null;' : 'Object? _$member; Object? get $member => _$member;')).join('\n')}\n}\n';
}

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final root = await Directory.systemTemp.createTemp(
    'wing-public-owner-state-',
  );
  var passed = 0;
  Future<void> reset({
    String? library,
    String? className,
    Map<String, String> replace = const {},
  }) async {
    for (final entry in rule.owners.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        foundation +
            entry.value.entries
                .map(
                  (entry) => owner(
                    entry.key,
                    entry.value,
                    replace:
                        library == file.path.substring(root.path.length + 1) &&
                            className == entry.key
                        ? replace
                        : const {},
                  ),
                )
                .join('\n'),
      );
    }
  }

  void verdict(int expected, String label) {
    try {
      final findings = rule.check(root);
      expect(expected != 2, '$label: expected INPUT');
      expect(findings.isEmpty == (expected == 0), '$label: wrong findings');
      for (final finding in findings) {
        expect(
          finding.id == rule.id &&
              rule.owners.containsKey(finding.file) &&
              finding.line > 0,
          '$label: diagnostic identity/location',
        );
      }
    } on FormatException {
      expect(expected == 2, '$label: unexpected INPUT');
    }
    passed++;
  }

  try {
    await reset();
    verdict(0, 'current getter/final field declarations');
    for (final library in rule.owners.entries) {
      for (final declaration in library.value.entries) {
        for (final member in declaration.value) {
          await reset(
            library: library.key,
            className: declaration.key,
            replace: {member: 'Object? $member;'},
          );
          verdict(1, 'public writable ${declaration.key}.$member');
          if (declaration.key != 'AdministrationObservation') {
            await reset(
              library: library.key,
              className: declaration.key,
              replace: {member: 'final Object? $member = null;'},
            );
            verdict(1, 'public final registry/scalar is not a getter $member');
          }
        }
      }
    }
    await reset(
      library: tasks,
      className: 'ScheduledTasksController',
      replace: {'error': 'Object? error, notice;', 'notice': ''},
    );
    final grouped = rule.check(root);
    expect(
      grouped.map((f) => f.subject).toSet().containsAll({
        'ScheduledTasksController.error',
        'ScheduledTasksController.notice',
      }),
      'each grouped public field detected',
    );
    passed++;
    await reset(
      library: tasks,
      className: 'ScheduledTasksController',
      replace: {
        'loading':
            'Object? _loading; Object? get loading => _loading; set loading(Object? value) { _loading = value; }',
      },
    );
    verdict(1, 'explicit instance setter');
    await reset(
      library: overview,
      className: 'AdministrationObservation',
      replace: {
        'error':
            'Object? _error; Object? get error => _error; set error(Object? value) { _error = value; }',
      },
    );
    verdict(1, 'value cannot replace final field with getter/setter');
    await reset(
      library: overview,
      className: 'AdministrationObservation',
      replace: {'data': 'late final Object? data;'},
    );
    verdict(1, 'late final uninitialized field has public write slot');
    await reset(
      library: overview,
      className: 'AdministrationObservation',
      replace: {'data': 'late final Object? data = null;'},
    );
    verdict(0, 'initialized late final has no public setter');
    await reset(
      library: tasks,
      className: 'ScheduledTasksController',
      replace: {
        'tasks': 'Object? _tasks; Object? get tasks { return _tasks; }',
      },
    );
    verdict(0, 'block getter');
    final file = File('${root.path}/$tasks');
    await reset();
    await file.writeAsString(
      (await file.readAsString())
          .replaceAll(
            "import 'package:flutter/foundation.dart';",
            "import 'package:flutter/foundation.dart' as f show ChangeNotifier;",
          )
          .replaceAll('extends ChangeNotifier', 'extends f.ChangeNotifier'),
    );
    verdict(0, 'prefixed explicit framework ancestry');
    await reset();
    final unrelated = File('${root.path}/lib/other.dart');
    await unrelated.writeAsString(
      'class ScheduledTasksController { Object? tasks; } class AdministrationObservation { Object? data; }',
    );
    await file.writeAsString(
      '${await file.readAsString()}\nclass UiState { Object? tasks; set error(Object? value) {} }',
    );
    verdict(0, 'same names elsewhere or another class do not match');
    await reset(
      library: overview,
      className: 'AdministrationObservation',
      replace: {
        'checkedAt': 'final Object? checkedAt = null, error = null;',
        'error': '',
      },
    );
    verdict(0, 'grouped final value fields');
    await reset();
    await file.writeAsString(
      '${await file.readAsString()}\n// Object? tasks; set error(v) {}\n',
    );
    verdict(0, 'comments are not declarations');
    for (final replacement in [
      '',
      'static Object? get tasks => null;',
      'void tasks() {}',
    ]) {
      await reset(
        library: tasks,
        className: 'ScheduledTasksController',
        replace: {'tasks': replacement},
      );
      verdict(2, 'missing or noninstance observation surface');
    }
    for (final transform in <String Function(String)>[
      (s) =>
          s.replaceAll('class ScheduledTasksController', 'class AnotherOwner'),
      (s) => s.replaceAll('extends ChangeNotifier', 'extends UnknownBase'),
      (s) => s.replaceAll(
        'extends ChangeNotifier',
        'extends ChangeNotifier with UnknownMixin',
      ),
      (s) => s.replaceAll(
        'extends ChangeNotifier',
        'extends ChangeNotifier implements OtherOwner',
      ),
      (s) => s.replaceAll(
        'class ScheduledTasksController extends',
        'class ScheduledTasksController<ChangeNotifier> extends',
      ),
      (s) => '$s\nclass ChangeNotifier { set tasks(Object? value) {} }',
      (s) => s.replaceAll(
        "'package:flutter/foundation.dart';",
        "'package:flutter/foundation.dart' hide ChangeNotifier;",
      ),
      (s) => "part 'other.dart';\n$s",
      (s) => "part of 'other.dart';\n$s",
      (s) => "import 'other.dart' if (dart.library.io) 'alternate.dart';\n$s",
      (s) => '$s\nvoid broken() {',
    ]) {
      await reset();
      await file.writeAsString(transform(await file.readAsString()));
      verdict(2, 'unsupported class/ancestry/namespace/syntax');
    }
    await reset();
    await file.delete();
    var absent = false;
    try {
      rule.check(root);
    } on FileSystemException {
      absent = true;
    }
    expect(absent, 'missing canonical library fails input');
    passed++;
    final executable = File(
      'tools/architecture/rules/public_owner_state.dart',
    ).absolute.path;
    for (final expected in [1, 0, 2]) {
      await reset(
        library: tasks,
        className: 'ScheduledTasksController',
        replace: switch (expected) {
          1 => {'tasks': 'Object? tasks;'},
          2 => {'tasks': ''},
          _ => const {},
        },
      );
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        executable,
        '--root',
        root.path,
      ]);
      expect(
        result.exitCode == expected,
        'actual CLI $expected: ${result.stdout}\n${result.stderr}',
      );
      if (expected == 1) {
        expect(
          '${result.stdout}'.contains('$tasks:3 [${rule.id}]') &&
              '${result.stdout}'.contains('ScheduledTasksController.tasks'),
          'actual CLI exact declaration location',
        );
      } else if (expected == 2) {
        expect(
          '${result.stderr}'.contains('[${rule.id} INPUT]'),
          'actual CLI input diagnostic',
        );
      }
      passed++;
    }
    stdout.writeln(
      '${rule.id}: $passed AST fixtures and actual source CLI 1/0/2 passed',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
