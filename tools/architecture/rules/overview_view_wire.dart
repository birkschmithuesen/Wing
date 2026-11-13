import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_OVERVIEW_VIEW_WIRE';
const _view = 'lib/core/screens/administration/admin_profile_overview.dart';
const _members = {
  'ProfileAdministration': {'read', 'write', 'saveSettings', 'config'},
  'ProfileGateway': {'get', 'put', 'rpc', 'discover'},
  'AdministrationOverview': {'observations', 'connectorChecks'},
  'AdministrationObservation': {'data'},
  'ScheduledTasksController': {'tasks'},
  'ConfiguredModel': {'fromInfo'},
  'ProviderAccess': {'validateIdentity'},
};
const _owners = {
  'ProfileAdministration': 'lib/core/services/administration_repository.dart',
  'ProfileGateway': 'lib/core/services/profile_gateway.dart',
  'AdministrationOverview': 'lib/core/services/administration_overview.dart',
  'AdministrationObservation': 'lib/core/services/administration_overview.dart',
  'ScheduledTasksController':
      'lib/core/services/scheduled_tasks_controller.dart',
  'ConfiguredModel': 'lib/core/models/model_choice.dart',
  'ProviderAccess': 'lib/core/models/provider_access.dart',
};
const _functions = {
  'administrationRows': 'lib/core/services/administration_repository.dart',
  'setting': 'lib/core/models/settings_edit.dart',
};
final _names = {
  ..._members.values.expand((members) => members),
  ..._functions.keys,
};

/// Forbids one property: the completed overview view consuming wire/cache records.
/// Syntax only selects candidates; diagnostics require resolved declaration
/// provenance. The current clean overview has no candidates and starts no resolver.
Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) dartSdkPath(root, configured: sdkPath);
  final candidates = <Source>[];
  final constructors = _constructorNames(snapshot);
  for (final source in snapshot.sources.values) {
    if (snapshot.libraries[source.path] != _view) continue;
    if (!{'view', 'presentation'}.contains(snapshot.roleOf(source.path))) {
      throw FormatException(
        '${source.path}: completed overview must have a view role.',
      );
    }
    final accesses = _ProtocolCandidates(constructors);
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
        '${source.path}: conditional overview-wire provenance requires branch-specific verification.',
      );
    }
  }

  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'overview-view-wire',
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
          '${source.path}: cannot resolve overview wire access.',
        );
      }
      final accesses = _ResolvedProtocolAccess(
        source,
        root,
        snapshot,
        findings,
        constructors,
      );
      result.unit.accept(accesses);
      if (accesses.unresolved) {
        throw FormatException(
          '${source.path}: unresolved overview wire access; use a typed owner command.',
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

bool _isCandidate(SimpleIdentifier node, Set<String> constructors) {
  if (node.name == 'new') {
    final parent = node.parent;
    if (parent is PrefixedIdentifier && identical(parent.identifier, node)) {
      return constructors.contains(parent.prefix.name);
    }
    if (parent is PropertyAccess && identical(parent.propertyName, node)) {
      final target = parent.target;
      return target is PrefixedIdentifier &&
          constructors.contains(target.identifier.name);
    }
  }
  if ((!_names.contains(node.name) && !constructors.contains(node.name)) ||
      node.inDeclarationContext()) {
    return false;
  }
  if (_functions.containsKey(node.name)) {
    // Include function tear-offs before aliases can conceal the eventual call.
    return node.parent is! Combinator;
  }
  return switch (node.parent) {
    MethodInvocation call => identical(call.methodName, node),
    PropertyAccess access => identical(access.propertyName, node),
    PrefixedIdentifier access => identical(access.identifier, node),
    _ => node.inGetterContext(),
  };
}

// A conservative syntax prefilter follows typedef spelling chains. It never
// proves provenance; resolved constructor identity below decides diagnostics.
Set<String> _constructorNames(Snapshot snapshot) {
  final names = <String>{'ProviderAccess'};
  var changed = true;
  while (changed) {
    changed = false;
    for (final source in snapshot.sources.values) {
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        final type = alias.type;
        if (type is NamedType && names.contains(type.name.lexeme)) {
          changed = names.add(alias.name.lexeme) || changed;
        }
      }
    }
  }
  return names;
}

class _ProtocolCandidates extends RecursiveAstVisitor<void> {
  _ProtocolCandidates(this.constructors);
  final Set<String> constructors;
  final offsets = <int>{};
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_isCandidate(node, constructors)) offsets.add(node.offset);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    if (constructors.contains(node.type.name.lexeme)) offsets.add(node.offset);
    super.visitConstructorName(node);
  }
}

class _ResolvedProtocolAccess extends RecursiveAstVisitor<void> {
  _ResolvedProtocolAccess(
    this.source,
    this.root,
    this.snapshot,
    this.findings,
    this.constructors,
  );
  final Source source;
  final String root;
  final Snapshot snapshot;
  final List<Finding> findings;
  final Set<String> constructors;
  bool unresolved = false;
  var occurrence = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_isCandidate(node, constructors)) {
      _check(node.element, node.name, node.offset);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    // Resolved constructor identity, including typedef/prefix aliases. All
    // constructor calls are inspected after a candidate activated resolution.
    _check(node.element, 'new', node.offset);
    super.visitConstructorName(node);
  }

  void _check(Element? element, String name, int offset) {
    final declaration = element?.baseElement;
    if (declaration == null) {
      unresolved = true;
      return;
    }
    final owner = declaration.enclosingElement?.name;
    final library = _declaringLibrary(declaration);
    final forbidden = declaration is TopLevelFunctionElement
        ? _functions[name] == library
        : declaration is ConstructorElement
        ? owner == 'ProviderAccess' && _owners[owner] == library
        : (declaration is MethodElement ||
                  declaration is PropertyAccessorElement) &&
              _members[owner]?.contains(name) == true &&
              _owners[owner] == library;
    if (forbidden) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(offset),
          '${owner ?? 'function'}.$name#${++occurrence}',
          'Render the typed overview summary; wire parsing and mutable observation/task records belong in its route owner.',
        ),
      );
    }
  }

  String? _declaringLibrary(Element declaration) {
    final path = declaration.firstFragment.libraryFragment?.source.fullName;
    if (path == null || !path.startsWith('$root/')) return null;
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
          throw const FormatException('Unknown view overview-wire option.');
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
