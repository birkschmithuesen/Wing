import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/source.dart' as analyzer_source;
import 'package:analyzer/src/generated/source.dart' show SourceFactory;

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_PROFILE_COLOURS_VIEW';
const views = {
  'lib/core/widgets/profile_selector.dart': 'ProfileSelector',
  'lib/core/widgets/chat_profile_bar.dart': 'ChatProfileBar',
};
const owner = 'lib/core/services/profile_colors_session.dart';
const storage = {
  'lib/core/services/app_preferences.dart',
  'lib/core/services/profile_color_store.dart',
};
const _external = {'dart:io', 'dart:convert'};
const _native = {
  'MethodChannel',
  'OptionalMethodChannel',
  'BasicMessageChannel',
  'EventChannel',
  'BinaryMessenger',
  'SystemChannels',
  'defaultBinaryMessenger',
};
const _operations = {
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
  'read',
  'write',
  'preferences',
  'connectionIdentity',
};

bool _access(SimpleIdentifier node) =>
    !node.inDeclarationContext() &&
    node.parent is! Combinator &&
    node.parent is! Label &&
    node.parent is! NamedType;
bool _externalRisk(String uri) =>
    _external.contains(uri) ||
    uri.startsWith('package:shared_preferences/') ||
    uri.startsWith('package:shared_preferences_platform_interface/') ||
    uri.startsWith('package:crypto/');

// Candidate names are only an over-approximation. Identity decisions below use
// analyzer elements; no name grants a semantic exemption.
Set<String> _names(Snapshot snapshot) {
  final result = <String>{
    ..._operations,
    ..._native,
    'SharedPreferences',
    'SharedPreferencesAsync',
    'SharedPreferencesWithCache',
    'AppPreferences',
    'ProfileColorStore',
    'ProfileColorsSession',
    'File',
    'Directory',
    'RandomAccessFile',
    'utf8',
    'json',
    'jsonDecode',
    'jsonEncode',
    'sha256',
    'Sha256',
    'Digest',
    'Hash',
    'Hmac',
    'dynamic',
  };
  for (final source in snapshot.sources.values) {
    if (!storage.contains(snapshot.libraries[source.path])) continue;
    for (final declaration in source.ast.declarations) {
      final name = switch (declaration) {
        ClassDeclaration d => d.namePart.typeName.lexeme,
        EnumDeclaration d => d.namePart.typeName.lexeme,
        GenericTypeAlias d => d.name.lexeme,
        FunctionDeclaration d => d.name.lexeme,
        _ => null,
      };
      if (name != null) result.add(name);
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final source in snapshot.sources.values) {
      for (final declaration in source.ast.declarations) {
        final (name, signatures) = switch (declaration) {
          ClassDeclaration d => (
            d.namePart.typeName.lexeme,
            <AstNode?>[
              d.extendsClause,
              d.withClause,
              d.implementsClause,
              d.namePart.typeParameters,
            ],
          ),
          ClassTypeAlias d => (
            d.name.lexeme,
            <AstNode?>[
              d.superclass,
              d.withClause,
              d.implementsClause,
              d.typeParameters,
            ],
          ),
          MixinDeclaration d => (
            d.name.lexeme,
            <AstNode?>[d.onClause, d.implementsClause, d.typeParameters],
          ),
          EnumDeclaration d => (
            d.namePart.typeName.lexeme,
            <AstNode?>[
              d.withClause,
              d.implementsClause,
              d.namePart.typeParameters,
            ],
          ),
          ExtensionTypeDeclaration d => (
            d.primaryConstructor.typeName.lexeme,
            <AstNode?>[
              d.primaryConstructor.formalParameters,
              d.implementsClause,
              d.primaryConstructor.typeParameters,
            ],
          ),
          _ => (null, <AstNode?>[]),
        };
        final visitor = _Names(result);
        for (final signature in signatures) {
          signature?.accept(visitor);
        }
        if (name != null && visitor.found) {
          changed = result.add(name) || changed;
        }
      }
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        final visitor = _Names(result);
        alias.type.accept(visitor);
        if (visitor.found) changed = result.add(alias.name.lexeme) || changed;
      }
    }
  }
  // Return annotations add captured authority names, including aliases and
  // nullable facts; inference/erasure is conservative for getter declarations.
  for (final source in snapshot.sources.values) {
    for (final declaration in source.ast.declarations) {
      if (declaration is FunctionDeclaration) {
        final visitor = _Names(result);
        declaration.returnType?.accept(visitor);
        if ((visitor.found || declaration.returnType == null) &&
            !declaration.name.lexeme.startsWith('_')) {
          result.add(declaration.name.lexeme);
        }
      }
      if (declaration is TopLevelVariableDeclaration) {
        final visitor = _Names(result);
        declaration.variables.type?.accept(visitor);
        if (visitor.found || declaration.variables.type == null) {
          result.addAll(
            declaration.variables.variables
                .where((v) => !v.name.lexeme.startsWith('_'))
                .map((v) => v.name.lexeme),
          );
        }
      }
      final members = switch (declaration) {
        ClassDeclaration d when d.body is BlockClassBody =>
          (d.body as BlockClassBody).members,
        MixinDeclaration d => d.body.members,
        ExtensionDeclaration d => d.body.members,
        EnumDeclaration d => d.body.members,
        ExtensionTypeDeclaration d when d.body is BlockClassBody =>
          (d.body as BlockClassBody).members,
        _ => <ClassMember>[],
      };
      for (final member in members) {
        if (member is MethodDeclaration) {
          final visitor = _Names(result);
          member.returnType?.accept(visitor);
          if (visitor.found || member.returnType == null) {
            result.add(member.name.lexeme);
          }
        }
        if (member is FieldDeclaration) {
          final visitor = _Names(result);
          member.fields.type?.accept(visitor);
          if (visitor.found || member.fields.type == null) {
            result.addAll(member.fields.variables.map((v) => v.name.lexeme));
          }
        }
      }
    }
  }
  return result;
}

class _Names extends RecursiveAstVisitor<void> {
  _Names(this.names);
  final Set<String> names;
  bool found = false;
  @override
  void visitNamedType(NamedType node) {
    if (names.contains(node.name.lexeme)) found = true;
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (names.contains(node.name)) found = true;
    super.visitSimpleIdentifier(node);
  }
}

void _validate(
  Snapshot snapshot,
  String library,
  Set<String> seen,
  analyzer_source.Source origin,
  SourceFactory factory,
) {
  // The same physical file may be imported through different package origins;
  // relative namespaces must be valid for each actual origin, not just its disk path.
  if (!seen.add('$library\u0000${origin.uri}')) return;
  if (!origin.exists() ||
      File(origin.fullName).resolveSymbolicLinksSync() !=
          File('${snapshot.root}/$library').resolveSymbolicLinksSync()) {
    throw const FormatException('Invalid authored library origin');
  }
  final primary = snapshot.sources[library];
  if (primary == null ||
      snapshot.libraries[library] != library ||
      primary.ast.directives.whereType<PartOfDirective>().isNotEmpty) {
    throw const FormatException('Containing colour library missing');
  }
  for (final directive in primary.ast.directives.whereType<PartDirective>()) {
    final value = directive.uri.stringValue;
    if (value == null) throw const FormatException('Unknown part URI');
    final actual = factory.resolveUri(origin, value);
    if (actual == null || !actual.exists()) {
      throw const FormatException('Missing actual colour part namespace');
    }
    final target = File('${snapshot.root}/$library').uri.resolve(value);
    if (target.scheme != 'file' || !File.fromUri(target).existsSync()) {
      throw const FormatException('Missing part');
    }
    final path = File.fromUri(target).resolveSymbolicLinksSync();
    if (File(actual.fullName).resolveSymbolicLinksSync() != path ||
        !path.startsWith('${snapshot.root}/') ||
        !primary.partTargets.contains(
          path.substring(snapshot.root.length + 1),
        )) {
      throw const FormatException('Actual part outside parsed ownership');
    }
  }
  for (final path in primary.partTargets) {
    final part = snapshot.sources[path];
    if (part == null ||
        part.ast.directives.length != 1 ||
        snapshot.partOwners[path]?.length != 1 ||
        snapshot.partOwners[path]?.single != library ||
        (part.partOf != library && !part.namedPartOf)) {
      throw const FormatException('Invalid colour part owner');
    }
    if (part.namedPartOf) {
      final name = primary.ast.directives
          .whereType<LibraryDirective>()
          .singleOrNull
          ?.name
          ?.toSource();
      if (name == null ||
          part.ast.directives
                  .whereType<PartOfDirective>()
                  .singleOrNull
                  ?.libraryName
                  ?.toSource() !=
              name) {
        throw const FormatException('Invalid named colour part');
      }
    }
  }
  for (final source in snapshot.sources.values.where(
    (s) => snapshot.libraries[s.path] == library,
  )) {
    for (final directive
        in source.ast.directives.whereType<NamespaceDirective>()) {
      if (directive.configurations.isNotEmpty) {
        throw const FormatException(
          'Conditional colour namespace requires branch proof',
        );
      }
      final value = directive.uri.stringValue;
      if (value == null) throw const FormatException('Unknown namespace');
      final containing = source.path == library
          ? origin
          : factory.forUri(
              File('${snapshot.root}/${source.path}').uri.toString(),
            );
      final target = factory.resolveUri(containing, value);
      if (target == null || !target.exists()) {
        throw const FormatException('Missing actual colour namespace');
      }
      if (target.uri.scheme == 'dart') continue;
      if (target.uri.scheme != 'file' && target.uri.scheme != 'package') {
        throw const FormatException('Unsupported namespace origin');
      }
      final path = File(target.fullName).resolveSymbolicLinksSync();
      if (path.startsWith('${snapshot.root}/')) {
        final relative = path.substring(snapshot.root.length + 1);
        final owner = snapshot.libraries[relative];
        if (owner == null) {
          throw const FormatException(
            'Authored namespace outside parsed scope',
          );
        }
        _validate(snapshot, owner, seen, target, factory);
      } else if (target.uri.scheme != 'package') {
        throw const FormatException('External authored namespace unsupported');
      }
    }
  }
}

String? _target(
  Snapshot snapshot,
  Source source,
  String value,
  Map<String, Uri> packages,
) {
  final uri = Uri.parse(value);
  if (uri.scheme == 'dart') return null;
  final target = uri.scheme == 'package'
      ? packages[uri.pathSegments.first]?.resolve(
          uri.pathSegments.skip(1).join('/'),
        )
      : File('${snapshot.root}/${source.path}').uri.resolveUri(uri);
  if (target == null || target.scheme != 'file') return null;
  final path = File.fromUri(target).resolveSymbolicLinksSync();
  if (!path.startsWith('${snapshot.root}/')) return null;
  final relative = path.substring(snapshot.root.length + 1);
  return snapshot.libraries[relative];
}

bool _key(AstNode node) => switch (node) {
  SimpleStringLiteral value => value.value.startsWith('profile_color_v1_'),
  AdjacentStrings value =>
    value.stringValue?.startsWith('profile_color_v1_') == true,
  StringInterpolation value =>
    value.elements.whereType<InterpolationString>().any(
      (part) => part.value.startsWith('profile_color_v1_'),
    ),
  _ => false,
};

bool _declarationRisk(Source source) => source.ast.declarations.any(
  (d) =>
      d is FunctionDeclaration ||
      d is TopLevelVariableDeclaration ||
      d is GenericTypeAlias ||
      d is FunctionTypeAlias,
);

bool _namespaceCandidate(
  Snapshot snapshot,
  Source source,
  Set<String> seen,
  Map<String, Uri> packages,
) {
  if (!seen.add(source.path)) return false;
  for (final dependency in source.dependencies) {
    if (_externalRisk(dependency.uri)) return true;
    if (_target(snapshot, source, dependency.uri, packages)
        case final target?) {
      if (storage.contains(target)) return true;
      final next = snapshot.sources[target];
      if (next != null &&
          (_declarationRisk(next) ||
              _exportCandidate(snapshot, next, seen, packages))) {
        return true;
      }
    }
  }
  return false;
}

bool _exportCandidate(
  Snapshot snapshot,
  Source source,
  Set<String> seen,
  Map<String, Uri> packages,
) {
  if (!seen.add(source.path)) return false;
  for (final dependency in source.dependencies.where(
    (d) => d.kind == 'export',
  )) {
    if (_externalRisk(dependency.uri)) return true;
    final target = _target(snapshot, source, dependency.uri, packages);
    if (storage.contains(target)) return true;
    final next = snapshot.sources[target];
    if (next != null &&
        (_declarationRisk(next) ||
            _exportCandidate(snapshot, next, seen, packages))) {
      return true;
    }
  }
  return false;
}

// Dart leaves some omitted executable return annotations dynamic. Inspect
// only the actual resolved arrow expression/initializer of a captured authored
// declaration; never infer control flow or propagate types through other bodies.
DartType? _declaredType(Element element) => switch (element.baseElement) {
  PropertyAccessorElement e => e.returnType,
  FieldElement e => e.type,
  TopLevelVariableElement e => e.type,
  TypeAliasElement e => e.aliasedType,
  ExtensionTypeElement e => e.representation.type,
  FormalParameterElement e => e.type,
  LocalVariableElement e => e.type,
  MethodElement e => e.returnType,
  TopLevelFunctionElement e => e.returnType,
  _ => null,
};

class _ErasedCaptures extends RecursiveAstVisitor<void> {
  _ErasedCaptures(this.root);
  final String root;
  final libraries = <String>{};
  void add(Element? element) {
    if (element == null || _declaredType(element) is! DynamicType) return;
    final path = element.library?.firstFragment.source.fullName;
    if (path != null && path.startsWith('$root/')) libraries.add(path);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_access(node)) add(node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    for (final element
        in node.libraryImport?.namespace.definedNames2.values ?? <Element>[]) {
      add(element);
    }
    super.visitImportDirective(node);
  }
}

class _ArrowTypes extends RecursiveAstVisitor<void> {
  final types = <Element, DartType>{};
  void add(Element? element, Expression? expression) {
    final type = expression?.staticType;
    if (element == null || type == null) return;
    types[element.baseElement] = type;
    if (element is PropertyInducingElement && element.getter != null) {
      types[element.getter!.baseElement] = type;
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final body = node.functionExpression.body;
    if (body is ExpressionFunctionBody) {
      add(node.declaredFragment?.element, body.expression);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final body = node.body;
    if (body is ExpressionFunctionBody) {
      add(node.declaredFragment?.element, body.expression);
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    add(node.declaredFragment?.element, node.initializer);
    super.visitVariableDeclaration(node);
  }
}

Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  final sdk = dartSdkPath(root, configured: sdkPath);
  final config = File('$root/.dart_tool/package_config.json');
  final json = jsonDecode(config.readAsStringSync()) as Map;
  final packages = <String, Uri>{};
  for (final package in (json['packages'] as List).cast<Map>()) {
    final base = config.uri.resolve(package['rootUri'] as String);
    packages[package['name'] as String] = base
        .replace(path: base.path.endsWith('/') ? base.path : '${base.path}/')
        .resolve(package['packageUri'] as String? ?? '');
  }
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: views.keys.map((p) => '$root/$p').toList(),
    cacheNamespace: 'profile-colours-view',
  );
  try {
    // The configured analyzer source factory includes the SDK and actual
    // package embedder mappings (for example Flutter's dart:ui).
    final context = contexts.contextFor('$root/${views.keys.first}');
    final factory = context.driver.sourceFactory;
    final names = _names(snapshot);
    final selected = <Source>[];
    for (final entry in views.entries) {
      final uri = factory.pathToUri('$root/${entry.key}');
      final origin = uri == null ? null : factory.forUri2(uri);
      if (origin == null) {
        throw const FormatException('Unknown selected namespace origin');
      }
      _validate(snapshot, entry.key, {}, origin, factory);
      final units = snapshot.sources.values
          .where((s) => snapshot.libraries[s.path] == entry.key)
          .toList();
      if (units
              .expand((s) => s.ast.declarations)
              .whereType<ClassDeclaration>()
              .where((d) => d.namePart.typeName.lexeme == entry.value)
              .length !=
          1) {
        throw const FormatException('Completed colour class missing/ambiguous');
      }
      final visitor = _Candidates(names, snapshot);
      for (final unit in units) {
        unit.ast.accept(visitor);
      }
      if (visitor.found ||
          units.any((s) => _namespaceCandidate(snapshot, s, {}, packages))) {
        selected.addAll(units);
      }
    }
    if (selected.isEmpty) return [];
    final findings = <Finding>[];
    final resolved = <String, ResolvedLibraryResult>{};
    for (final source in selected) {
      final library = snapshot.libraries[source.path]!;
      final result = resolved[library] ??= await (() async {
        final r = await contexts
            .contextFor('$root/$library')
            .currentSession
            .getResolvedLibrary('$root/$library');
        if (r is! ResolvedLibraryResult) {
          throw const FormatException('Colour library resolution failed');
        }
        return r;
      })();
      if (result.units.any(
        (u) =>
            u.diagnostics.any((d) => d.diagnosticCode.severity.name == 'ERROR'),
      )) {
        throw const FormatException('Unresolved colour candidate');
      }
      final captures = _ErasedCaptures(root);
      for (final unit in result.units) {
        unit.unit.accept(captures);
      }
      final arrows = _ArrowTypes();
      for (final path in captures.libraries) {
        final declaration = resolved[path] ??= await (() async {
          final value = await contexts
              .contextFor('$root/$library')
              .currentSession
              .getResolvedLibrary(path);
          if (value is! ResolvedLibraryResult ||
              value.units.any(
                (u) => u.diagnostics.any(
                  (d) => d.diagnosticCode.severity.name == 'ERROR',
                ),
              )) {
            throw const FormatException(
              'Captured declaration resolution failed',
            );
          }
          return value;
        })();
        for (final unit in declaration.units) {
          unit.unit.accept(arrows);
        }
      }
      final unit = result.units.singleWhere(
        (u) => u.path == '$root/${source.path}',
      );
      unit.unit.accept(_Resolved(root, source, findings, arrows.types));
    }
    return findings..sort();
  } finally {
    await contexts.dispose();
  }
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.names, Snapshot snapshot)
    : sessionShadow = snapshot.sources.values.any(
        (source) =>
            snapshot.libraries[source.path] != owner &&
            source.ast.declarations.any(
              (d) => switch (d) {
                ClassDeclaration value =>
                  value.namePart.typeName.lexeme == 'ProfileColorsSession',
                GenericTypeAlias value =>
                  value.name.lexeme == 'ProfileColorsSession',
                ClassTypeAlias value =>
                  value.name.lexeme == 'ProfileColorsSession',
                MixinDeclaration value =>
                  value.name.lexeme == 'ProfileColorsSession',
                EnumDeclaration value =>
                  value.namePart.typeName.lexeme == 'ProfileColorsSession',
                ExtensionTypeDeclaration value =>
                  value.primaryConstructor.typeName.lexeme ==
                      'ProfileColorsSession',
                FunctionTypeAlias value =>
                  value.name.lexeme == 'ProfileColorsSession',
                _ => false,
              },
            ),
      );
  final Set<String> names;
  final bool sessionShadow;
  bool found = false;
  @override
  void visitExportDirective(ExportDirective node) {
    found = true;
    super.visitExportDirective(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (_key(node)) found = true;
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    if (_key(node)) found = true;
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    if (_key(node)) found = true;
    super.visitStringInterpolation(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (names.contains(node.extendsClause?.superclass.name.lexeme)) {
      found = true;
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    if (names.contains(node.superclass.name.lexeme)) found = true;
    super.visitClassTypeAlias(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_access(node) && names.contains(node.name)) {
      found = true;
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if ((node.name.lexeme != 'ProfileColorsSession' || sessionShadow) &&
        names.contains(node.name.lexeme)) {
      found = true;
    }
    super.visitNamedType(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    if (names.contains(node.type.name.lexeme)) found = true;
    super.visitConstructorName(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && names.contains(node.methodName.name)) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.root, this.source, this.findings, this.arrowTypes);
  final String root;
  final Source source;
  final List<Finding> findings;
  final Map<Element, DartType> arrowTypes;
  final reported = <int>{};
  final _verdicts = <(Element, bool), bool>{};
  bool forbidden(Element raw, {bool importing = false}) {
    final element = raw.baseElement;
    return _verdicts.putIfAbsent((
      element,
      importing,
    ), () => _forbidden(element, importing: importing));
  }

  bool _forbidden(Element element, {required bool importing}) {
    final library = element.library;
    if (library == null) return false;
    final path = library.firstFragment.source.fullName;
    final relative = path.startsWith('$root/')
        ? path.substring(root.length + 1)
        : '';
    final uri = library.uri.toString();
    if (storage.contains(relative) || _externalRisk(uri)) return true;
    if (!importing && uri.startsWith('package:flutter/')) {
      for (Element? e = element; e != null; e = e.enclosingElement) {
        if (_native.contains(e.name)) return true;
      }
    }
    if (element is InterfaceElement &&
        element.allSupertypes.any(
          (type) => forbidden(type.element, importing: importing),
        )) {
      return true;
    }
    if (relative == owner &&
        element is ConstructorElement &&
        element.enclosingElement.name == 'ProfileColorsSession') {
      return true;
    }
    var type = _declaredType(element);
    if (type is DynamicType && path.startsWith('$root/')) {
      type = arrowTypes[element];
      if (type == null || type is DynamicType) {
        throw const FormatException(
          'Unprovable erased authored authority capture',
        );
      }
    }
    final checkedTypes = <DartType>{};
    bool authorityType(DartType? type) {
      if (type == null || !checkedTypes.add(type)) return false;
      if (type is InterfaceType) {
        return forbidden(type.element, importing: importing) ||
            type.typeArguments.any(authorityType) ||
            (type.element is ExtensionTypeElement &&
                authorityType(
                  (type.element as ExtensionTypeElement).representation.type,
                ));
      }
      if (type is TypeParameterType) return authorityType(type.bound);
      if (type is FunctionType) return authorityType(type.returnType);
      if (type is RecordType) {
        return type.positionalFields.any((f) => authorityType(f.type)) ||
            type.namedFields.any((f) => authorityType(f.type));
      }
      return false;
    }

    if (authorityType(type)) return true;
    if (element is ConstructorElement) {
      final seen = <ConstructorElement>{};
      for (
        var parent = element.superConstructor;
        parent != null && seen.add(parent);
        parent = parent.superConstructor
      ) {
        if (forbidden(parent)) return true;
      }
    }
    return false;
  }

  void record(AstNode node, Element? element) {
    if (element == null &&
        node is SimpleIdentifier &&
        _operations.contains(node.name)) {
      throw const FormatException('Unknown/dynamic persistence operation');
    }
    if (element != null && forbidden(element) && reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          '${element.displayName}@${node.offset}',
          'Render typed colour facts and invoke the injected session; keep persistence, key hashing and owner construction outside colour views.',
        ),
      );
    }
  }

  void key(AstNode node) {
    if (_key(node) && reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          'storage-key@${node.offset}',
          'Keep the persisted colour key construction in the shared owner.',
        ),
      );
    }
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    key(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    key(node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    key(node);
    super.visitStringInterpolation(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    for (final constructor
        in node.declaredFragment?.element.constructors ??
            <ConstructorElement>[]) {
      record(node, constructor.superConstructor);
    }
    super.visitClassTypeAlias(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    final import = node.libraryImport;
    if (import?.importedLibrary == null) {
      throw const FormatException('Missing colour import');
    }
    if (import!.namespace.definedNames2.values.any(
          (e) => forbidden(e, importing: true),
        ) &&
        reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          'authority-namespace@${node.offset}',
          'Import typed colour projections/session, not raw storage or key encoders.',
        ),
      );
    }
    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    if (reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          'view-export@${node.offset}',
          'Keep the colour widget library a rendering consumer.',
        ),
      );
    }
    super.visitExportDirective(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_access(node)) record(node, node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    record(node, node.element);
    if (node.type case InterfaceType type) record(node, type.element);
    super.visitNamedType(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    record(node, node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    record(node, node.declaredFragment?.element.superConstructor);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.body case BlockClassBody body
        when !body.members.any((m) => m is ConstructorDeclaration)) {
      for (final constructor
          in node.declaredFragment?.element.constructors ??
              <ConstructorElement>[]) {
        record(node, constructor.superConstructor);
      }
    }
    super.visitClassDeclaration(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = Directory.current.path;
    String? roles, sdk;
    var json = false;
    final seen = <String>{};
    for (var i = 0; i < args.length; i++) {
      final option = args[i];
      if (!seen.add(option)) throw const FormatException('Duplicate argument');
      if (option == '--json') {
        json = true;
        continue;
      }
      if (!{'--root', '--roles', '--sdk'}.contains(option) ||
          i + 1 == args.length) {
        throw const FormatException('Invalid argument');
      }
      final value = args[++i];
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
          'findings': findings.map((f) => f.toJson()).toList(),
        }),
      );
    } else {
      findings.forEach(stdout.writeln);
    }
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '[$id INPUT] Invalid colour scope, namespace, SDK or semantic candidate.',
    );
    exitCode = 2;
  }
}
