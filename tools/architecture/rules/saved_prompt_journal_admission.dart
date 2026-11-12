import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_SAVED_PROMPT_JOURNAL_ADMISSION';
const library = 'lib/core/services/profile_workspace_controller.dart';
const ownerClass = 'ProfileWorkspaceController';
const stages = {
  '_regenerate': 'stageRegeneration',
  '_replaceSavedPrompt': 'stageSavedPromptEdit',
};

List<Source> _namespace(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.partOf != null ||
      source.namedPartOf) {
    throw const FormatException(
      'Canonical saved-prompt containing library required',
    );
  }
  final targets = source.partTargets.toSet();
  if (targets.length !=
      source.ast.directives.whereType<PartDirective>().length) {
    throw const FormatException('Unresolved or duplicate saved-prompt parts');
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
      throw FormatException(
        'Unsupported reciprocal saved-prompt part: $target',
      );
    }
    units.add(part);
  }
  if (snapshot.sources.values.any(
    (p) => p.partOf == library && !targets.contains(p.path),
  )) {
    throw const FormatException('Orphan saved-prompt part');
  }
  return units;
}

List<Finding> check(Snapshot snapshot) {
  final units = _namespace(snapshot);
  final owners = [
    for (final source in units)
      for (final declaration
          in source.ast.declarations.whereType<ClassDeclaration>())
        if (declaration.namePart.typeName.lexeme == ownerClass)
          (source, declaration),
  ];
  if (owners.length != 1 || owners.single.$2.body is! BlockClassBody) {
    throw const FormatException(
      'Missing or ambiguous canonical saved-prompt owner',
    );
  }
  final chats = [
    for (final unit in units)
      ...unit.ast.declarations.whereType<ClassDeclaration>().where(
        (c) => c.namePart.typeName.lexeme == 'ProfileChat',
      ),
  ];
  if (chats.length != 1 ||
      units.any(
        (unit) => unit.ast.declarations.any(
          (d) =>
              d is GenericTypeAlias && d.name.lexeme == 'ProfileChat' ||
              d is ClassTypeAlias && d.name.lexeme == 'ProfileChat',
        ),
      )) {
    throw const FormatException(
      'Missing or ambiguous canonical ProfileChat type',
    );
  }
  final (source, owner) = owners.single;
  final members = (owner.body as BlockClassBody).members;
  MethodDeclaration method(String name) {
    final matches = members
        .whereType<MethodDeclaration>()
        .where((m) => m.name.lexeme == name)
        .toList();
    if (matches.length != 1 ||
        matches.single.isStatic ||
        matches.single.isGetter ||
        matches.single.isSetter ||
        matches.single.body is! BlockFunctionBody ||
        members.whereType<FieldDeclaration>().any(
          (f) => f.fields.variables.any((v) => v.name.lexeme == name),
        )) {
      throw FormatException(
        'Missing or unsupported canonical saved-prompt member: $name',
      );
    }
    return matches.single;
  }

  method('_journal');
  method('_commandOwner');
  final findings = <Finding>[];
  for (final entry in stages.entries) {
    final command = method(entry.key);
    final parameters =
        command.parameters?.parameters ?? const <FormalParameter>[];
    if (parameters.isEmpty || parameters.first.name?.lexeme != 'chat') {
      throw FormatException('Expected captured chat parameter: ${entry.key}');
    }
    FormalParameter parameter = parameters.first;
    if (parameter is DefaultFormalParameter) parameter = parameter.parameter;
    final type = parameter is SimpleFormalParameter ? parameter.type : null;
    if (type is! NamedType ||
        type.name.lexeme != 'ProfileChat' ||
        type.importPrefix != null ||
        type.typeArguments != null ||
        type.question != null ||
        owner.namePart.typeParameters?.typeParameters.any(
              (p) => p.name.lexeme == 'ProfileChat',
            ) ==
            true ||
        command.typeParameters?.typeParameters.any(
              (p) => p.name.lexeme == 'ProfileChat',
            ) ==
            true) {
      throw const FormatException('Unproved captured ProfileChat parameter');
    }
    final calls = _Calls();
    command.body.accept(calls);
    final staging = calls.calls
        .where(
          (c) =>
              c.methodName.name == entry.value &&
              _chatMember(c.target, 'reading', command),
        )
        .toList();
    final accepting = calls.calls
        .where(
          (c) =>
              c.methodName.name == 'acceptTurn' &&
              _chatMember(c.target, '_runtime', command),
        )
        .toList();
    if (staging.length != 1 || accepting.length != 1) {
      throw FormatException(
        'Expected one literal reading stage and acceptTurn: ${entry.key}',
      );
    }
    final stage = staging.single;
    final stageStatement = _statement(stage, command);
    final acceptStatement = _statement(accepting.single, command);
    final block = stageStatement.parent;
    if (block is! Block || !identical(acceptStatement.parent, block)) {
      throw const FormatException('Unsupported saved-prompt staging block');
    }
    final index = block.statements.indexOf(stageStatement);
    final journals = block.statements.take(index).where((statement) {
      if (statement is! ExpressionStatement) return false;
      final expression = _unwrap(statement.expression);
      return expression is AwaitExpression &&
          _ownerCall(_unwrap(expression.expression), '_journal', command);
    }).toList();
    if (journals.isEmpty) {
      throw FormatException(
        'Expected a direct awaited journal before ${entry.value}',
      );
    }
    final journalIndex = block.statements.indexOf(journals.last);
    final fenced =
        index == journalIndex + 2 &&
        index > 0 &&
        block.statements[index - 1] is ExpressionStatement &&
        _ownerCall(
          _unwrap(
            (block.statements[index - 1] as ExpressionStatement).expression,
          ),
          '_commandOwner',
          command,
        ) &&
        block.statements.indexOf(acceptStatement) == index + 1;
    if (!fenced) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(stage.offset),
          '$ownerClass.${entry.key}',
          'After awaiting the journal, recheck _commandOwner(chat) immediately before staging reading and accepting the turn.',
        ),
      );
    }
  }
  return findings..sort();
}

Expression? _unwrap(Expression? expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}

bool _chatMember(
  Expression? expression,
  String member,
  MethodDeclaration command,
) {
  expression = _unwrap(expression);
  final (receiver, name) = switch (expression) {
    PropertyAccess p => (_unwrap(p.realTarget), p.propertyName.name),
    PrefixedIdentifier p => (p.prefix, p.identifier.name),
    _ => (null, null),
  };
  if (name != member ||
      receiver is! SimpleIdentifier ||
      receiver.name != 'chat') {
    return false;
  }
  _requireBinding(receiver, 'chat', command);
  return true;
}

bool _ownerCall(
  Expression? expression,
  String name,
  MethodDeclaration command,
) {
  expression = _unwrap(expression);
  if (expression is! MethodInvocation || expression.methodName.name != name) {
    return false;
  }
  final target = _unwrap(expression.target);
  if (target != null && target is! ThisExpression) return false;
  if (target == null) _requireBinding(expression.methodName, name, command);
  final arguments = expression.argumentList.arguments;
  if (name == '_journal') return arguments.isEmpty;
  if (arguments.length != 1) return false;
  final chat = _unwrap(arguments.single);
  if (chat is! SimpleIdentifier || chat.name != 'chat') return false;
  _requireBinding(chat, 'chat', command);
  return true;
}

ExpressionStatement _statement(
  MethodInvocation call,
  MethodDeclaration command,
) {
  AstNode node = call;
  while (node.parent is ParenthesizedExpression) {
    node = node.parent!;
  }
  if (node.parent is! ExpressionStatement) {
    throw const FormatException(
      'Saved-prompt stage/accept must be direct statements',
    );
  }
  for (
    AstNode? scope = node.parent;
    scope != null && !identical(scope, command);
    scope = scope.parent
  ) {
    if (scope is FunctionExpression ||
        scope is FunctionDeclaration ||
        scope is MethodDeclaration) {
      throw const FormatException(
        'Nested saved-prompt stage/accept callback unsupported',
      );
    }
  }
  return node.parent! as ExpressionStatement;
}

// Only enclosing scopes can shadow a relevant literal receiver/member. A
// homonym inside an unrelated nested function or another class is harmless.
void _requireBinding(AstNode node, String name, MethodDeclaration command) {
  for (AstNode? scope = node.parent; scope != null; scope = scope.parent) {
    final parameters = switch (scope) {
      FunctionExpression f => f.parameters,
      MethodDeclaration m => m.parameters,
      _ => null,
    };
    if (parameters?.parameters.any((p) => p.name?.lexeme == name) == true &&
        !(identical(scope, command) && name == 'chat')) {
      throw FormatException('Shadowed saved-prompt binding: $name');
    }
    if (scope is Block) {
      for (final statement in scope.statements) {
        if (statement is VariableDeclarationStatement &&
                statement.variables.variables.any(
                  (v) => v.name.lexeme == name,
                ) ||
            statement is FunctionDeclarationStatement &&
                statement.functionDeclaration.name.lexeme == name) {
          throw FormatException('Shadowed saved-prompt block binding: $name');
        }
      }
    }
    if (scope is CatchClause &&
        (scope.exceptionParameter?.name.lexeme == name ||
            scope.stackTraceParameter?.name.lexeme == name)) {
      throw FormatException('Shadowed saved-prompt catch binding: $name');
    }
    if (scope is ForStatement) {
      final names = _Names(name);
      scope.forLoopParts.accept(names);
      if (names.found) {
        throw FormatException('Unsupported saved-prompt loop binding: $name');
      }
    }
    if (scope is IfStatement ||
        scope is SwitchStatement ||
        scope is SwitchExpression ||
        scope is Block) {
      final names = _Patterns(name, scope);
      scope.accept(names);
      if (names.found) {
        throw FormatException(
          'Unsupported saved-prompt pattern binding: $name',
        );
      }
    }
    if (identical(scope, command)) return;
  }
  throw const FormatException('Saved-prompt binding outside canonical method');
}

class _Calls extends RecursiveAstVisitor<void> {
  final calls = <MethodInvocation>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    calls.add(node);
    super.visitMethodInvocation(node);
  }
}

class _Names extends GeneralizingAstVisitor<void> {
  _Names(this.name);
  final String name;
  bool found = false;
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitVariableDeclaration(node);
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
}

class _Patterns extends RecursiveAstVisitor<void> {
  _Patterns(this.name, this.scope);
  final String name;
  final AstNode scope;
  bool found = false;
  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (node.name.lexeme == name &&
        identical(
          node.thisOrAncestorOfType<Block>(),
          scope is Block ? scope : scope.thisOrAncestorOfType<Block>(),
        )) {
      found = true;
    }
    super.visitDeclaredVariablePattern(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
