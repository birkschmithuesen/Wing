import 'dart:convert';
import 'dart:io';

import '../rules/dart_main_roots.dart' as rule;
import '../proof_process.dart';

class RootFixture {
  RootFixture(
    Map<String, String> sources, {
    List<Map<String, Object>> roots = const [],
    bool census = true,
  }) {
    directory = Directory.systemTemp.createTempSync('wing-dart-main-roots-');
    _git(['init', '-q']);
    for (final entry in sources.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    document = {
      'schema': 1,
      'files': [
        if (census)
          for (final path in sources.keys) {'path': path},
      ],
      'roots': roots,
    };
    writeManifest();
  }
  late final Directory directory;
  late Map<String, Object> document;
  void _git(List<String> args) {
    final result = Process.runSync('git', ['-C', directory.path, ...args]);
    if (result.exitCode != 0) throw StateError('Fixture Git command failed');
  }

  void writeManifest() {
    final file = File('${directory.path}/${rule.manifestPath}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(document));
  }

  void dispose() => directory.deleteSync(recursive: true);
}

Map<String, Object> explicit(String path, {String kind = 'guard-cli'}) => {
  'id': path,
  'path': path,
  'kind': kind,
  'selector': 'main',
  'purpose': 'Independent fixture executable',
  'source': 'Fixture command',
  'status': 'supported',
};

Map<String, Object> discovery() => {
  'id': 'host-test-discovery',
  'path': 'test',
  'kind': 'dart-test-discovery',
  'selector': {'declaration': 'main', 'pattern': '**/*_test.dart'},
  'purpose': 'Mandatory host test discovery',
  'source': 'flutter test',
  'status': 'supported',
};

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> prove({String? binary}) async {
  var cases = 0;
  void fixture(
    String name,
    Map<String, String> sources, {
    List<Map<String, Object>> roots = const [],
    int count = 0,
    bool inputError = false,
    bool census = true,
    void Function(RootFixture)? prepare,
  }) {
    final workspace = RootFixture(sources, roots: roots, census: census);
    try {
      prepare?.call(workspace);
      List<String>? findings;
      var invalid = false;
      try {
        findings = rule.check(workspace.directory);
      } on FormatException {
        invalid = true;
      }
      require(invalid == inputError, '$name: input verdict mismatch');
      if (!invalid) {
        require(findings!.length == count, '$name: findings $findings');
        for (final finding in findings) {
          require(finding.contains('[${rule.id}]'), '$name: wrong diagnostic');
        }
      }
      cases++;
    } finally {
      workspace.dispose();
    }
  }

  fixture(
    'unregistered alternate main and exact location',
    {'tools/run.dart': '// entry\nvoid main() {}'},
    count: 1,
    prepare: (workspace) {
      require(
        rule
            .check(workspace.directory)
            .single
            .startsWith('"tools/run.dart":2 [${rule.id}]'),
        'Declaration line must identify main',
      );
    },
  );
  fixture(
    'explicit tool main',
    {'tools/run.dart': 'Future<void> main(List<String> args) async {}'},
    roots: [explicit('tools/run.dart')],
  );
  fixture(
    'current performance root selector list',
    {'tools/performance.dart': 'void main() {}'},
    roots: [
      {
        ...explicit('tools/performance.dart', kind: 'alternate-dart-main'),
        'selector': ['main', 'WING_PERF_INSTRUMENTATION'],
      },
    ],
  );
  fixture('non-entry symbols comments and literals', {
    'lib/value.dart':
        "// void main() {}\nconst text = 'void main() {}';\nclass C { void main() {} }\nvoid outer() { void main() {} main(); }\nint get main => 1;",
  });
  fixture(
    'typed nested host discovery',
    {'test/nested/example_test.dart': 'void main() {}'},
    roots: [discovery()],
  );
  fixture(
    'discovery does not exempt helpers',
    {'test/support/helper.dart': 'void main() {}'},
    roots: [discovery()],
    count: 1,
  );
  fixture(
    'discovery does not exempt another tree',
    {'integration_test/example_test.dart': 'void main() {}'},
    roots: [discovery()],
    count: 1,
  );
  fixture(
    'relative part main covered by library root',
    {
      'tools/run.dart': "part 'parts/body.dart';",
      'tools/parts/body.dart': "part of '../run.dart';\nvoid main() {}",
    },
    roots: [explicit('tools/run.dart')],
  );
  fixture(
    'named part main covered by library root',
    {
      'tools/run.dart': "library owned.tool; part 'body.dart';",
      'tools/body.dart': 'part of owned.tool; void main() {}',
    },
    roots: [explicit('tools/run.dart')],
  );
  fixture(
    'part cannot be independently executable',
    {
      'tools/run.dart': "part 'body.dart';",
      'tools/body.dart': "part of 'run.dart'; void main() {}",
    },
    roots: [explicit('tools/body.dart')],
    count: 1,
  );
  fixture('duplicate part owner', {
    'tools/a.dart': "part 'body.dart';",
    'tools/b.dart': "part 'body.dart';",
    'tools/body.dart': "part of 'a.dart'; void main() {}",
  }, inputError: true);
  fixture('mismatched part owner', {
    'tools/a.dart': "part 'body.dart';",
    'tools/body.dart': "part of 'other.dart'; void main() {}",
  }, inputError: true);
  fixture(
    'part URI query cannot be discarded',
    {
      'tools/run.dart': "part 'body.dart?ignored';",
      'tools/body.dart': "part of 'run.dart'; void main() {}",
    },
    roots: [explicit('tools/run.dart')],
    inputError: true,
  );
  fixture(
    'part URI fragment cannot be discarded',
    {
      'tools/run.dart': "part 'body.dart#ignored';",
      'tools/body.dart': "part of 'run.dart'; void main() {}",
    },
    roots: [explicit('tools/run.dart')],
    inputError: true,
  );
  fixture('orphan part', {
    'tools/body.dart': "part of 'absent.dart'; void main() {}",
  }, inputError: true);
  fixture('missing part source', {
    'tools/a.dart': "part 'absent.dart';",
  }, inputError: true);
  fixture(
    'Git-visible missing census entry',
    {'tools/new.dart': 'void main() {}'},
    census: false,
    count: 1,
  );
  fixture('census-listed ignored source still checked', {
    'hidden.dart': 'void main() {}',
    '.gitignore': 'hidden.dart\n',
  }, count: 1);
  fixture('fixed installed directory exclusions', {
    'build/bad.dart': 'void main(',
    '.dart_tool/bad.dart': 'void main(',
    'tools/node_modules/bad.dart': 'void main(',
    'tools/__pycache__/bad.dart': 'void main(',
  });
  fixture('no generated or fixture suffix exemption', {
    'tools/value.g.dart': 'void main() {}',
  }, count: 1);
  fixture(
    'physical tracked deletion skipped',
    {'tools/deleted.dart': 'void main() {}'},
    prepare: (workspace) {
      workspace._git(['add', 'tools/deleted.dart']);
      File('${workspace.directory.path}/tools/deleted.dart').deleteSync();
    },
  );
  fixture(
    'asset row cannot masquerade as executable',
    {'tools/run.dart': 'void main() {}'},
    roots: [explicit('tools/run.dart', kind: 'asset-or-source')],
    count: 1,
  );
  fixture('malformed source', {
    'tools/run.dart': 'void main(',
  }, inputError: true);
  fixture(
    'bool schema rejected',
    {},
    inputError: true,
    prepare: (workspace) {
      workspace.document['schema'] = true;
      workspace.writeManifest();
    },
  );
  fixture(
    'noncanonical census path',
    {},
    inputError: true,
    prepare: (workspace) {
      workspace.document['files'] = [
        {'path': '../outside.dart'},
      ];
      workspace.writeManifest();
    },
  );
  fixture(
    'broad discovery rejected',
    {},
    roots: [
      {...discovery(), 'path': 'lib'},
    ],
    inputError: true,
  );
  fixture(
    'Dart symlink rejected without following source',
    {},
    inputError: true,
    prepare: (workspace) {
      File(
        '${workspace.directory.path}/real.txt',
      ).writeAsStringSync('void main() {}');
      Link('${workspace.directory.path}/linked.dart').createSync('real.txt');
    },
  );

  final bad = RootFixture({'tools/run.dart': '\nvoid main() {}'});
  final valid = RootFixture(
    {'tools/run.dart': 'void main() {}'},
    roots: [explicit('tools/run.dart')],
  );
  final malformed = RootFixture({'tools/run.dart': 'void main('});
  try {
    final runningExecutable = proofDartExecutable;
    final dart =
        const {
          'dart',
          'dart.exe',
        }.contains(runningExecutable.split(Platform.pathSeparator).last)
        ? runningExecutable
        : 'dart'; // The Flutter host's executable is flutter_tester, not Dart.
    Future<ProcessResult> invoke(RootFixture workspace) => binary == null
        ? runProofProcess(dart, [
            'run',
            'tools/architecture/rules/dart_main_roots.dart',
            '--root',
            workspace.directory.path,
          ])
        : runProofProcess(binary, ['--root', workspace.directory.path]);
    final rejected = await invoke(bad);
    require(
      rejected.exitCode == 1 &&
          '${rejected.stdout}'.contains('"tools/run.dart":2 [${rule.id}]'),
      'Actual bad CLI must exit1 with exact diagnostic: ${rejected.stdout}${rejected.stderr}',
    );
    final accepted = await invoke(valid);
    require(
      accepted.exitCode == 0 &&
          '${accepted.stdout}'.contains('0 uncovered main declarations'),
      'Actual valid CLI must exit0: ${accepted.stdout}${accepted.stderr}',
    );
    final invalid = await invoke(malformed);
    require(
      invalid.exitCode == 2 &&
          '${invalid.stderr}'.contains('[${rule.id}_INPUT]'),
      'Actual malformed CLI must exit2: ${invalid.stdout}${invalid.stderr}',
    );
    stdout.writeln(
      'Dart main root proof: $cases API fixtures; actual ${binary == null ? 'source' : 'compiled'} CLI invalid1/valid0/input2 passed.',
    );
  } finally {
    bad.dispose();
    valid.dispose();
    malformed.dispose();
  }
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--binary')) {
    throw ArgumentError('Usage: dart_main_roots_test.dart [--binary PATH]');
  }
  await prove(binary: args.isEmpty ? null : args.last);
}
