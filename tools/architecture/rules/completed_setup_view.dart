import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_COMPLETED_SETUP_VIEW';
const completedView = 'lib/core/screens/connection_setup_screen.dart';
const _methods = {
  'lib/core/services/connection_manager.dart': {
    'ConnectionManager': {
      'accessFor',
      'getConnections',
      'saveConnection',
      'updateConnection',
      'updateConnectionIcon',
      'updateDashboardAuth',
      'deleteConnection',
    },
  },
  'lib/core/services/hermes_cloud.dart': {
    'HermesCloud': {'discover', 'signIn', 'cancel', 'close'},
    'CloudDiscovery': {'parse'},
  },
  'lib/core/services/connection_setup_probe.dart': {
    'ConnectionSetupProbe': {'check', 'cancel', 'dispose'},
  },
  'lib/core/models/connection_address.dart': {
    'ConnectionAddress': {'parse'},
  },
  'lib/core/models/connection.dart': {
    'SavedConnection': {'copyWith', 'joinBaseUrl'},
  },
};
const _constructors = {
  'lib/core/services/connection_manager.dart': {'ConnectionManager'},
  'lib/core/services/hermes_cloud.dart': {
    'HermesCloud',
    'CloudDiscovery',
    'CloudInstance',
  },
  'lib/core/services/connection_setup_probe.dart': {
    'ConnectionSetupProbe',
    'DashboardConnectionProbe',
  },
  'lib/core/services/dashboard_oauth_session.dart': {'DashboardOAuthSession'},
  'lib/core/services/connection_access.dart': {'ConnectionAccess'},
  'lib/core/models/connection.dart': {'SavedConnection'},
  'lib/core/models/connection_address.dart': {'ConnectionAddress'},
};
const _functionLibrary = 'lib/core/models/connection.dart';
const _function = 'resolveGatewayHeaderUpdate';
final _operationNames = {
  for (final owners in _methods.values)
    for (final members in owners.values) ...members,
  _function,
};
final _constructorNames = {
  for (final owners in _constructors.values) ...owners,
};

/// A deliberately local owner boundary, not a proof of races or every possible
/// business calculation. Canonical symbol identity covers calls and tearoffs,
/// imports, exports, aliases, cascades and inherited naked member access.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final absolute = '$root/$completedView';
  final parsed = parseString(
    content: File(absolute).readAsStringSync(),
    path: absolute,
    throwIfDiagnostics: false,
  );
  if (parsed.errors.isNotEmpty) {
    throw const FormatException('Invalid setup view Dart');
  }
  if (parsed.unit.directives.any(
        (node) => node is PartDirective || node is PartOfDirective,
      ) ||
      parsed.unit.directives.whereType<NamespaceDirective>().any(
        (node) => node.configurations.isNotEmpty,
      )) {
    throw const FormatException(
      'Setup view parts/conditional imports require explicit branch proof',
    );
  }
  // Validate SDK and namespace provenance even when no operation needs resolution.
  final sdk = dartSdkPath(root, configured: sdkPath);
  final namespace = _Namespace(root, sdk, absolute, parsed.unit);
  final candidates = _Candidates(parsed.unit, namespace);
  parsed.unit.accept(candidates);
  if (!candidates.found) return [];
  final contexts = semanticContextCollection(
    root: root,
    cacheNamespace: 'completed-setup-view',
    includedPaths: [absolute],
    sdk: sdk,
  );
  final findings = <Finding>[];
  try {
    final resolved = await contexts
        .contextFor(absolute)
        .currentSession
        .getResolvedUnit(absolute);
    if (resolved is! ResolvedUnitResult) {
      throw const FormatException('Cannot resolve setup view');
    }
    if (resolved.diagnostics.any(
      (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
    )) {
      throw const FormatException('Setup view has unresolved semantic errors');
    }
    resolved.unit.accept(_Resolved(root, resolved, findings));
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

// Only declaration/namespace parsing is shared with the prefilter. This is not
// expression type inference: unknown values, aliases and inheritance resolve.
class _Declaration {
  _Declaration(this.path, this.node);
  final String path;
  final CompilationUnitMember node;
}

class _Namespace {
  _Namespace(this.root, this.sdk, this.view, CompilationUnit unit) {
    final config = File('$root/.dart_tool/package_config.json');
    if (config.existsSync()) {
      final data = jsonDecode(config.readAsStringSync()) as Map;
      for (final package in (data['packages'] as List).cast<Map>()) {
        final rawBase = config.uri.resolve(package['rootUri'] as String);
        final base = rawBase.replace(
          path: rawBase.path.endsWith('/') ? rawBase.path : '${rawBase.path}/',
        );
        packages[package['name'] as String] = base.resolve(
          package['packageUri'] as String? ?? '',
        );
      }
    }
    // Fixture workspaces and alternate roots own their authored package.
    packages['wing'] = Directory('$root/lib/').uri;
    units[view] = unit;
    for (final directive in unit.directives.whereType<ImportDirective>()) {
      validate(resolve(view, directive.uri.stringValue!));
    }
    declarations(view);
  }
  final String root, sdk, view;
  final packages = <String, Uri>{};
  final units = <String, CompilationUnit>{};
  final _declarations = <String, Map<String, List<_Declaration>>>{};
  final _exportEdges = <String, List<(String, List<Combinator>)>>{};
  final _visible = <String, List<_Declaration>>{};
  final _exported = <(String, String), List<_Declaration>>{};

  late final Set<String> aliases = {
    for (final unit in units.values)
      for (final declaration in unit.declarations)
        if (declaration is GenericTypeAlias)
          declaration.name.lexeme
        else if (declaration is FunctionTypeAlias)
          declaration.name.lexeme
        else if (declaration is ClassTypeAlias)
          declaration.name.lexeme,
  };

  late final Map sdkLibraries =
      (jsonDecode(File('$sdk/lib/libraries.json').readAsStringSync())
              as Map)['vm_common']['libraries']
          as Map;

  String resolve(String source, String value) {
    final uri = Uri.parse(value);
    Uri target;
    if (uri.scheme == 'package') {
      final package = packages[uri.pathSegments.first];
      if (package == null) throw FormatException('Unknown package $value');
      target = package.resolve(uri.pathSegments.skip(1).join('/'));
    } else if (uri.scheme == 'dart') {
      if (uri.path == 'ui') {
        final sky = packages['sky_engine'];
        if (sky == null) {
          throw const FormatException('Missing dart:ui provenance');
        }
        target = sky.resolve('ui/ui.dart');
      } else {
        final library = sdkLibraries[uri.path];
        if (library is! Map || library['uri'] is! String) {
          throw FormatException('Unknown SDK namespace $value');
        }
        target = File('$sdk/lib/${library['uri']}').uri;
      }
    } else if (uri.scheme.isEmpty || uri.scheme == 'file') {
      target = File(source).uri.resolveUri(uri);
    } else {
      throw FormatException('Unsupported namespace $value');
    }
    if (target.scheme != 'file' || !File.fromUri(target).existsSync()) {
      throw FormatException('Missing namespace $value');
    }
    return File.fromUri(target).resolveSymbolicLinksSync();
  }

  CompilationUnit parsed(String path) => units.putIfAbsent(path, () {
    final result = parseString(
      content: File(path).readAsStringSync(),
      path: path,
      featureSet: FeatureSet.latestLanguageVersion(
        flags: ['private-named-parameters'],
      ),
      throwIfDiagnostics: false,
    );
    if (result.errors.isNotEmpty) {
      throw FormatException('Invalid namespace $path');
    }
    return result.unit;
  });

  Map<String, List<_Declaration>> declarations(String path) {
    if (_declarations[path] case final cached?) return cached;
    final result = <String, List<_Declaration>>{};
    void add(CompilationUnitMember member) {
      final names = switch (member) {
        TopLevelVariableDeclaration value => value.variables.variables.map(
          (v) => v.name.lexeme,
        ),
        ClassDeclaration value => [value.namePart.typeName.lexeme],
        EnumDeclaration value => [value.namePart.typeName.lexeme],
        MixinDeclaration value => [value.name.lexeme],
        ExtensionDeclaration value => [
          if (value.name != null) value.name!.lexeme,
        ],
        ExtensionTypeDeclaration value => [
          value.primaryConstructor.typeName.lexeme,
        ],
        ClassTypeAlias value => [value.name.lexeme],
        GenericTypeAlias value => [value.name.lexeme],
        FunctionTypeAlias value => [value.name.lexeme],
        FunctionDeclaration value => [value.name.lexeme],
        _ => <String>[],
      };
      for (final name in names) {
        result.putIfAbsent(name, () => []).add(_Declaration(path, member));
      }
    }

    void collect(String source) {
      final unit = parsed(source);
      unit.declarations.forEach(add);
      for (final part in unit.directives.whereType<PartDirective>()) {
        final partPath = resolve(source, part.uri.stringValue!);
        final child = parsed(partPath);
        final owners = child.directives.whereType<PartOfDirective>().toList();
        if (owners.length != 1 ||
            (owners.single.uri != null
                ? resolve(partPath, owners.single.uri!.stringValue!) != path
                : owners.single.libraryName?.toSource() !=
                      unit.directives
                          .whereType<LibraryDirective>()
                          .singleOrNull
                          ?.name
                          ?.toSource())) {
          throw const FormatException('Malformed namespace part ownership');
        }
        child.declarations.forEach(add);
      }
    }

    collect(path);
    return _declarations[path] = result;
  }

  // Validation is unconditional. Namespace contents are demanded by name;
  // constructing every transitive namespace copied thousands of declarations
  // even though the boundary asks about only a handful of receiver types.
  void validate(String path) {
    if (_exportEdges.containsKey(path)) return;
    declarations(path);
    final edges = <(String, List<Combinator>)>[];
    _exportEdges[path] = edges; // Reserve before traversing export cycles.
    for (final directive in parsed(
      path,
    ).directives.whereType<ExportDirective>()) {
      if (directive.configurations.isNotEmpty) {
        final flutter = packages['flutter'];
        final sky = packages['sky_engine'];
        final uri = File(path).uri.toString();
        if (path.startsWith('$root/lib/') ||
            !(path.startsWith('$sdk/lib/') ||
                flutter != null && uri.startsWith(flutter.toString()) ||
                sky != null && uri.startsWith(sky.toString()))) {
          throw const FormatException(
            'Conditional setup provenance outside SDK/framework',
          );
        }
        continue;
      }
      final target = resolve(path, directive.uri.stringValue!);
      edges.add((target, directive.combinators.toList()));
      validate(target);
    }
  }

  bool _allows(
    Iterable<Combinator> combinators,
    String name,
  ) => combinators.every(
    (combinator) => switch (combinator) {
      ShowCombinator show => show.shownNames.any((node) => node.name == name),
      HideCombinator hide => !hide.hiddenNames.any((node) => node.name == name),
    },
  );

  List<_Declaration> exported(String path, String name) =>
      _exported.putIfAbsent((path, name), () {
        // A complete per-name traversal avoids caching partial cycle results.
        final result = <_Declaration>[];
        final seen = <String>{};
        final pending = [path];
        while (pending.isNotEmpty) {
          final current = pending.removeLast();
          if (!seen.add(current)) continue;
          for (final declaration
              in declarations(current)[name] ?? <_Declaration>[]) {
            if (!result.any(
              (other) =>
                  other.path == declaration.path &&
                  identical(other.node, declaration.node),
            )) {
              result.add(declaration);
            }
          }
          for (final (target, combinators)
              in _exportEdges[current] ?? <(String, List<Combinator>)>[]) {
            if (_allows(combinators, name)) pending.add(target);
          }
        }
        return result;
      });

  _Declaration? unique(String name) {
    final values = _visible.putIfAbsent(name, () {
      final local = declarations(view)[name];
      if (local != null) return local;
      final dot = name.indexOf('.');
      final prefix = dot == -1 ? null : name.substring(0, dot);
      final simple = dot == -1 ? name : name.substring(dot + 1);
      final result = <_Declaration>[];
      for (final directive in parsed(
        view,
      ).directives.whereType<ImportDirective>()) {
        if (directive.prefix?.name != prefix ||
            !_allows(directive.combinators, simple)) {
          continue;
        }
        result.addAll(
          exported(resolve(view, directive.uri.stringValue!), simple),
        );
      }
      return result;
    });
    return values.length == 1 ? values.single : null;
  }

  bool unrelated(String type, String operation) {
    // A lexical type parameter can hide the imported class used by a field.
    // Keep such bindings semantic rather than interpreting their bounds here.
    final shadows = _Shadows(type.split('.').first);
    parsed(view).accept(shadows);
    if (shadows.found) return false;
    final declaration = unique(type);
    if (declaration == null || declaration.node is! ClassDeclaration) {
      return false;
    }
    if (_methods[declaration.path.substring(
              declaration.path.startsWith('$root/') ? root.length + 1 : 0,
            )]?[(declaration.node as ClassDeclaration).namePart.typeName.lexeme]
            ?.contains(operation) ==
        true) {
      return false;
    }
    // A framework-typed receiver cannot have a canonical authored class member
    // as its static declaration. Runtime overrides remain outside this rule.
    final flutter = packages['flutter'];
    if (flutter != null &&
        File(declaration.path).uri.toString().startsWith(flutter.toString())) {
      return true;
    }
    final body = (declaration.node as ClassDeclaration).body;
    return body is BlockClassBody &&
        body.members.any(
          (member) =>
              member is MethodDeclaration && member.name.lexeme == operation ||
              member is FieldDeclaration &&
                  member.fields.variables.any(
                    (field) => field.name.lexeme == operation,
                  ),
        );
  }
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.unit, this.namespace);
  final CompilationUnit unit;
  final _Namespace namespace;
  bool found = false;

  String? fieldType(SimpleIdentifier receiver) {
    for (
      AstNode? ancestor = receiver.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is MethodDeclaration ||
          ancestor is FunctionExpression ||
          ancestor is ConstructorDeclaration) {
        final shadows = _Shadows(receiver.name);
        ancestor.accept(shadows);
        if (shadows.found) return null;
      }
      if (ancestor is FunctionExpression &&
          ancestor.parameters?.parameters.any(
                (p) => p.name?.lexeme == receiver.name,
              ) ==
              true) {
        return null;
      }
      if (ancestor is ClassDeclaration && ancestor.body is BlockClassBody) {
        for (final member in (ancestor.body as BlockClassBody).members) {
          if (member is MethodDeclaration &&
              member.isGetter &&
              member.name.lexeme == receiver.name) {
            return member.returnType is NamedType
                ? (member.returnType as NamedType).toSource().replaceAll(
                    '?',
                    '',
                  )
                : null;
          }
          if (member is FieldDeclaration) {
            for (final field in member.fields.variables) {
              if (field.name.lexeme != receiver.name) continue;
              if (member.fields.type is NamedType) {
                return (member.fields.type as NamedType).toSource().replaceAll(
                  '?',
                  '',
                );
              }
              final initial = field.initializer;
              if (initial is MethodInvocation &&
                  initial.target == null &&
                  namespace.unique(initial.methodName.name)?.node
                      is ClassDeclaration) {
                return initial.methodName.name;
              }
              if (initial is InstanceCreationExpression) {
                return initial.constructorName.type.toSource();
              }
            }
          }
        }
        return null;
      }
    }
    return null;
  }

  Expression? target(SimpleIdentifier node) => switch (node.parent) {
    MethodInvocation call when identical(call.methodName, node) =>
      call.realTarget,
    PropertyAccess access => access.realTarget,
    PrefixedIdentifier access => access.prefix,
    _ => null,
  };

  bool provenUnrelated(SimpleIdentifier node) {
    final receiver = target(node);
    if (receiver is SuperExpression) {
      for (
        AstNode? ancestor = node;
        ancestor != null;
        ancestor = ancestor.parent
      ) {
        if (ancestor is ClassDeclaration) {
          final type = ancestor.extendsClause?.superclass
              .toSource()
              .split('<')
              .first;
          return type != null && namespace.unrelated(type, node.name);
        }
      }
    }
    if (receiver is SimpleIdentifier) {
      // A homogeneous literal iteration retains the explicit field type; any
      // expression, spread, inferred value or local shadow remains unresolved.
      for (
        AstNode? ancestor = receiver;
        ancestor != null;
        ancestor = ancestor.parent
      ) {
        if (ancestor is ForStatement &&
            ancestor.forLoopParts is ForEachPartsWithDeclaration) {
          final loop = ancestor.forLoopParts as ForEachPartsWithDeclaration;
          if (loop.loopVariable.name.lexeme == receiver.name) {
            if (loop.iterable is! ListLiteral) return false;
            final values = (loop.iterable as ListLiteral).elements;
            final types = {
              for (final value in values)
                if (value is SimpleIdentifier) fieldType(value),
            };
            if (values.isNotEmpty &&
                values.every((value) => value is SimpleIdentifier) &&
                types.length == 1 &&
                !types.contains(null)) {
              return namespace.unrelated(types.single!, node.name);
            }
            return false;
          }
        }
      }
      final type = fieldType(receiver);
      if (type != null && namespace.unrelated(type, node.name)) return true;
      final shadow = _Shadows(receiver.name);
      unit.accept(shadow);
      if (shadow.found) return false;
      // Uri is an implicit dart:core declaration; imported/local homonyms and
      // aliases cannot use this proof.
      if (receiver.name == 'Uri' &&
          namespace.unique('Uri') == null &&
          node.name == 'parse') {
        return true;
      }
      final declaration = namespace.unique(receiver.name);
      if (declaration?.node is EnumDeclaration) return true;
      if (declaration?.node is ClassDeclaration &&
          namespace.unrelated(receiver.name, node.name)) {
        return true;
      }
    }
    if (node.name == 'copyWith' &&
        receiver is PropertyAccess &&
        receiver.propertyName.name == 'bodySmall' &&
        receiver.target is PropertyAccess) {
      final theme = receiver.target as PropertyAccess;
      final call = theme.target;
      if (theme.propertyName.name == 'textTheme' &&
          call is MethodInvocation &&
          call.methodName.name == 'of' &&
          call.target is SimpleIdentifier &&
          (call.target as SimpleIdentifier).name == 'Theme') {
        final shadow = _Shadows('Theme');
        unit.accept(shadow);
        if (!shadow.found && _themeFacts()) return true;
      }
    }
    return false;
  }

  // One finite rendering chain, checked against the actual framework namespace
  // and explicit member types. Casts, aliases, custom chains and unknown return
  // inference are not interpreted and require real resolution.
  bool _themeFacts() {
    bool field(String owner, String name, String type) {
      final declaration = namespace.unique(owner);
      final node = declaration?.node;
      if (node is! ClassDeclaration ||
          !namespace.unrelated(owner, 'copyWith') ||
          node.body is! BlockClassBody) {
        return false;
      }
      return (node.body as BlockClassBody).members
          .whereType<FieldDeclaration>()
          .any(
            (member) =>
                member.fields.type?.toSource().replaceAll('?', '') == type &&
                member.fields.variables.any(
                  (value) => value.name.lexeme == name,
                ),
          );
    }

    final theme = namespace.unique('Theme')?.node;
    return theme is ClassDeclaration &&
        namespace.unrelated('Theme', 'copyWith') &&
        theme.body is BlockClassBody &&
        (theme.body as BlockClassBody).members
            .whereType<MethodDeclaration>()
            .any(
              (method) =>
                  method.isStatic &&
                  method.name.lexeme == 'of' &&
                  method.returnType?.toSource() == 'ThemeData',
            ) &&
        field('ThemeData', 'textTheme', 'TextTheme') &&
        field('TextTheme', 'bodySmall', 'TextStyle') &&
        namespace.unrelated('TextStyle', 'copyWith');
  }

  bool passiveConstant(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent is! PrefixedIdentifier || !identical(parent.prefix, node)) {
      return false;
    }
    final shadows = _Shadows(node.name);
    unit.accept(shadows);
    if (shadows.found) return false;
    final declaration = namespace.unique(node.name)?.node;
    final body = declaration is ClassDeclaration ? declaration.body : null;
    if (body is! BlockClassBody) return false;
    final name = parent.identifier.name;
    if (_operationNames.contains(name)) return false;
    final members = body.members
        .where(
          (member) =>
              member is MethodDeclaration && member.name.lexeme == name ||
              member is ConstructorDeclaration && member.name?.lexeme == name ||
              member is FieldDeclaration &&
                  member.fields.variables.any(
                    (field) => field.name.lexeme == name,
                  ),
        )
        .toList();
    if (members.length != 1 || members.single is! FieldDeclaration) {
      return false;
    }
    final field = members.single as FieldDeclaration;
    final values = field.fields.variables
        .where((variable) => variable.name.lexeme == name)
        .toList();
    return field.isStatic &&
        field.fields.isConst &&
        values.length == 1 &&
        values.single.initializer is StringLiteral;
  }

  @override
  void visitConstructorName(ConstructorName node) {
    if (_constructorNames.contains(node.type.name.lexeme) ||
        namespace.aliases.contains(node.type.name.lexeme)) {
      found = true;
    }
    super.visitConstructorName(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext() &&
        node.parent is! Combinator &&
        node.parent is! Label &&
        node.inGetterContext()) {
      if (_constructorNames.contains(node.name) && !passiveConstant(node) ||
          node.name == _function ||
          namespace.aliases.contains(node.name)) {
        found = true;
      }
      if (_operationNames.contains(node.name) && !provenUnrelated(node)) {
        found = true;
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

class _Shadows extends RecursiveAstVisitor<void> {
  _Shadows(this.name);
  final String name;
  bool found = false;
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    if (node.name?.lexeme == name) found = true;
    super.visitSimpleFormalParameter(node);
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
  void visitTypeParameter(TypeParameter node) {
    if (node.name.lexeme == name) found = true;
    super.visitTypeParameter(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    if (node.exceptionParameter?.name.lexeme == name ||
        node.stackTraceParameter?.name.lexeme == name) {
      found = true;
    }
    super.visitCatchClause(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter && node.name.lexeme == name) found = true;
    super.visitMethodDeclaration(node);
  }
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.root, this.result, this.findings);
  final String root;
  final ResolvedUnitResult result;
  final List<Finding> findings;
  final _reported = <int>{};
  void _inspect(AstNode node, Element? raw) {
    final element = raw?.baseElement;
    if (element == null) return;
    final library = element.library?.firstFragment.source.fullName;
    if (library == null || !library.startsWith('$root/')) return;
    final path = library.substring(root.length + 1);
    final enclosing = element.enclosingElement;
    final owner = enclosing is InterfaceElement ? enclosing.name : null;
    final forbidden =
        element is ConstructorElement &&
            _constructors[path]?.contains(owner) == true ||
        element is MethodElement &&
            _methods[path]?[owner]?.contains(element.name) == true ||
        element is TopLevelFunctionElement &&
            path == _functionLibrary &&
            element.name == _function;
    if (forbidden && _reported.add(node.offset)) {
      findings.add(
        Finding(
          id,
          completedView,
          result.lineInfo.getLocation(node.offset).lineNumber,
          'setup-owner:${node.offset}',
          'Construct and verify connection candidates in ConnectionSetupSession; render typed state and invoke its commands here.',
        ),
      );
    }
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

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        !node.inDeclarationContext() &&
        node.parent is! Combinator) {
      if (_operationNames.contains(node.name) && node.element == null) {
        final parent = node.parent;
        if (!(node.name == 'call' &&
            parent is MethodInvocation &&
            parent.realTarget?.staticType is FunctionType)) {
          throw FormatException(
            'Unresolved setup operation ${node.name}; use a typed command',
          );
        }
      }
      _inspect(node, node.element);
    }
    super.visitSimpleIdentifier(node);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    var root = '.';
    String? sdk;
    final seen = <String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 == arguments.length ||
          !{'--root', '--sdk'}.contains(arguments[index]) ||
          !seen.add(arguments[index])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (arguments[index] == '--root') root = arguments[index + 1];
      if (arguments[index] == '--sdk') sdk = arguments[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdk);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
