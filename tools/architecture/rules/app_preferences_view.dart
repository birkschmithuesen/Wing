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

const id = 'ARCH_APP_PREFERENCES_VIEW';
const completedViews = {
  'lib/core/screens/app_settings_content.dart': 'AppSettingsContent',
  'lib/core/widgets/text_size_settings_card.dart': 'TextSizeSettingsCard',
  'lib/core/widgets/composer_action_settings.dart': 'ComposerActionSettings',
  'lib/main.dart': 'HomeScreenState',
};
const homeLibrary = 'lib/main.dart';
const canonicalLibrary =
    'package:shared_preferences/src/shared_preferences_legacy.dart';
const members = {
  'getInstance',
  'getKeys',
  'get',
  'getBool',
  'getInt',
  'getDouble',
  'getString',
  'getStringList',
  'containsKey',
  'setBool',
  'setInt',
  'setDouble',
  'setString',
  'setStringList',
  'remove',
  'clear',
  'reload',
  'commit',
  'setPrefix',
  'resetStatic',
  'setMockInitialValues',
};

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

Iterable<AstNode> _selected(CompilationUnit unit, String library) =>
    library == homeLibrary
    ? unit.declarations.whereType<ClassDeclaration>().where(
        (node) => node.namePart.typeName.lexeme == completedViews[homeLibrary],
      )
    : [unit];

Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  if (sdkPath != null) dartSdkPath(root, configured: sdkPath);
  for (final entry in completedViews.entries) {
    final librarySource = snapshot.sources[entry.key];
    if (librarySource == null) {
      throw const FormatException('Completed view library missing');
    }
    for (final target in librarySource.partTargets) {
      final part = snapshot.sources[target];
      if (part == null ||
          snapshot.partOwners[target]?.length != 1 ||
          snapshot.partOwners[target]?.single != entry.key ||
          (part.partOf != entry.key && !part.namedPartOf)) {
        throw const FormatException('Malformed completed view part ownership');
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
          throw const FormatException('Mismatched completed view named part');
        }
      }
    }
    if (!snapshot.sources.values.any(
      (source) =>
          snapshot.libraries[source.path] == entry.key &&
          source.ast.declarations.whereType<ClassDeclaration>().any(
            (node) => node.namePart.typeName.lexeme == entry.value,
          ),
    )) {
      throw const FormatException('Completed preferences view scope missing');
    }
    if (entry.key == homeLibrary &&
        snapshot.sources.values
                .where(
                  (source) => snapshot.libraries[source.path] == homeLibrary,
                )
                .expand((source) => _selected(source.ast, homeLibrary))
                .length !=
            1) {
      throw const FormatException('Missing/ambiguous Home preference scope');
    }
  }
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    if (!completedViews.containsKey(snapshot.libraries[source.path])) continue;
    final visitor = _Candidates(source, snapshot);
    for (final node in _selected(
      source.ast,
      snapshot.libraries[source.path]!,
    )) {
      node.accept(visitor);
    }
    if (visitor.found) candidates.add(source);
  }
  if (candidates.isEmpty) return [];
  for (final source in candidates) {
    final library = snapshot.libraries[source.path]!;
    final closure = {library, ...snapshot.reachable(library)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (node) => node.configurations.isNotEmpty,
          ),
    )) {
      throw const FormatException(
        'Conditional preferences provenance needs branch-specific proof',
      );
    }
    final owners = snapshot.partOwners[source.path];
    if (owners != null && owners.length != 1) {
      throw const FormatException('Ambiguous completed view part ownership');
    }
  }
  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'app-preferences-view',
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
            'Preferences view library cannot resolve',
          );
        }
        resolved = result;
        resolvedLibraries[library] = resolved;
      }
      final units = resolved.units
          .where((unit) => unit.path == absolute)
          .toList();
      if (units.length != 1) {
        throw const FormatException('Preferences view cannot resolve');
      }
      // Resolve the proven owner library, then select its actual part unit.
      // Asking a named part to infer its owner independently can lose imports.
      final visitor = _Resolved(source, snapshot, findings);
      for (final node in _selected(units.single.unit, library)) {
        node.accept(visitor);
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
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
        throw const FormatException('Unresolved preferences access');
      }
      if (declaration is MethodElement &&
          declaration.enclosingElement?.name == 'SharedPreferences' &&
          declaration.library.uri.toString() == canonicalLibrary) {
        findings.add(
          Finding(
            id,
            source.path,
            source.lineAt(node.offset),
            'SharedPreferences.${declaration.name}@${node.offset}',
            'Use the shared AppPreferences owner; completed views cannot issue or capture persisted-preference APIs.',
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
      '[$id INPUT] Invalid view scope, source, SDK or unresolved preferences access.',
    );
    exitCode = 2;
  }
}
