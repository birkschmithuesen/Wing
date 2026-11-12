import 'dart:io';

import '../rules/secure_reply_view_wire.dart' as rule;
import '../proof_process.dart';

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final root = Directory.systemTemp.createTempSync('wing-secure-reply-wire-');
  const panel = 'class GatewaySensitivePromptPanel {}';
  var passed = 0;
  void reset(String source, [Map<String, String> extra = const {}]) {
    final lib = Directory('${root.path}/lib');
    if (lib.existsSync()) lib.deleteSync(recursive: true);
    for (final entry in {rule.view: source, ...extra}.entries) {
      final file = File('${root.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
  }

  void verdict(int expected, String label) {
    try {
      final findings = rule.check(root);
      require(
        expected != 2 && findings.isEmpty == (expected == 0),
        '$label: $findings',
      );
      for (final f in findings) {
        require(
          f.id == rule.id &&
              f.file == rule.view &&
              f.line > 0 &&
              f.subject.startsWith('GatewaySensitivePromptPanel.namespace@'),
          '$label identity/location',
        );
      }
    } on FormatException {
      require(expected == 2, '$label unexpected INPUT');
    } on FileSystemException {
      require(expected == 2, '$label unexpected missing namespace');
    }
    passed++;
  }

  try {
    reset(panel);
    verdict(0, 'passive panel');
    for (final import in [
      "import 'dart:convert';",
      "import 'dart:convert' as wire;",
      "import 'dart:convert' show jsonEncode;",
      "import 'dart:convert' hide jsonDecode;",
      "export 'dart:convert';",
    ]) {
      reset('$import\n$panel');
      verdict(1, 'direct codec namespace $import');
    }
    reset("import '../models/reply.dart';\n$panel", {
      'lib/core/models/reply.dart':
          "import 'dart:convert';\nclass Reply { String encode() => jsonEncode({}); }",
      'lib/unrelated_view.dart': "import 'dart:convert'; class OtherPanel {}",
    });
    verdict(0, 'owner-private codec and unrelated view');
    reset("import 'barrel.dart' as facts show jsonEncode;\n$panel", {
      'lib/core/widgets/barrel.dart': "export '../models/reply.dart';",
      'lib/core/models/reply.dart': "export 'dart:convert' show jsonEncode;",
    });
    verdict(1, 'export chain');
    reset("import 'package:wing/core/widgets/barrel.dart';\n$panel", {
      'lib/core/widgets/barrel.dart': "export 'dart:convert';",
    });
    verdict(1, 'package URI barrel');
    reset("import 'barrel.dart';\n$panel", {
      'lib/core/widgets/barrel.dart':
          "export 'safe.dart' if (dart.library.io) 'wire.dart';",
      'lib/core/widgets/safe.dart': 'class Safe {}',
      'lib/core/widgets/wire.dart': "export 'dart:convert';",
    });
    verdict(1, 'conditional export');
    reset("import 'barrel.dart';\n$panel", {
      'lib/core/widgets/barrel.dart': "export 'cycle.dart';",
      'lib/core/widgets/cycle.dart': "export 'barrel.dart';",
    });
    verdict(0, 'safe export cycle');
    reset("import 'package:codec/wire.dart';\n$panel", {
      '.dart_tool/package_config.json':
          '{"configVersion":2,"packages":[{"name":"codec","rootUri":"../external_codec","packageUri":"lib/"}]}',
      'external_codec/lib/wire.dart': "export 'dart:convert';",
    });
    verdict(1, 'package root without a trailing slash');
    reset("library secure_reply; part 'panel_part.dart';", {
      'lib/core/widgets/panel_part.dart': 'part of secure_reply; $panel',
    });
    verdict(0, 'class in actual named part');
    reset("import 'dart:convert' as wire; part 'panel_part.dart';", {
      'lib/core/widgets/panel_part.dart':
          "part of 'gateway_sensitive_prompt_panel.dart'; $panel",
    });
    verdict(1, 'codec visible to actual URI part');
    reset("part 'panel_part.dart';", {
      'lib/core/widgets/panel_part.dart': "part of 'other.dart'; $panel",
    });
    verdict(2, 'mismatched part');
    reset('class OtherPanel {}');
    verdict(2, 'missing canonical authority');
    reset("import 'missing.dart'; $panel");
    verdict(2, 'missing imported namespace');
    reset('$panel class Broken {');
    verdict(2, 'malformed source');
    final executable = File(
      'tools/architecture/rules/secure_reply_view_wire.dart',
    ).absolute.path;
    for (final expected in [0, 1, 2]) {
      reset(switch (expected) {
        1 => "import 'dart:convert';\n$panel",
        2 => 'class OtherPanel {}',
        _ => panel,
      });
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        executable,
        '--root',
        root.path,
      ]);
      require(
        result.exitCode == expected,
        'CLI $expected: ${result.stdout}\n${result.stderr}',
      );
      if (expected == 1) {
        require(
          '${result.stdout}'.contains('${rule.view}:1 [${rule.id}]'),
          'CLI declaration location',
        );
      }
      if (expected == 2) {
        require(
          '${result.stderr}'.contains('[${rule.id} INPUT]'),
          'CLI input identity',
        );
      }
      passed++;
    }
    stdout.writeln('${rule.id}: $passed finite fixtures and CLI exits passed');
  } finally {
    root.deleteSync(recursive: true);
  }
}
