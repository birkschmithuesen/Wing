import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart';
import '../model.dart';

const id = 'ARCH_INTELLIGENCE_READ_ADMISSION';
const owner = 'lib/core/services/profile_workspace_controller.dart';
const _admission = 'requireCurrentRead';

/// Finite structural boundary: this owner's awaited intelligence read must
/// synchronously revalidate its capture before processing the result. Held-I/O
/// regressions establish what the capture checks actually mean.
List<Finding> check(Snapshot snapshot) {
  if (!snapshot.sources.containsKey(owner)) {
    throw const FormatException('Missing intelligence owner');
  }
  final matches = <(Source, ClassDeclaration)>[];
  for (final source in snapshot.sources.values) {
    if (snapshot.libraries[source.path] != owner) continue;
    for (final declaration
        in source.ast.declarations.whereType<ClassDeclaration>()) {
      if (declaration.namePart.typeName.lexeme ==
          'ProfileWorkspaceController') {
        matches.add((source, declaration));
      }
    }
  }
  if (matches.length != 1) {
    throw const FormatException('Missing or ambiguous intelligence owner');
  }
  final (source, declaration) = matches.single;
  final body = declaration.body;
  if (body is! BlockClassBody) {
    throw const FormatException('Unsupported intelligence owner');
  }
  final methods = body.members
      .whereType<MethodDeclaration>()
      .where((method) => method.name.lexeme == 'loadIntelligence')
      .toList();
  if (methods.length != 1 || methods.single.body is! BlockFunctionBody) {
    throw const FormatException('Missing intelligence read boundary');
  }
  final method = methods.single;
  final statements = (method.body as BlockFunctionBody).block.statements;
  final declarations = statements
      .whereType<FunctionDeclarationStatement>()
      .where(
        (statement) => statement.functionDeclaration.name.lexeme == _admission,
      )
      .toList();
  final waits = <int>[];
  for (var i = 0; i < statements.length; i++) {
    final scan = _AwaitedRead();
    statements[i].accept(scan);
    if (scan.found) waits.add(i);
  }
  if (waits.isEmpty) {
    throw const FormatException('Intelligence read has no awaited boundary');
  }
  final declared = declarations.length == 1 ? declarations.single : null;
  final function = declared?.functionDeclaration.functionExpression;
  final synchronous =
      function != null &&
      !function.body.isAsynchronous &&
      !function.body.isGenerator &&
      function.parameters?.parameters.isEmpty == true;
  final admittedBeforeRead =
      synchronous &&
      statements.indexOf(declared!) < waits.first &&
      waits.first > 0 &&
      _isAdmission(statements[waits.first - 1]);
  final findings = <Finding>[];
  for (final index in waits) {
    // A compound statement could mutate observations before its trailing check.
    // Keep this finite seam's asynchronous read as a direct statement.
    final direct = _isDirectRead(statements[index]);
    if (!admittedBeforeRead ||
        !direct ||
        index + 1 >= statements.length ||
        !_isAdmission(statements[index + 1])) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(statements[index].offset),
          'ProfileWorkspaceController.loadIntelligence',
          'Declare synchronous captured read admission before I/O and invoke it '
              'directly before the read and immediately after each await.',
        ),
      );
    }
  }
  return findings..sort();
}

bool _isDirectRead(Statement statement) {
  Expression? expression;
  if (statement is VariableDeclarationStatement &&
      statement.variables.variables.length == 1) {
    expression = statement.variables.variables.single.initializer;
  } else if (statement is ExpressionStatement) {
    expression = statement.expression;
  }
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  // Assignment, processing wrappers and grouped declarations could consume or
  // publish the awaited value before the following admission check.
  return expression is AwaitExpression;
}

bool _isAdmission(Statement statement) {
  if (statement is! ExpressionStatement) return false;
  Expression expression = statement.expression;
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression is MethodInvocation &&
      expression.target == null &&
      expression.methodName.name == _admission &&
      expression.argumentList.arguments.isEmpty;
}

class _AwaitedRead extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    found = true;
  }

  // Callback bodies have their own execution/lifetime; they are not this read.
  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {}
}

Future<void> main(List<String> args) => run(args, {id: check});
