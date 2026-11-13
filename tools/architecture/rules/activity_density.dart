import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../cli.dart' as cli;
import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_ACTIVITY_DENSITY';
const rowPath = 'lib/core/widgets/compact_activity_row.dart';
const _seams = {
  'lib/core/widgets/profile_tool_call.dart': ('ProfileToolCall', 'build'),
  'lib/core/widgets/profile_saved_agents.dart': (
    'ProfileSavedAgents',
    '_buildAgent',
  ),
};

/// A finite construction boundary, not a proof of rendered dimensions.
Future<List<Finding>> check(Snapshot snapshot, {String? sdkPath}) async {
  final root = Directory(snapshot.root).resolveSymbolicLinksSync();
  for (final path in [rowPath, ..._seams.keys]) {
    final source = snapshot.sources[path];
    if (source == null ||
        source.partOf != null ||
        source.namedPartOf ||
        source.partTargets.isNotEmpty ||
        source.ast.directives.whereType<NamespaceDirective>().any(
          (directive) => directive.configurations.isNotEmpty,
        )) {
      throw const FormatException(
        'Density owners require explicit physical libraries',
      );
    }
  }
  final contexts = semanticContextCollection(
    root: root,
    sdk: dartSdkPath(root, configured: sdkPath),
    includedPaths: [
      for (final path in [rowPath, ..._seams.keys]) '$root/$path',
    ],
    cacheNamespace: 'activity-density',
  );
  final findings = <Finding>[];
  try {
    for (final path in [rowPath, ..._seams.keys]) {
      final result = await contexts
          .contextFor('$root/$path')
          .currentSession
          .getResolvedUnit('$root/$path');
      if (result is! ResolvedUnitResult ||
          result.diagnostics.any(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          )) {
        throw const FormatException('Cannot resolve density owner');
      }
      final className = path == rowPath
          ? 'CompactActivityRow'
          : _seams[path]!.$1;
      final owners = result.unit.declarations
          .whereType<ClassDeclaration>()
          .where((node) => node.namePart.typeName.lexeme == className)
          .toList();
      if (owners.length != 1 || owners.single.body is! BlockClassBody) {
        throw const FormatException('Missing or ambiguous density owner');
      }
      if (path == rowPath) continue;
      final name = _seams[path]!.$2;
      final methods = (owners.single.body as BlockClassBody).members
          .whereType<MethodDeclaration>()
          .where((node) => node.name.lexeme == name)
          .toList();
      if (methods.length != 1) {
        throw const FormatException('Missing density seam');
      }
      final body = methods.single.body;
      final expressions = <Expression>[];
      if (body is ExpressionFunctionBody) {
        expressions.add(body.expression);
      } else if (body is BlockFunctionBody) {
        body.accept(_Returns(expressions));
      } else {
        throw const FormatException('Density seam must have an implementation');
      }
      if (expressions.isEmpty) {
        throw const FormatException('Density seam has no return');
      }
      for (var index = 0; index < expressions.length; index++) {
        var expression = expressions[index];
        while (expression is ParenthesizedExpression) {
          expression = expression.expression;
        }
        final constructor = expression is InstanceCreationExpression
            ? expression.constructorName.element?.baseElement
            : null;
        final owner = constructor?.enclosingElement;
        if (owner is InterfaceElement &&
            owner.name == 'CompactActivityRow' &&
            owner.library.firstFragment.source.fullName == '$root/$rowPath') {
          continue;
        }
        findings.add(
          Finding(
            id,
            path,
            result.lineInfo.getLocation(expression.offset).lineNumber,
            '$className.$name:return#$index',
            'Return the canonical CompactActivityRow directly; header wrappers and alternate rows bypass density controls.',
          ),
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _Returns extends RecursiveAstVisitor<void> {
  _Returns(this.expressions);
  final List<Expression> expressions;
  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression == null) {
      throw const FormatException('Empty density return');
    }
    expressions.add(node.expression!);
  }

  // A callback or local function has its own return contract.
  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

Future<void> main(List<String> args) =>
    cli.run([...args, '--strict'], {id: check});
