import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_APP_PREFERENCES_CONSTRUCTION';
const definition = 'lib/core/services/app_preferences.dart';
const bootstrap = 'lib/core/services/application_startup.dart';
const bootstrapFunction = 'createApplicationDependencies';
const _unsupportedScope =
    'Authored imports or production-library parts outside the parsed lib scope require explicit provenance.';

/// Placement of statically resolved owner construction, not a runtime count of
/// instances or proof that arbitrary supplied factory callbacks preserve identity.
Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  final sdk = dartSdkPath(root, configured: sdkPath);
  _validateAuthoredScope(snapshot, root);
  _validateLibrary(snapshot, definition);
  _validateLibrary(snapshot, bootstrap);
  final ownerUnits = snapshot.sources.values.where(
    (source) => snapshot.libraries[source.path] == definition,
  );
  if (ownerUnits
          .expand((source) => source.ast.declarations)
          .whereType<ClassDeclaration>()
          .where((node) => node.namePart.typeName.lexeme == 'AppPreferences')
          .length !=
      1) {
    throw const FormatException('Canonical AppPreferences declaration missing');
  }
  final bootstrapFunctions = snapshot.sources.values
      .where((source) => snapshot.libraries[source.path] == bootstrap)
      .expand((source) => source.ast.declarations)
      .whereType<FunctionDeclaration>()
      .where(
        (node) =>
            node.name.lexeme == bootstrapFunction &&
            !node.isGetter &&
            !node.isSetter,
      );
  if (bootstrapFunctions.length != 1) {
    throw const FormatException(
      'Actual application bootstrap missing or ambiguous',
    );
  }
  final names = <String>{'AppPreferences'};
  var changed = true;
  while (changed) {
    changed = false;
    for (final source in snapshot.sources.values) {
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        if (alias.type case NamedType type
            when names.contains(type.name.lexeme)) {
          changed = names.add(alias.name.lexeme) || changed;
        }
      }
    }
  }
  final candidates = <Source>[];
  for (final source in snapshot.sources.values) {
    final visitor = _Candidates(
      names,
      bootstrapLibrary: snapshot.libraries[source.path] == bootstrap,
    );
    source.ast.accept(visitor);
    if (!visitor.found) continue;
    final library = snapshot.libraries[source.path];
    if (library == null) throw const FormatException('Unknown library scope');
    _validateLibrary(snapshot, library);
    final closure = {library, ...snapshot.reachable(library)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (directive) => directive.configurations.isNotEmpty,
          ),
    )) {
      throw const FormatException(
        'Conditional construction requires branch proof',
      );
    }
    if (visitor.requiresResolution) candidates.add(source);
  }
  if (candidates.isEmpty) return [];
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: [root],
    cacheNamespace: 'app-preferences-construction',
  );
  final findings = <Finding>[];
  final libraries = <String, ResolvedLibraryResult>{};
  try {
    for (final source in candidates) {
      final library = snapshot.libraries[source.path]!;
      var resolved = libraries[library];
      if (resolved == null) {
        final result = await contexts
            .contextFor('$root/$library')
            .currentSession
            .getResolvedLibrary('$root/$library');
        if (result is! ResolvedLibraryResult) {
          throw const FormatException('Cannot resolve construction library');
        }
        resolved = result;
        libraries[library] = resolved;
      }
      final units = resolved.units
          .where((unit) => unit.path == '$root/${source.path}')
          .toList();
      if (units.length != 1 ||
          units.single.diagnostics.any(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          )) {
        throw const FormatException('Unresolved construction input');
      }
      units.single.unit.accept(_Resolved(source, snapshot, root, findings));
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

// The shared parsed snapshot contains lib only. Never silently drop authored
// namespace/part files that can introduce a constructor alias or a library unit.
void _validateAuthoredScope(Snapshot snapshot, String root) {
  final packageRoots = <String, Uri>{};
  final config = File('$root/.dart_tool/package_config.json');
  if (config.existsSync()) {
    final data = jsonDecode(config.readAsStringSync()) as Map;
    for (final package in (data['packages'] as List).cast<Map>()) {
      final location = config.uri.resolve(package['rootUri'] as String);
      final directory = location.replace(
        path: location.path.endsWith('/') ? location.path : '${location.path}/',
      );
      final source = directory.resolve(package['packageUri'] as String? ?? '');
      packageRoots[package['name'] as String] = source.replace(
        path: source.path.endsWith('/') ? source.path : '${source.path}/',
      );
    }
  }
  String? authoredTarget(String source, String? value) {
    if (value == null) throw const FormatException('Unresolved source URI');
    final uri = Uri.parse(value);
    Uri target;
    if (uri.scheme == 'dart') return null;
    if (uri.scheme == 'package') {
      final slash = uri.path.indexOf('/');
      if (slash < 0) throw const FormatException('Invalid package URI');
      final package = packageRoots[uri.path.substring(0, slash)];
      if (package == null) throw const FormatException('Unknown package URI');
      target = package.resolve(uri.path.substring(slash + 1));
    } else {
      target = File('$root/$source').uri.resolveUri(uri);
    }
    if (target.scheme != 'file') {
      throw const FormatException('Unsupported namespace URI');
    }
    final path = File.fromUri(target).absolute.path;
    return path.startsWith('$root/') ? path.substring(root.length + 1) : null;
  }

  for (final source in snapshot.sources.values) {
    for (final directive in source.ast.directives) {
      if (directive is PartOfDirective) {
        final owners = snapshot.partOwners[source.path];
        if (owners == null || owners.length != 1) {
          throw const FormatException('Unowned or ambiguous production part');
        }
        _validateLibrary(snapshot, owners.single);
      } else if (directive is PartDirective) {
        final target = authoredTarget(source.path, directive.uri.stringValue);
        if (target == null || !snapshot.sources.containsKey(target)) {
          throw const FormatException(_unsupportedScope);
        }
        final owners = snapshot.partOwners[target];
        if (owners == null ||
            owners.length != 1 ||
            owners.single != source.path) {
          throw const FormatException(_unsupportedScope);
        }
        _validateLibrary(snapshot, source.path);
      } else if (directive is NamespaceDirective) {
        for (final uri in [
          directive.uri,
          ...directive.configurations.map((node) => node.uri),
        ]) {
          final target = authoredTarget(source.path, uri.stringValue);
          if (target != null && !snapshot.sources.containsKey(target)) {
            throw const FormatException(_unsupportedScope);
          }
        }
      }
    }
  }
}

void _validateLibrary(Snapshot snapshot, String library) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.whereType<PartOfDirective>().isNotEmpty) {
    throw const FormatException('Canonical containing library missing');
  }
  for (final target in source.partTargets) {
    final part = snapshot.sources[target];
    if (part == null ||
        snapshot.partOwners[target]?.length != 1 ||
        snapshot.partOwners[target]?.single != library ||
        (part.partOf != library && !part.namedPartOf)) {
      throw const FormatException('Malformed construction part ownership');
    }
    if (part.namedPartOf) {
      final owners = source.ast.directives
          .whereType<LibraryDirective>()
          .map((node) => node.name?.toSource())
          .toList();
      final names = part.ast.directives
          .whereType<PartOfDirective>()
          .map((node) => node.libraryName?.toSource())
          .toList();
      if (owners.length != 1 ||
          names.length != 1 ||
          owners.single == null ||
          owners.single != names.single) {
        throw const FormatException('Mismatched named construction part');
      }
    }
  }
  if (snapshot.partOwners[library]?.isNotEmpty == true) {
    throw const FormatException('Containing library is itself a part');
  }
}

// Every canonical constructor at this syntactic placement is permitted, so
// semantic identity cannot change its placement verdict. SDK analysis remains
// responsible for general semantic validity inside an otherwise permitted body.
bool _withinApplicationBootstrap(AstNode node) {
  for (AstNode? cursor = node; cursor != null; cursor = cursor.parent) {
    if (cursor is MethodDeclaration) return false;
    if (cursor is FunctionExpression) {
      final declaration = cursor.parent;
      return declaration is FunctionDeclaration &&
          declaration.parent is CompilationUnit &&
          declaration.name.lexeme == bootstrapFunction &&
          !declaration.isGetter &&
          !declaration.isSetter &&
          cursor.body.offset <= node.offset &&
          node.end <= cursor.body.end;
    }
  }
  return false;
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.names, {required this.bootstrapLibrary});
  final Set<String> names;
  final bool bootstrapLibrary;
  bool found = false;
  bool requiresResolution = false;

  void _consider(AstNode node) {
    found = true;
    if (!bootstrapLibrary || !_withinApplicationBootstrap(node)) {
      requiresResolution = true;
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (names.contains(node.name) &&
        !node.inDeclarationContext() &&
        node.parent is! NamedType &&
        node.parent is! Combinator) {
      _consider(node);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    if (names.contains(node.type.name.lexeme)) _consider(node);
    super.visitConstructorName(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (names.contains(node.extendsClause?.superclass.name.lexeme)) {
      _consider(node);
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    if (names.contains(node.superclass.name.lexeme)) _consider(node);
    super.visitClassTypeAlias(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.source, this.snapshot, this.root, this.findings);
  final Source source;
  final Snapshot snapshot;
  final String root;
  final List<Finding> findings;
  final _reported = <int>{};

  bool _canonical(ConstructorElement element) =>
      element.enclosingElement.name == 'AppPreferences' &&
      element.library.firstFragment.source.fullName == '$root/$definition';

  bool _allowed(AstNode node) =>
      snapshot.libraries[source.path] == bootstrap &&
      _withinApplicationBootstrap(node);

  void _record(AstNode node, ConstructorElement? raw) {
    final element = raw?.baseElement;
    if (element is! ConstructorElement ||
        !_canonical(element) ||
        _allowed(node) ||
        !_reported.add(node.offset)) {
      return;
    }
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        'AppPreferences.${element.name}@${node.offset}',
        'Construct the settings owner only in createApplicationDependencies; inject the existing owner into consumers.',
      ),
    );
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _record(node, node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _record(node, node.element);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _record(node, node.element);
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Implicit superclass calls and super-parameters have no explicit `super`
    // expression. The resolved constructor records their actual target.
    final element = node.declaredFragment?.element;
    if (!node.initializers.any(
      (initializer) => initializer is SuperConstructorInvocation,
    )) {
      _record(node, element?.superConstructor);
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.body case BlockClassBody body
        when !body.members.any((member) => member is ConstructorDeclaration)) {
      for (final constructor
          in node.declaredFragment?.element.constructors ??
              <ConstructorElement>[]) {
        _record(node, constructor.superConstructor);
      }
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    for (final constructor
        in node.declaredFragment?.element.constructors ??
            <ConstructorElement>[]) {
      _record(node, constructor.superConstructor);
    }
    super.visitClassTypeAlias(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = Directory.current.path;
    String? roles, sdk;
    var json = false;
    final seen = <String>{};
    for (var index = 0; index < args.length; index++) {
      final option = args[index];
      if (!seen.add(option)) throw const FormatException('Duplicate option');
      if (option == '--json') {
        json = true;
        continue;
      }
      if (!{'--root', '--roles', '--sdk'}.contains(option) ||
          index + 1 == args.length) {
        throw const FormatException('Invalid option');
      }
      final value = args[++index];
      switch (option) {
        case '--root':
          root = value;
        case '--roles':
          roles = value;
        case '--sdk':
          sdk = value;
      }
    }
    root = Directory(root).resolveSymbolicLinksSync();
    final snapshot = Snapshot.load(
      root,
      roles ?? '$root/tools/architecture/roles.json',
    );
    final findings = await check(snapshot, root, sdkPath: sdk);
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
  } catch (error) {
    stderr.writeln(
      error is FormatException && error.message == _unsupportedScope
          ? '[$id INPUT] $_unsupportedScope'
          : '[$id INPUT] Invalid construction scope, SDK, source or unresolved owner provenance.',
    );
    exitCode = 2;
  }
}
