import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';
import '../flutter_widget_identity.dart';

const id = 'ARCH_FORM_CONFIRMATION_ACTIONS';
const owner = 'lib/core/widgets/studio_form_actions.dart';
const _retiredLabels = {
  'Cancel',
  'Save',
  'Save changes',
  'Save icon',
  'Save language',
  'Create task',
  'Apply',
  'Apply decisions',
  'Use in task',
  'Use model',
  'Save default',
  'Confirm',
  'Add',
};
const _buttons = {'TextButton', 'FilledButton', 'ElevatedButton'};

/// Rejects the concrete text-footers encountered during the family migration.
/// It does not infer a dynamic label's operation, async lifetime or reachability.
List<Finding> check(Snapshot snapshot) {
  final namespace = FlutterWidgetIdentity(
    snapshot,
    widgets: {..._buttons, 'Text'},
  );
  final findings = <Finding>[];
  for (final source in snapshot.sources.values) {
    final visitor = _Buttons(namespace, source, findings);
    source.ast.accept(visitor);
  }
  return findings;
}

class _Buttons extends RecursiveAstVisitor<void> {
  _Buttons(this.namespace, this.source, this.findings);
  final FlutterWidgetIdentity namespace;
  final Source source;
  final List<Finding> findings;

  (String, String?, ArgumentList)? call(Expression expression) {
    if (expression is InstanceCreationExpression) {
      final type = expression.constructorName.type;
      return (
        type.name.lexeme,
        type.importPrefix?.name.lexeme,
        expression.argumentList,
      );
    }
    if (expression is MethodInvocation) {
      final target = expression.target;
      if (target == null) {
        return (expression.methodName.name, null, expression.argumentList);
      }
      if (target is SimpleIdentifier) {
        if (_buttons.contains(expression.methodName.name) ||
            expression.methodName.name == 'Text') {
          return (
            expression.methodName.name,
            target.name,
            expression.argumentList,
          );
        }
        return (target.name, null, expression.argumentList);
      }
      if (target is PrefixedIdentifier) {
        return (
          target.identifier.name,
          target.prefix.name,
          expression.argumentList,
        );
      }
    }
    return null;
  }

  void inspect(Expression expression) {
    final invocation = call(expression);
    if (invocation == null ||
        !namespace.candidates.contains(invocation.$1) ||
        flutterNameIsLocallyBound(expression, invocation.$2 ?? invocation.$1) ||
        !_buttons.contains(
          namespace.symbol(source.path, invocation.$1, prefix: invocation.$2),
        )) {
      return;
    }
    for (final argument
        in invocation.$3.arguments.whereType<NamedExpression>()) {
      if (!{'child', 'label'}.contains(argument.name.label.name)) continue;
      final text = call(argument.expression);
      if (text == null ||
          flutterNameIsLocallyBound(argument.expression, text.$2 ?? text.$1) ||
          namespace.symbol(source.path, text.$1, prefix: text.$2) != 'Text') {
        continue;
      }
      final label = text.$3.arguments.firstOrNull;
      if (label is! StringLiteral ||
          !_retiredLabels.contains(label.stringValue)) {
        continue;
      }
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(expression.offset),
          'text-footer:${label.stringValue}#${expression.offset}',
          'Use StudioFormActions for explicit draft confirmation; put operation names in tooltips and accessibility labels.',
        ),
      );
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    inspect(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    inspect(node);
    super.visitMethodInvocation(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
