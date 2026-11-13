import 'package:analyzer/dart/ast/ast.dart';

import 'model.dart';

bool flutterNameIsLocallyBound(AstNode node, String name) {
  for (
    AstNode? ancestor = node.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    final parameters = switch (ancestor) {
      FunctionExpression() => ancestor.parameters,
      MethodDeclaration() => ancestor.parameters,
      _ => null,
    };
    if (parameters?.parameters.any(
          (parameter) => parameter.name?.lexeme == name,
        ) ==
        true) {
      return true;
    }
    if (ancestor is Block) {
      for (final statement in ancestor.statements.where(
        (statement) => statement.offset < node.offset,
      )) {
        if (statement is VariableDeclarationStatement &&
            statement.variables.variables.any(
              (variable) => variable.name.lexeme == name,
            )) {
          return true;
        }
        if (statement is FunctionDeclarationStatement &&
            statement.functionDeclaration.name.lexeme == name) {
          return true;
        }
      }
    }
    if (ancestor is BlockClassBody &&
        ancestor.members.whereType<MethodDeclaration>().any(
          (method) => method.name.lexeme == name,
        )) {
      return true;
    }
  }
  return false;
}

class FlutterWidgetIdentity {
  FlutterWidgetIdentity(this.snapshot, {required this.widgets}) {
    for (final source in snapshot.sources.values) {
      candidates.addAll(
        source.ast.declarations.whereType<GenericTypeAlias>().map(
          (alias) => alias.name.lexeme,
        ),
      );
    }
  }
  final Snapshot snapshot;
  final Set<String> widgets;
  late final candidates = {...widgets};
  final _units = <String, List<Source>>{};
  final _symbols = <String, String?>{};
  Iterable<Source> units(String path) => _units.putIfAbsent(
    snapshot.libraries[path] ?? path,
    () => snapshot.sources.values
        .where(
          (source) =>
              (snapshot.libraries[source.path] ?? source.path) ==
              (snapshot.libraries[path] ?? path),
        )
        .toList(),
  );
  String? symbol(
    String path,
    String name, {
    String? prefix,
    bool exported = false,
    Set<String> seen = const {},
  }) {
    final key = '$path:$name:$prefix:$exported';
    if (_symbols.containsKey(key)) return _symbols[key];
    final result = _lookup(
      path,
      name,
      prefix: prefix,
      exported: exported,
      seen: seen,
    );
    if (result != null || seen.isEmpty) _symbols[key] = result;
    return result;
  }

  String? _lookup(
    String path,
    String name, {
    String? prefix,
    bool exported = false,
    Set<String> seen = const {},
  }) {
    final key = '$path:$name:$prefix:$exported';
    if (seen.contains(key)) return null;
    final visited = {...seen, key};
    if (prefix == null) {
      for (final unit in units(path)) {
        for (final declaration in unit.ast.declarations) {
          if (declaration is FunctionDeclaration &&
              declaration.name.lexeme == name) {
            return null;
          }
          if (declaration is TopLevelVariableDeclaration &&
              declaration.variables.variables.any(
                (variable) => variable.name.lexeme == name,
              )) {
            return null;
          }
          if (declaration is ClassDeclaration &&
              declaration.namePart.typeName.lexeme == name) {
            return null;
          }
          if (declaration is GenericTypeAlias &&
              declaration.name.lexeme == name &&
              declaration.type is NamedType) {
            final type = declaration.type as NamedType;
            return symbol(
              unit.path,
              type.name.lexeme,
              prefix: type.importPrefix?.name.lexeme,
              seen: visited,
            );
          }
        }
      }
    }
    for (final unit in units(path)) {
      for (final directive
          in unit.ast.directives.whereType<NamespaceDirective>()) {
        if (exported && directive is! ExportDirective) continue;
        if (!exported &&
            directive is ImportDirective &&
            directive.prefix?.name != prefix) {
          continue;
        }
        if (!exported && directive is ExportDirective && prefix != null) {
          continue;
        }
        if (directive.combinators.any(
          (c) =>
              c is ShowCombinator && !c.shownNames.any((n) => n.name == name) ||
              c is HideCombinator && c.hiddenNames.any((n) => n.name == name),
        )) {
          continue;
        }
        final uris = [
          directive.uri.stringValue,
          for (final branch in directive.configurations) branch.uri.stringValue,
        ];
        for (final uri in uris) {
          if (uri != null && renderingUris.contains(uri)) return name;
          for (final dependency in unit.dependencies.where(
            (d) => d.uri == uri,
          )) {
            if (dependency.target case final target?) {
              final origin = symbol(
                target,
                name,
                exported: true,
                seen: visited,
              );
              if (origin != null) return origin;
            }
          }
        }
      }
    }
    return null;
  }
}
