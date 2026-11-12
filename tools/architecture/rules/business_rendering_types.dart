import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart';
import '../model.dart';

const id = 'ARCH_BUSINESS_RENDERING_TYPE';
const _types = {
  'BuildContext',
  'Widget',
  'State',
  'StatelessWidget',
  'StatefulWidget',
  'TextEditingController',
  'ScrollController',
  'AnimationController',
  'NavigatorState',
  'FormState',
  'FocusNode',
  'PageController',
  'TabController',
};

List<Finding> check(Snapshot snapshot) {
  final result = <Finding>[];
  for (final source in snapshot.sources.values) {
    if (!businessRoles.contains(snapshot.roleOf(source.path))) continue;
    final owner = snapshot.libraries[source.path];
    final units = snapshot.sources.values.where(
      (unit) => snapshot.libraries[unit.path] == owner,
    );
    final imported = <String, Set<String>>{};
    final locallyDeclared = <String>{};
    for (final unit in units) {
      for (final declaration in unit.ast.declarations) {
        if (declaration is ClassDeclaration) {
          locallyDeclared.add(declaration.namePart.typeName.lexeme);
        }
        if (declaration is EnumDeclaration) {
          locallyDeclared.add(declaration.namePart.typeName.lexeme);
        }
        if (declaration is MixinDeclaration) {
          locallyDeclared.add(declaration.name.lexeme);
        }
        if (declaration is TypeAlias) {
          locallyDeclared.add(declaration.name.lexeme);
        }
      }
      for (final directive
          in unit.ast.directives.whereType<ImportDirective>()) {
        if (![
          directive.uri,
          ...directive.configurations.map((entry) => entry.uri),
        ].any((uri) => renderingUris.contains(uri.stringValue))) {
          continue;
        }
        final available = {..._types};
        for (final combinator in directive.combinators) {
          if (combinator is ShowCombinator) {
            available.retainAll(combinator.shownNames.map((name) => name.name));
          } else if (combinator is HideCombinator) {
            available.removeAll(
              combinator.hiddenNames.map((name) => name.name),
            );
          }
        }
        imported
            .putIfAbsent(directive.prefix?.name ?? '', () => {})
            .addAll(available);
      }
    }
    source.ast.accept(_Types(source, imported, locallyDeclared, result));
  }
  return result;
}

class _Types extends RecursiveAstVisitor<void> {
  _Types(this.source, this.imported, this.locallyDeclared, this.result);
  final Source source;
  final Map<String, Set<String>> imported;
  final Set<String> locallyDeclared;
  final List<Finding> result;
  final occurrences = <String, int>{};
  @override
  void visitNamedType(NamedType node) {
    final prefix = node.importPrefix?.name.lexeme ?? '';
    final name = node.name.lexeme;
    if ((prefix.isNotEmpty ||
            (!locallyDeclared.contains(name) &&
                !_typeParameterShadows(node, name))) &&
        (imported[prefix]?.contains(name) ?? false)) {
      final type = '$prefix.$name';
      final ordinal = occurrences.update(type, (n) => n + 1, ifAbsent: () => 1);
      result.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          '$type#$ordinal',
          'Keep framework rendering/focus controllers in the view or presentation owner.',
        ),
      );
    }
    super.visitNamedType(node);
  }

  bool _typeParameterShadows(AstNode node, String name) {
    AstNode? ancestor = node.parent;
    while (ancestor != null) {
      final parameters = switch (ancestor) {
        ClassDeclaration() => ancestor.namePart.typeParameters,
        EnumDeclaration() => ancestor.namePart.typeParameters,
        MixinDeclaration() => ancestor.typeParameters,
        GenericTypeAlias() => ancestor.typeParameters,
        GenericFunctionType() => ancestor.typeParameters,
        MethodDeclaration() => ancestor.typeParameters,
        FunctionExpression() => ancestor.typeParameters,
        ExtensionDeclaration() => ancestor.typeParameters,
        _ => null,
      };
      if (parameters?.typeParameters.any(
            (parameter) => parameter.name.lexeme == name,
          ) ??
          false) {
        return true;
      }
      ancestor = ancestor.parent;
    }
    return false;
  }
}

void main(List<String> args) => run(args, {id: check});
