import 'package:analyzer/dart/ast/ast.dart';

import 'model.dart';

/// A declared namespace boundary, not symbol-use or business-policy analysis.
/// Imports of typed owners may import adapters internally; only export edges
/// make an adapter dependency visible through a local barrel.
List<Finding> checkViewAdapterDependencies(
  Snapshot snapshot, {
  required String id,
  required String view,
  required String viewClass,
  required Set<String> adapters,
  required String message,
  required String missingViewMessage,
  required String detachedPartMessage,
}) {
  final units = <String, List<Source>>{};
  for (final source in snapshot.sources.values) {
    units.putIfAbsent(snapshot.libraries[source.path]!, () => []).add(source);
  }
  final validated = <String>{};
  List<Source> library(String path) {
    final primary = snapshot.sources[path];
    if (primary == null ||
        snapshot.libraries[path] != path ||
        primary.ast.directives.whereType<PartOfDirective>().isNotEmpty) {
      throw FormatException('Missing or ambiguous declared library: $path');
    }
    final members = units[path]!;
    if (!validated.add(path)) return members;
    if (primary.ast.directives.whereType<PartDirective>().length !=
        primary.partTargets.length) {
      throw FormatException('Unsupported declared part namespace: $path');
    }
    for (final source in members) {
      if (snapshot.classifications[source.path]?.library != path) {
        throw FormatException(
          'Missing or mismatched library role: ${source.path}',
        );
      }
    }
    for (final target in primary.partTargets) {
      final part = snapshot.sources[target];
      final owners = snapshot.partOwners[target];
      final directives = part?.ast.directives.whereType<PartOfDirective>();
      if (part == null ||
          owners?.length != 1 ||
          owners!.single != path ||
          directives!.length != 1 ||
          (part.partOf != path && !part.namedPartOf)) {
        throw FormatException('Missing or ambiguous actual part: $target');
      }
      if (part.partTargets.isNotEmpty) {
        throw FormatException('Nested actual part ownership: $target');
      }
      if (part.namedPartOf) {
        final names = primary.ast.directives.whereType<LibraryDirective>();
        if (names.length != 1 ||
            names.single.name == null ||
            names.single.name!.toSource() !=
                directives.single.libraryName?.toSource()) {
          throw FormatException('Mismatched named part: $target');
        }
      }
    }
    return members;
  }

  String? localTarget(Dependency edge) {
    if (edge.target case final target?) {
      // Snapshot normalizes relative URIs; normalize package:wing dot segments
      // too, so alternate URI spelling cannot hide a canonical library.
      final path = Uri(path: target).normalizePath().path;
      library(path);
      return path;
    }
    final uri = Uri.tryParse(edge.uri);
    if (uri == null ||
        !uri.hasScheme ||
        !{'dart', 'package'}.contains(uri.scheme)) {
      throw FormatException('Unsupported visible namespace: ${edge.uri}');
    }
    return null;
  }

  final viewUnits = library(view);
  if (!{'view', 'presentation'}.contains(snapshot.roleOf(view)) ||
      viewUnits
              .expand((unit) => unit.ast.declarations)
              .whereType<ClassDeclaration>()
              .where((node) => node.namePart.typeName.lexeme == viewClass)
              .length !=
          1) {
    throw FormatException(missingViewMessage);
  }
  // A detached part claiming the completed owner must not disappear from scope.
  final viewNames = snapshot.sources[view]!.ast.directives
      .whereType<LibraryDirective>()
      .map((directive) => directive.name?.toSource())
      .whereType<String>()
      .toSet();
  if (snapshot.sources.values.any(
    (source) =>
        snapshot.libraries[source.path] != view &&
        (source.partOf == view ||
            source.ast.directives.whereType<PartOfDirective>().any(
              (directive) =>
                  viewNames.contains(directive.libraryName?.toSource()),
            )),
  )) {
    throw FormatException(detachedPartMessage);
  }

  bool exposesAdapter(Dependency edge) {
    final first = localTarget(edge);
    if (first == null) return false;
    final seen = <String>{};
    final pending = [first];
    var forbidden = false;
    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!seen.add(path)) continue;
      forbidden |= adapters.contains(path);
      // Inspect every conditional export even after finding an adapter: an
      // absent alternative is invalid input, rather than silently omitted.
      for (final source in library(path)) {
        for (final export in source.dependencies.where(
          (d) => d.kind == 'export',
        )) {
          if (localTarget(export) case final next?) pending.add(next);
        }
      }
    }
    return forbidden;
  }

  return [
    for (final source in viewUnits)
      for (final edge in source.dependencies)
        if (exposesAdapter(edge))
          Finding(id, source.path, edge.line, edge.subject, message),
  ]..sort();
}
