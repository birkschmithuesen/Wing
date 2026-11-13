import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_BACKUP_OWNER_BOUNDARY';
const service = 'lib/core/services/config_backup_service.dart';
const platform = 'lib/core/services/config_backup_io.dart';
const mainView = 'lib/main.dart';
const sheetView = 'lib/core/widgets/config_backup_card.dart';
const _handlerNames = {'_showBackupConfig', '_showRestoreConfig'};
const _sheetNames = {'_ExportPassphraseSheetState', '_ImportOptionsSheetState'};
const _uiOperations = {
  'lib/core/services/config_backup_service.dart': {
    'ConfigBackupService': {'export', 'import'},
  },
  'lib/core/services/config_backup.dart': {
    'ConfigBackupCodec': {'encode', 'decode'},
    'ConfigBackup': {'fromJson', 'toJson'},
  },
  'lib/core/services/config_backup_io.dart': {
    'ConfigBackupIo': {
      'appVersion',
      'pickBackupFile',
      'readBackupStream',
      'deliverExport',
    },
  },
  'lib/core/services/connection_manager.dart': {
    'ConnectionManager': {'importConnections', 'loadConnectionsWithSecrets'},
  },
  'lib/core/services/app_preferences.dart': {
    'AppPreferences': {'exportBackupSnapshot', 'restoreBackupPatch'},
  },
};
const _platformAuthorities = {
  'lib/core/services/connection_manager.dart': {
    'ConnectionManager',
    'CredentialStore',
    'FlutterSecureCredentialStore',
  },
  'lib/core/services/app_preferences.dart': {'AppPreferences'},
  'lib/core/services/config_backup_service.dart': {'ConfigBackupService'},
};
const _jsonOperations = {'jsonDecode', 'jsonEncode', 'JsonCodec'};
const _rawNames = {
  'prefs',
  'saveDevicePreference',
  'SharedPreferences',
  'get',
  'getKeys',
  'getString',
  'getBool',
  'getInt',
  'getDouble',
  'getStringList',
  'setString',
  'setBool',
  'setInt',
  'setDouble',
  'setStringList',
  'remove',
  'clear',
};

/// A finite canonical operation boundary. This does not prove arbitrary helper
/// behavior, byte preservation, admission ordering, rollback or disposal.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  // Validate scope and SDK before a parsed no-candidate return. Syntax is a
  // conservative admission filter; canonical findings still use resolution.
  final sdk = dartSdkPath(root, configured: sdkPath);
  final parsed = _ParsedSources(root, sdk);
  final candidates = <String>[];
  for (final path in [service, platform, mainView, sheetView]) {
    final unit = parsed.unit('$root/$path');
    if (unit.directives.any(
          (node) => node is PartDirective || node is PartOfDirective,
        ) ||
        unit.directives.whereType<NamespaceDirective>().any(
          (node) => node.configurations.isNotEmpty,
        )) {
      throw const FormatException(
        'Conditional/part scope requires branch proof',
      );
    }
    final selected = _scopes(unit, path);
    final visitor = _Candidates(path, parsed);
    for (final scope in selected) {
      scope.accept(visitor);
    }
    if (visitor.found) candidates.add(path);
  }
  final optionsPath = '$root/analysis_options.yaml';
  final options = File(optionsPath).existsSync()
      ? File(optionsPath).readAsStringSync()
      : '';
  if (options.contains('enable-experiment:')) {
    throw const FormatException(
      'Experimental context requires explicit review',
    );
  }
  if (candidates.isEmpty) return [];
  final contexts = semanticContextCollection(
    root: root,
    cacheNamespace: 'backup-owner-boundary',
    includedPaths: [root],
    sdk: sdk,
  );
  final findings = <Finding>[];
  try {
    for (final path in candidates) {
      final absolute = '$root/$path';
      if (!File(absolute).existsSync()) {
        throw const FormatException('Missing completed backup scope');
      }
      final result = await contexts
          .contextFor(absolute)
          .currentSession
          .getResolvedUnit(absolute);
      if (result is! ResolvedUnitResult ||
          result.diagnostics.any(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          )) {
        throw const FormatException('Unresolved completed backup scope');
      }
      final scopes = _scopes(result.unit, path);
      final visitor = _Operations(root, path, result, findings);
      for (final scope in scopes) {
        scope.accept(visitor);
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

List<AstNode> _scopes(CompilationUnit unit, String path) {
  if (path == service || path == platform) return [unit];
  final scopes = <AstNode>[];
  final found = <String>{};
  for (final declaration in unit.declarations.whereType<ClassDeclaration>()) {
    final name = declaration.namePart.typeName.lexeme;
    if (path == sheetView && _sheetNames.contains(name)) {
      scopes.add(declaration);
      found.add(name);
    } else if (path == mainView && name == 'HomeScreenState') {
      final body = declaration.body;
      if (body is! BlockClassBody) {
        throw const FormatException('Unexpected backup view class body');
      }
      for (final member in body.members.whereType<MethodDeclaration>()) {
        if (_handlerNames.contains(member.name.lexeme)) {
          scopes.add(member);
          found.add(member.name.lexeme);
        }
      }
    }
  }
  if (found.length !=
      (path == mainView ? _handlerNames.length : _sheetNames.length)) {
    throw const FormatException('Missing selected backup UI declaration');
  }
  return scopes;
}

// This parser only proves declarations, not inferred types or arbitrary flow.
// Unknown/aliased declarations stay candidates. Imports/exports/combinators are
// traversed to prove a direct class declaration and its own member; an inherited
// member is never exempted. No receiver spelling is special.
class _ParsedSources {
  _ParsedSources(this.root, this.sdk) {
    final config = File('$root/.dart_tool/package_config.json');
    if (!config.existsSync()) throw const FormatException('Missing packages');
    final value = jsonDecode(config.readAsStringSync());
    if (value is! Map ||
        value['configVersion'] != 2 ||
        value['packages'] is! List) {
      throw const FormatException('Invalid package configuration');
    }
    for (final package in value['packages'] as List) {
      if (package is! Map ||
          package['name'] is! String ||
          packages.containsKey(package['name'])) {
        throw const FormatException('Ambiguous package configuration');
      }
      final location = config.uri.resolve(package['rootUri'] as String);
      final base = Uri.directory(location.toFilePath());
      packages[package['name'] as String] = base.resolve(
        package['packageUri'] as String? ?? 'lib/',
      );
    }
  }
  final String root, sdk;
  final packages = <String, Uri>{};
  final units = <String, CompilationUnit>{};
  Set<String>? _storageMembers, _jsonMembers;
  Set<String> get storageMembers => _storageMembers ??= {
    ..._rawNames,
    ..._classMembers(
      'package:shared_preferences/shared_preferences.dart',
      'SharedPreferences',
    ),
  };
  Set<String> get jsonMembers => _jsonMembers ??= {
    ..._jsonOperations,
    ..._classMembers('dart:convert', 'JsonCodec'),
  };
  Set<String> _classMembers(String uri, String name) {
    final file = target('$root/$service', uri);
    final declarations = file == null ? null : exported(file, name);
    if (declarations?.length != 1 ||
        declarations!.single.$2 is! ClassDeclaration) {
      throw const FormatException('Unresolved canonical API vocabulary');
    }
    final body = (declarations.single.$2 as ClassDeclaration).body;
    if (body is! BlockClassBody) {
      throw const FormatException('Unsupported canonical class');
    }
    return {
      for (final member in body.members.whereType<MethodDeclaration>())
        member.name.lexeme,
      for (final member in body.members.whereType<FieldDeclaration>())
        for (final variable in member.fields.variables) variable.name.lexeme,
    };
  }

  final _typeParameters = <String, Set<String>>{};
  final _lookups = <(String, String, bool), List<(String, AstNode)>?>{};
  CompilationUnit unit(String path) => units.putIfAbsent(path, () {
    final file = File(path);
    if (!file.existsSync()) throw const FormatException('Missing source');
    final result = parseString(
      content: file.readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    if (result.errors.isNotEmpty) throw const FormatException('Invalid syntax');
    return result.unit;
  });
  String? target(String path, String? text) {
    final uri = text == null ? null : Uri.tryParse(text);
    if (uri == null || uri.hasFragment || uri.hasQuery) return null;
    if (uri.scheme == 'dart') {
      final name = uri.path;
      final file = name == 'ui' && packages.containsKey('sky_engine')
          ? packages['sky_engine']!.resolve('ui/ui.dart').toFilePath()
          : '$sdk/lib/$name/$name.dart';
      return File(file).existsSync() ? file : null;
    }
    if (uri.scheme == 'package') {
      final slash = uri.path.indexOf('/');
      if (slash < 0) return null;
      return packages[uri.path.substring(0, slash)]
          ?.resolve(uri.path.substring(slash + 1))
          .toFilePath();
    }
    if (uri.scheme.isNotEmpty) return null;
    return File(path).uri.resolveUri(uri).toFilePath();
  }

  bool visible(NamespaceDirective directive, String name) =>
      directive.combinators.every(
        (c) => switch (c) {
          ShowCombinator show => show.shownNames.any((n) => n.name == name),
          HideCombinator hide => !hide.hiddenNames.any((n) => n.name == name),
        },
      );
  List<(String, AstNode)>? exported(
    String path,
    String name, [
    Set<String> visiting = const {},
    bool includeExports = true,
  ]) {
    final key = (path, name, includeExports);
    if (_lookups.containsKey(key)) return _lookups[key];
    if (visiting.contains(path)) return [];
    final ast = unit(path);
    final found = <(String, AstNode)>[];
    for (final declaration in ast.declarations) {
      final declared = switch (declaration) {
        ClassDeclaration c => c.namePart.typeName.lexeme,
        GenericTypeAlias a => a.name.lexeme,
        ClassTypeAlias a => a.name.lexeme,
        EnumDeclaration e => e.namePart.typeName.lexeme,
        _ => null,
      };
      if (declared == name) found.add((path, declaration));
    }
    for (final declaration
        in ast.declarations.whereType<TopLevelVariableDeclaration>()) {
      for (final variable in declaration.variables.variables) {
        if (variable.name.lexeme == name) found.add((path, variable));
      }
    }
    for (final part in ast.directives.whereType<PartDirective>()) {
      final file = target(path, part.uri.stringValue);
      if (file == null) return null;
      final members = exported(file, name, {...visiting, path}, includeExports);
      if (members == null) return null;
      found.addAll(members);
    }
    for (final directive
        in includeExports
            ? ast.directives.whereType<ExportDirective>()
            : <ExportDirective>[]) {
      if (!visible(directive, name)) continue;
      for (final literal in [
        directive.uri,
        ...directive.configurations.map((c) => c.uri),
      ]) {
        final file = target(path, literal.stringValue);
        if (file == null) return null;
        final members = exported(file, name, {
          ...visiting,
          path,
        }, includeExports);
        if (members == null) return null;
        found.addAll(members);
      }
    }
    return _lookups[key] = found.toSet().toList();
  }

  List<(String, AstNode)>? type(String path, NamedType type) {
    return binding(path, type.name.lexeme, type.importPrefix?.name.lexeme);
  }

  List<(String, AstNode)>? binding(String path, String name, [String? prefix]) {
    final parameters = _typeParameters.putIfAbsent(path, () {
      final visitor = _TypeParameters();
      unit(path).accept(visitor);
      return visitor.names;
    });
    if (parameters.contains(name) || parameters.contains(prefix)) return null;
    // Unresolved parsing represents C.named() as type C.named. Only treat C
    // as the class when no import prefix C exists; ambiguous imports resolve.
    if (prefix != null &&
        !unit(path).directives.whereType<ImportDirective>().any(
          (directive) => directive.prefix?.name == prefix,
        )) {
      name = prefix;
      prefix = null;
    }
    final local = exported(path, name, const {}, false);
    if (prefix == null && local?.isNotEmpty == true) return local;
    final found = <(String, AstNode)>[];
    for (final directive in unit(
      path,
    ).directives.whereType<ImportDirective>()) {
      if (directive.prefix?.name != prefix || !visible(directive, name)) {
        continue;
      }
      for (final literal in [
        directive.uri,
        ...directive.configurations.map((c) => c.uri),
      ]) {
        final file = target(path, literal.stringValue);
        if (file == null) return null;
        final members = exported(file, name);
        if (members == null) return null;
        found.addAll(members);
      }
    }
    if (prefix == null &&
        !unit(path).directives.whereType<ImportDirective>().any(
          (d) => d.uri.stringValue == 'dart:core',
        )) {
      final implicit = exported('$sdk/lib/core/core.dart', name);
      if (implicit == null) return null;
      found.addAll(implicit);
    }
    return found.toSet().toList();
  }

  bool ownUnrelatedMember(SimpleIdentifier node, String path) {
    final parent = node.parent;
    final Expression? receiver = switch (parent) {
      MethodInvocation call when identical(call.methodName, node) =>
        call.realTarget,
      PropertyAccess access when identical(access.propertyName, node) =>
        access.realTarget,
      PrefixedIdentifier access when identical(access.identifier, node) =>
        access.prefix,
      _ => null,
    };
    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (owner?.body is! BlockClassBody) return false;
    if (receiver == null) {
      final shadows = _Shadow(node.name);
      method?.accept(shadows);
      if (shadows.found) return false;
      return _hasSafeMember(owner!, path, node.name, path);
    }
    if (receiver is! SimpleIdentifier) return false;
    final shadows = _Shadow(receiver.name);
    method?.accept(shadows);
    if (shadows.found) return false;
    if ((owner!.body as BlockClassBody).members
        .whereType<MethodDeclaration>()
        .any((member) => member.name.lexeme == receiver.name)) {
      return false;
    }
    final fields = (owner.body as BlockClassBody).members
        .whereType<FieldDeclaration>()
        .where(
          (field) => field.fields.variables.any(
            (variable) => variable.name.lexeme == receiver.name,
          ),
        )
        .toList();
    List<(String, AstNode)>? definitions;
    if (fields.length == 1 && fields.single.fields.type is NamedType) {
      definitions = type(path, fields.single.fields.type as NamedType);
    } else if (fields.isEmpty &&
        owner.extendsClause == null &&
        owner.withClause == null &&
        !(owner.body as BlockClassBody).members
            .whereType<MethodDeclaration>()
            .any((m) => m.name.lexeme == receiver.name)) {
      // Static class members and explicit top-level typed constants only.
      // Never infer a local variable's initializer or a helper return type.
      definitions = binding(path, receiver.name);
    }
    if (definitions?.length != 1) return false;
    var (file, declaration) = definitions!.single;
    if (declaration is VariableDeclaration &&
        declaration.parent is VariableDeclarationList &&
        (declaration.parent as VariableDeclarationList).type is NamedType) {
      final types = type(
        file,
        (declaration.parent as VariableDeclarationList).type as NamedType,
      );
      if (types?.length != 1) return false;
      (file, declaration) = types!.single;
    }
    if (declaration is! ClassDeclaration) return false;
    return _hasSafeMember(declaration, file, node.name, path);
  }

  bool _hasSafeMember(
    ClassDeclaration declaration,
    String file,
    String member,
    String scope,
  ) {
    final name = declaration.namePart.typeName.lexeme;
    final relative = file.startsWith('$root/')
        ? file.substring(root.length + 1)
        : file;
    if (name == 'SharedPreferences' ||
        (scope.endsWith(mainView) || scope.endsWith(sheetView)) &&
            (name == 'JsonCodec' ||
                _uiOperations[relative]?[name]?.contains(member) == true) ||
        relative == 'lib/core/services/connection_manager.dart' &&
            member == 'prefs' ||
        scope.endsWith(platform) &&
            _platformAuthorities[relative]?.contains(name) == true) {
      return false;
    }
    final body = declaration.body;
    return body is BlockClassBody &&
        body.members.any(
          (m) =>
              m is MethodDeclaration && m.name.lexeme == member ||
              m is ConstructorDeclaration && m.name?.lexeme == member,
        );
  }
}

class _TypeParameters extends RecursiveAstVisitor<void> {
  final names = <String>{};
  @override
  void visitTypeParameter(TypeParameter node) {
    names.add(node.name.lexeme);
    super.visitTypeParameter(node);
  }
}

class _Shadow extends RecursiveAstVisitor<void> {
  _Shadow(this.name);
  final String name;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == name && node.inDeclarationContext()) found = true;
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    if (node.name.lexeme == name) found = true;
    super.visitCatchClauseParameter(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    if (node.name.lexeme == name) found = true;
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (node.name.lexeme == name) found = true;
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    if (node.parameters.any((parameter) => parameter.name?.lexeme == name)) {
      found = true;
    }
    super.visitFormalParameterList(node);
  }
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.path, this.parsed);
  final String path;
  final _ParsedSources parsed;
  bool found = false;
  bool? _importsAuthority;
  bool get ui => path == mainView || path == sheetView;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        !node.inDeclarationContext() &&
        node.parent is! Combinator) {
      final watched = {
        ...parsed.storageMembers,
        if (ui) ...parsed.jsonMembers,
        if (ui)
          for (final owners in _uiOperations.values)
            for (final methods in owners.values) ...methods,
      };
      if (watched.contains(node.name) &&
          !parsed.ownUnrelatedMember(node, '${parsed.root}/$path')) {
        found = true;
      }
      // Platform authorities forbid every member, not just named backup APIs.
      // Any unknown field/member receiver still requires canonical resolution.
      if (path == platform &&
          (node.parent is PropertyAccess ||
              node.parent is PrefixedIdentifier ||
              node.parent is MethodInvocation)) {
        // A platform adapter importing a local authority path cannot pass just
        // because its called member has an unrelated spelling.
        _importsAuthority ??= _platformAuthorities.keys.any(
          (authority) => _reachable(
            '${parsed.root}/$path',
            '${parsed.root}/$authority',
            {},
          ),
        );
        if (_importsAuthority!) found = true;
      }
    }
    super.visitSimpleIdentifier(node);
  }

  bool _reachable(String source, String target, Set<String> seen) {
    if (source == target) return true;
    if (!seen.add(source)) return false;
    for (final directive
        in parsed.unit(source).directives.whereType<NamespaceDirective>()) {
      for (final literal in [
        directive.uri,
        ...directive.configurations.map((c) => c.uri),
      ]) {
        // SDK libraries cannot own the application's canonical authorities.
        // Their generic return/value flow is not part of this finite property.
        if (literal.stringValue?.startsWith('dart:') == true) continue;
        final next = parsed.target(source, literal.stringValue);
        if (next == null || _reachable(next, target, seen)) return true;
      }
    }
    return false;
  }

  @override
  void visitNamedType(NamedType node) {
    final definitions = parsed.type('${parsed.root}/$path', node);
    if (definitions == null || definitions.isEmpty) {
      if (!{'void', 'dynamic'}.contains(node.name.lexeme)) found = true;
    } else {
      for (final (file, declaration) in definitions) {
        final relative = file.startsWith('${parsed.root}/')
            ? file.substring(parsed.root.length + 1)
            : file;
        if (declaration is GenericTypeAlias &&
            declaration.type is GenericFunctionType) {
          continue;
        }
        if (declaration is! ClassDeclaration &&
            declaration is! EnumDeclaration) {
          found = true; // An alias must retain resolved underlying identity.
          continue;
        }
        final name = declaration is ClassDeclaration
            ? declaration.namePart.typeName.lexeme
            : node.name.lexeme;
        if (name == 'SharedPreferences' ||
            ui && name == 'JsonCodec' ||
            path == platform &&
                _platformAuthorities[relative]?.contains(name) == true) {
          found = true;
        }
      }
    }
    super.visitNamedType(node);
  }
}

class _Operations extends RecursiveAstVisitor<void> {
  _Operations(this.root, this.path, this.result, this.findings);
  final String root;
  final String path;
  final ResolvedUnitResult result;
  final List<Finding> findings;
  final _reported = <int>{};

  void _inspect(AstNode node, Element? raw) {
    final element = raw?.baseElement;
    if (element == null) return;
    final library = element.library;
    final absolute = library?.firstFragment.source.fullName;
    final relative = absolute?.startsWith('$root/') == true
        ? absolute!.substring(root.length + 1)
        : null;
    final owner = element.enclosingElement?.name;
    final rawStorage =
        library?.uri.toString().startsWith('package:shared_preferences/') ==
                true &&
            (owner == 'SharedPreferences' ||
                element.name == 'SharedPreferences') ||
        relative == 'lib/core/services/connection_manager.dart' &&
            owner == 'ConnectionManager' &&
            element.name == 'prefs' ||
        relative == 'lib/core/services/device_preference.dart' &&
            element is TopLevelFunctionElement &&
            element.name == 'saveDevicePreference';
    final uiScope = path == mainView || path == sheetView;
    final platformAuthority =
        path == platform &&
        (_platformAuthorities[relative]?.contains(owner) == true ||
            element is InterfaceElement &&
                _platformAuthorities[relative]?.contains(element.name) == true);
    final jsonOperation =
        uiScope &&
        library?.uri.toString() == 'dart:convert' &&
        (element is TopLevelFunctionElement &&
                _jsonOperations.contains(element.name) ||
            owner == 'JsonCodec' ||
            element is InterfaceElement && element.name == 'JsonCodec');
    final uiOperation =
        uiScope &&
        (element is MethodElement || element is ConstructorElement) &&
        _uiOperations[relative]?[owner]?.contains(element.name) == true;
    if ((rawStorage || uiOperation || platformAuthority || jsonOperation) &&
        _reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          path,
          result.lineInfo.getLocation(node.offset).lineNumber,
          'backup-owner:${node.offset}',
          path == platform
              ? 'Keep backup platform IO independent of settings and connection authorities.'
              : path == service
              ? 'Read and restore canonical settings through the shared AppPreferences owner.'
              : 'Render typed backup choices and invoke BackupSession; storage and codec operations belong to its owners.',
        ),
      );
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        !node.inDeclarationContext() &&
        node.parent is! Combinator) {
      final watched = {
        ..._rawNames,
        if (path == mainView || path == sheetView) ..._jsonOperations,
        if (path == platform)
          for (final owners in _platformAuthorities.values) ...owners,
        for (final owners in _uiOperations.values)
          for (final methods in owners.values) ...methods,
      };
      if (watched.contains(node.name) && node.element == null) {
        final parent = node.parent;
        if (!(node.name == 'call' &&
            parent is MethodInvocation &&
            parent.realTarget?.staticType is FunctionType)) {
          throw const FormatException('Use a resolved backup owner command');
        }
      }
      _inspect(node, node.element);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final type = node.type;
    if (type is InterfaceType) _inspect(node, type.element);
    super.visitNamedType(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _inspect(node.constructorName, node.constructorName.element);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    _inspect(node.constructorName, node.constructorName.element);
    super.visitConstructorReference(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = '.';
    String? sdk;
    final seen = <String>{};
    for (var index = 0; index < args.length; index += 2) {
      if (index + 1 == args.length ||
          !{'--root', '--sdk'}.contains(args[index]) ||
          !seen.add(args[index])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (args[index] == '--root') root = args[index + 1];
      if (args[index] == '--sdk') sdk = args[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdk);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] ${error.runtimeType}');
    exitCode = 2;
  }
}
