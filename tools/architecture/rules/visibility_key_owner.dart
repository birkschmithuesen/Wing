import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../dart_sdk.dart';
import '../lexical_bindings.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_VISIBILITY_KEY_OWNER';
const owner = 'lib/core/services/app_preferences.dart';
const definition = 'lib/core/models/session_visibility.dart';
const canonicalLibrary = 'package:wing/core/models/session_visibility.dart';
const members = {'preferenceKey'};

bool _access(SimpleIdentifier node) =>
    !node.inDeclarationContext() &&
    node.parent is! Combinator &&
    node.parent is! Label &&
    (node.inGetterContext() ||
        node.parent is MethodInvocation &&
            identical((node.parent as MethodInvocation).methodName, node));

bool _bare(SimpleIdentifier node) => switch (node.parent) {
  MethodInvocation call => call.target == null && !call.isCascaded,
  PropertyAccess _ || PrefixedIdentifier _ => false,
  _ => true,
};

bool _candidate(SimpleIdentifier node, Source source, Snapshot snapshot) =>
    members.contains(node.name) &&
    _access(node) &&
    !(_bare(node) &&
        isProvenLocalRead(
          node,
          library: snapshot.libraries[source.path] ?? source.path,
          canonicalLibraries: const [canonicalLibrary],
        ));

Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) dartSdkPath(root, configured: sdkPath);
  for (final path in const [owner, definition]) {
    _validateLibrary(snapshot, path);
  }
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    if (snapshot.libraries[source.path] == owner) continue;
    final visitor = _Candidates(source, snapshot);
    source.ast.accept(visitor);
    if (visitor.found) candidates.add(source);
  }
  if (candidates.isEmpty) return [];
  for (final source in candidates) {
    final library = snapshot.libraries[source.path]!;
    _validateLibrary(snapshot, library);
    final closure = {library, ...snapshot.reachable(library)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (node) => node.configurations.isNotEmpty,
          ),
    )) {
      throw const FormatException(
        'Conditional visibility provenance needs branch-specific proof',
      );
    }
    final owners = snapshot.partOwners[source.path];
    if (owners != null && owners.length != 1) {
      throw const FormatException('Ambiguous visibility caller part ownership');
    }
  }
  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'visibility-key-owner',
    enableSdkExperiments: false,
  );
  final findings = <Finding>[];
  final resolvedLibraries = <String, ResolvedLibraryResult>{};
  try {
    for (final source in candidates) {
      final absolute = '$root/${source.path}';
      final library = snapshot.libraries[source.path]!;
      final ownerPath = '$root/$library';
      var resolved = resolvedLibraries[library];
      if (resolved == null) {
        final result = await contexts
            .contextFor(ownerPath)
            .currentSession
            .getResolvedLibrary(ownerPath);
        if (result is! ResolvedLibraryResult) {
          throw const FormatException(
            'Visibility caller library cannot resolve',
          );
        }
        resolved = result;
        resolvedLibraries[library] = resolved;
      }
      final units = resolved.units
          .where((unit) => unit.path == absolute)
          .toList();
      if (units.length != 1) {
        throw const FormatException('Visibility caller cannot resolve');
      }
      // Resolve the proven owner library, then select its actual part unit.
      // Asking a named part to infer its owner independently can lose imports.
      units.single.unit.accept(_Resolved(source, snapshot, findings));
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

void _validateLibrary(Snapshot snapshot, String path) {
  final librarySource = snapshot.sources[path];
  if (librarySource == null) {
    throw const FormatException(
      'Canonical visibility ownership library missing',
    );
  }
  for (final target in librarySource.partTargets) {
    final part = snapshot.sources[target];
    if (part == null ||
        snapshot.partOwners[target]?.length != 1 ||
        snapshot.partOwners[target]?.single != path ||
        (part.partOf != path && !part.namedPartOf)) {
      throw const FormatException('Malformed visibility caller part ownership');
    }
    if (part.namedPartOf) {
      final ownerNames = librarySource.ast.directives
          .whereType<LibraryDirective>()
          .map((node) => node.name?.toSource())
          .toList();
      final partNames = part.ast.directives
          .whereType<PartOfDirective>()
          .map((node) => node.libraryName?.toSource())
          .toList();
      if (ownerNames.length != 1 ||
          partNames.length != 1 ||
          ownerNames.single == null ||
          ownerNames.single != partNames.single) {
        throw const FormatException('Mismatched visibility caller named part');
      }
    }
  }
  if (snapshot.libraries[path] != path) {
    throw const FormatException('Canonical visibility owner is not a library');
  }
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.source, this.snapshot);
  final Source source;
  final Snapshot snapshot;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_candidate(node, source, snapshot)) found = true;
    super.visitSimpleIdentifier(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.source, this.snapshot, this.findings);
  final Source source;
  final Snapshot snapshot;
  final List<Finding> findings;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_candidate(node, source, snapshot)) {
      final declaration = node.element?.baseElement;
      if (declaration == null) {
        throw const FormatException('Unresolved visibility key access');
      }
      if (declaration is MethodElement &&
          declaration.enclosingElement?.name == 'SessionVisibility' &&
          declaration.library.uri.toString() == canonicalLibrary) {
        findings.add(
          Finding(
            id,
            source.path,
            source.lineAt(node.offset),
            'SessionVisibility.${declaration.name}@${node.offset}',
            'Derive persisted visibility keys only in AppPreferences. Other callers borrow its typed per-connection observation and commands.',
          ),
        );
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = Directory.current.path;
    String? rolePath, sdkPath;
    var json = false;
    final seen = <String>{};
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (!seen.add(argument)) throw const FormatException('Duplicate option');
      if (argument == '--json') {
        json = true;
        continue;
      }
      if (!{'--root', '--roles', '--sdk'}.contains(argument) ||
          index + 1 == args.length) {
        throw const FormatException('Invalid option');
      }
      final value = args[++index];
      switch (argument) {
        case '--root':
          root = value;
        case '--roles':
          rolePath = value;
        case '--sdk':
          sdkPath = value;
      }
    }
    root = Directory(root).resolveSymbolicLinksSync();
    final snapshot = Snapshot.load(
      root,
      rolePath ?? '$root/tools/architecture/roles.json',
    );
    final findings = await check(snapshot, root, sdkPath: sdkPath);
    if (json) {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'files': snapshot.sources.length,
          'findings': findings.map((item) => item.toJson()).toList(),
        }),
      );
    } else {
      for (final finding in findings) {
        stdout.writeln(finding);
      }
      stdout.writeln('$id: ${findings.length} findings');
    }
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '[$id INPUT] Invalid ownership scope, source, SDK or unresolved visibility key access.',
    );
    exitCode = 2;
  }
}
