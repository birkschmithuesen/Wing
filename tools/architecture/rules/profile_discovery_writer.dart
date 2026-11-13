import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import '../cli.dart' as cli;
import '../lexical_bindings.dart';
import '../model.dart';

const id = 'ARCH_PROFILE_DISCOVERY_WRITER';
const library = 'lib/core/services/profile_workspace_controller.dart';
const ownerClass = 'ProfileWorkspaceController';
const field = '_discovery';
const writer = '_adoptDiscovery';
const subject = '$ownerClass.$field';

List<Source> _namespace(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.partOf != null ||
      source.namedPartOf) {
    throw const FormatException(
      'Canonical discovery containing library required',
    );
  }
  final targets = source.partTargets.toSet();
  if (targets.length !=
      source.ast.directives.whereType<PartDirective>().length) {
    throw const FormatException('Unresolved or duplicate discovery parts');
  }
  final units = <Source>[source];
  for (final target in targets) {
    final part = snapshot.sources[target];
    final owners = snapshot.partOwners[target] ?? const <String>[];
    if (part == null ||
        part.partOf != library ||
        part.namedPartOf ||
        part.partTargets.isNotEmpty ||
        owners.length != 1 ||
        owners.single != library ||
        snapshot.libraries[target] != library) {
      throw FormatException('Unsupported reciprocal discovery part: $target');
    }
    units.add(part);
  }
  if (snapshot.sources.values.any(
    (part) => part.partOf == library && !targets.contains(part.path),
  )) {
    throw const FormatException('Orphan discovery part');
  }
  return units;
}

List<Finding> check(Snapshot snapshot) {
  final units = _namespace(snapshot);
  final classes = [
    for (final unit in units)
      ...unit.ast.declarations.whereType<ClassDeclaration>(),
  ];
  final owners = classes
      .where((c) => c.namePart.typeName.lexeme == ownerClass)
      .toList();
  if (owners.length != 1 || owners.single.body is! BlockClassBody) {
    throw const FormatException('Missing canonical workspace owner');
  }
  final owner = owners.single;
  final body = owner.body as BlockClassBody;
  final fields = [
    for (final member in body.members.whereType<FieldDeclaration>())
      for (final variable in member.fields.variables)
        if (variable.name.lexeme == field) (member, variable),
  ];
  if (fields.length != 1 ||
      fields.single.$1.isStatic ||
      body.members.whereType<MethodDeclaration>().any(
        (m) => m.name.lexeme == field,
      )) {
    throw const FormatException(
      'Missing or ambiguous canonical discovery field',
    );
  }
  final findings = <Finding>[];
  for (final source in units) {
    final writes = _Writes(source, owner, classes, units);
    source.ast.accept(writes);
    if (fields.single.$2.initializer != null &&
        fields.single.$2.thisOrAncestorOfType<CompilationUnit>() ==
            source.ast) {
      writes.unsafe.add(fields.single.$2);
    }
    findings.addAll([
      for (final node in writes.unsafe)
        Finding(
          id,
          source.path,
          source.lineAt(node.offset),
          subject,
          'Publish canonical profile discovery only through its private _adoptDiscovery method; preserve unchanged structural facts there.',
        ),
    ]);
  }
  findings.sort();
  return findings;
}

Expression? _unwrap(Expression? expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}

class _Writes extends RecursiveAstVisitor<void> {
  _Writes(this.source, this.owner, this.classes, this.units);
  final Source source;
  final ClassDeclaration owner;
  final List<ClassDeclaration> classes;
  final List<Source> units;
  final unsafe = <AstNode>[];
  void _record(AstNode node) {
    final member = node.thisOrAncestorOfType<ClassMember>();
    if (member is! MethodDeclaration ||
        member.isStatic ||
        member.isGetter ||
        member.isSetter ||
        member.name.lexeme != writer ||
        !identical(member.thisOrAncestorOfType<ClassDeclaration>(), owner)) {
      unsafe.add(node);
    }
  }

  bool _type(TypeAnnotation? type) {
    if (type is! NamedType ||
        type.importPrefix != null ||
        type.typeArguments != null) {
      throw const FormatException('Unsupported discovery receiver type');
    }
    for (AstNode? scope = type.parent; scope != null; scope = scope.parent) {
      final parameters = switch (scope) {
        FunctionExpression fn => fn.typeParameters,
        MethodDeclaration method => method.typeParameters,
        ClassDeclaration declaration => declaration.namePart.typeParameters,
        ExtensionDeclaration extension => extension.typeParameters,
        _ => null,
      };
      if (parameters?.typeParameters.any(
            (p) => p.name.lexeme == type.name.lexeme,
          ) ==
          true) {
        throw const FormatException('Shadowed discovery receiver type');
      }
    }
    if (type.name.lexeme == ownerClass) {
      return true;
    }
    final others = classes
        .where((c) => c.namePart.typeName.lexeme == type.name.lexeme)
        .toList();
    if (others.length == 1 && _ownsField(others.single)) {
      return false;
    }
    throw FormatException(
      'Unproved discovery receiver type: ${type.toSource()}',
    );
  }

  bool _ownsField(ClassDeclaration declaration) =>
      declaration.body is BlockClassBody &&
      (declaration.body as BlockClassBody).members
          .whereType<FieldDeclaration>()
          .any(
            (member) =>
                !member.isStatic &&
                member.fields.variables.any((v) => v.name.lexeme == field),
          );

  bool _implicit(AstNode node) {
    for (AstNode? scope = node.parent; scope != null; scope = scope.parent) {
      if (scope is ClassDeclaration) {
        if (identical(scope, owner)) {
          return true;
        }
        if (_ownsField(scope)) {
          return false;
        }
        throw const FormatException('Unproved inherited discovery field');
      }
      if (scope is ExtensionDeclaration) {
        return _type(scope.onClause?.extendedType);
      }
    }
    if (units.any(
      (unit) =>
          unit.ast.declarations.whereType<TopLevelVariableDeclaration>().any(
            (declaration) => declaration.variables.variables.any(
              (v) => v.name.lexeme == field,
            ),
          ),
    )) {
      return false;
    }
    throw const FormatException('Unproved top-level discovery field');
  }

  bool _receiver(SimpleIdentifier receiver) {
    final unknown = _UnknownReceiverBindings(receiver.name);
    final member = receiver.thisOrAncestorOfType<ClassMember>();
    if (member != null) {
      member.accept(unknown);
    } else {
      receiver.thisOrAncestorOfType<FunctionExpression>()?.accept(unknown);
    }
    if (unknown.found) {
      throw const FormatException('Unsupported discovery receiver shadow');
    }
    for (
      AstNode? scope = receiver.parent;
      scope != null;
      scope = scope.parent
    ) {
      final (parameters, body) = switch (scope) {
        FunctionExpression fn => (fn.parameters, fn.body),
        MethodDeclaration method => (method.parameters, method.body),
        _ => (null, null),
      };
      if (body != null &&
          receiver.offset >= body.offset &&
          receiver.end <= body.end) {
        final matches =
            parameters?.parameters
                .where((p) => p.name?.lexeme == receiver.name)
                .toList() ??
            [];
        if (matches.length == 1) {
          FormalParameter parameter = matches.single;
          if (parameter is DefaultFormalParameter) {
            parameter = parameter.parameter;
          }
          if (parameter is SimpleFormalParameter) {
            return _type(parameter.type);
          }
          throw const FormatException('Unproved discovery receiver parameter');
        }
      }
      if (scope is Block) {
        for (final statement
            in scope.statements.whereType<VariableDeclarationStatement>()) {
          for (final variable in statement.variables.variables) {
            if (variable.name.lexeme == receiver.name &&
                receiver.offset >= variable.end) {
              return _type(statement.variables.type);
            }
          }
        }
      }
      if (scope is ClassDeclaration || scope is ExtensionDeclaration) {
        break;
      }
    }
    throw FormatException(
      'Unproved discovery receiver binding: ${receiver.name}',
    );
  }

  bool _canonical(SimpleIdentifier node) {
    final parent = node.parent;
    Expression? receiver;
    if (parent is PropertyAccess && identical(parent.propertyName, node)) {
      receiver = _unwrap(parent.realTarget);
    }
    if (parent is PrefixedIdentifier && identical(parent.identifier, node)) {
      receiver = parent.prefix;
    }
    if (receiver is ThisExpression) {
      return _implicit(node);
    }
    if (receiver is SimpleIdentifier) {
      return _receiver(receiver);
    }
    if (receiver != null) {
      throw const FormatException('Unsupported discovery receiver expression');
    }
    if (isProvenLocalRead(
      node,
      library: library,
      canonicalLibraries: const [library],
    )) {
      return false;
    }
    for (
      AstNode? scope = node.parent;
      scope != null && scope is! ClassMember;
      scope = scope.parent
    ) {
      if (scope is! Block) {
        continue;
      }
      for (final statement
          in scope.statements.whereType<VariableDeclarationStatement>()) {
        for (final variable in statement.variables.variables) {
          if (variable.name.lexeme == field && node.offset >= variable.end) {
            return false;
          }
        }
      }
    }
    final bindings = _CompetingBindings();
    final member = node.thisOrAncestorOfType<ClassMember>();
    if (member != null) {
      member.accept(bindings);
    } else {
      node.thisOrAncestorOfType<FunctionExpression>()?.accept(bindings);
    }
    if (bindings.found) {
      throw const FormatException('Unproved bare discovery write binding');
    }
    return _implicit(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == field &&
        node.parent is! ConstructorFieldInitializer &&
        node.inSetterContext() &&
        _canonical(node)) {
      _record(node);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    if (node.fieldName.name == field && _implicit(node)) {
      _record(node.fieldName);
    }
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    if (node.name.lexeme == field && _implicit(node)) {
      _record(node);
    }
    super.visitFieldFormalParameter(node);
  }
}

class _CompetingBindings extends GeneralizingAstVisitor<void> {
  bool found = false;
  void _name(String? name) {
    if (name == field) {
      found = true;
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration n) {
    _name(n.name.lexeme);
    super.visitVariableDeclaration(n);
  }

  @override
  void visitFormalParameter(FormalParameter n) {
    _name(n.name?.lexeme);
    super.visitFormalParameter(n);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier n) {
    _name(n.name.lexeme);
    super.visitDeclaredIdentifier(n);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern n) {
    _name(n.name.lexeme);
    super.visitDeclaredVariablePattern(n);
  }

  @override
  void visitCatchClause(CatchClause n) {
    _name(n.exceptionParameter?.name.lexeme);
    _name(n.stackTraceParameter?.name.lexeme);
    super.visitCatchClause(n);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration n) {
    _name(n.name.lexeme);
    super.visitFunctionDeclaration(n);
  }
}

class _UnknownReceiverBindings extends GeneralizingAstVisitor<void> {
  _UnknownReceiverBindings(this.name);
  final String name;
  bool found = false;
  void _name(String? value) {
    if (value == name) {
      found = true;
    }
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier n) {
    _name(n.name.lexeme);
    super.visitDeclaredIdentifier(n);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern n) {
    _name(n.name.lexeme);
    super.visitDeclaredVariablePattern(n);
  }

  @override
  void visitCatchClause(CatchClause n) {
    _name(n.exceptionParameter?.name.lexeme);
    _name(n.stackTraceParameter?.name.lexeme);
    super.visitCatchClause(n);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration n) {
    _name(n.name.lexeme);
    super.visitFunctionDeclaration(n);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
