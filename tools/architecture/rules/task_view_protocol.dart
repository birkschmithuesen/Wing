import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../lexical_bindings.dart';
import '../dart_sdk.dart';

const id = 'ARCH_TASK_VIEW_PROTOCOL';
const _methods = {
  'read',
  'write',
  'list',
  'get',
  'create',
  'update',
  'action',
  'delete',
  'runs',
  'destinations',
  'templates',
  'instantiate',
  'path',
};
const _owners = {
  'ScheduledTasksRepository':
      'lib/core/services/scheduled_tasks_repository.dart',
  'ProfileAdministration': 'lib/core/services/administration_repository.dart',
};

/// Forbids one property: task views issuing or capturing protocol operations.
/// Syntax only selects candidates; diagnostics require resolved declaration
/// provenance. The current clean pilot has no candidates and starts no resolver.
Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) dartSdkPath(root, configured: sdkPath);
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    if (!{'view', 'presentation'}.contains(snapshot.roleOf(source.path))) {
      continue;
    }
    if (snapshot
            .classifications[snapshot.libraries[source.path] ?? source.path]
            ?.feature !=
        'scheduled-tasks') {
      continue;
    }
    final accesses = _ProtocolCandidates(snapshot.libraries[source.path]!);
    source.ast.accept(accesses);
    if (accesses.offsets.isNotEmpty) candidates.add(source);
  }
  if (candidates.isEmpty) return [];

  // A single resolver environment cannot prove alternate conditional branches.
  // Fail closed for candidate libraries with local conditional dependencies;
  // do not pretend the selected branch establishes all-platform provenance.
  for (final source in candidates) {
    final library = snapshot.libraries[source.path]!;
    final closure = {library, ...snapshot.reachable(library)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (directive) => directive.configurations.isNotEmpty,
          ),
    )) {
      throw FormatException(
        '${source.path}: conditional task-protocol provenance requires branch-specific verification.',
      );
    }
  }

  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'task-view-protocol',
    enableSdkExperiments: false,
  );
  final findings = <Finding>[];
  try {
    for (final source in candidates) {
      final absolute = '$root/${source.path}';
      final result = await contexts
          .contextFor(absolute)
          .currentSession
          .getResolvedUnit(absolute);
      if (result is! ResolvedUnitResult) {
        throw FormatException(
          '${source.path}: cannot resolve task protocol access.',
        );
      }
      final accesses = _ResolvedProtocolAccess(
        source,
        root,
        snapshot,
        findings,
      );
      result.unit.accept(accesses);
      if (accesses.unresolved) {
        throw FormatException(
          '${source.path}: unresolved task protocol access; use a typed owner command.',
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

bool _isAccess(SimpleIdentifier node, String library) => switch (node.parent) {
  MethodInvocation call => identical(call.methodName, node),
  PropertyAccess access => identical(access.propertyName, node),
  PrefixedIdentifier access => identical(access.identifier, node),
  _ =>
    node.inGetterContext() &&
        !node.inDeclarationContext() &&
        !isProvenLocalRead(
          node,
          library: library,
          canonicalLibraries: _owners.values,
        ),
};

class _ProtocolCandidates extends RecursiveAstVisitor<void> {
  _ProtocolCandidates(this.library);
  final String library;
  final offsets = <int>{};
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_methods.contains(node.name) && _isAccess(node, library)) {
      offsets.add(node.offset);
    }
    super.visitSimpleIdentifier(node);
  }
}

class _ResolvedProtocolAccess extends RecursiveAstVisitor<void> {
  _ResolvedProtocolAccess(this.source, this.root, this.snapshot, this.findings);
  final Source source;
  final String root;
  final Snapshot snapshot;
  final List<Finding> findings;
  bool unresolved = false;
  var occurrence = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_methods.contains(node.name) &&
        _isAccess(node, snapshot.libraries[source.path]!)) {
      final declaration = node.element?.baseElement;
      if (declaration == null) {
        unresolved = true;
      } else if (declaration is MethodElement &&
          _owners.containsKey(declaration.enclosingElement?.name) &&
          _owners[declaration.enclosingElement?.name] ==
              _declaringLibrary(declaration)) {
        findings.add(
          Finding(
            id,
            source.path,
            source.lineAt(node.offset),
            '${declaration.enclosingElement?.name}.${node.name}#${++occurrence}',
            'Send task input through its application owner; protocol requests and their lifetime do not belong in views.',
          ),
        );
      }
    }
    super.visitSimpleIdentifier(node);
  }

  String? _declaringLibrary(MethodElement declaration) {
    final path = declaration.firstFragment.libraryFragment.source.fullName;
    if (!path.startsWith('$root/')) return null;
    return snapshot.libraries[path.substring(root.length + 1)];
  }
}

/// Strict independent CLI: no baseline or suppression is needed for this rule.
Future<void> main(List<String> arguments) async {
  try {
    var root = Directory.current.path;
    String? roles;
    String? sdkPath;
    var json = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--root':
          root = arguments[++i];
        case '--roles':
          roles = arguments[++i];
        case '--sdk':
          sdkPath = arguments[++i];
        case '--json':
          json = true;
        default:
          throw const FormatException('Unknown view task-protocol option.');
      }
    }
    root = Directory(root).resolveSymbolicLinksSync();
    final clock = Stopwatch()..start();
    final snapshot = Snapshot.load(
      root,
      roles ?? '$root/tools/architecture/roles.json',
    );
    final parseMicros = clock.elapsedMicroseconds;
    final findings = await check(snapshot, root, sdkPath: sdkPath);
    clock.stop();
    if (json) {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'files': snapshot.sources.length,
          'findings': findings.map((finding) => finding.toJson()).toList(),
          'parseMicros': parseMicros,
          'totalMicros': clock.elapsedMicroseconds,
        }),
      );
    } else {
      for (final finding in findings) {
        stdout.writeln(finding);
      }
      stdout.writeln(
        '$id: ${findings.length} findings; ${clock.elapsedMilliseconds} ms in process',
      );
    }
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
