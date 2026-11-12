import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_MEMORY_VIEW_PROTOCOL';
const _views = {'lib/core/screens/administration/admin_memory_page.dart'};
const _methods = {
  'config',
  'read',
  'write',
  'requireProfile',
  'request',
  'ownedMutation',
  'settingsWrite',
  'saveSettings',
  'apiWriteOwned',
  'apiGet',
  'apiPut',
  'apiPost',
  'apiDelete',
  'fromWire',
  'fromResponse',
  'tryParse',
};
const _functions = {'administrationRows', 'jsonDecode'};
const _owners = {
  'AdministrationRepository':
      'lib/core/services/administration_repository.dart',
  'ProfileAdministration': 'lib/core/services/administration_repository.dart',
  'DashboardClient': 'lib/core/services/connection_manager.dart',
  'RetainedMemoryIdentity': 'lib/core/models/retained_memory.dart',
  'RetainedMemoryGraph': 'lib/core/models/retained_memory.dart',
  'RetainedMemoryDetail': 'lib/core/models/retained_memory.dart',
  'RetainedMemorySource': 'lib/core/models/retained_memory.dart',
};

/// Forbids one property: completed memory views issuing or capturing protocol operations.
/// Syntax only selects candidates; diagnostics require resolved declaration
/// provenance. The current clean pilot has no candidates and starts no resolver.
Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) {
    dartSdkPath(root, configured: sdkPath);
  }
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    if (!{'view', 'presentation'}.contains(snapshot.roleOf(source.path))) {
      continue;
    }
    if (!_views.contains(snapshot.libraries[source.path] ?? source.path)) {
      continue;
    }
    final accesses = _ProtocolCandidates();
    source.ast.accept(accesses);
    if (accesses.offsets.isNotEmpty) {
      candidates.add(source);
    }
  }
  if (candidates.isEmpty) {
    return [];
  }

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
        '${source.path}: conditional memory-protocol provenance requires branch-specific verification.',
      );
    }
  }

  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'memory-view-protocol',
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
          '${source.path}: cannot resolve memory protocol access.',
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
          '${source.path}: unresolved memory protocol access; use a typed owner command.',
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

bool _isAccess(SimpleIdentifier node) => switch (node.parent) {
  MethodInvocation call => identical(call.methodName, node),
  PropertyAccess access => identical(access.propertyName, node),
  PrefixedIdentifier access => identical(access.identifier, node),
  ConstructorName constructor => identical(constructor.name, node),
  _ => !node.inDeclarationContext(),
};

class _ProtocolCandidates extends RecursiveAstVisitor<void> {
  final offsets = <int>{};
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if ((_methods.contains(node.name) && _isAccess(node)) ||
        (_functions.contains(node.name) && !node.inDeclarationContext())) {
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
    if ((_methods.contains(node.name) && _isAccess(node)) ||
        (_functions.contains(node.name) && !node.inDeclarationContext())) {
      final declaration = node.element?.baseElement;
      if (declaration == null) {
        unresolved = true;
      } else {
        final library = declaration.library?.uri.toString();
        final method =
            (declaration is MethodElement ||
                    declaration is GetterElement ||
                    declaration is FieldElement ||
                    declaration is ConstructorElement) &&
                _owners.containsKey(declaration.enclosingElement?.name) &&
                _owners[declaration.enclosingElement?.name] ==
                    _declaringLibrary(declaration) ||
            declaration is MethodElement &&
                declaration.enclosingElement?.name == 'int' &&
                node.name == 'tryParse' &&
                library == 'dart:core';
        final function =
            declaration is TopLevelFunctionElement &&
            (node.name == 'administrationRows' &&
                    _declaringLibrary(declaration) ==
                        'lib/core/services/administration_repository.dart' ||
                node.name == 'jsonDecode' && library == 'dart:convert');
        if (method || function) {
          findings.add(
            Finding(
              id,
              source.path,
              source.lineAt(node.offset),
              '${declaration.enclosingElement?.name ?? 'memory'}.${node.name}#${++occurrence}',
              'Send memory input through its application owner; protocol and memory graph/node wire parsing do not belong in views.',
            ),
          );
        }
      }
    }
    super.visitSimpleIdentifier(node);
  }

  String? _declaringLibrary(Element declaration) {
    final path = declaration.library?.firstFragment.source.fullName;
    if (path == null || !path.startsWith('$root/')) {
      return null;
    }
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
          throw const FormatException('Unknown view memory-protocol option.');
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
