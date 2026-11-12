import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/transcript_history_dispatch.dart' as rule;
import '../proof_process.dart';

class _Case {
  const _Case(this.name, this.source, this.exit, {this.cli = false});
  final String name, source;
  final int exit;
  final bool cli;
}

// Original layout-time dispatch, repaired frame dispatch and retained button
// intent are the actual source patterns. Helpers/closures exercise that same seam.
const _cases = [
  _Case(
    'original notification dispatch',
    'class _ProfileTranscriptState { Object build() => NotificationListener(onNotification: (event) { unawaited(widget.onLoadOlder()); return false; }); }',
    1,
    cli: true,
  ),
  _Case(
    'captured and coalesced frame dispatch plus original buttons',
    'class _ProfileTranscriptState { bool pending = false; void _scheduleLoadOlder() { if (pending) return; pending = true; final chat = widget.chat; WidgetsBinding.instance.addPostFrameCallback((_) { pending = false; if (!mounted || !identical(chat, widget.chat)) return; unawaited(widget.onLoadOlder()); }); } Object build() => TextButton(onPressed: () => widget.onLoadOlder()); }',
    0,
    cli: true,
  ),
  _Case(
    'direct newly named helper',
    'class _ProfileTranscriptState { void anotherLoad() { unawaited(widget.onLoadOlder()); } }',
    1,
  ),
  _Case(
    'ordinary closure is not a frame',
    'class _ProfileTranscriptState { Object build() => listen(() => widget.onLoadOlder()); }',
    1,
  ),
  _Case(
    'unrelated callback registration is not a frame',
    'class _ProfileTranscriptState { void schedule() { another.addPostFrameCallback((_) => widget.onLoadOlder()); } }',
    1,
  ),
  _Case(
    'inner helper does not inherit frame exemption',
    'class _ProfileTranscriptState { void schedule() { WidgetsBinding.instance.addPostFrameCallback((_) { void helper() { widget.onLoadOlder(); } helper(); }); } }',
    1,
  ),
  _Case(
    'direct retry button remains valid',
    'class _ProfileTranscriptState { Object build() => TextButton(onPressed: () { widget.onLoadOlder(); }); }',
    0,
  ),
  _Case(
    'other owner callback is outside literal receiver scope',
    'class _ProfileTranscriptState { void load() { other.onLoadOlder(); } }',
    0,
  ),
  _Case(
    'parenthesized widget receiver is still direct',
    'class _ProfileTranscriptState { void load() { (widget).onLoadOlder(); } }',
    1,
  ),
  _Case(
    'explicit this widget receiver is still direct',
    'class _ProfileTranscriptState { void load() { this.widget.onLoadOlder(); } }',
    1,
  ),
  _Case(
    'inner button helper does not inherit user callback exemption',
    'class _ProfileTranscriptState { Object build() => TextButton(onPressed: () { void helper() { widget.onLoadOlder(); } helper(); }); }',
    1,
  ),
  _Case('missing canonical owner', 'class Other {}', 2, cli: true),
  _Case(
    'ambiguous canonical owner',
    'class _ProfileTranscriptState {} class _ProfileTranscriptState {}',
    2,
  ),
  _Case(
    'unsupported part scope',
    "part 'other.dart'; class _ProfileTranscriptState {}",
    2,
  ),
  _Case('malformed source', 'class _ProfileTranscriptState {', 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final root = Directory.systemTemp.createTempSync(
      'wing-transcript-dispatch-',
    );
    try {
      final file = File('${root.path}/${rule.library}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(fixture.source);
      final roles = '${root.path}/roles.json';
      File(roles).writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'files': {
            rule.library: {
              'role': 'view',
              'feature': 'transcript',
              'library': rule.library,
            },
          },
        }),
      );
      var exit = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(root.path, roles));
        exit = findings.isEmpty ? 0 : 1;
      } on FormatException {
        exit = 2;
      }
      if (exit != fixture.exit ||
          exit == 1 &&
              (findings.length != 1 ||
                  findings.single.id != rule.id ||
                  findings.single.file != rule.library ||
                  findings.single.subject != rule.subject ||
                  findings.single.line != 1)) {
        throw StateError('${fixture.name}: $exit / $findings');
      }
      if (!fixture.cli) continue;
      if (!cliExits.add(fixture.exit)) throw StateError('Duplicate CLI proof');
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        'tools/architecture/rules/transcript_history_dispatch.dart',
        '--root',
        root.path,
        '--roles',
        roles,
        '--json',
      ]);
      if (result.exitCode != fixture.exit) {
        throw StateError(
          '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
        );
      }
      if (fixture.exit == 2) {
        if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
          throw StateError('Missing CLI input diagnostic');
        }
      } else {
        final output = jsonDecode(result.stdout as String) as Map;
        final problems = output['problems'] as List;
        if (fixture.exit == 0
            ? problems.isNotEmpty
            : problems.length != 1 ||
                  (problems.single as Map)['id'] != rule.id ||
                  (problems.single as Map)['file'] != rule.library ||
                  (problems.single as Map)['subject'] != rule.subject ||
                  (problems.single as Map)['line'] != 1) {
          throw StateError('CLI diagnostic identity/location mismatch');
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 0/1/2 were not proved');
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures and three CLI representatives passed',
  );
}
