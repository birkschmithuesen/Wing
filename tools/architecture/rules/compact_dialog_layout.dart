import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../flutter_widget_identity.dart';
import '../model.dart';

const id = 'ARCH_COMPACT_DIALOG_LAYOUT';
const owner = 'lib/core/widgets/studio_form_actions.dart';
const _dialogs = {'AlertDialog', 'SimpleDialog'};

/// Shared framing controls resolved gutters and text-scale behavior. Native
/// bounded viewers are separately reviewed; this guard owns alert/select frames.
List<Finding> check(Snapshot snapshot) {
  final identity = FlutterWidgetIdentity(snapshot, widgets: _dialogs);
  final findings = <Finding>[];
  for (final source in snapshot.sources.values) {
    if (source.path == owner) continue;
    source.ast.accept(_Dialogs(identity, source, findings));
  }
  return findings;
}

class _Dialogs extends RecursiveAstVisitor<void> {
  _Dialogs(this.identity, this.source, this.findings);
  final FlutterWidgetIdentity identity;
  final Source source;
  final List<Finding> findings;

  void inspect(AstNode node, String name, String? prefix) {
    if (!identity.candidates.contains(name) ||
        flutterNameIsLocallyBound(node, prefix ?? name) ||
        !_dialogs.contains(
          identity.symbol(source.path, name, prefix: prefix),
        )) {
      return;
    }
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        'unowned-dialog-frame#${node.offset}',
        'Use StudioDialog so heading, content and actions share compact, text-scale-safe insets.',
      ),
    );
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type;
    inspect(node, type.name.lexeme, type.importPrefix?.name.lexeme);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    final type = node.constructorName.type;
    inspect(node, type.name.lexeme, type.importPrefix?.name.lexeme);
    super.visitConstructorReference(node);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    final type = node.superclass;
    inspect(node, type.name.lexeme, type.importPrefix?.name.lexeme);
    super.visitExtendsClause(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (identity.candidates.contains(node.prefix.name)) {
      inspect(node, node.prefix.name, null);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    if (target is PrefixedIdentifier &&
        identity.candidates.contains(target.identifier.name)) {
      inspect(node, target.identifier.name, target.prefix.name);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target == null) {
      inspect(node, node.methodName.name, null);
    } else if (target is SimpleIdentifier) {
      if (identity.candidates.contains(node.methodName.name)) {
        inspect(node, node.methodName.name, target.name);
      } else {
        inspect(node, target.name, null);
      }
    } else if (target is PrefixedIdentifier) {
      inspect(node, target.identifier.name, target.prefix.name);
    }
    super.visitMethodInvocation(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
