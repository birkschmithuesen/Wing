import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_COMPLETED_MODEL_VIEW';
const completedViews = [
  'lib/core/widgets/profile_default_model_sheet.dart',
  'lib/core/screens/administration/admin_fallback_page.dart',
  'lib/core/widgets/profile_diagnostics_panel.dart',
  'lib/core/screens/administration/admin_defaults_page.dart',
  'lib/core/screens/administration/admin_health_page.dart',
];
const _owners = {
  'lib/core/services/profile_gateway.dart': 'ProfileGateway',
  'lib/core/services/administration_repository.dart': 'ProfileAdministration',
  'lib/core/services/connection_manager.dart': 'DashboardClient',
  'lib/core/services/ws_client.dart': 'WsClient',
};
const _diagnosticsLibrary =
    'lib/core/services/profile_diagnostics_controller.dart';
const _diagnosticsClass = 'ProfileDiagnosticsController';
const _diagnosticsCommands = {
  'check',
  'invalidate',
  'updateModel',
  'updateGateway',
  'restore',
};
const _repositoryCallbacks = {'request', 'settingsWrite', 'ownedMutation'};
const _parserOwners = {
  'lib/core/models/model_catalog.dart': [('ModelCatalog', 'fromOptions')],
  'lib/core/models/model_choice.dart': [('ConfiguredModel', 'fromInfo')],
  'lib/core/models/fallback_model.dart': [('FallbackModel', 'fromConfig')],
  'lib/core/models/profile_model_defaults.dart': [
    ('HelperModelAssignment', 'fromResponse'),
    ('ModelDefaultsObservation', 'fromResponses'),
    ('ModelProviderAccess', 'fromResponse'),
  ],
};
const _wireKeys = {
  'providers',
  'provider',
  'model',
  'models',
  'confirm_required',
  'confirm_message',
  'tasks',
  'base_url',
  'reasoning_effort',
  'capabilities',
};

/// One completed-view contract: owner methods and stock wire projections belong
/// outside these views. Candidate scanning is syntactic; method identity and map
/// types require resolution. This is not whole-program flow or all-platform proof.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final names =
      _parserOwners.values
          .expand((owners) => owners.map((owner) => owner.$2))
          .toSet()
        ..addAll(_repositoryCallbacks)
        ..addAll(_diagnosticsCommands);
  for (final owner in _owners.entries) {
    final file = File('$root/${owner.key}');
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw FormatException('${owner.key}: invalid Dart');
    }
    final declaration = parsed.unit.declarations
        .whereType<ClassDeclaration>()
        .where((node) => node.namePart.typeName.lexeme == owner.value)
        .single;
    names.addAll(
      (declaration.body as BlockClassBody).members
          .whereType<MethodDeclaration>()
          .where(
            (node) =>
                !node.isGetter &&
                !node.isSetter &&
                !node.name.lexeme.startsWith('_'),
          )
          .map((node) => node.name.lexeme),
    );
  }
  // This finite command set is deliberately narrower than the controller's
  // passive projections and notifier lifecycle. Verify its canonical owner.
  final diagnostics = File('$root/$_diagnosticsLibrary');
  final parsedDiagnostics = parseString(
    content: diagnostics.readAsStringSync(),
    path: diagnostics.path,
    throwIfDiagnostics: false,
  );
  if (parsedDiagnostics.errors.isNotEmpty) {
    throw const FormatException('Invalid diagnostics owner');
  }
  final diagnosticsDeclaration = parsedDiagnostics.unit.declarations
      .whereType<ClassDeclaration>()
      .where((node) => node.namePart.typeName.lexeme == _diagnosticsClass)
      .single;
  final declaredCommands = (diagnosticsDeclaration.body as BlockClassBody)
      .members
      .whereType<MethodDeclaration>()
      .where((node) => !node.isGetter && !node.isSetter)
      .map((node) => node.name.lexeme)
      .toSet();
  if (!_diagnosticsCommands.every(declaredCommands.contains)) {
    throw const FormatException('Missing canonical diagnostics command');
  }
  final candidates = <String>[];
  for (final path in completedViews) {
    final source = File('$root/$path').readAsStringSync();
    final parsed = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) throw FormatException('$path: invalid Dart');
    if (parsed.unit.directives.any(
      (node) => node is PartDirective || node is PartOfDirective,
    )) {
      throw FormatException(
        '$path: completed-view parts require guard adaptation',
      );
    }
    if (parsed.unit.directives.whereType<NamespaceDirective>().any(
      (node) => node.configurations.isNotEmpty,
    )) {
      throw FormatException(
        '$path: conditional completed-view imports require branch verification',
      );
    }
    final scan = _Candidates(names);
    parsed.unit.accept(scan);
    if (scan.found) candidates.add(path);
  }
  if (candidates.isEmpty) return [];
  final contexts = semanticContextCollection(
    root: root,
    cacheNamespace: 'completed-model-view',
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
  );
  final findings = <Finding>[];
  try {
    for (final path in candidates) {
      final absolute = '$root/$path';
      final resolved = await contexts
          .contextFor(absolute)
          .currentSession
          .getResolvedUnit(absolute);
      if (resolved is! ResolvedUnitResult) {
        throw FormatException('$path: cannot resolve view');
      }
      resolved.unit.accept(_Resolved(root, path, names, resolved, findings));
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

bool _member(SimpleIdentifier node) =>
    node.inGetterContext() &&
    !node.inDeclarationContext() &&
    node.parent is! Combinator;

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.names);
  final Set<String> names;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (names.contains(node.name) && _member(node)) found = true;
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    if (node.index is StringLiteral &&
        _wireKeys.contains((node.index as StringLiteral).stringValue)) {
      found = true;
    }
    super.visitIndexExpression(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.root, this.path, this.names, this.result, this.findings);
  final String root, path;
  final Set<String> names;
  final ResolvedUnitResult result;
  final List<Finding> findings;
  void invalid(AstNode node, String reason) => findings.add(
    Finding(
      id,
      path,
      result.lineInfo.getLocation(node.offset).lineNumber,
      'owner-boundary:${node.offset}',
      reason,
    ),
  );
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (names.contains(node.name) && _member(node)) {
      final element = node.element?.baseElement;
      if (element == null) {
        final parent = node.parent;
        // Explicit invocation of a typed Dart function has no member element.
        // Its target is still visited, so a canonical captured callback fails.
        if (node.name == 'call' &&
            parent is MethodInvocation &&
            parent.realTarget?.staticType is FunctionType) {
          super.visitSimpleIdentifier(node);
          return;
        }
        throw FormatException(
          '$path: unresolved member ${node.name}; use typed UI commands',
        );
      }
      if (element is MethodElement ||
          element is GetterElement ||
          element is FieldElement) {
        final library = element.library?.firstFragment.source.fullName;
        if (library == null) {
          throw FormatException('$path: member ownership unavailable');
        }
        final relative = library.startsWith('$root/')
            ? library.substring(root.length + 1)
            : null;
        if ((relative == 'lib/core/services/administration_repository.dart' &&
                element.enclosingElement?.name == 'AdministrationRepository' &&
                _repositoryCallbacks.contains(element.name)) ||
            (element is MethodElement &&
                relative == _diagnosticsLibrary &&
                element.enclosingElement?.name == _diagnosticsClass &&
                _diagnosticsCommands.contains(element.name)) ||
            (element is MethodElement &&
                _owners[relative] != null &&
                _owners[relative] == element.enclosingElement?.name) ||
            (element is MethodElement &&
                _parserOwners[relative]?.any(
                      (owner) =>
                          element.enclosingElement?.name == owner.$1 &&
                          node.name == owner.$2,
                    ) ==
                    true)) {
          invalid(
            node,
            'Move transport, model parsing and diagnostics command coordination to the scoped owner; pass typed state and callbacks to this view.',
          );
        }
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final key = node.index is StringLiteral
        ? (node.index as StringLiteral).stringValue
        : null;
    if (_wireKeys.contains(key)) {
      final type = node.realTarget.staticType;
      if (type == null || type is DynamicType) {
        throw FormatException(
          '$path: unresolved model wire projection; use a typed UI value',
        );
      }
      if (type is InterfaceType &&
          type.element.name == 'Map' &&
          type.element.library.uri.toString() == 'dart:core') {
        final value = type.typeArguments[1];
        if (value is DynamicType ||
            (value is InterfaceType && value.isDartCoreObject)) {
          invalid(
            node,
            'Project stock model fields in the owner; this view must consume typed model state.',
          );
        }
      }
    }
    super.visitIndexExpression(node);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    var root = '.';
    String? sdkPath;
    final seen = <String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 == arguments.length ||
          !{'--root', '--sdk'}.contains(arguments[index]) ||
          !seen.add(arguments[index])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (arguments[index] == '--root') root = arguments[index + 1];
      if (arguments[index] == '--sdk') sdkPath = arguments[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdkPath);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
