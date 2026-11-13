import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_CURRENT_TOOL_EVENTS';
// Stock e5ea5fd includes tool.progress. Its live exact-call admission is covered
// by ChatRuntime regressions; retired event aliases remain forbidden here.
const unsupportedEvents = {'tool.args_delta', 'tool.error'};
const unsupportedKeys = {
  'toolCallId',
  'tool_call_id',
  'id',
  'tool',
  'label',
  'arguments',
  'input',
  'status',
  'detail',
  'emoji',
  'error',
};

class _Scope {
  const _Scope(
    this.file,
    this.owner,
    this.method,
    this.selector, {
    this.property,
    this.payload,
  });
  final String file, owner, method;
  final int selector;
  final String? property;
  final int? payload;
}

const _scopes = [
  _Scope(
    'lib/core/models/gateway_activity.dart',
    'GatewayToolActivity',
    'fromGatewayEvent',
    0,
    payload: 1,
  ),
  _Scope(
    'lib/core/services/chat_runtime.dart',
    'ChatRuntime',
    'observeEvent',
    0,
  ),
  _Scope(
    'lib/core/services/chat_runtime.dart',
    'ChatRuntime',
    'observeTool',
    0,
  ),
  _Scope(
    'lib/core/services/profile_workspace_controller.dart',
    'ProfileWorkspaceController',
    '_event',
    1,
    property: 'type',
  ),
];

Expression? _unwrap(Expression? value) {
  while (value is ParenthesizedExpression) {
    value = value.expression;
  }
  return value;
}

List<Finding> check(Snapshot snapshot) {
  final findings = <Finding>[];
  for (final scope in _scopes) {
    final source = snapshot.sources[scope.file];
    if (source == null) {
      throw const FormatException('Missing canonical tool-event library');
    }
    _validateLibrary(snapshot, source);
    final namespaceOwners = snapshot.sources.values
        .where((unit) => snapshot.libraries[unit.path] == scope.file)
        .expand((unit) => unit.ast.declarations.whereType<ClassDeclaration>())
        .where((owner) => owner.namePart.typeName.lexeme == scope.owner)
        .toList();
    if (namespaceOwners.length != 1) {
      throw const FormatException('Ambiguous canonical tool-event namespace');
    }
    final owners = source.ast.declarations
        .whereType<ClassDeclaration>()
        .where((d) => d.namePart.typeName.lexeme == scope.owner)
        .toList();
    if (owners.length != 1 || owners.single.body is! BlockClassBody) {
      throw const FormatException('Missing canonical tool-event owner');
    }
    final methods = (owners.single.body as BlockClassBody).members
        .whereType<MethodDeclaration>()
        .where((d) => d.name.lexeme == scope.method)
        .toList();
    if (methods.length != 1 ||
        methods.single.isGetter ||
        methods.single.isSetter ||
        methods.single.parameters == null ||
        methods.single.parameters!.parameters.length <= scope.selector ||
        scope.payload != null &&
            methods.single.parameters!.parameters.length <= scope.payload! ||
        methods.single.parameters!.parameters[scope.selector].name == null ||
        scope.payload != null &&
            methods.single.parameters!.parameters[scope.payload!].name ==
                null) {
      throw const FormatException('Missing canonical tool-event seam');
    }
    methods.single.body.accept(
      _Dispatches(source, scope, methods.single, findings),
    );
  }
  return findings..sort();
}

// Snapshot records physical containing libraries; verify reciprocal ownership
// before trusting their namespace. Canonical methods stay in their exact files.
void _validateLibrary(Snapshot snapshot, Source source) {
  if (snapshot.libraries[source.path] != source.path ||
      source.ast.directives.any((d) => d is PartOfDirective) ||
      source.ast.directives.whereType<PartDirective>().length !=
          source.partTargets.length ||
      source.partTargets.toSet().length != source.partTargets.length) {
    throw const FormatException('Unsupported canonical tool-event library');
  }
  for (final target in source.partTargets) {
    final part = snapshot.sources[target];
    final owners = snapshot.partOwners[target] ?? const <String>[];
    if (part == null ||
        owners.length != 1 ||
        owners.single != source.path ||
        snapshot.libraries[target] != source.path ||
        part.ast.directives.whereType<PartOfDirective>().length != 1 ||
        part.partTargets.isNotEmpty ||
        (part.partOf != source.path && !part.namedPartOf)) {
      throw const FormatException(
        'Invalid reciprocal tool-event part ownership',
      );
    }
    if (part.namedPartOf) {
      final names = source.ast.directives
          .whereType<LibraryDirective>()
          .map((d) => d.name?.toSource())
          .toList();
      final partNames = part.ast.directives
          .whereType<PartOfDirective>()
          .map((d) => d.libraryName?.toSource())
          .toList();
      if (names.length != 1 ||
          partNames.length != 1 ||
          names.single == null ||
          names.single != partNames.single) {
        throw const FormatException(
          'Mismatched named tool-event part ownership',
        );
      }
    }
  }
}

class _Dispatches extends RecursiveAstVisitor<void> {
  _Dispatches(this.source, this.scope, this.method, this.findings);
  final Source source;
  final _Scope scope;
  final MethodDeclaration method;
  final List<Finding> findings;
  final seen = <int>{};

  // Resolve only local ordinary parameters and preceding immutable aliases.
  // A nearer closure parameter or block variable shadows the captured value.
  AstNode? _binding(SimpleIdentifier read) {
    for (AstNode? p = read.parent; p != null; p = p.parent) {
      final shadow = _Bindings(read.name);
      if (p is ForStatement) p.forLoopParts.accept(shadow);
      if (p is SwitchPatternCase) p.guardedPattern.accept(shadow);
      if (p is SwitchExpressionCase) p.guardedPattern.accept(shadow);
      if (p is CatchClause &&
          (p.exceptionParameter?.name.lexeme == read.name ||
              p.stackTraceParameter?.name.lexeme == read.name)) {
        return null;
      }
      if (p is IfStatement) {
        for (final child in p.childEntities.whereType<AstNode>()) {
          if (child is CaseClause || child is DartPattern) child.accept(shadow);
        }
      }
      if (p is Block) {
        for (final statement
            in p.statements.whereType<PatternVariableDeclarationStatement>()) {
          if (statement.end < read.offset) statement.accept(shadow);
        }
      }
      if (shadow.found) return null;
      if (p is Block) {
        for (final statement
            in p.statements.whereType<VariableDeclarationStatement>()) {
          for (final variable in statement.variables.variables) {
            if (variable.name.lexeme == read.name &&
                variable.end < read.offset) {
              return variable;
            }
          }
        }
      }
      final parameters = switch (p) {
        FunctionExpression f => f.parameters,
        MethodDeclaration m => m.parameters,
        _ => null,
      };
      for (final parameter
          in parameters?.parameters ?? const <FormalParameter>[]) {
        if (parameter.name?.lexeme == read.name) return parameter;
      }
      if (identical(p, method)) break;
    }
    return null;
  }

  String? _origin(Expression? raw, [Set<int>? visiting]) {
    final value = _unwrap(raw);
    if (value is SimpleIdentifier) {
      final binding = _binding(value);
      final parameters = method.parameters!.parameters;
      if (identical(binding, parameters[scope.selector])) {
        return scope.property == null ? 'selector' : 'receiver';
      }
      if (scope.payload != null &&
          identical(binding, parameters[scope.payload!])) {
        return 'payload';
      }
      if (binding is VariableDeclaration &&
          binding.parent is VariableDeclarationList &&
          ((binding.parent as VariableDeclarationList).isFinal ||
              (binding.parent as VariableDeclarationList).isConst)) {
        final active = visiting ?? <int>{};
        if (!active.add(binding.offset)) return null;
        final origin = _origin(binding.initializer, active);
        active.remove(binding.offset);
        return origin;
      }
    }
    final (target, name) = switch (value) {
      PropertyAccess p => (p.target, p.propertyName.name),
      PrefixedIdentifier p => (p.prefix, p.identifier.name),
      _ => (null, null),
    };
    if (scope.property != null &&
        name == scope.property &&
        _origin(target, visiting) == 'receiver') {
      return 'selector';
    }
    return null;
  }

  void _report(SimpleStringLiteral literal, String kind) {
    if (!seen.add(literal.offset)) return;
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(literal.offset),
        '${scope.owner}.${scope.method}:$kind:${literal.value}',
        'Use current stock tool.start/generating/progress/complete and canonical tool-event keys; arbitrary nested results and saved history are separate contracts.',
      ),
    );
  }

  void _eventLiterals(AstNode pattern) {
    void read(SimpleStringLiteral literal) {
      if (unsupportedEvents.contains(literal.value)) _report(literal, 'event');
    }

    if (pattern is Expression) {
      final value = _unwrap(pattern);
      if (value is SimpleStringLiteral) read(value);
    } else {
      pattern.accept(_EventPatterns(read));
    }
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '==' || node.operator.lexeme == '!=') {
      if (_origin(node.leftOperand) == 'selector') {
        _eventLiterals(node.rightOperand);
      }
      if (_origin(node.rightOperand) == 'selector') {
        _eventLiterals(node.leftOperand);
      }
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    if (_origin(node.expression) == 'selector') {
      for (final branch in node.cases) {
        _eventLiterals(branch.guardedPattern.pattern);
      }
    }
    super.visitSwitchExpression(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    if (_origin(node.expression) == 'selector') {
      for (final member in node.members) {
        if (member is SwitchCase) _eventLiterals(member.expression);
        if (member is SwitchPatternCase) {
          _eventLiterals(member.guardedPattern.pattern);
        }
      }
    }
    super.visitSwitchStatement(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final index = _unwrap(node.index);
    if (_origin(node.target) == 'payload' &&
        index is SimpleStringLiteral &&
        unsupportedKeys.contains(index.value)) {
      _report(index, 'key');
    }
    super.visitIndexExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final arguments = node.argumentList.arguments;
    if (scope.payload != null &&
        arguments.length >= 2 &&
        _origin(arguments.first) == 'payload') {
      final keys = _unwrap(arguments[1]);
      if (keys is ListLiteral) {
        keys.accept(
          _Literals((literal) {
            if (unsupportedKeys.contains(literal.value)) {
              _report(literal, 'key');
            }
          }),
        );
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _Bindings extends RecursiveAstVisitor<void> {
  _Bindings(this.name);
  final String name;
  bool found = false;
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    found |= node.name.lexeme == name;
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    found |= node.name.lexeme == name;
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    found |= node.name.lexeme == name;
  }
}

class _EventPatterns extends RecursiveAstVisitor<void> {
  _EventPatterns(this.read);
  final void Function(SimpleStringLiteral) read;
  @override
  void visitConstantPattern(ConstantPattern node) {
    final value = _unwrap(node.expression);
    if (value is SimpleStringLiteral) read(value);
  }
}

class _Literals extends RecursiveAstVisitor<void> {
  _Literals(this.read);
  final void Function(SimpleStringLiteral) read;
  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => read(node);
}

Future<void> main(List<String> args) =>
    cli.run([...args, '--strict'], {id: check});
