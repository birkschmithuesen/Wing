import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/analysis/results.dart';

const roles = {
  'domain',
  'data',
  'application',
  'presentation',
  'view',
  'composition',
  'platform',
  'utility',
};
const businessRoles = {'data', 'application'};
const renderingUris = {
  'package:flutter/material.dart',
  'package:flutter/cupertino.dart',
  'package:flutter/widgets.dart',
};

/// Own parsed inputs for one linter batch; findings are always recomputed.
Future<T> withSharedSourceParses<T>(Future<T> Function() action) =>
    runZoned(action, zoneValues: {_sourceParses: _SourceParses()});

final _sourceParses = Object();

class _SourceParses {
  String? root;
  final current = <String, (String, ParseStringResult)>{};

  void select(String selectedRoot, Set<String> paths) {
    if (root != selectedRoot) {
      current.clear();
      root = selectedRoot;
    }
    current.removeWhere((path, _) => !paths.contains(path));
  }

  ParseStringResult parse(String path, String content) {
    final previous = current[path];
    if (previous != null && previous.$1 == content) return previous.$2;
    final parsed = parseString(
      content: content,
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isEmpty) {
      current[path] = (content, parsed);
    } else {
      current.remove(path);
    }
    return parsed;
  }
}

class Finding implements Comparable<Finding> {
  const Finding(this.id, this.file, this.line, this.subject, this.message);
  final String id;
  final String file;
  final int line;
  final String subject;
  final String message;
  String get key => jsonEncode([id, file, subject]);
  Map<String, Object> toJson() => {
    'id': id,
    'file': file,
    'line': line,
    'subject': subject,
    'message': message,
    'key': key,
  };
  @override
  int compareTo(Finding other) => key.compareTo(other.key);
  @override
  String toString() => '$file:$line [$id] $message ($subject)';
}

class Role {
  const Role(this.role, this.feature, this.library);
  final String role;
  final String feature;
  final String library;
}

class Dependency {
  const Dependency({
    required this.uri,
    required this.line,
    required this.kind,
    required this.ordinal,
    this.target,
    this.pureWidgetHelpers = false,
  });
  final String uri;
  final int line;
  final String kind;
  final int ordinal;
  final String? target;
  final bool pureWidgetHelpers;
  String get subject => '$kind:$uri#$ordinal';
}

class Source {
  Source(
    this.path,
    this.ast,
    this.lineAt,
    this.dependencies,
    this.partTargets,
    this.partOf,
    this.namedPartOf,
  );
  final String path;
  final CompilationUnit ast;
  final int Function(int offset) lineAt;
  final List<Dependency> dependencies;
  final List<String> partTargets;
  final String? partOf;
  final bool namedPartOf;
}

/// One read-only parse snapshot is shared by independent rules in the runner.
/// Actual part directives determine library identity; the manifest cannot hide
/// arbitrary files inside a declared library.
class Snapshot {
  Snapshot._(
    this.root,
    this.sources,
    this.classifications,
    this.libraries,
    this.graph,
    this.partOwners,
  );
  final String root;
  final Map<String, Source> sources;
  final Map<String, Role> classifications;
  final Map<String, String> libraries;
  final Map<String, Set<String>> graph;
  final Map<String, List<String>> partOwners;

  String? roleOf(String path) => classifications[libraries[path] ?? path]?.role;

  Set<String> reachable(String library) {
    final seen = <String>{};
    final pending = [...?graph[library]];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (seen.add(next)) pending.addAll(graph[next] ?? const <String>{});
    }
    return seen;
  }

  static Snapshot load(String root, String rolePath) {
    root = Directory(root).resolveSymbolicLinksSync();
    final manifest = jsonDecode(File(rolePath).readAsStringSync());
    if (manifest is! Map ||
        manifest['schema'] != 1 ||
        manifest['files'] is! Map) {
      throw const FormatException('roles.json requires schema 1 and files map');
    }
    final classifications = <String, Role>{};
    for (final entry in (manifest['files'] as Map).entries) {
      final path = entry.key;
      final value = entry.value;
      if (path is! String ||
          !path.startsWith('lib/') ||
          !path.endsWith('.dart') ||
          value is! Map ||
          value['role'] is! String ||
          value['feature'] is! String ||
          value['library'] is! String ||
          !roles.contains(value['role']) ||
          (value['feature'] as String).trim().isEmpty) {
        throw const FormatException('Invalid authored-library role entry');
      }
      classifications[path] = Role(
        value['role'] as String,
        value['feature'] as String,
        value['library'] as String,
      );
    }
    final paths =
        Directory('$root/lib')
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .map(
              (file) =>
                  file.path.substring(root.length + 1).replaceAll('\\', '/'),
            )
            .toList()
          ..sort();
    final sources = <String, Source>{};
    final partOwners = <String, List<String>>{};
    final shared = Zone.current[_sourceParses] as _SourceParses?;
    shared?.select(root, {for (final path in paths) '$root/$path'});
    for (final path in paths) {
      final absolute = '$root/$path';
      final content = File(absolute).readAsStringSync();
      final parsed =
          shared?.parse(absolute, content) ??
          parseString(
            content: content,
            path: absolute,
            throwIfDiagnostics: false,
          );
      if (parsed.errors.isNotEmpty) {
        throw FormatException('Cannot parse $path; run flutter analyze first');
      }
      int lineAt(int offset) => parsed.lineInfo.getLocation(offset).lineNumber;
      final dependencies = <Dependency>[];
      final parts = <String>[];
      String? partOf;
      var namedPartOf = false;
      final occurrences = <String, int>{};
      for (final directive in parsed.unit.directives) {
        if (directive is PartDirective) {
          final target = _local(root, path, directive.uri.stringValue);
          if (target != null) {
            parts.add(target);
            partOwners.putIfAbsent(target, () => []).add(path);
          }
        } else if (directive is PartOfDirective) {
          partOf = _local(root, path, directive.uri?.stringValue);
          namedPartOf = directive.libraryName != null;
        } else if (directive is NamespaceDirective) {
          final kind = directive is ImportDirective ? 'import' : 'export';
          for (final literal in [
            directive.uri,
            ...directive.configurations.map(
              (configuration) => configuration.uri,
            ),
          ]) {
            final uri = literal.stringValue;
            if (uri == null) continue;
            final occurrence = occurrences.update(
              '$kind:$uri',
              (n) => n + 1,
              ifAbsent: () => 1,
            );
            dependencies.add(
              Dependency(
                uri: uri,
                line: lineAt(literal.offset),
                kind: kind,
                ordinal: occurrence,
                target: _local(root, path, uri),
                pureWidgetHelpers:
                    directive.combinators.length == 1 &&
                    directive.combinators.single is ShowCombinator &&
                    (directive.combinators.single as ShowCombinator).shownNames
                        .every((name) => name.name == 'StringCharacters'),
              ),
            );
          }
        }
      }
      sources[path] = Source(
        path,
        parsed.unit,
        lineAt,
        List.unmodifiable(dependencies),
        List.unmodifiable(parts),
        partOf,
        namedPartOf,
      );
    }
    final libraries = <String, String>{};
    for (final path in paths) {
      final owners = partOwners[path] ?? const <String>[];
      libraries[path] = owners.length == 1 ? owners.single : path;
    }
    final graph = <String, Set<String>>{};
    for (final source in sources.values) {
      final owner = libraries[source.path]!;
      final edges = graph.putIfAbsent(owner, () => {});
      for (final dependency in source.dependencies) {
        final target = libraries[dependency.target];
        if (target != null) edges.add(target);
      }
    }
    return Snapshot._(
      root,
      Map.unmodifiable(sources),
      Map.unmodifiable(classifications),
      Map.unmodifiable(libraries),
      Map.unmodifiable(
        graph.map(
          (key, value) => MapEntry(key, Set<String>.unmodifiable(value)),
        ),
      ),
      Map.unmodifiable(
        partOwners.map(
          (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
        ),
      ),
    );
  }
}

String? _local(String root, String path, String? value) {
  if (value == null) return null;
  if (value.startsWith('package:wing/')) return 'lib/${value.substring(13)}';
  final uri = Uri.tryParse(value);
  if (uri == null || uri.hasScheme) return null;
  final absolute = Uri.file('$root/$path').resolveUri(uri).toFilePath();
  return absolute.startsWith('$root/lib/')
      ? absolute.substring(root.length + 1).replaceAll('\\', '/')
      : null;
}

typedef Rule = FutureOr<List<Finding>> Function(Snapshot snapshot);

/// Transitive graph reachability prevents a barrel/utility from hiding a layer
/// dependency. Diagnostics point at the first dependency edge in the owner.
List<Finding> forbiddenDependencies(
  Snapshot snapshot, {
  required String id,
  required Set<String> sourceRoles,
  required Set<String> forbiddenRoles,
  required bool Function(String uri) forbiddenExternal,
  bool Function(Dependency dependency)? allowedExternal,
  required String remedy,
}) {
  final result = <Finding>[];
  final reached = <String, Set<String>>{};
  for (final source in snapshot.sources.values) {
    if (!sourceRoles.contains(snapshot.roleOf(source.path))) continue;
    for (final dependency in source.dependencies) {
      final target = snapshot.libraries[dependency.target];
      var forbidden =
          forbiddenExternal(dependency.uri) &&
          !(allowedExternal?.call(dependency) ?? false);
      if (target != null) {
        final closure = reached.putIfAbsent(
          target,
          () => {target, ...snapshot.reachable(target)},
        );
        forbidden |= closure.any(
          (path) =>
              forbiddenRoles.contains(snapshot.roleOf(path)) ||
              snapshot.sources.values
                  .where((unit) => snapshot.libraries[unit.path] == path)
                  .any(
                    (unit) => unit.dependencies.any(
                      (edge) =>
                          forbiddenExternal(edge.uri) &&
                          !(allowedExternal?.call(edge) ?? false),
                    ),
                  ),
        );
      }
      if (forbidden) {
        result.add(
          Finding(id, source.path, dependency.line, dependency.subject, remedy),
        );
      }
    }
  }
  return result;
}
