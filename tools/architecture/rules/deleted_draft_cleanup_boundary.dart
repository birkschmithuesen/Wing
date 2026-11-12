import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_DELETED_DRAFT_CLEANUP_BOUNDARY';
const _controller = 'lib/core/services/profile_workspace_controller.dart';
const _store = 'lib/core/services/deleted_draft_cleanup_store.dart';
const _attachments = 'lib/core/services/attachment_draft_service.dart';
const _ioNames = {'File', 'Directory', 'Link', 'FileSystemEntity'};
const _operations = {'delete', 'deleteSync', 'removeAll', 'removeCachedFile'};

bool _inScope(AstNode node, String library) {
  if (library == _store) {
    return node
            .thisOrAncestorOfType<ClassDeclaration>()
            ?.namePart
            .typeName
            .lexeme ==
        'DeletedDraftCleanupStore';
  }
  return library == _controller &&
      node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme ==
          '_cleanupDeletedDraft';
}

/// One property: durable cleanup does not directly reference standard filesystem
/// types/deletion APIs or the attachment owner's general removal APIs. Syntax selects potential
/// uses; actual API identity is resolved only for candidates. This does not prove
/// ACK ordering, persistence durability, or atomic filesystem isolation.
Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) dartSdkPath(root, configured: sdkPath);
  final aliases = <String>{..._ioNames};
  bool grew;
  do {
    grew = false;
    for (final source in snapshot.sources.values) {
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        final type = alias.type;
        if (type is NamedType && aliases.contains(type.name.lexeme)) {
          grew = aliases.add(alias.name.lexeme) || grew;
        }
      }
    }
  } while (grew);
  final names = {...aliases, ..._operations};
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    final library = snapshot.libraries[source.path]!;
    if (!{_controller, _store}.contains(library)) continue;
    final visitor = _Candidates(library, names);
    source.ast.accept(visitor);
    if (visitor.found) candidates.add(source);
  }
  if (candidates.isEmpty) return [];
  for (final source in candidates) {
    final owner = snapshot.libraries[source.path]!;
    final closure = {owner, ...snapshot.reachable(owner)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (d) => d.configurations.isNotEmpty,
          ),
    )) {
      throw FormatException(
        '${source.path}: conditional cleanup provenance requires branch verification.',
      );
    }
  }
  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'deleted-draft-cleanup-boundary',
    enableSdkExperiments: false,
  );
  final findings = <Finding>[];
  try {
    for (final source in candidates) {
      final path = '$root/${source.path}';
      final result = await contexts
          .contextFor(path)
          .currentSession
          .getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        throw FormatException('${source.path}: unresolved cleanup unit.');
      }
      final visitor = _Resolved(source, snapshot, root, names, findings);
      result.unit.accept(visitor);
      if (visitor.unresolved) {
        throw FormatException(
          '${source.path}: cleanup API identity is unresolved.',
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.library, this.names);
  final String library;
  final Set<String> names;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_inScope(node, library) &&
        names.contains(node.name) &&
        !node.inDeclarationContext()) {
      found = true;
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (_inScope(node, library) && names.contains(node.name.lexeme)) {
      found = true;
    }
    super.visitNamedType(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.source, this.snapshot, this.root, this.names, this.findings);
  final Source source;
  final Snapshot snapshot;
  final String root;
  final Set<String> names;
  final List<Finding> findings;
  final offsets = <int>{};
  bool unresolved = false;
  var occurrence = 0;

  void inspect(AstNode node, String name, Element? element) {
    if (!_inScope(node, snapshot.libraries[source.path]!) ||
        !names.contains(name) ||
        !offsets.add(node.offset)) {
      return;
    }
    var declaration = element?.baseElement;
    if (declaration is TypeAliasElement &&
        declaration.aliasedType is InterfaceType) {
      declaration = (declaration.aliasedType as InterfaceType).element;
    }
    if (declaration == null) {
      unresolved = true;
      return;
    }
    final fragment = declaration.firstFragment.libraryFragment;
    final uri = declaration.library?.uri.toString();
    final path = fragment?.source.fullName;
    final library = path != null && path.startsWith('$root/')
        ? snapshot.libraries[path.substring(root.length + 1)]
        : null;
    final forbiddenIo = uri == 'dart:io';
    final forbiddenRemoval =
        library == _attachments &&
        declaration.enclosingElement?.name == 'AttachmentDraftService' &&
        {'removeAll', 'removeCachedFile'}.contains(name);
    if (forbiddenIo || forbiddenRemoval) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          '$name#${++occurrence}',
          'Use validateDeletedDraftCleanup and removeDeletedDraftCleanup; persisted paths do not authorize general filesystem removal.',
        ),
      );
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext()) inspect(node, node.name, node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    inspect(node, node.name.lexeme, node.element);
    super.visitNamedType(node);
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
          throw const FormatException('Unknown deleted-draft cleanup option.');
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
