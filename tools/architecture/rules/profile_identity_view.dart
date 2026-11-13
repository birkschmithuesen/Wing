import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:yaml/yaml.dart' as yaml;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../dart_sdk.dart';
import '../lexical_bindings.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_PROFILE_IDENTITY_VIEW';
const view = 'lib/core/screens/administration/admin_identity_page.dart';
const session = 'lib/core/services/profile_identity_edit_session.dart';
const model = 'lib/core/models/profile_identity_edit.dart';
const authorities = {
  'lib/core/services/administration_repository.dart': null,
  'lib/core/services/profile_gateway.dart': null,
  'lib/core/services/profiles_repository.dart': null,
  'lib/core/services/profile_identity_repository.dart': null,
  'lib/core/services/remote_files_client.dart': null,
  'lib/core/services/connection_manager.dart': {'DashboardClient'},
  model: {
    'ProfileIdentityEditIntent',
    'ProfileIdentityObservation',
    'ProfileIdentityEditResolution',
    'ProfileIdentityFieldResult',
    'ProfileIdentitySaveResult',
    'normalizeProfileIdentityText',
    'validateProfileIdentityText',
  },
};
const _codecNames = {
  'jsonDecode',
  'jsonEncode',
  'JsonCodec',
  'JsonDecoder',
  'JsonEncoder',
  'json',
  'Utf8Codec',
  'Utf8Encoder',
  'Utf8Decoder',
  'Base64Codec',
  'Base64Encoder',
  'Base64Decoder',
  'base64',
  'base64Decode',
  'base64Encode',
  'utf8',
  'decode',
  'encode',
  'loadYaml',
  'loadYamlDocument',
  'loadYamlStream',
  'YamlMap',
  'YamlList',
  'YamlNode',
  'YamlScalar',
  'YamlException',
  'wrapAsYamlNode',
  'File',
  'readAsString',
  'readAsBytes',
};

void _validate(Snapshot snapshot, String library) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.whereType<PartOfDirective>().isNotEmpty) {
    throw const FormatException('Containing identity library missing');
  }
  for (final directive in source.ast.directives.whereType<PartDirective>()) {
    final uri = directive.uri.stringValue;
    if (uri == null) throw const FormatException('Unknown identity part URI');
    final target = File('${snapshot.root}/$library').uri.resolve(uri);
    final path = File.fromUri(target).absolute.path;
    if (!path.startsWith('${snapshot.root}/') ||
        !source.partTargets.contains(
          path.substring(snapshot.root.length + 1),
        )) {
      throw const FormatException(
        'Actual identity part outside parsed ownership',
      );
    }
  }
  for (final path in source.partTargets) {
    final part = snapshot.sources[path];
    if (part == null ||
        snapshot.partOwners[path]?.length != 1 ||
        snapshot.partOwners[path]?.single != library ||
        (part.partOf != library && !part.namedPartOf)) {
      throw const FormatException('Invalid identity part ownership');
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
        throw const FormatException('Mismatched named identity part');
      }
    }
  }
}

Set<String> _names(Snapshot snapshot, Set<String> codecs) {
  final result = {
    ..._codecNames,
    ...codecs,
    'profile',
    'ProfileIdentityEditSession',
  };
  for (final source in snapshot.sources.values) {
    final selected = authorities[snapshot.libraries[source.path]];
    if (!authorities.containsKey(snapshot.libraries[source.path])) continue;
    for (final declaration in source.ast.declarations) {
      final name = switch (declaration) {
        ClassDeclaration d => d.namePart.typeName.lexeme,
        FunctionDeclaration d => d.name.lexeme,
        _ => null,
      };
      if (selected != null && !selected.contains(name)) continue;
      declaration.accept(_Vocabulary(result));
    }
  }
  // A public owner member returning a raw authority must remain a candidate
  // even when its name is new and no raw type appears in the view.
  for (final source in snapshot.sources.values.where(
    (s) => snapshot.libraries[s.path] == session,
  )) {
    for (final declaration in source.ast.declarations) {
      declaration.accept(_Vocabulary(result));
    }
  }
  // Alias chains may introduce any spelling into a selected library through a
  // barrel or part. Identity still comes from resolved constructors/types.
  var changed = true;
  while (changed) {
    changed = false;
    for (final source in snapshot.sources.values) {
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        if (alias.type case NamedType type
            when result.contains(type.name.lexeme)) {
          changed = result.add(alias.name.lexeme) || changed;
        }
      }
    }
  }
  return result;
}

class _Vocabulary extends RecursiveAstVisitor<void> {
  _Vocabulary(this.names);
  final Set<String> names;
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    names.add(node.namePart.typeName.lexeme);
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    names.add(node.namePart.typeName.lexeme);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    names.add(node.name.lexeme);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    names.add(node.name.lexeme);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    if (node.name != null) names.add(node.name!.lexeme);
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    names.add(node.primaryConstructor.typeName.lexeme);
    super.visitExtensionTypeDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    names.add(node.name.lexeme);
    super.visitClassTypeAlias(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    names.add(node.name.lexeme);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    names.add(node.name.lexeme);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.parent?.parent is FieldDeclaration ||
        node.parent?.parent is TopLevelVariableDeclaration) {
      names.add(node.name.lexeme);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    names.add(node.name.lexeme);
    super.visitGenericTypeAlias(node);
  }
}

bool _access(SimpleIdentifier node) =>
    !node.inDeclarationContext() &&
    node.parent is! Combinator &&
    node.parent is! Label &&
    node.parent is! NamedType;

// This is a finite declaration proof for presentation facts, not expression
// inference. Unknown aliases, inheritance and inferred receiver types resolve.
class _PassiveDeclaration {
  const _PassiveDeclaration(this.library, this.node);
  final String library;
  final CompilationUnitMember node;
}

class _PassiveProof {
  _PassiveProof(this.snapshot, this.packages, this.source);
  final Snapshot snapshot;
  final Map<String, Uri> packages;
  final Source source;
  final _exports = <(String, String), List<_PassiveDeclaration>>{};
  final _visible = <(String, String), List<_PassiveDeclaration>>{};
  final _shadows = <String, List<AstNode>>{};
  static const _passive = {
    session: {
      'ProfileIdentityEditSession',
      'ProfileIdentityEditState',
      'ProfileIdentityFieldState',
      'ProfileIdentityCloseDecision',
      'ProfileIdentitySaveOutcome',
    },
    model: {'ProfileIdentityField'},
  };

  bool _allows(Iterable<Combinator> values, String name) => values.every(
    (value) => switch (value) {
      ShowCombinator show => show.shownNames.any((n) => n.name == name),
      HideCombinator hide => !hide.hiddenNames.any((n) => n.name == name),
    },
  );

  String? _target(String path, String value) {
    final uri = Uri.parse(value);
    final Uri target;
    if (uri.scheme == 'package') {
      final base = packages[uri.pathSegments.first];
      if (base == null) return null;
      target = base.resolve(uri.pathSegments.skip(1).join('/'));
    } else if (uri.scheme == 'dart') {
      return null;
    } else {
      target = File('${snapshot.root}/$path').uri.resolveUri(uri);
    }
    if (target.scheme != 'file') return null;
    final absolute = File.fromUri(target).absolute.path;
    if (!absolute.startsWith('${snapshot.root}/')) return null;
    final relative = absolute.substring(snapshot.root.length + 1);
    return snapshot.libraries[relative];
  }

  Iterable<_PassiveDeclaration> _local(String library, String name) sync* {
    for (final unit in snapshot.sources.values.where(
      (s) => snapshot.libraries[s.path] == library,
    )) {
      for (final declaration in unit.ast.declarations) {
        final names = switch (declaration) {
          ClassDeclaration d => [d.namePart.typeName.lexeme],
          EnumDeclaration d => [d.namePart.typeName.lexeme],
          MixinDeclaration d => [d.name.lexeme],
          ExtensionDeclaration d => [if (d.name != null) d.name!.lexeme],
          ExtensionTypeDeclaration d => [d.primaryConstructor.typeName.lexeme],
          ClassTypeAlias d => [d.name.lexeme],
          GenericTypeAlias d => [d.name.lexeme],
          FunctionTypeAlias d => [d.name.lexeme],
          FunctionDeclaration d => [d.name.lexeme],
          TopLevelVariableDeclaration d => d.variables.variables.map(
            (v) => v.name.lexeme,
          ),
          _ => <String>[],
        };
        if (names.contains(name)) {
          yield _PassiveDeclaration(library, declaration);
        }
      }
    }
  }

  List<_PassiveDeclaration> _exported(String library, String name) =>
      _exports.putIfAbsent((library, name), () {
        final result = <_PassiveDeclaration>[];
        final seen = <String>{};
        final pending = [library];
        while (pending.isNotEmpty) {
          final current = pending.removeLast();
          if (!seen.add(current)) continue;
          result.addAll(_local(current, name));
          for (final unit in snapshot.sources.values.where(
            (s) => snapshot.libraries[s.path] == current,
          )) {
            for (final directive
                in unit.ast.directives.whereType<ExportDirective>()) {
              if (!_allows(directive.combinators, name)) continue;
              final target = _target(unit.path, directive.uri.stringValue!);
              if (target != null) pending.add(target);
            }
          }
        }
        return result;
      });

  List<_PassiveDeclaration> _namespace(String name, [String library = view]) =>
      _visible.putIfAbsent((library, name), () {
        final dot = name.indexOf('.');
        final prefix = dot < 0 ? null : name.substring(0, dot);
        final simple = dot < 0 ? name : name.substring(dot + 1);
        final local = prefix == null ? _local(library, simple).toList() : null;
        if (local?.isNotEmpty == true) return local!;
        final result = <_PassiveDeclaration>[];
        for (final unit in snapshot.sources.values.where(
          (s) => snapshot.libraries[s.path] == library,
        )) {
          for (final directive
              in unit.ast.directives.whereType<ImportDirective>()) {
            if (directive.prefix?.name != prefix ||
                !_allows(directive.combinators, simple)) {
              continue;
            }
            final target = _target(unit.path, directive.uri.stringValue!);
            if (target == null) continue;
            for (final declaration in _exported(target, simple)) {
              if (!result.any((d) => identical(d.node, declaration.node))) {
                result.add(declaration);
              }
            }
          }
        }
        return result;
      });

  List<AstNode> _bindings(String name) => _shadows.putIfAbsent(name, () {
    final visitor = _BindingDeclarations(name);
    for (final unit in snapshot.sources.values.where(
      (s) => snapshot.libraries[s.path] == view,
    )) {
      unit.ast.accept(visitor);
    }
    return visitor.nodes;
  });

  _PassiveDeclaration? _type(NamedType type) {
    final name =
        '${type.importPrefix?.name ?? ''}'
        '${type.importPrefix == null ? '' : '.'}${type.name.lexeme}';
    if (_bindings(name.split('.').first).isNotEmpty) return null;
    final candidates = _namespace(name);
    if (candidates.length != 1) return null;
    final declaration = candidates.single;
    return type.typeArguments == null &&
            !(declaration.node is ClassDeclaration &&
                (declaration.node as ClassDeclaration)
                        .namePart
                        .typeParameters !=
                    null) &&
            _passive[declaration.library]?.contains(type.name.lexeme) == true &&
            (declaration.node is ClassDeclaration ||
                declaration.node is EnumDeclaration)
        ? declaration
        : null;
  }

  bool passiveType(NamedType type) => _type(type) != null;

  ClassDeclaration? _class(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is ClassDeclaration) return parent;
    }
    return null;
  }

  AstNode? _own(SimpleIdentifier node) {
    final body = _class(node)?.body;
    if (body is! BlockClassBody) return null;
    final declarations = <AstNode>[];
    for (final member in body.members) {
      if (member is FieldDeclaration) {
        declarations.addAll(
          member.fields.variables.where((v) => v.name.lexeme == node.name),
        );
      } else if (member is MethodDeclaration &&
          member.name.lexeme == node.name) {
        declarations.add(member);
      }
    }
    if (declarations.length != 1) return null;
    final declaration = declarations.single;
    return _bindings(node.name).every((d) => identical(d, declaration))
        ? declaration
        : null;
  }

  _PassiveDeclaration? _receiver(Expression node) {
    if (node is ParenthesizedExpression) return _receiver(node.expression);
    if (node is SimpleIdentifier) {
      final own = _own(node);
      final annotation = switch (own) {
        VariableDeclaration v => (v.parent as VariableDeclarationList).type,
        MethodDeclaration m when m.isGetter => m.returnType,
        _ => null,
      };
      if (annotation is NamedType) return _type(annotation);
      // Only an explicitly typed formal parameter can add another receiver.
      final bindings = _bindings(node.name);
      if (bindings.length == 1 && bindings.single is SimpleFormalParameter) {
        final parameter = bindings.single as SimpleFormalParameter;
        for (
          AstNode? parent = node.parent;
          parent != null;
          parent = parent.parent
        ) {
          if (identical(parent, parameter.parent?.parent)) {
            return parameter.type is NamedType
                ? _type(parameter.type as NamedType)
                : null;
          }
        }
      }
      if (bindings.length == 1 && bindings.single is VariableDeclaration) {
        final variable = bindings.single as VariableDeclaration;
        final list = variable.parent as VariableDeclarationList;
        final statement = list.parent;
        if (statement is VariableDeclarationStatement &&
            statement.offset < node.offset &&
            list.type == null &&
            variable.initializer is MethodInvocation) {
          for (
            AstNode? parent = node.parent;
            parent != null;
            parent = parent.parent
          ) {
            if (identical(parent, statement.parent)) {
              return _receiver(variable.initializer!);
            }
          }
        }
      }
      return null;
    }
    if (node is PrefixedIdentifier) {
      return _fieldType(_receiver(node.prefix), node.identifier.name);
    }
    if (node is PropertyAccess && !node.isCascaded && node.target != null) {
      return _fieldType(_receiver(node.target!), node.propertyName.name);
    }
    if (node is MethodInvocation && !node.isCascaded && node.target != null) {
      final receiver = _receiver(node.target!);
      if (receiver?.node case ClassDeclaration declaration
          when declaration.namePart.typeName.lexeme ==
              'ProfileIdentityEditSession') {
        return _fieldType(receiver, node.methodName.name);
      }
    }
    return null;
  }

  TypeAnnotation? _member(_PassiveDeclaration? receiver, String name) {
    if (receiver?.node case ClassDeclaration declaration
        when declaration.body is BlockClassBody &&
            declaration.namePart.typeParameters == null) {
      for (final member in (declaration.body as BlockClassBody).members) {
        if (member is FieldDeclaration &&
            member.fields.variables.any((v) => v.name.lexeme == name)) {
          return member.fields.type;
        }
        if (member is MethodDeclaration &&
            member.name.lexeme == name &&
            member.typeParameters == null) {
          return member.returnType;
        }
      }
    }
    return null;
  }

  _PassiveDeclaration? _fieldType(_PassiveDeclaration? receiver, String name) {
    final annotation = _member(receiver, name);
    if (annotation is! NamedType ||
        annotation.importPrefix != null ||
        annotation.typeArguments != null) {
      return null;
    }
    final candidates = _local(
      receiver!.library,
      annotation.name.lexeme,
    ).toList();
    if (candidates.length != 1 ||
        _passive[receiver.library]?.contains(annotation.name.lexeme) != true) {
      return null;
    }
    final candidate = candidates.single;
    return candidate.node is EnumDeclaration ||
            candidate.node is ClassDeclaration &&
                (candidate.node as ClassDeclaration).namePart.typeParameters ==
                    null
        ? candidate
        : null;
  }

  bool _safeReturn(_PassiveDeclaration receiver, TypeAnnotation? type) {
    if (type is! NamedType || type.importPrefix != null) return false;
    if (_namespace(type.name.lexeme, receiver.library).isNotEmpty) {
      final candidates = _namespace(type.name.lexeme, receiver.library);
      return candidates.length == 1 &&
          candidates.single.library == receiver.library &&
          _passive[receiver.library]?.contains(type.name.lexeme) == true &&
          type.typeArguments == null &&
          (candidates.single.node is EnumDeclaration ||
              candidates.single.node is ClassDeclaration &&
                  (candidates.single.node as ClassDeclaration)
                          .namePart
                          .typeParameters ==
                      null);
    }
    // Explicit core hiding or an unknown external namespace can rebind a
    // core-looking annotation. No shortcut interprets that binding.
    for (final unit in snapshot.sources.values.where(
      (s) => snapshot.libraries[s.path] == receiver.library,
    )) {
      for (final directive
          in unit.ast.directives.whereType<ImportDirective>()) {
        final uri = directive.uri.stringValue!;
        if (uri == 'dart:core' &&
            (directive.prefix != null ||
                !_allows(directive.combinators, type.name.lexeme))) {
          return false;
        }
        if (_target(unit.path, uri) == null &&
            !uri.startsWith('dart:') &&
            !uri.startsWith('package:flutter/')) {
          return false;
        }
      }
    }
    return {
          'void',
          'bool',
          'String',
          'int',
          'double',
        }.contains(type.name.lexeme) ||
        type.name.lexeme == 'Future' &&
            type.typeArguments?.arguments.length == 1 &&
            _safeReturn(receiver, type.typeArguments!.arguments.single);
  }

  bool operation(SimpleIdentifier node) {
    final (Expression? target, String name) = switch (node.parent) {
      MethodInvocation m when identical(m.methodName, node) && !m.isCascaded =>
        (m.target, node.name),
      PrefixedIdentifier p when identical(p.identifier, node) => (
        p.prefix,
        node.name,
      ),
      PropertyAccess p when identical(p.propertyName, node) && !p.isCascaded =>
        (p.target, node.name),
      _ => (null, ''),
    };
    if (node.parent case PrefixedIdentifier p when identical(p.prefix, node)) {
      if (_bindings(node.name).isEmpty) {
        final declarations = _namespace(node.name);
        if (declarations.length == 1 &&
            declarations.single.node is EnumDeclaration &&
            _passive[declarations.single.library]?.contains(node.name) ==
                true) {
          return true;
        }
      }
    }
    if (target is SuperExpression &&
        name == 'dispose' &&
        _flutterState(_class(node))) {
      return true;
    }
    if (target == null) return false;
    final receiver = _receiver(target);
    if (receiver != null && _safeReturn(receiver, _member(receiver, name))) {
      return true;
    }
    if (target is SimpleIdentifier) {
      // Enum constants and declared static presentation constructors bind to
      // their actual authored namespace; aliases and inherited members resolve.
      final declarations = _bindings(target.name).isEmpty
          ? _namespace(target.name)
          : <_PassiveDeclaration>[];
      if (declarations.length == 1) {
        final declaration = declarations.single;
        if (declaration.node case EnumDeclaration enumNode
            when _passive[declaration.library]?.contains(target.name) == true) {
          return enumNode.body.constants.any((c) => c.name.lexeme == name);
        }
        if (declaration.node case ClassDeclaration c
            when !authorities.containsKey(declaration.library) &&
                declaration.library != session &&
                c.body is BlockClassBody) {
          return (c.body as BlockClassBody).members.any(
            (m) =>
                m is ConstructorDeclaration && m.name?.lexeme == name ||
                m is MethodDeclaration && m.isStatic && m.name.lexeme == name,
          );
        }
      }
      if (_controller(target, name)) return true;
      if (target.name == 'widget' && _widgetFactory(node, name)) return true;
    }
    return false;
  }

  bool _flutterName(String name) {
    if (_bindings(name).isNotEmpty || _namespace(name).isNotEmpty) return false;
    return snapshot.sources.values
        .where((s) => snapshot.libraries[s.path] == view)
        .expand((s) => s.ast.directives.whereType<ImportDirective>())
        .any(
          (d) =>
              renderingUris.contains(d.uri.stringValue) &&
              d.prefix == null &&
              _allows(d.combinators, name),
        );
  }

  bool _controller(SimpleIdentifier target, String operation) {
    if (!{'text', 'dispose'}.contains(operation)) return false;
    final declaration = _own(target);
    if (declaration is! VariableDeclaration ||
        !(declaration.parent as VariableDeclarationList).isFinal) {
      return false;
    }
    final creation = declaration.initializer;
    final direct =
        creation is InstanceCreationExpression &&
            creation.constructorName.name == null &&
            creation.constructorName.type.importPrefix == null &&
            creation.constructorName.type.name.lexeme ==
                'TextEditingController' ||
        creation is MethodInvocation &&
            creation.target == null &&
            !creation.isCascaded &&
            creation.typeArguments == null &&
            creation.methodName.name == 'TextEditingController';
    return direct && _flutterName('TextEditingController');
  }

  bool _flutterState(ClassDeclaration? declaration) {
    final superclass = declaration?.extendsClause?.superclass;
    return declaration?.withClause == null &&
        superclass != null &&
        superclass.name.lexeme == 'State' &&
        superclass.importPrefix == null &&
        _flutterName('State');
  }

  bool _widgetFactory(SimpleIdentifier node, String name) {
    if (_bindings('widget').isNotEmpty) return false;
    final superclass = _class(node)?.extendsClause?.superclass;
    if (superclass == null ||
        superclass.name.lexeme != 'State' ||
        superclass.importPrefix != null ||
        !_flutterName('State')) {
      return false;
    }
    final arguments = superclass.typeArguments?.arguments;
    if (arguments?.length != 1 || arguments!.single is! NamedType) return false;
    final declarations = _namespace(
      (arguments.single as NamedType).name.lexeme,
    );
    if (declarations.length != 1 || declarations.single.library != view) {
      return false;
    }
    final declaration = declarations.single.node;
    if (declaration is! ClassDeclaration ||
        declaration.body is! BlockClassBody) {
      return false;
    }
    for (final field
        in (declaration.body as BlockClassBody).members
            .whereType<FieldDeclaration>()) {
      if (!field.fields.variables.any((v) => v.name.lexeme == name)) continue;
      final type = field.fields.type;
      return type is GenericFunctionType &&
          type.returnType is NamedType &&
          _type(type.returnType as NamedType)?.node is ClassDeclaration &&
          (type.returnType as NamedType).name.lexeme ==
              'ProfileIdentityEditSession';
    }
    return false;
  }

  bool localRead(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent is PrefixedIdentifier && !identical(parent.prefix, node) ||
        parent is PropertyAccess && identical(parent.propertyName, node) ||
        parent is MethodInvocation &&
            identical(parent.methodName, node) &&
            (parent.target != null || parent.isCascaded)) {
      return false;
    }
    if (_own(node) != null) return true;
    if (isProvenLocalRead(
      node,
      library: view,
      canonicalLibraries: authorities.keys,
    )) {
      return true;
    }
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is Block) {
        for (final statement in parent.statements) {
          if (statement.offset >= node.offset) break;
          if (statement is VariableDeclarationStatement &&
              statement.variables.variables.any(
                (v) => v.name.lexeme == node.name,
              )) {
            return true;
          }
        }
      }
    }
    return false;
  }
}

class _BindingDeclarations extends RecursiveAstVisitor<void> {
  _BindingDeclarations(this.name);
  final String name;
  final nodes = <AstNode>[];
  @override
  void visitVariableDeclaration(VariableDeclaration n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitVariableDeclaration(n);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter n) {
    if (n.name?.lexeme == name) nodes.add(n);
    super.visitSimpleFormalParameter(n);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitFieldFormalParameter(n);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitSuperFormalParameter(n);
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitFunctionTypedFormalParameter(n);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitDeclaredIdentifier(n);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitDeclaredVariablePattern(n);
  }

  @override
  void visitTypeParameter(TypeParameter n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitTypeParameter(n);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitFunctionDeclaration(n);
  }

  @override
  void visitCatchClause(CatchClause n) {
    if (n.exceptionParameter?.name.lexeme == name ||
        n.stackTraceParameter?.name.lexeme == name) {
      nodes.add(n);
    }
    super.visitCatchClause(n);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration n) {
    if (n.name.lexeme == name) nodes.add(n);
    super.visitMethodDeclaration(n);
  }
}

class _Candidates extends RecursiveAstVisitor<void> {
  _Candidates(this.source, this.snapshot, this.names, this.proof);
  final _PassiveProof proof;
  final Source source;
  final Snapshot snapshot;
  final Set<String> names;
  bool found = false;
  bool candidate(SimpleIdentifier node) =>
      names.contains(node.name) &&
      _access(node) &&
      !proof.localRead(node) &&
      !proof.operation(node);
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (candidate(node)) found = true;
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (names.contains(node.name.lexeme) && !proof.passiveType(node)) {
      found = true;
    }
    super.visitNamedType(node);
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
  void visitConstructorName(ConstructorName node) {
    if (names.contains(node.type.name.lexeme)) found = true;
    super.visitConstructorName(node);
  }
}

Map<String, Uri> _packages(String root) {
  final config = File('$root/.dart_tool/package_config.json');
  final data = jsonDecode(config.readAsStringSync()) as Map;
  final packages = <String, Uri>{};
  for (final package in (data['packages'] as List).cast<Map>()) {
    final location = config.uri.resolve(package['rootUri'] as String);
    final directory = location.replace(
      path: location.path.endsWith('/') ? location.path : '${location.path}/',
    );
    packages[package['name'] as String] = directory.resolve(
      package['packageUri'] as String? ?? '',
    );
  }
  return packages;
}

Set<String> _namespace(
  Snapshot snapshot,
  Source source,
  Map<String, Uri> packages,
) {
  final targets = <String>{};
  for (final dependency in source.dependencies) {
    final uri = Uri.parse(dependency.uri);
    if (uri.scheme == 'dart') continue;
    Uri target;
    if (uri.scheme == 'package') {
      final slash = uri.path.indexOf('/');
      if (slash < 1 || !packages.containsKey(uri.path.substring(0, slash))) {
        throw const FormatException('Unknown identity package');
      }
      target = packages[uri.path.substring(0, slash)]!.resolve(
        uri.path.substring(slash + 1),
      );
    } else {
      target = File('${snapshot.root}/${source.path}').uri.resolveUri(uri);
    }
    if (target.scheme != 'file') {
      throw const FormatException('Unsupported identity URI');
    }
    final file = File.fromUri(target);
    if (!file.existsSync()) {
      throw const FormatException('Missing identity namespace');
    }
    final path = file.absolute.path;
    if (path.startsWith('${snapshot.root}/') &&
        !snapshot.sources.containsKey(
          path.substring(snapshot.root.length + 1),
        )) {
      throw const FormatException(
        'Authored identity namespace outside parsed scope',
      );
    }
    if (path.startsWith('${snapshot.root}/')) {
      final relative = path.substring(snapshot.root.length + 1);
      targets.add(snapshot.libraries[relative] ?? relative);
    }
    if (uri.scheme != 'package' && !path.startsWith('${snapshot.root}/')) {
      throw const FormatException(
        'External authored identity namespace needs provenance',
      );
    }
  }
  return targets;
}

/// Read declarations of exactly the forbidden codec namespaces, including
/// exports and parts. Imported implementation dependencies cannot own these
/// namespace declarations and are not a new whole-package graph scan.
Set<String> _codecs(String sdk, Map<String, Uri> packages) {
  final names = <String>{};
  final seen = <String>{};
  void collect(Uri entry, String boundary) {
    void visit(Uri uri) {
      if (uri.scheme != 'file') {
        throw const FormatException('Unknown codec provenance');
      }
      final file = File.fromUri(uri);
      if (!file.path.startsWith(boundary) || !seen.add(file.path)) return;
      final parsed = parseString(
        content: file.readAsStringSync(),
        path: file.path,
        throwIfDiagnostics: false,
      );
      if (parsed.errors.isNotEmpty) {
        throw const FormatException('Invalid codec declarations');
      }
      parsed.unit.accept(_Vocabulary(names));
      for (final directive in parsed.unit.directives) {
        if (directive is ExportDirective || directive is PartDirective) {
          final literal = directive is ExportDirective
              ? directive.uri
              : (directive as PartDirective).uri;
          final value = literal.stringValue;
          if (value == null) {
            throw const FormatException('Unknown codec namespace');
          }
          final target = uri.resolve(value);
          if (target.scheme == 'file') visit(target);
        }
      }
    }

    visit(entry);
  }

  final convert = Directory('$sdk/lib/convert').uri;
  collect(convert.resolve('convert.dart'), convert.toFilePath());
  final library = packages['yaml'];
  if (library == null) {
    throw const FormatException('YAML dependency unavailable');
  }
  collect(library.resolve('yaml.dart'), library.toFilePath());
  final yamlFiles =
      Directory.fromUri(library)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in yamlFiles) {
    collect(file.uri, library.toFilePath());
  }
  for (final path in ['file.dart', 'file_system_entity.dart']) {
    final file = File('$sdk/lib/io/$path');
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw const FormatException('Invalid file authority declarations');
    }
    for (final declaration
        in parsed.unit.declarations.whereType<ClassDeclaration>()) {
      if ({
        'File',
        'FileSystemEntity',
      }.contains(declaration.namePart.typeName.lexeme)) {
        declaration.accept(_Vocabulary(names));
      }
    }
  }
  return names;
}

Future<List<Finding>> check(
  Snapshot snapshot,
  String root, {
  String? sdkPath,
}) async {
  root = Directory(root).resolveSymbolicLinksSync();
  final sdk = dartSdkPath(root, configured: sdkPath);
  final packages = _packages(root);
  final visited = <String>{};
  final pending = [view, session, model];
  while (pending.isNotEmpty) {
    final library = pending.removeLast();
    if (!visited.add(library)) continue;
    _validate(snapshot, library);
    for (final source in snapshot.sources.values.where(
      (s) => snapshot.libraries[s.path] == library,
    )) {
      if (source.ast.directives.whereType<NamespaceDirective>().any(
        (d) => d.configurations.isNotEmpty,
      )) {
        throw const FormatException(
          'Conditional identity namespace needs branch proof',
        );
      }
      pending.addAll(_namespace(snapshot, source, packages));
    }
  }
  final sources = snapshot.sources.values
      .where((s) => snapshot.libraries[s.path] == view)
      .toList();
  if (sources
          .expand((s) => s.ast.declarations)
          .whereType<ClassDeclaration>()
          .where((c) => c.namePart.typeName.lexeme == 'AdminIdentityPage')
          .length !=
      1) {
    throw const FormatException('Completed identity page missing or ambiguous');
  }
  final optionsPath = '$root/analysis_options.yaml';
  final options = File(optionsPath).existsSync()
      ? File(optionsPath).readAsStringSync()
      : '';
  final configuration = yaml.loadYaml(options);
  if (configuration != null && configuration is! Map ||
      configuration is Map &&
          configuration['analyzer'] is Map &&
          (configuration['analyzer'] as Map).containsKey('enable-experiment')) {
    throw const FormatException('Unsupported analysis configuration');
  }
  final names = _names(snapshot, _codecs(sdk, packages));
  final candidates = sources.where((s) {
    final visitor = _Candidates(
      s,
      snapshot,
      names,
      _PassiveProof(snapshot, packages, s),
    );
    s.ast.accept(visitor);
    return visitor.found;
  }).toList();
  if (candidates.isEmpty) return [];
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: ['$root/$view'],
    cacheNamespace: 'profile-identity-view',
  );
  final findings = <Finding>[];
  try {
    final result = await contexts
        .contextFor('$root/$view')
        .currentSession
        .getResolvedLibrary('$root/$view');
    if (result is! ResolvedLibraryResult) {
      throw const FormatException('Identity resolution failed');
    }
    for (final source in candidates) {
      final unit = result.units.singleWhere(
        (u) => u.path == '$root/${source.path}',
      );
      if (unit.diagnostics.any(
        (d) => d.diagnosticCode.severity.name == 'ERROR',
      )) {
        throw const FormatException('Unresolved identity candidate');
      }
      unit.unit.accept(_Resolved(source, snapshot, root, findings));
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _Resolved extends RecursiveAstVisitor<void> {
  _Resolved(this.source, this.snapshot, this.root, this.findings);
  final Source source;
  final Snapshot snapshot;
  final String root;
  final List<Finding> findings;
  final _reported = <int>{};
  bool _forbidden(Element raw) {
    final element = raw.baseElement;
    final library = element.library;
    if (library == null) return false;
    final path = library.firstFragment.source.fullName;
    final relative = path.startsWith('$root/')
        ? path.substring(root.length + 1)
        : '';
    final canonical = snapshot.libraries[relative] ?? relative;
    if (authorities.containsKey(canonical)) {
      final selected = authorities[canonical];
      Element? owner = element;
      while (owner != null &&
          owner is! ClassElement &&
          owner is! LibraryElement) {
        if (selected?.contains(owner.name) == true) return true;
        owner = owner.enclosingElement;
      }
      if (selected == null || selected.contains(owner?.name)) return true;
    }
    final uri = library.uri.toString();
    if (uri == 'dart:convert' || uri.startsWith('package:yaml/')) return true;
    if (uri.startsWith('dart:io') &&
        (element is ClassElement &&
                {'File', 'FileSystemEntity'}.contains(element.name) ||
            element.enclosingElement?.name == 'File' ||
            element.enclosingElement?.name == 'FileSystemEntity')) {
      return true;
    }
    if (canonical == session) {
      if (element is ConstructorElement &&
          element.enclosingElement.name == 'ProfileIdentityEditSession') {
        return true;
      }
      final type = switch (element) {
        PropertyAccessorElement accessor => accessor.returnType,
        FieldElement field => field.type,
        MethodElement method => method.returnType,
        _ => null,
      };
      if (type is InterfaceType && _forbidden(type.element)) return true;
    }
    return false;
  }

  void _record(AstNode node, Element? element) {
    if (element == null ||
        !_forbidden(element) ||
        !_reported.add(node.offset)) {
      return;
    }
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        '${element.displayName}@${node.offset}',
        'Render identity session facts and delegate commands; keep transport, metadata and save policy in their owners.',
      ),
    );
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_access(node)) _record(node, node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (node.parent is! ConstructorName) {
      _record(node, node.element);
      if (node.type case InterfaceType type) _record(node, type.element);
    }
    super.visitNamedType(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _record(node, node.element);
    super.visitConstructorName(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _record(node, node.declaredFragment?.element.superConstructor);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (node.body case BlockClassBody body
        when !body.members.any((m) => m is ConstructorDeclaration)) {
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
    for (var i = 0; i < args.length; ++i) {
      final option = args[i];
      if (!seen.add(option)) throw const FormatException('Duplicate option');
      if (option == '--json') {
        json = true;
        continue;
      }
      if (!{'--root', '--roles', '--sdk'}.contains(option) ||
          i + 1 == args.length) {
        throw const FormatException('Invalid option');
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
      for (final f in findings) {
        stdout.writeln(f);
      }
    }
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '[$id INPUT] Invalid identity scope, source, provenance, SDK or semantic candidate.',
    );
    exitCode = 2;
  }
}
