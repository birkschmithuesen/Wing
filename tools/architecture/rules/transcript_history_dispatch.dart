import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_TRANSCRIPT_HISTORY_DISPATCH';
const library = 'lib/core/screens/profile_transcript.dart';
const ownerClass = '_ProfileTranscriptState';
const subject = '$ownerClass.widget.onLoadOlder';

Expression? _unwrap(Expression? expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}

bool _widgetReceiver(Expression? expression) {
  final receiver = _unwrap(expression);
  return receiver is SimpleIdentifier && receiver.name == 'widget' ||
      receiver is PropertyAccess &&
          receiver.target is ThisExpression &&
          receiver.propertyName.name == 'widget';
}

/// Literal transcript history dispatch belongs to its frame callback or an
/// explicit user onPressed callback. Callback/receiver syntax is finite here;
/// this rule does not resolve SDK identity, aliases or captured-owner lifetime.
List<Finding> check(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.any(
        (directive) =>
            directive is PartDirective || directive is PartOfDirective,
      )) {
    throw const FormatException('Unsupported transcript history scope');
  }
  final owners = source.ast.declarations
      .whereType<ClassDeclaration>()
      .where((owner) => owner.namePart.typeName.lexeme == ownerClass)
      .toList();
  if (owners.length != 1 || owners.single.body is! BlockClassBody) {
    throw const FormatException('Missing canonical transcript state');
  }
  final calls = _HistoryDispatches();
  owners.single.body.accept(calls);
  return [
    for (final call in calls.unsafe)
      Finding(
        id,
        library,
        source.lineAt(call.methodName.offset),
        subject,
        'Dispatch transcript older-history intent in an inline post-frame callback or an explicit onPressed callback; never directly from scroll/layout notification.',
      ),
  ];
}

class _HistoryDispatches extends RecursiveAstVisitor<void> {
  final unsafe = <MethodInvocation>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'onLoadOlder' &&
        _widgetReceiver(node.realTarget) &&
        !_inAllowedCallback(node)) {
      unsafe.add(node);
    }
    super.visitMethodInvocation(node);
  }
}

bool _inAllowedCallback(AstNode node) {
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is! FunctionExpression) continue;
    // The nearest function must itself be the registered callback. An inner
    // local helper or unrelated closure does not inherit the outer exemption.
    final enclosing = parent.parent;
    if (enclosing is NamedExpression &&
        enclosing.name.label.name == 'onPressed' &&
        enclosing.parent is ArgumentList) {
      return true;
    }
    final registration = enclosing?.parent;
    return enclosing is ArgumentList &&
        registration is MethodInvocation &&
        registration.methodName.name == 'addPostFrameCallback' &&
        registration.target?.toSource() == 'WidgetsBinding.instance' &&
        enclosing.arguments.isNotEmpty &&
        identical(enclosing.arguments.first, parent);
  }
  return false;
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
