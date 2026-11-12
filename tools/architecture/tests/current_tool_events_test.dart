import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/current_tool_events.dart' as rule;
import '../proof_process.dart';

const modelPath = 'lib/core/models/gateway_activity.dart';
const runtimePath = 'lib/core/services/chat_runtime.dart';
const controllerPath = 'lib/core/services/profile_workspace_controller.dart';

class _Case {
  const _Case(
    this.name,
    this.exit, {
    this.model = '',
    this.event = '',
    this.tool = '',
    this.controller = '',
    this.extraModel = '',
    this.selector = 'eventType',
    this.invalid,
    this.cli = false,
  });
  final String name, model, event, tool, controller, extraModel, selector;
  final int exit;
  final String? invalid;
  final bool cli;
}

const _cases = [
  _Case(
    'current event and key selectors',
    0,
    cli: true,
    model:
        "final phase = switch(eventType) { 'tool.start' || 'tool.generating' || 'tool.complete' => true, _ => false }; data['tool_id']; first(data, const ['name']); data['result']; data['result_text'];",
    event: "switch(type) { case 'tool.start': case 'tool.complete': break; }",
    tool: "if(type != 'tool.complete') {}",
    controller: "switch(event.type) { case 'tool.generating': break; }",
  ),
  _Case('original parser status alias', 1, cli: true, model: "data['status'];"),
  _Case(
    'stock progress parser',
    0,
    model: "switch(eventType) { case 'tool.progress': break; }",
  ),
  _Case(
    'runtime args delta Or pattern',
    1,
    event:
        "final relevant = switch(type) { 'tool.start' || 'tool.args_delta' => true, _ => false };",
  ),
  _Case(
    'runtime error completion comparison',
    1,
    tool: "if(type != 'tool.error') {}",
  ),
  _Case(
    'coordinator stock progress dispatch',
    0,
    controller: "switch(event.type) { case 'tool.progress': break; }",
  ),
  _Case(
    'renamed parameter and immutable selector alias',
    1,
    selector: 'kind',
    model: "final captured = (kind); if('tool.error' == captured) {}",
  ),
  _Case(
    'captured coordinator event type',
    1,
    controller:
        "final kind = (event).type; switch((kind)) { case 'tool.error': break; }",
  ),
  _Case(
    'payload immutable alias',
    1,
    model: "final payload = (data); payload['toolCallId'];",
  ),
  _Case(
    'renamed key reader still consumes alias',
    1,
    model: "renamedReader(data, const ['tool_id', 'tool_call_id']);",
  ),
  _Case(
    'nested arbitrary result keys stay valid',
    0,
    model:
        "final result = data['result']; result['error']; result['status']; result['toolCallId']; first(result, const ['input', 'tool']);",
  ),
  _Case(
    'unrelated string comparison and literal payload',
    0,
    model:
        "if(other == 'tool.error') {} final result = {'error':'tool.progress'}; send(data['result']);",
  ),
  _Case(
    'same member on unrelated owner stays valid',
    0,
    extraModel:
        "class Other { void fromGatewayEvent(String type, Map data) { if(type == 'tool.error') {} data['status']; } }",
  ),
  _Case(
    'nearer closure parameters shadow event and payload',
    0,
    model:
        "listen((eventType, data) { if(eventType == 'tool.error') {} data['status']; });",
  ),
  _Case(
    'nearer ordinary locals shadow event and payload',
    0,
    model:
        "{ final eventType = unrelated; final data = unrelated; if(eventType == 'tool.error') {} data['status']; }",
  ),
  _Case(
    'loop binding shadows event selector',
    0,
    model: "for(final eventType in other) { if(eventType == 'tool.error') {} }",
  ),
  _Case(
    'catch binding shadows payload',
    0,
    model: "try {} catch(data) { data['status']; }",
  ),
  _Case(
    'pattern binding shadows selector',
    0,
    model:
        "if(other case final eventType) { if(eventType == 'tool.error') {} }",
  ),
  _Case('missing canonical owner', 2, invalid: 'owner', cli: true),
  _Case('missing canonical method', 2, invalid: 'method'),
  _Case('missing declared part', 2, invalid: 'part'),
  _Case('actual reciprocal controller part', 0, invalid: 'validpart'),
  _Case('named reciprocal controller part', 0, invalid: 'namedpart'),
  _Case('mismatched controller part owner', 2, invalid: 'mismatchpart'),
  _Case('ambiguous owner namespace across part', 2, invalid: 'duplicatepart'),
  _Case('canonical path cannot be a part', 2, invalid: 'partof'),
  _Case('malformed source', 2, invalid: 'syntax'),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final root = Directory.systemTemp.createTempSync(
      'wing-current-tool-events-',
    );
    try {
      final sources = {
        modelPath:
            'class GatewayToolActivity { static Object? fromGatewayEvent(String ${fixture.selector}, Map data) { ${fixture.model} return null; } } ${fixture.extraModel}',
        runtimePath:
            'class ChatRuntime { void observeEvent(String type, Map data) { ${fixture.event} } void observeTool(String type, Map data) { ${fixture.tool} } }',
        controllerPath:
            'class ProfileWorkspaceController { void _event(Object owner, dynamic event) { ${fixture.controller} } }',
      };
      switch (fixture.invalid) {
        case 'owner':
          sources[modelPath] = 'class Other {}';
        case 'method':
          sources[modelPath] = 'class GatewayToolActivity {}';
        case 'part':
          sources[modelPath] = "part 'other.dart'; ${sources[modelPath]}";
        case 'syntax':
          sources[modelPath] = 'class GatewayToolActivity {';
      }
      const partPath = 'lib/core/services/tool_event_fixture_part.dart';
      if (const {
        'validpart',
        'namedpart',
        'mismatchpart',
        'duplicatepart',
      }.contains(fixture.invalid)) {
        final named = fixture.invalid == 'namedpart';
        sources[controllerPath] =
            '${named ? 'library wing_fixture; ' : ''}'
            "part 'tool_event_fixture_part.dart'; ${sources[controllerPath]}";
        sources[partPath] = fixture.invalid == 'mismatchpart'
            ? "part of 'wrong.dart'; class OtherHelper {}"
            : '${named ? 'part of wing_fixture;' : "part of 'profile_workspace_controller.dart';"} '
                  '${fixture.invalid == 'duplicatepart' ? 'class ProfileWorkspaceController {}' : 'class OtherHelper {}'}';
      }
      if (fixture.invalid == 'partof') {
        sources[modelPath] = "part of 'other.dart'; ${sources[modelPath]}";
      }
      for (final entry in sources.entries) {
        final file = File('${root.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      final roles = '${root.path}/roles.json';
      File(roles).writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'files': {
            for (final path in sources.keys)
              path: {
                'role': 'application',
                'feature': 'conversation',
                'library': path == partPath ? controllerPath : path,
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
                  findings.single.line != 1 ||
                  !sources.containsKey(findings.single.file) ||
                  !findings.single.subject.contains(':'))) {
        throw StateError('${fixture.name}: $exit / $findings');
      }
      if (!fixture.cli) continue;
      if (!cliExits.add(fixture.exit)) {
        throw StateError('Duplicate CLI representative');
      }
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        'tools/architecture/rules/current_tool_events.dart',
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
        final problems =
            (jsonDecode(result.stdout as String) as Map)['problems'] as List;
        if (fixture.exit == 0
            ? problems.isNotEmpty
            : problems.length != 1 ||
                  (problems.single as Map)['id'] != findings.single.id ||
                  (problems.single as Map)['file'] != findings.single.file ||
                  (problems.single as Map)['subject'] !=
                      findings.single.subject ||
                  (problems.single as Map)['line'] != 1) {
          throw StateError('CLI diagnostic identity/location mismatch');
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) {
    throw StateError('CLI exits 0/1/2 were not exercised');
  }
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures and three CLI representatives passed',
  );
}
