import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as path;

class TestPlan {
  const TestPlan(
    this.files,
    this.isolated,
    this.batches,
    this.targets,
    this.scheduled,
  );

  final List<String> files, isolated, targets, scheduled;
  final List<List<String>> batches;

  Map<String, Object> toJson() => {
    'files': files,
    'isolated': isolated,
    'batches': batches,
    'targets': targets,
    'scheduled': scheduled,
  };
}

// Callback transport and value fixtures reviewed for per-test ownership and
// cleanup. New transport suites remain isolated until their fixtures are reviewed.
// These reviewed fixtures reset preferences in each case or fixture.initialize,
// rather than a main-level setUp. Other global-state safeguards still apply.
const _reviewedPerCasePreferences = {
  'test/administration_comparison_test.dart',
  'test/analytics_content_test.dart',
  'test/chat_profile_bar_test.dart',
  'test/composer_action_settings_test.dart',
  'test/doctor_chat_test.dart',
  'test/home_group_navigation_test.dart',
  'test/internal_message_visibility_test.dart',
  'test/large_chat_outputs_test.dart',
  'test/notification_delivery_ledger_test.dart',
  'test/notification_outage_recovery_test.dart',
  'test/profile_clarification_screen_test.dart',
  'test/profile_combined_activity_test.dart',
  'test/profile_draft_recovery_test.dart',
  'test/profile_overview_access_boundary_test.dart',
  'test/profile_question_delivery_test.dart',
  'test/profile_recents_visibility_test.dart',
  'test/profile_selector_test.dart',
  'test/profile_unread_filter_test.dart',
  'test/profile_workspace_route_lease_test.dart',
  'test/project_folder_picker_test.dart',
  'test/workspace_file_read_disposal_test.dart',
  'test/workspace_reading_snapshot_test.dart',
};

const _reviewedPureFixtures = {
  'test/administration_connector_health_test.dart',
  'test/administration_repository_test.dart',
  'test/administration_transport_test.dart',
  'test/backend_update_controller_test.dart',
  'test/chat_browser_data_test.dart',
  'test/chat_output_test.dart',
  'test/composer_draft_record_work_test.dart',
  'test/config_backup_exact_credentials_test.dart',
  'test/config_backup_required_fields_test.dart',
  'test/config_backup_test.dart',
  'test/connection_address_test.dart',
  'test/deleted_session_presence_test.dart',
  'test/file_open_error_message_test.dart',
  'test/gateway_endpoint_test.dart',
  'test/gateway_sensitive_prompt_test.dart',
  'test/hermes_cloud_test.dart',
  'test/markdown_inline_parser_test.dart',
  'test/message_content_test.dart',
  'test/notification_delivery_ledger_test.dart',
  'test/notification_outage_recovery_test.dart',
  'test/profile_capabilities_session_test.dart',
  'test/profile_connection_identity_test.dart',
  'test/profile_connectors_session_test.dart',
  'test/profile_fallback_edit_session_test.dart',
  'test/profile_identity_repository_test.dart',
  'test/profile_management_owned_transport_test.dart',
  'test/profile_message_presentation_test.dart',
  'test/profile_model_defaults_session_test.dart',
  'test/profile_model_edit_session_test.dart',
  'test/profile_model_owned_transport_test.dart',
  'test/profile_overview_access_boundary_test.dart',
  'test/profile_recents_visibility_test.dart',
  'test/profile_saved_history_test.dart',
  'test/profile_sensitive_prompt_delivery_test.dart',
  'test/profile_session_key_test.dart',
  'test/profiles_management_session_test.dart',
  'test/profiles_repository_test.dart',
  'test/provider_console_test.dart',
  'test/reading_snapshot_message_test.dart',
  'test/remote_files_client_test.dart',
  'test/resource_preview_owner_test.dart',
  'test/retained_memory_session_test.dart',
  'test/scheduled_tasks_detail_session_test.dart',
  'test/scheduled_tasks_edit_session_test.dart',
  'test/scheduled_tasks_repository_test.dart',
  'test/server_connection_status_test.dart',
  'test/settings_owned_transport_test.dart',
  'test/tool_call_presentation_test.dart',
};

const _reviewedProofFixtures = {
  'test/activity_density_guard_test.dart',
  'test/app_preferences_construction_guard_test.dart',
  'test/app_preferences_view_guard_test.dart',
  'test/backup_owner_boundary_guard_test.dart',
  'test/browser_row_work_guard_test.dart',
  'test/browser_values_guard_test.dart',
  'test/browser_view_dependency_guard_test.dart',
  'test/capabilities_view_dependency_guard_test.dart',
  'test/chat_runtime_observation_guard_test.dart',
  'test/completed_model_view_guard_test.dart',
  'test/completed_setup_view_guard_test.dart',
  'test/connector_detail_mount_guard_test.dart',
  'test/connectors_view_dependency_guard_test.dart',
  'test/current_tool_events_guard_test.dart',
  'test/dart_main_roots_guard_test.dart',
  'test/deleted_draft_cleanup_boundary_guard_test.dart',
  'test/download_file_value_guard_test.dart',
  'test/find_view_dependency_guard_test.dart',
  'test/logs_view_dependency_guard_test.dart',
  'test/mcp_setup_view_dependency_guard_test.dart',
  'test/memory_view_protocol_guard_test.dart',
  'test/notification_journal_ack_guard_test.dart',
  'test/outputs_view_dependency_guard_test.dart',
  'test/owned_model_mutation_guard_test.dart',
  'test/plugins_view_dependency_guard_test.dart',
  'test/profile_colours_view_guard_test.dart',
  'test/profile_discovery_writer_guard_test.dart',
  'test/profile_identity_view_guard_test.dart',
  'test/profile_overview_wire_guard_test.dart',
  'test/profiles_management_view_guard_test.dart',
  'test/project_actions_view_dependency_guard_test.dart',
  'test/provider_recovery_view_dependency_guard_test.dart',
  'test/provider_values_guard_test.dart',
  'test/provider_view_protocol_guard_test.dart',
  'test/public_owner_state_guard_test.dart',
  'test/reading_view_input_guard_test.dart',
  'test/resume_durable_identity_guard_test.dart',
  'test/retained_memory_values_guard_test.dart',
  'test/retired_answer_versions_namespace_guard_test.dart',
  'test/row_actions_view_dependency_guard_test.dart',
  'test/saved_prompt_journal_admission_guard_test.dart',
  'test/scheduled_tasks_intent_guard_test.dart',
  'test/scheduled_tasks_protocol_guard_test.dart',
  'test/secure_reply_view_wire_guard_test.dart',
  'test/settings_edit_intent_guard_test.dart',
  'test/settings_view_protocol_guard_test.dart',
  'test/shared_draft_view_dependency_guard_test.dart',
  'test/skills_view_dependency_guard_test.dart',
  'test/slash_completion_view_dependency_guard_test.dart',
  'test/speech_synthesis_view_dependency_guard_test.dart',
  'test/supervision_view_dependency_guard_test.dart',
  'test/tool_setup_view_dependency_guard_test.dart',
  'test/transcript_history_dispatch_guard_test.dart',
  'test/usage_view_dependency_guard_test.dart',
  'test/view_draft_write_guard_test.dart',
  'test/visibility_key_owner_guard_test.dart',
  'test/voice_view_dependency_guard_test.dart',
  'test/workspace_canonical_state_guard_test.dart',
  'test/workspace_entry_key_owner_guard_test.dart',
};

/// Checker fixtures run nightly, when checking tools change, and before release.
/// Product/DTO tests in mixed scheduled-task suites stay in routine verification.
const architectureProofSuites = {
  ..._reviewedProofFixtures,
  'test/architecture_contract_test.dart',
  'test/image_codec_confinement_test.dart',
  'test/image_codec_provenance_test.dart',
  'test/intelligence_read_admission_guard_test.dart',
  'test/model_catalog_fixture_guard_test.dart',
  'test/retired_declarations_guard_test.dart',
  'test/required_quality_gates_test.dart',
};

const _reviewedWidgetFixtures = {
  'test/answer_versions_test.dart',
  'test/admin_tool_models_test.dart',
  'test/administration_connectivity_test.dart',
  'test/administration_comparison_test.dart',
  'test/administration_operation_session_test.dart',
  'test/administration_recovery_test.dart',
  'test/administration_retry_test.dart',
  'test/analytics_content_test.dart',
  'test/block_reusing_markdown_body_test.dart',
  'test/chat_image_preview_test.dart',
  'test/chat_profile_bar_test.dart',
  'test/composer_action_settings_test.dart',
  'test/doctor_chat_test.dart',
  'test/drawer_versions_test.dart',
  'test/event_read_recovery_test.dart',
  'test/gateway_sensitive_prompt_panel_test.dart',
  'test/home_group_navigation_test.dart',
  'test/host_resources_session_test.dart',
  'test/internal_message_visibility_test.dart',
  'test/large_chat_outputs_test.dart',
  'test/mcp_editor_navigation_test.dart',
  'test/mcp_setup_test.dart',
  'test/model_chooser_test.dart',
  'test/notification_answer_visibility_test.dart',
  'test/profile_camera_action_test.dart',
  'test/profile_clarification_screen_test.dart',
  'test/profile_combined_activity_test.dart',
  'test/profile_capabilities_screen_test.dart',
  'test/profile_editor_sheet_test.dart',
  'test/profile_draft_recovery_test.dart',
  'test/profile_disclosure_layout_test.dart',
  'test/profile_empty_history_test.dart',
  'test/profile_execution_activity_test.dart',
  'test/profile_management_view_test.dart',
  'test/profile_model_defaults_view_test.dart',
  'test/profile_overview_widget_test.dart',
  'test/profile_plugins_session_test.dart',
  'test/profile_project_actions_test.dart',
  'test/profile_question_delivery_test.dart',
  'test/profile_row_actions_test.dart',
  'test/profile_selector_test.dart',
  'test/profile_unread_filter_test.dart',
  'test/profile_workspace_route_lease_test.dart',
  'test/project_folder_picker_test.dart',
  'test/provider_device_sign_in_session_test.dart',
  'test/scheduled_tasks_transport_test.dart',
  'test/side_question_delivery_card_test.dart',
  'test/slash_commands_test.dart',
  'test/wing_theme_test.dart',
  'test/workspace_file_read_disposal_test.dart',
  'test/workspace_reading_snapshot_test.dart',
};

/// Group ordinary registration-only mains; preserve special suite lifetimes.
bool canBatch(
  String name,
  String source, {
  bool pure = false,
  bool proof = false,
  bool reviewedWidget = false,
}) {
  if (proof &&
      (!_reviewedProofFixtures.contains(name) ||
          RegExp(
            r"\b(?:testWidgets|TestWidgetsFlutterBinding|WidgetsFlutterBinding)\b",
          ).hasMatch(source))) {
    return false;
  }
  // These fixtures own inherited transports or import special owner lifetimes.
  if (const {
    'test/connection_setup_session_test.dart',
    'test/profile_workspace_registry_test.dart',
  }.contains(name)) {
    return false;
  }
  if (pure &&
      RegExp(
        r"\b(?:testWidgets|TestWidgetsFlutterBinding|WidgetsFlutterBinding)\b",
      ).hasMatch(source)) {
    return false;
  }
  if ((pure || reviewedWidget) &&
      RegExp(
        r'\b(?:HttpServer|HttpClient|WebSocket|Socket|SecureSocket|Process|File|Directory)\s*[(.]',
      ).hasMatch(source)) {
    return false;
  }
  if (RegExp(r'\.instance\s*=').hasMatch(source)) {
    return false;
  }
  final lower = source.toLowerCase();
  if (RegExp(r'extends\s+[\w.]*Binding\b').hasMatch(source)) return false;
  if ([
    if (!reviewedWidget) 'font',
    if (reviewedWidget) ...['fontloader', '.ttf', '.otf'],
    if (!pure && !proof && !reviewedWidget) ...['dart:io', 'http', 'socket'],
    if (!proof) ...['process.', 'proof_process'],
    'worker',
    'httpoverrides',
    'binarymessenger',
    'packageinfo',
    'setmockmethod',
    if (!pure && !proof && !reviewedWidget) 'capture',
    'fromenvironment',
    'platform.environment',
    'targetplatformoverride',
    '.platform =',
    'completiondiagnostics',
    'fluttererror.onerror',
  ].any(lower.contains)) {
    return false;
  }
  if (!proof &&
      RegExp(
        pure
            ? r'(?:^|_)(?:live|benchmark|instrumentation|voice|native)(?:_|$)'
            : r'(?:^|_)(?:live|benchmark|budget|retention|snapshot|cache|instrumentation|voice|native)(?:_|$)',
      ).hasMatch(path.basename(name))) {
    return false;
  }
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  if (parsed.errors.isNotEmpty) return false;
  if (parsed.unit.directives.any(
    (directive) =>
        directive is LibraryDirective && directive.metadata.isNotEmpty,
  )) {
    return false;
  }
  final mains = parsed.unit.declarations.whereType<FunctionDeclaration>().where(
    (function) => function.name.lexeme == 'main',
  );
  if (mains.length != 1) return false;
  final main = mains.single;
  final body = main.functionExpression.body;
  if (main.returnType?.toSource() != 'void' ||
      main.functionExpression.parameters?.parameters.isNotEmpty != false ||
      body is! BlockFunctionBody ||
      body.isAsynchronous) {
    return false;
  }
  if (lower.contains('sharedpreferences') &&
      !((pure || reviewedWidget) &&
          _reviewedPerCasePreferences.contains(name)) &&
      !body.block.statements.whereType<ExpressionStatement>().any((statement) {
        final expression = statement.expression;
        return expression is MethodInvocation &&
            expression.target == null &&
            expression.methodName.name == 'setUp' &&
            expression.toSource().contains('setMockInitialValues');
      })) {
    return false;
  }
  return body.block.statements.every(_registration);
}

bool _registration(Statement statement) {
  if (statement is FunctionDeclarationStatement) return true;
  if (statement is VariableDeclarationStatement) {
    return statement.variables.variables.every((variable) {
      final initializer = variable.initializer;
      if (initializer == null || initializer is FunctionExpression) return true;
      if (initializer is InstanceCreationExpression) {
        final type = initializer.constructorName.type.toSource();
        return !RegExp(
          r'(?:Controller|Repository|Session|Store|Client|Worker|Preferences|Registry|Hub|Host|Service|Manager|Binding)$',
        ).hasMatch(type);
      }
      if (initializer is MethodInvocation) {
        return const {
          'fromJson',
          'parse',
          'fromUri',
          'utc',
          'fromMillisecondsSinceEpoch',
          'fromMicrosecondsSinceEpoch',
        }.contains(initializer.methodName.name);
      }
      return initializer is Literal ||
          initializer is PrefixExpression && initializer.operand is Literal;
    });
  }
  if (statement is Block) return statement.statements.every(_registration);
  if (statement is ForStatement) {
    return !_executesCallback(statement.forLoopParts) &&
        _registration(statement.body);
  }
  if (statement is IfStatement) {
    return !_executesCallback(statement.expression) &&
        _registration(statement.thenStatement) &&
        (statement.elseStatement == null ||
            _registration(statement.elseStatement!));
  }
  if (statement is! ExpressionStatement) return false;
  final expression = statement.expression;
  if (expression is! MethodInvocation) return false;
  if (expression.target?.toSource() == 'TestWidgetsFlutterBinding' &&
      expression.methodName.name == 'ensureInitialized') {
    return true;
  }
  return expression.target == null &&
      const {
        'group',
        'test',
        'testWidgets',
        'setUp',
        'tearDown',
        'setUpAll',
        'tearDownAll',
      }.contains(expression.methodName.name);
}

// Registration bodies alone do not establish isolation: control expressions run
// while all imported mains register in the same isolate, before test teardown.
bool _executesCallback(AstNode node) =>
    node is MethodInvocation ||
    node is FunctionExpressionInvocation ||
    node is InstanceCreationExpression ||
    node.childEntities.whereType<AstNode>().any(_executesCallback);

String _literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

/// Compile current architecture commands together; each main gets a fresh VM.
List<String> createProofDispatcher(Directory root, Directory output) {
  final files = <File>[
    for (final name in ['tests', 'rules', 'dead_code'])
      if (Directory('${root.path}/tools/architecture/$name').existsSync())
        ...Directory('${root.path}/tools/architecture/$name')
            .listSync(followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
    if (File('${root.path}/tools/architecture/check_all.dart').existsSync())
      File('${root.path}/tools/architecture/check_all.dart'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final entries = <(File, bool)>[];
  for (final file in files) {
    final parsed = parseString(content: file.readAsStringSync());
    final mains = parsed.unit.declarations
        .whereType<FunctionDeclaration>()
        .where((function) => function.name.lexeme == 'main');
    if (mains.isEmpty) continue;
    final main = mains.single;
    final parameters = main.functionExpression.parameters!.parameters;
    if (parameters.length > 1 ||
        parameters.length == 1 &&
            parameters.single.toSource() != 'List<String> args' &&
            parameters.single.toSource() != 'List<String> arguments') {
      throw FormatException('Unsupported proof main: ${file.path}');
    }
    entries.add((file, parameters.isNotEmpty));
  }
  if (entries.isEmpty) throw const FormatException('No architecture proofs');
  final dispatcher = File('${output.path}/proofs.dart');
  dispatcher.writeAsStringSync(
    [
      "import 'dart:async';",
      for (var index = 0; index < entries.length; index++)
        'import ${_literal(entries[index].$1.absolute.uri.toString())} as proof$index;',
      'Future<void> main(List<String> arguments) async {',
      "  if (arguments.isEmpty) throw FormatException('Proof path required');",
      '  switch (arguments.first) {',
      for (var index = 0; index < entries.length; index++) ...[
        '    case ${_literal(entries[index].$1.absolute.path)}:',
        '      await Future<void>.sync(() => proof$index.main(${entries[index].$2 ? 'arguments.skip(1).toList()' : ''}));',
        '      return;',
      ],
      "    default: throw FormatException('Unregistered proof');",
      '  }',
      '}',
    ].join('\n'),
  );
  return [for (final entry in entries) entry.$1.absolute.path];
}

/// Every discovered original main appears exactly once, grouped or isolated.
TestPlan createTestPlan(
  Directory root,
  Directory output, {
  int count = 8,
  bool full = false,
}) {
  if (count < 1) throw const FormatException('Positive batch count required');
  final files = Directory('${root.path}/test')
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith('_test.dart'))
      .toList();
  if (files.isEmpty) {
    throw const FormatException('No host test files discovered');
  }
  String relative(File file) =>
      path.relative(file.path, from: root.path).replaceAll('\\', '/');
  final sources = {
    for (final file in files) relative(file): file.readAsStringSync(),
  };
  final scheduled =
      full
            ? <String>[]
            : sources.keys.where(architectureProofSuites.contains).toList()
        ..sort();
  final active = sources.keys.where((name) => !scheduled.contains(name));
  final configured =
      File('${root.path}/dart_test.yaml').existsSync() ||
      Directory('${root.path}/test')
          .listSync(recursive: true)
          .any(
            (entry) => path.basename(entry.path) == 'flutter_test_config.dart',
          );
  final eligible = active.where(
    (name) =>
        !configured &&
        (canBatch(name, sources[name]!) ||
            _reviewedPureFixtures.contains(name) &&
                canBatch(name, sources[name]!, pure: true) ||
            _reviewedProofFixtures.contains(name) &&
                canBatch(name, sources[name]!, proof: true) ||
            _reviewedWidgetFixtures.contains(name) &&
                canBatch(name, sources[name]!, reviewedWidget: true)),
  );
  int weight(String name) {
    final source = sources[name]!;
    var value =
        source.length +
        RegExp(r'\btest(?:Widgets)?\s*\(').allMatches(source).length * 2000;
    // Account for work hidden behind short wrappers, which otherwise run last.
    for (final match in RegExp(
      r"tools/architecture/(?:tests|rules)/[a-z_]+\.dart",
    ).allMatches(source)) {
      final proof = File('${root.path}/${match.group(0)}');
      if (proof.existsSync()) value += proof.lengthSync() * 8;
    }
    return value;
  }

  final weights = {for (final name in sources.keys) name: weight(name)};
  final candidates = eligible.toList()
    ..sort((a, b) => weights[b]!.compareTo(weights[a]!));
  final groups = List.generate(count * 3, (_) => <String>[]);
  final costs = List.filled(count * 3, 0);
  for (final name in candidates) {
    // Pure tests share lanes without a widget binding's mock HTTP client.
    final offset = canBatch(name, sources[name]!, proof: true)
        ? count * 2
        : canBatch(name, sources[name]!, pure: true)
        ? 0
        : count;
    var smallest = offset;
    for (var index = offset + 1; index < offset + count; index++) {
      if (costs[index] < costs[smallest]) smallest = index;
    }
    groups[smallest].add(name);
    costs[smallest] += weights[name]!;
  }
  final grouped = candidates.toSet();
  final isolated = active.where((name) => !grouped.contains(name)).toList()
    ..sort((a, b) => weights[b]!.compareTo(weights[a]!));
  final batchTargets = <String>[];
  output.createSync(recursive: true);
  for (var index = 0; index < groups.length; index++) {
    if (groups[index].isEmpty) continue;
    final file = File('${output.path}/batch_${index}_test.dart');
    file.writeAsStringSync(
      [
        "import 'package:flutter_test/flutter_test.dart';",
        for (var suite = 0; suite < groups[index].length; suite++)
          'import ${_literal(File('${root.path}/${groups[index][suite]}').uri.toString())} as suite$suite;',
        'void main() {',
        for (var suite = 0; suite < groups[index].length; suite++)
          '  group(${_literal(groups[index][suite])}, suite$suite.main);',
        '}',
      ].join('\n'),
    );
    batchTargets.add(file.absolute.path);
  }
  batchTargets.sort((a, b) {
    int lane(String target) =>
        int.parse(RegExp(r'batch_(\d+)_test').firstMatch(target)!.group(1)!);
    int order(String target) {
      final index = lane(target);
      final kind = index ~/ count;
      return (index % count) * 3 +
          (kind == 2
              ? 0
              : kind == 1
              ? 1
              : 2);
    }

    return order(a).compareTo(order(b));
  });
  final names = sources.keys.toList()..sort();
  final covered = [
    ...isolated,
    for (final group in groups) ...group,
    ...scheduled,
  ]..sort();
  if (jsonEncode(names) != jsonEncode(covered)) {
    throw StateError('Test discovery must have complete, unique coverage');
  }
  // Start grouped lanes before short standalone suites can consume all slots.
  // Long proof wrappers lead; remaining isolated suites follow the batch lanes.
  final heavy = isolated.where((name) => weights[name]! >= 100000).toList();
  // These matrix/journey suites contain work hidden behind loop declarations;
  // source size underestimates them. Start them before short isolated suites.
  final journeys = const [
    'test/studio_layout_test.dart',
    'test/administration_usage_test.dart',
  ].where(isolated.contains).toList();
  final remainingHeavy = heavy.where((name) => !journeys.contains(name));
  final firstProofs = remainingHeavy.take((count + 1) ~/ 2).toList();
  final firstBatches = batchTargets.take(count ~/ 2).toList();
  final targets = [
    ...journeys,
    ...firstProofs,
    ...firstBatches,
    ...remainingHeavy.skip(firstProofs.length),
    ...batchTargets.skip(firstBatches.length),
    ...isolated.where(
      (name) => !heavy.contains(name) && !journeys.contains(name),
    ),
  ];
  return TestPlan(names, isolated, groups, targets, scheduled);
}

void main(List<String> arguments) {
  if (arguments.length != 3 || !{'routine', 'full'}.contains(arguments[2])) {
    throw const FormatException(
      'Use OUTPUT_DIRECTORY BATCH_COUNT routine|full',
    );
  }
  final plan = createTestPlan(
    Directory.current,
    Directory(arguments[0]),
    count: int.parse(arguments[1]),
    full: arguments[2] == 'full',
  );
  final proofs = arguments[2] == 'full'
      ? createProofDispatcher(Directory.current, Directory(arguments[0]))
      : <String>[];
  stdout.writeln(
    jsonEncode({
      ...plan.toJson(),
      'proof_commands': proofs,
      'dart_executable': Platform.resolvedExecutable,
    }),
  );
}
