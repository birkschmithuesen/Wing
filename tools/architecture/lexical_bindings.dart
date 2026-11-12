import 'package:analyzer/dart/ast/ast.dart';

/// Proves a narrow bare read binds to a parsed local declaration, never an
/// inherited protocol member. Qualified accesses still require resolution.
/// This does not skip traversal of the declaration's initializer or body.
bool isProvenLocalRead(
  SimpleIdentifier node, {
  required String library,
  required Iterable<String> canonicalLibraries,
}) {
  for (AstNode? parent = node.parent; parent != null; parent = parent.parent) {
    final (parameters, body) = switch (parent) {
      FunctionExpression expression => (expression.parameters, expression.body),
      MethodDeclaration method => (method.parameters, method.body),
      ConstructorDeclaration constructor => (
        constructor.parameters,
        constructor.body,
      ),
      _ => (null, null),
    };
    if (body != null &&
        node.offset >= body.offset &&
        node.end <= body.end &&
        parameters?.parameters.any((p) => p.name?.lexeme == node.name) ==
            true) {
      return true;
    }
    if (parent is ClassDeclaration) {
      // A canonical owner split across parts is never a local exemption.
      if (canonicalLibraries.contains(library)) return false;
      final classBody = parent.body;
      if (classBody is! BlockClassBody) return false;
      return classBody.members.any(
        (member) => switch (member) {
          FieldDeclaration field => field.fields.variables.any(
            (variable) => variable.name.lexeme == node.name,
          ),
          MethodDeclaration method =>
            method.isGetter && method.name.lexeme == node.name,
          _ => false,
        },
      );
    }
  }
  return false;
}
