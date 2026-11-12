import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_VIEW_DRAFT_WRITE';
const _owner = 'lib/core/services/profile_workspace_controller.dart';

/// Forbids one property: views writing the application-owned ProfileChat.draft.
/// Syntax only selects candidates; diagnostics require resolved declaration
/// provenance. Clean views never start a semantic analysis context.
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
    final writes = _DraftCandidates();
    source.ast.accept(writes);
    if (writes.offsets.isNotEmpty) candidates.add(source);
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
        '${source.path}: conditional draft-write provenance requires branch-specific verification.',
      );
    }
  }

  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'view-draft-write',
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
        throw FormatException('${source.path}: cannot resolve draft writes.');
      }
      final writes = _ResolvedDraftWrites(source, root, snapshot, findings);
      result.unit.accept(writes);
      if (writes.unresolved) {
        throw FormatException(
          '${source.path}: unresolved draft write; use a typed owner command.',
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _DraftCandidates extends RecursiveAstVisitor<void> {
  final offsets = <int>{};
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'draft' && node.inSetterContext()) {
      offsets.add(node.offset);
    }
    super.visitSimpleIdentifier(node);
  }
}

class _ResolvedDraftWrites extends RecursiveAstVisitor<void> {
  _ResolvedDraftWrites(this.source, this.root, this.snapshot, this.findings);
  final Source source;
  final String root;
  final Snapshot snapshot;
  final List<Finding> findings;
  bool unresolved = false;
  var occurrence = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'draft' && node.inSetterContext()) {
      Element? element = node.element;
      AstNode target = node;
      while (target.parent is PropertyAccess ||
          target.parent is PrefixedIdentifier) {
        target = target.parent!;
      }
      if (target.parent case CompoundAssignmentExpression assignment) {
        element = assignment.writeElement ?? element;
      }
      final declaration = element?.baseElement;
      if (declaration == null) {
        unresolved = true;
      } else if (declaration is PropertyAccessorElement &&
          declaration.enclosingElement.name == 'ProfileChat' &&
          _declaringLibrary(declaration) == _owner) {
        findings.add(
          Finding(
            id,
            source.path,
            source.lineAt(node.offset),
            'ProfileChat.draft#${++occurrence}',
            'Send draft changes through the application owner command; keep persistence and revision ordering out of views.',
          ),
        );
      }
    }
    super.visitSimpleIdentifier(node);
  }

  String? _declaringLibrary(PropertyAccessorElement declaration) {
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
          throw const FormatException('Unknown view draft-write option.');
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
