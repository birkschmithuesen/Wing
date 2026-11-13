import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../cli.dart' as cli;
import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_WORKSPACE_ENTRY_KEY_OWNER';
const codec = 'lib/core/models/workspace_entry.dart';
const owner = 'lib/core/services/app_preferences.dart';
const storageKey = 'last_connection_id';
const preferenceLibrary =
    'package:shared_preferences/src/shared_preferences_legacy.dart';
const keyedMethods = {
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
};

Expression _unwrapped(Expression expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}

String? _name(Expression expression) => switch (_unwrapped(expression)) {
  SimpleIdentifier node => node.name,
  PrefixedIdentifier node => node.identifier.name,
  PropertyAccess node => node.propertyName.name,
  _ => null,
};

Set<String> _keyNames(Snapshot snapshot) {
  final declarations = _ConstNames();
  for (final source in snapshot.sources.values) {
    source.ast.accept(declarations);
  }
  final names = <String>{};
  var grew = true;
  while (grew) {
    grew = false;
    for (final entry in declarations.values.entries) {
      if (names.contains(entry.key)) continue;
      if (entry.value.any(
        (value) =>
            value is StringLiteral && value.stringValue == storageKey ||
            names.contains(_name(value)),
      )) {
        grew = names.add(entry.key) || grew;
      }
    }
  }
  return names;
}

class _ConstNames extends RecursiveAstVisitor<void> {
  final values = <String, List<Expression>>{};
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final parent = node.parent;
    final initializer = node.initializer;
    if (parent is VariableDeclarationList &&
        parent.isConst &&
        initializer != null) {
      values
          .putIfAbsent(node.name.lexeme, () => [])
          .add(_unwrapped(initializer));
    }
    super.visitVariableDeclaration(node);
  }
}

Expression? _keyArgument(MethodInvocation node, Set<String> names) {
  if (!keyedMethods.contains(node.methodName.name) ||
      node.argumentList.arguments.isEmpty) {
    return null;
  }
  final argument = _unwrapped(node.argumentList.arguments.first);
  return argument is StringLiteral && argument.stringValue == storageKey ||
          names.contains(_name(argument))
      ? argument
      : null;
}

bool _keyAccess(SimpleIdentifier node) =>
    node.name == 'storageKey' &&
    !node.inDeclarationContext() &&
    node.parent is! Combinator &&
    node.inGetterContext();

void _validateParts(Snapshot snapshot, String library) {
  final containing = snapshot.sources[library];
  if (containing == null) {
    throw const FormatException('Missing containing library');
  }
  for (final path in containing.partTargets) {
    final part = snapshot.sources[path];
    final owners = snapshot.partOwners[path];
    if (part == null ||
        owners == null ||
        owners.length != 1 ||
        owners.single != library ||
        (part.partOf != library && !part.namedPartOf)) {
      throw const FormatException('Invalid actual key part ownership');
    }
    if (part.namedPartOf) {
      final names = containing.ast.directives
          .whereType<LibraryDirective>()
          .map((node) => node.name?.toSource())
          .toList();
      final partNames = part.ast.directives
          .whereType<PartOfDirective>()
          .map((node) => node.libraryName?.toSource())
          .toList();
      if (names.length != 1 ||
          partNames.length != 1 ||
          names.single == null ||
          names.single != partNames.single) {
        throw const FormatException('Invalid named key part ownership');
      }
    }
  }
}

Future<List<Finding>> check(Snapshot snapshot, {String? sdkPath}) async {
  for (final entry in {
    codec: 'WorkspaceEntryCodec',
    owner: 'AppPreferences',
  }.entries) {
    _validateParts(snapshot, entry.key);
    if (!snapshot.sources.containsKey(entry.key) ||
        snapshot.libraries[entry.key] != entry.key ||
        snapshot.sources.values
                .where((source) => snapshot.libraries[source.path] == entry.key)
                .expand(
                  (source) =>
                      source.ast.declarations.whereType<ClassDeclaration>(),
                )
                .where((node) => node.namePart.typeName.lexeme == entry.value)
                .length !=
            1) {
      throw FormatException('Missing/ambiguous key authority: ${entry.key}');
    }
  }
  final codecClass = snapshot.sources[codec]!.ast.declarations
      .whereType<ClassDeclaration>()
      .singleWhere(
        (node) => node.namePart.typeName.lexeme == 'WorkspaceEntryCodec',
      );
  if (codecClass.body is! BlockClassBody ||
      (codecClass.body as BlockClassBody).members
              .whereType<FieldDeclaration>()
              .where(
                (field) =>
                    field.isStatic &&
                    field.fields.isConst &&
                    field.fields.variables.any(
                      (variable) =>
                          variable.name.lexeme == 'storageKey' &&
                          variable.initializer is StringLiteral &&
                          (variable.initializer as StringLiteral).stringValue ==
                              storageKey,
                    ),
              )
              .length !=
          1) {
    throw const FormatException('Missing canonical remembered-entry key');
  }
  final names = _keyNames(snapshot);
  final selected = <Source>[];
  for (final source in snapshot.sources.values) {
    if (!source.path.startsWith('lib/') ||
        snapshot.libraries[source.path] == owner) {
      continue;
    }
    final visitor = _Candidates(names);
    source.ast.accept(visitor);
    if (visitor.found) selected.add(source);
  }
  if (selected.isEmpty) return [];
  for (final source in selected) {
    final library = snapshot.libraries[source.path]!;
    _validateParts(snapshot, library);
    final closure = {library, ...snapshot.reachable(library)};
    if (snapshot.sources.values.any(
      (unit) =>
          closure.contains(snapshot.libraries[unit.path]) &&
          unit.ast.directives.whereType<NamespaceDirective>().any(
            (node) => node.configurations.isNotEmpty,
          ),
    )) {
      throw const FormatException('Conditional key provenance is unsupported');
    }
  }
  final root = snapshot.root;
  final contexts = semanticContextCollection(
    root: root,
    sdk: dartSdkPath(root, configured: sdkPath),
    includedPaths: [root],
    cacheNamespace: 'workspace-entry-key-owner',
  );
  final findings = <Finding>[];
  final libraries = <String, ResolvedLibraryResult>{};
  try {
    for (final source in selected) {
      final library = snapshot.libraries[source.path]!;
      var resolved = libraries[library];
      if (resolved == null) {
        final path = '$root/$library';
        final result = await contexts
            .contextFor(path)
            .currentSession
            .getResolvedLibrary(path);
        if (result is! ResolvedLibraryResult) {
          throw const FormatException('Key namespace cannot resolve');
        }
        resolved = result;
        libraries[library] = resolved;
      }
      final units = resolved.units
          .where((unit) => unit.path == '$root/${source.path}')
          .toList();
      if (units.length != 1) {
        throw const FormatException('Key unit cannot resolve');
      }
      units.single.unit.accept(_Resolved(source, root, findings, names));
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.names);
  final Set<String> names;
  bool found = false;
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_keyAccess(node)) found = true;
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_keyArgument(node, names) != null) found = true;
    super.visitMethodInvocation(node);
  }
}

Element? _expressionElement(Expression expression) => switch (expression) {
  SimpleIdentifier node => node.element?.baseElement,
  PrefixedIdentifier node => node.identifier.element?.baseElement,
  PropertyAccess node => node.propertyName.element?.baseElement,
  _ => null,
};

Element? _variable(Element? element) =>
    element is PropertyAccessorElement ? element.variable.baseElement : element;

String? _constantKey(Expression expression) {
  if (expression is StringLiteral) return expression.stringValue;
  final element = _variable(_expressionElement(expression));
  return element is VariableElement && element.isConst
      ? element.computeConstantValue()?.toStringValue()
      : null;
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.source, this.root, this.findings, this.names);
  final Source source;
  final String root;
  final List<Finding> findings;
  final Set<String> names;

  void reject(AstNode node, String subject) => findings.add(
    Finding(
      id,
      source.path,
      source.lineAt(node.offset),
      '$subject@${node.offset}',
      'Keep the remembered instance key in the shared AppPreferences owner; use typed workspace-entry observations and commands.',
    ),
  );

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_keyAccess(node)) {
      final element = _variable(node.element?.baseElement);
      if (element == null) {
        throw const FormatException('Unresolved key capture');
      }
      if (element.name == 'storageKey' &&
          element.enclosingElement?.name == 'WorkspaceEntryCodec' &&
          element.library?.firstFragment.source.fullName == '$root/$codec') {
        reject(node, 'WorkspaceEntryCodec.storageKey');
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final argument = _keyArgument(node, names);
    if (argument != null && _constantKey(argument) == storageKey) {
      final element = node.methodName.element?.baseElement;
      if (element == null) {
        throw const FormatException('Unresolved key operation');
      }
      if (element is MethodElement &&
          element.enclosingElement?.name == 'SharedPreferences' &&
          element.library.uri.toString() == preferenceLibrary) {
        reject(node.methodName, 'SharedPreferences.${element.name}');
      }
    }
    super.visitMethodInvocation(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
