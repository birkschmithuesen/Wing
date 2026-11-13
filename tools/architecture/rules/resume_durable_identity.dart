import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart';
import '../model.dart';

const id = 'ARCH_RESUME_DURABLE_IDENTITY';
const owner = 'lib/core/services/profile_workspace_controller.dart';
const methods = {'loadNotificationApproval', '_loadNotificationInput'};

/// These two workflows compare a captured durable identity using the gateway
/// projection. Active-list row decoding and unrelated libraries remain valid.
List<Finding> check(Snapshot snapshot) {
  if (!snapshot.sources.containsKey(owner)) {
    throw const FormatException('Missing notification resume owner');
  }
  final classes = <(Source, ClassDeclaration)>[];
  for (final source in snapshot.sources.values) {
    final partOwners = snapshot.partOwners[source.path] ?? const <String>[];
    if (partOwners.contains(owner) || source.partOf == owner) {
      if (partOwners.length != 1 ||
          snapshot.libraries[source.path] != owner ||
          (source.partOf != null && source.partOf != owner)) {
        throw const FormatException('Unverifiable notification resume part');
      }
    }
    if (snapshot.libraries[source.path] != owner) continue;
    for (final declaration
        in source.ast.declarations.whereType<ClassDeclaration>()) {
      if (declaration.namePart.typeName.lexeme ==
          'ProfileWorkspaceController') {
        classes.add((source, declaration));
      }
    }
  }
  if (classes.length != 1) {
    throw const FormatException('Missing or ambiguous notification controller');
  }
  final (source, declaration) = classes.single;
  final body = declaration.body;
  if (body is! BlockClassBody) {
    throw const FormatException('Unsupported notification controller body');
  }
  final findings = <Finding>[];
  for (final method in methods) {
    final matches = body.members
        .whereType<MethodDeclaration>()
        .where((m) => m.name.lexeme == method)
        .toList();
    if (matches.length != 1) {
      throw const FormatException(
        'Missing or ambiguous notification resume method',
      );
    }
    matches.single.body.accept(_RawKeys(source, method, findings));
  }
  return findings..sort();
}

class _RawKeys extends RecursiveAstVisitor<void> {
  _RawKeys(this.source, this.method, this.findings);
  final Source source;
  final String method;
  final List<Finding> findings;

  @override
  void visitIndexExpression(IndexExpression node) {
    Expression key = node.index;
    while (key is ParenthesizedExpression) {
      key = key.expression;
    }
    if (key is SimpleStringLiteral &&
        {'session_key', 'stored_session_id'}.contains(key.value)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          'ProfileWorkspaceController.$method:${key.value}',
          'Compare the captured durable ID through the current gateway resume projection.',
        ),
      );
    }
    super.visitIndexExpression(node);
  }
}

void main(List<String> args) => run(args, {id: check});
