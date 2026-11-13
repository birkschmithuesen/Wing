import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/source.dart' as uri_source;
import 'package:analyzer/src/generated/source.dart' show SourceFactory;

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_NOTIFICATION_JOURNAL_ACK';
const owner = 'lib/core/services/chat_notification_coordinator.dart';
const _mutators = {
  'setBool',
  'setInt',
  'setDouble',
  'setString',
  'setStringList',
  'remove',
  'clear',
};

Expression _unwrap(Expression expression) {
  while (true) {
    switch (expression) {
      case ParenthesizedExpression():
        expression = expression.expression;
      case AwaitExpression():
        expression = expression.expression;
      case AsExpression():
        expression = expression.expression;
      default:
        return expression;
    }
  }
}

bool _boolFuture(DartType? type) =>
    type is InterfaceType &&
    type.element.name == 'Future' &&
    type.element.library.uri.toString() == 'dart:async' &&
    type.typeArguments.singleOrNull is InterfaceType &&
    (type.typeArguments.single as InterfaceType).isDartCoreBool;
bool _voidResult(DartType? type) =>
    type is VoidType ||
    type is InterfaceType &&
        type.element.name == 'Future' &&
        type.element.library.uri.toString() == 'dart:async' &&
        type.typeArguments.singleOrNull is VoidType;

class _Bindings extends RecursiveAstVisitor<void> {
  final parsed = <String, List<Expression>>{};
  final memberParsed = <String, List<Expression>>{};
  final resolved = <Element, Expression>{};
  void add(
    String name,
    Element? element,
    Expression expression, {
    bool member = false,
  }) {
    parsed.putIfAbsent(name, () => []).add(expression);
    if (member) memberParsed.putIfAbsent(name, () => []).add(expression);
    if (element != null) resolved[element.baseElement] = expression;
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.initializer case final value?) {
      final declaration = node.parent?.parent;
      add(
        node.name.lexeme,
        node.declaredFragment?.element,
        value,
        member:
            declaration is FieldDeclaration ||
            declaration is TopLevelVariableDeclaration,
      );
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter && node.body is ExpressionFunctionBody) {
      add(
        node.name.lexeme,
        node.declaredFragment?.element,
        (node.body as ExpressionFunctionBody).expression,
        member: true,
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final body = node.functionExpression.body;
    if (node.isGetter && body is ExpressionFunctionBody) {
      add(
        node.name.lexeme,
        node.declaredFragment?.element,
        body.expression,
        member: true,
      );
    }
    super.visitFunctionDeclaration(node);
  }
}

class _Names extends RecursiveAstVisitor<void> {
  final names = <String>{};
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    names.add(node.name);
    super.visitSimpleIdentifier(node);
  }

  static Set<String> of(AstNode node) {
    final value = _Names();
    node.accept(value);
    return value.names;
  }
}

/// A deliberately stronger condition than lexical visibility: any competing
/// binding anywhere in the actual library keeps the receiver semantic.
class _ReceiverDeclarations extends GeneralizingAstVisitor<void> {
  final bindings = <String, List<AstNode>>{};
  void add(String? name, AstNode node) {
    if (name != null) bindings.putIfAbsent(name, () => []).add(node);
  }

  @override
  void visitDeclaration(Declaration node) {
    switch (node) {
      case VariableDeclaration():
        add(node.name.lexeme, node);
      case MethodDeclaration():
        add(node.name.lexeme, node);
      case FunctionDeclaration():
        add(node.name.lexeme, node);
      case EnumConstantDeclaration():
        add(node.name.lexeme, node);
    }
    super.visitDeclaration(node);
  }

  @override
  void visitFormalParameter(FormalParameter node) {
    add(node.name?.lexeme, node);
    super.visitFormalParameter(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    add(node.name.lexeme, node);
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    add(node.name.lexeme, node);
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    add(node.exceptionParameter?.name.lexeme, node);
    add(node.stackTraceParameter?.name.lexeme, node);
    super.visitCatchClause(node);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    add(node.name.lexeme, node);
    super.visitTypeParameter(node);
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    add(node.fieldName.name, node);
    super.visitConstructorFieldInitializer(node);
  }
}

Set<String> _literalMapReceivers(
  ClassDeclaration selected,
  Iterable<Source> library,
) {
  final bindings = _ReceiverDeclarations();
  for (final source in library) {
    source.ast.accept(bindings);
  }
  final names = <String>{};
  final body = selected.body;
  if (body is! BlockClassBody) return names;
  for (final field in body.members.whereType<FieldDeclaration>()) {
    if (!field.fields.isFinal || field.isStatic) continue;
    for (final variable in field.fields.variables) {
      final name = variable.name.lexeme;
      final literal = variable.initializer;
      if (!name.startsWith('_') || literal is! SetOrMapLiteral) continue;
      // No calls, casts, aliases or mutable references establish this proof.
      // An empty literal can also be contextually a set; neither language
      // collection can implement a SharedPreferences mutator. Contents may
      // change, while the final private receiver cannot be replaced.
      if (bindings.bindings[name] case final declarations?) {
        if (declarations.length == 1 &&
            identical(declarations.single, variable)) {
          names.add(name);
        }
      }
    }
  }
  return names;
}

bool _literalMapOperation(Expression expression, Set<String> fields) {
  expression = _unwrap(expression);
  if (expression is! MethodInvocation ||
      !{'clear', 'remove'}.contains(expression.methodName.name)) {
    return false;
  }
  Expression? receiver = expression.target;
  if (expression.isCascaded) {
    receiver = expression.thisOrAncestorOfType<CascadeExpression>()?.target;
  }
  if (receiver is SimpleIdentifier) return fields.contains(receiver.name);
  return receiver is PropertyAccess &&
      receiver.target is ThisExpression &&
      fields.contains(receiver.propertyName.name);
}

bool _possibleOrigin(
  Expression expression,
  Set<String> names,
  Set<String> members,
) {
  expression = _unwrap(expression);
  // Exactly the shapes followed by the resolved origin walk. Argument and
  // closure bodies receive their own independent visitor sites below.
  return switch (expression) {
    MethodInvocation() =>
      (expression.target == null ? names : members).contains(
            expression.methodName.name,
          ) ||
          expression.methodName.name == 'call' &&
              expression.target != null &&
              _possibleOrigin(expression.target!, names, members),
    FunctionExpressionInvocation() => _possibleOrigin(
      expression.function,
      names,
      members,
    ),
    SimpleIdentifier() => names.contains(expression.name),
    PrefixedIdentifier() => members.contains(expression.identifier.name),
    PropertyAccess() => members.contains(expression.propertyName.name),
    _ => false,
  };
}

class _Discards extends RecursiveAstVisitor<void> {
  _Discards(this.names, {Set<String>? members, this.literalMaps = const {}})
    : members = members ?? names;
  final Set<String> names;
  final Set<String> members;
  final Set<String> literalMaps;
  final sites = <({Expression expression, bool statement})>[];
  void add(Expression expression, bool statement) {
    // The receiver returned by a cascade is not the section's ACK. Direct
    // sections are visited independently, including nested argument cascades.
    if (_unwrap(expression) is CascadeExpression) return;
    if (!_literalMapOperation(expression, literalMaps) &&
        _possibleOrigin(expression, names, members)) {
      sites.add((expression: expression, statement: statement));
    }
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    add(node.expression, true);
    super.visitExpressionStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    add(node.expression, false);
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final value?) add(value, false);
    super.visitReturnStatement(node);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    // Each directly invoked section discards its result even when the cascade
    // itself is retained or returned as the receiver.
    for (final section in node.cascadeSections) {
      if (section is MethodInvocation) add(section, true);
    }
    super.visitCascadeExpression(node);
  }
}

ClassDeclaration _class(Snapshot snapshot) {
  final values = snapshot.sources.values
      .where((s) => snapshot.libraries[s.path] == owner)
      .expand((s) => s.ast.declarations)
      .whereType<ClassDeclaration>()
      .where((s) => s.namePart.typeName.lexeme == 'ChatNotificationCoordinator')
      .toList();
  if (values.length != 1) {
    throw const FormatException('One canonical coordinator is required');
  }
  return values.single;
}

void _namespace(
  Snapshot snapshot,
  String library,
  uri_source.Source origin,
  SourceFactory factory,
  Set<String> seen,
) {
  if (!seen.add('$library\u0000${origin.uri}')) return;
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.whereType<PartOfDirective>().isNotEmpty ||
      !origin.exists() ||
      File(origin.fullName).resolveSymbolicLinksSync() !=
          File('${snapshot.root}/$library').resolveSymbolicLinksSync()) {
    throw const FormatException('Invalid containing namespace');
  }
  for (final directive in source.ast.directives.whereType<PartDirective>()) {
    final text = directive.uri.stringValue;
    final actual = text == null ? null : factory.resolveUri(origin, text);
    if (actual == null || !actual.exists()) {
      throw const FormatException('Missing actual part namespace');
    }
    final path = File(actual.fullName).resolveSymbolicLinksSync();
    if (!path.startsWith('${snapshot.root}/') ||
        !source.partTargets.contains(
          path.substring(snapshot.root.length + 1),
        )) {
      throw const FormatException('Part disagrees with parsed ownership');
    }
    final part = snapshot.sources[path.substring(snapshot.root.length + 1)];
    final reciprocal = part?.ast.directives
        .whereType<PartOfDirective>()
        .singleOrNull;
    if (reciprocal?.uri case final uri?) {
      final text = uri.stringValue;
      final containing = text == null ? null : factory.resolveUri(actual, text);
      if (containing == null ||
          !containing.exists() ||
          File(containing.fullName).resolveSymbolicLinksSync() !=
              File(origin.fullName).resolveSymbolicLinksSync()) {
        throw const FormatException('Invalid reciprocal part namespace');
      }
    }
  }
  for (final path in source.partTargets) {
    final part = snapshot.sources[path];
    if (part == null ||
        part.ast.directives.length != 1 ||
        snapshot.partOwners[path]?.length != 1 ||
        snapshot.partOwners[path]?.single != library ||
        (part.partOf != library && !part.namedPartOf)) {
      throw const FormatException('Invalid part ownership');
    }
    if (part.namedPartOf) {
      final name = source.ast.directives
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
        throw const FormatException('Invalid named part ownership');
      }
    }
  }
  for (final directive
      in source.ast.directives.whereType<NamespaceDirective>()) {
    if (directive.configurations.isNotEmpty) {
      throw const FormatException('Conditional authored namespace unsupported');
    }
    final text = directive.uri.stringValue;
    final target = text == null ? null : factory.resolveUri(origin, text);
    if (target == null || !target.exists()) {
      throw const FormatException('Missing actual namespace');
    }
    if (target.uri.scheme == 'dart') continue;
    final path = File(target.fullName).resolveSymbolicLinksSync();
    if (path.startsWith('${snapshot.root}/')) {
      _namespace(
        snapshot,
        path.substring(snapshot.root.length + 1),
        target,
        factory,
        seen,
      );
    } else if (target.uri.scheme != 'package' &&
        !{'package', 'dart'}.contains(factory.pathToUri(path)?.scheme)) {
      throw const FormatException(
        'External authored file namespace unsupported',
      );
    }
  }
}

DartType? _returnType(Expression expression) {
  for (AstNode? node = expression.parent; node != null; node = node.parent) {
    if (node is FunctionExpression) {
      final type = node.staticType;
      return type is FunctionType ? type.returnType : null;
    }
    if (node is MethodDeclaration) {
      return node.declaredFragment?.element.returnType;
    }
    if (node is FunctionDeclaration) {
      return node.declaredFragment?.element.returnType;
    }
  }
  return null;
}

Future<List<Finding>> check(
  Directory directory, {
  String? sdkPath,
  String? rolesPath,
}) async {
  final root = directory.resolveSymbolicLinksSync();
  final sdk = dartSdkPath(root, configured: sdkPath);
  final snapshot = Snapshot.load(
    root,
    rolesPath ?? '$root/tools/architecture/roles.json',
  );
  final selected = _class(snapshot);
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: ['$root/$owner'],
    cacheNamespace: 'notification-journal-ack',
  );
  try {
    final context = contexts.contextFor('$root/$owner');
    final factory = context.driver.sourceFactory;
    final originUri = factory.pathToUri('$root/$owner');
    final origin = originUri == null ? null : factory.forUri2(originUri);
    if (origin == null) {
      throw const FormatException('Missing coordinator namespace');
    }
    final namespaces = <String>{};
    _namespace(snapshot, owner, origin, factory, namespaces);
    final reachable = namespaces
        .map((key) => key.split('\u0000').first)
        .toSet();
    final sources = snapshot.sources.values
        .where((source) => reachable.contains(snapshot.libraries[source.path]))
        .toList();
    final parsedBindings = _Bindings();
    for (final source in sources) {
      source.ast.accept(parsedBindings);
    }
    final names = {..._mutators};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in parsedBindings.parsed.entries) {
        if (!names.contains(entry.key) &&
            entry.value.any((value) => _Names.of(value).any(names.contains))) {
          changed = names.add(entry.key) || changed;
        }
      }
    }
    // A local alias can be used bare, but never as another object's member or
    // import prefix's top-level declaration. Keep separate finite vocabularies.
    final members = {..._mutators};
    for (final entry in parsedBindings.memberParsed.entries) {
      if (entry.value.any((value) => _Names.of(value).any(names.contains))) {
        members.add(entry.key);
      }
    }
    final literalMaps = _literalMapReceivers(
      selected,
      snapshot.sources.values.where(
        (source) => snapshot.libraries[source.path] == owner,
      ),
    );
    final candidates = _Discards(
      names,
      members: members,
      literalMaps: literalMaps,
    );
    selected.accept(candidates);
    if (candidates.sites.isEmpty) return [];
    final session = context.currentSession;
    final library = await session.getResolvedLibrary('$root/$owner');
    if (library is! ResolvedLibraryResult) {
      throw const FormatException('Cannot resolve coordinator');
    }
    void validate(ResolvedLibraryResult result) {
      if (result.units.any(
        (u) =>
            u.diagnostics.any((d) => d.diagnosticCode.severity.name == 'ERROR'),
      )) {
        throw const FormatException('Unresolved ACK candidate');
      }
    }

    validate(library);
    final bindings = _Bindings();
    for (final unit in library.units) {
      unit.unit.accept(bindings);
    }
    final resolvedLibraries = {owner};
    for (final source in sources) {
      if (resolvedLibraries.contains(snapshot.libraries[source.path])) {
        continue;
      }
      final ownBindings = _Bindings();
      source.ast.accept(ownBindings);
      if (!ownBindings.parsed.keys.any(names.contains)) continue;
      final other = await session.getResolvedLibrary(
        '${snapshot.root}/${snapshot.libraries[source.path]}',
      );
      if (other is! ResolvedLibraryResult) {
        throw const FormatException('Cannot resolve ACK alias');
      }
      validate(other);
      resolvedLibraries.add(snapshot.libraries[source.path]!);
      for (final unit in other.units) {
        unit.unit.accept(bindings);
      }
    }
    final canonical = factory.forUri(
      'package:shared_preferences/src/shared_preferences_legacy.dart',
    );
    if (canonical == null || !canonical.exists()) {
      throw const FormatException('Canonical preferences declaration missing');
    }
    final canonicalPath = File(canonical.fullName).resolveSymbolicLinksSync();
    bool originOf(Expression expression, Set<Element> visiting) {
      expression = _unwrap(expression);
      Element? element;
      switch (expression) {
        case MethodInvocation():
          element = expression.methodName.element;
          if (expression.methodName.name == 'call' &&
              expression.target != null) {
            return originOf(expression.target!, visiting);
          }
        case FunctionExpressionInvocation():
          return originOf(expression.function, visiting);
        case SimpleIdentifier():
          element = expression.element;
        case PrefixedIdentifier():
          element = expression.identifier.element;
        case PropertyAccess():
          element = expression.propertyName.element;
        default:
          return false;
      }
      element = element?.baseElement;
      if (element == null) {
        if (_Names.of(expression).any(_mutators.contains)) {
          throw const FormatException('Unknown mutation receiver');
        }
        return false;
      }
      if (element is MethodElement &&
          _mutators.contains(element.name) &&
          element.enclosingElement?.name == 'SharedPreferences' &&
          File(
                element.library.firstFragment.source.fullName,
              ).resolveSymbolicLinksSync() ==
              canonicalPath) {
        return true;
      }
      final variable = element is PropertyAccessorElement
          ? element.variable.baseElement
          : element;
      final binding = bindings.resolved[element] ?? bindings.resolved[variable];
      if (binding == null || !visiting.add(variable)) {
        return false;
      }
      if (variable is VariableElement &&
          !variable.isFinal &&
          !variable.isConst &&
          (element is VariableElement || bindings.resolved[element] == null)) {
        throw const FormatException('Mutable ACK alias is unproven');
      }
      final found = originOf(binding, visiting);
      visiting.remove(variable);
      return found;
    }

    final findings = <Finding>[];
    for (final unit in library.units) {
      final classes = unit.unit.declarations
          .whereType<ClassDeclaration>()
          .where(
            (c) => c.namePart.typeName.lexeme == 'ChatNotificationCoordinator',
          );
      for (final declaration in classes) {
        final discards = _Discards(names);
        declaration.accept(discards);
        for (final site in discards.sites) {
          final expression = _unwrap(site.expression);
          if (!_boolFuture(expression.staticType) &&
              expression.staticType is! DynamicType) {
            continue;
          }
          if (!originOf(expression, {})) {
            continue;
          }
          if (!site.statement && !_voidResult(_returnType(site.expression))) {
            continue;
          }
          findings.add(
            Finding(
              id,
              unit.path.substring(root.length + 1),
              unit.lineInfo.getLocation(site.expression.offset).lineNumber,
              'discarded-ack:${site.expression.offset}',
              'Check or preserve the boolean journal storage acknowledgment before reporting settlement.',
            ),
          );
        }
      }
    }
    return findings..sort();
  } finally {
    await contexts.dispose();
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = '.';
    String? sdk, roles;
    var json = false;
    final seen = <String>{};
    for (var i = 0; i < args.length; i++) {
      final option = args[i];
      if (!seen.add(option)) throw const FormatException('Duplicate argument');
      if (option == '--json') {
        json = true;
        continue;
      }
      if (!{'--root', '--sdk', '--roles'}.contains(option) ||
          i + 1 == args.length) {
        throw const FormatException('Invalid argument');
      }
      final value = args[++i];
      switch (option) {
        case '--root':
          root = value;
        case '--sdk':
          sdk = value;
        case '--roles':
          roles = value;
      }
    }
    final findings = await check(
      Directory(root),
      sdkPath: sdk,
      rolesPath: roles,
    );
    if (json) {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'findings': findings.map((f) => f.toJson()).toList(),
        }),
      );
    } else {
      findings.forEach(stdout.writeln);
    }
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '[$id INPUT] Invalid namespace, ownership, SDK or ACK candidate.',
    );
    exitCode = 2;
  }
}
