import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_CONNECTOR_DETAIL_MOUNT';
const library = 'lib/core/screens/administration/admin_connectors_page.dart';
const subject = '_AdminConnectorDetailState.initState';

/// The shared inventory's initial read begins after the child mounts.
List<Finding> check(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.any(
        (d) => d is PartDirective || d is PartOfDirective,
      )) {
    throw const FormatException('Unsupported connector detail scope');
  }
  final owners = source.ast.declarations
      .whereType<ClassDeclaration>()
      .where((c) => c.namePart.typeName.lexeme == '_AdminConnectorDetailState')
      .toList();
  if (owners.length != 1 || owners.single.body is! BlockClassBody) {
    throw const FormatException('Missing canonical connector detail state');
  }
  final methods = (owners.single.body as BlockClassBody).members
      .whereType<MethodDeclaration>()
      .where((m) => m.name.lexeme == 'initState')
      .toList();
  if (methods.length != 1 || methods.single.body is! BlockFunctionBody) {
    throw const FormatException('Missing connector detail initState body');
  }
  final calls = _InitialReads();
  methods.single.body.accept(calls);
  return [
    for (final call in calls.unsafe)
      Finding(
        id,
        library,
        source.lineAt(call.offset),
        subject,
        'Defer the shared connector inventory initial read with WidgetsBinding.instance.addPostFrameCallback.',
      ),
  ];
}

class _InitialReads extends RecursiveAstVisitor<void> {
  final unsafe = <MethodInvocation>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final receiver = node.target?.toSource();
    final read =
        node.methodName.name == '_load' &&
            (receiver == null || receiver == 'this') ||
        node.methodName.name == 'refresh' &&
            (receiver == '_session' || receiver == 'session');
    if (read && !_inPostFrameCallback(node)) unsafe.add(node);
    super.visitMethodInvocation(node);
  }
}

bool _inPostFrameCallback(AstNode node) {
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is! FunctionExpression) continue;
    final arguments = parent.parent;
    final registration = arguments?.parent;
    return arguments is ArgumentList &&
        registration is MethodInvocation &&
        registration.methodName.name == 'addPostFrameCallback' &&
        registration.target?.toSource() == 'WidgetsBinding.instance' &&
        arguments.arguments.isNotEmpty &&
        identical(arguments.arguments.first, parent);
  }
  return false;
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
