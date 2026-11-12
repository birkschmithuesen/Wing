import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_READING_VIEW_INPUT';
const model = 'lib/core/models/transcript_message.dart';
const timelineModel = 'lib/core/models/transcript_timeline.dart';
const presentationModel = 'lib/core/models/transcript_presentation.dart';
const models = {
  model: {'TranscriptMessage', 'TranscriptToolResult'},
  timelineModel: {'TranscriptTimeline', 'TranscriptTimelineSection'},
  presentationModel: {'TranscriptPresentation'},
};
const inputs = [
  (
    'lib/core/widgets/profile_message.dart',
    'ProfileMessage',
    'message',
    'TranscriptMessage',
    false,
    model,
  ),
  (
    'lib/core/widgets/profile_tool_activity.dart',
    'ProfileToolActivity',
    'results',
    'TranscriptToolResult',
    true,
    model,
  ),
  (
    'lib/core/screens/profile_transcript.dart',
    'ProfileTranscript',
    'presentation',
    'TranscriptPresentation',
    false,
    presentationModel,
  ),
  (
    presentationModel,
    'TranscriptPresentation',
    'timeline',
    'TranscriptTimeline',
    false,
    timelineModel,
  ),
  (
    'lib/core/widgets/profile_tool_activity.dart',
    'ProfileToolActivitySection',
    'section',
    'TranscriptTimelineSection',
    false,
    timelineModel,
  ),
];

/// A finite declaration contract; ordinary analysis validates language bodies.
List<Finding> check(Snapshot snapshot) {
  for (final entry in models.entries) {
    final values = snapshot.sources[entry.key];
    if (values == null || snapshot.libraries[entry.key] != entry.key) {
      throw FormatException('Missing canonical transcript model: ${entry.key}');
    }
    for (final expected in entry.value) {
      if (values.ast.declarations
              .whereType<ClassDeclaration>()
              .where((node) => node.namePart.typeName.lexeme == expected)
              .length !=
          1) {
        throw FormatException('Missing/ambiguous canonical $expected');
      }
    }
  }
  final findings = <Finding>[];
  for (final (path, owner, member, expected, list, canonicalModel) in inputs) {
    final source = snapshot.sources[path];
    if (source == null ||
        snapshot.libraries[path] != path ||
        source.ast.directives.any(
          (d) => d is PartDirective || d is PartOfDirective,
        ) ||
        source.ast.directives.whereType<NamespaceDirective>().any(
          (d) => d.configurations.isNotEmpty,
        )) {
      throw FormatException('Missing/unsupported reading view: $path');
    }
    final classes = source.ast.declarations
        .whereType<ClassDeclaration>()
        .where((node) => node.namePart.typeName.lexeme == owner)
        .toList();
    if (classes.length != 1 || classes.single.body is! BlockClassBody) {
      throw FormatException('Missing/ambiguous $owner');
    }
    final declaration = classes.single;
    final fields = <(FieldDeclaration, VariableDeclaration)>[
      for (final node
          in (declaration.body as BlockClassBody).members
              .whereType<FieldDeclaration>())
        for (final variable in node.fields.variables)
          if (variable.name.lexeme == member) (node, variable),
    ];
    if (fields.length != 1 ||
        fields.single.$1.isStatic ||
        (declaration.body as BlockClassBody).members
            .whereType<MethodDeclaration>()
            .any((node) => node.name.lexeme == member)) {
      throw FormatException('Missing/unsupported $owner.$member field');
    }
    final (field, variable) = fields.single;
    final type = field.fields.type;
    final element =
        list &&
            type is NamedType &&
            _coreList(snapshot, source, declaration, type) &&
            type.typeArguments?.arguments.length == 1
        ? type.typeArguments!.arguments.single
        : list
        ? null
        : type;
    if (!_canonicalType(
          snapshot,
          source,
          declaration,
          element,
          expected,
          canonicalModel,
        ) ||
        !field.fields.isFinal ||
        field.fields.isLate && variable.initializer == null) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(variable.name.offset),
          '$owner.$member',
          'Capture ${list ? 'List<$expected>' : expected} from the canonical transcript model; keep wire decoding outside this reading view.',
        ),
      );
    }
  }
  final transcript =
      snapshot.sources['lib/core/screens/profile_transcript.dart']!;
  transcript.ast.accept(_PendingInputUnion(transcript, findings));
  return findings..sort();
}

/// Finite copied-union detection, not a resolved runtime/dataflow proof.
class _PendingInputUnion extends RecursiveAstVisitor<void> {
  _PendingInputUnion(this.source, this.findings);
  final Source source;
  final List<Finding> findings;

  @override
  void visitBinaryExpression(BinaryExpression node) {
    super.visitBinaryExpression(node);
    if (node.operator.lexeme != '||') return;
    AstNode? ancestor = node.parent;
    while (ancestor != null && ancestor is! ClassDeclaration) {
      ancestor = ancestor.parent;
    }
    if (ancestor is! ClassDeclaration ||
        ancestor.namePart.typeName.lexeme != '_ProfileTranscriptState') {
      return;
    }
    final terms = <Expression>[];
    void flatten(Expression expression) {
      final value = _unwrapped(expression);
      if (value is BinaryExpression && value.operator.lexeme == '||') {
        flatten(value.leftOperand);
        flatten(value.rightOperand);
      } else {
        terms.add(value);
      }
    }

    flatten(node);
    if (terms.length != 3) return;
    final members = <String>{};
    String? receiver;
    for (final term in terms) {
      if (term is! BinaryExpression || term.operator.lexeme != '!=') return;
      final left = _unwrapped(term.leftOperand);
      final right = _unwrapped(term.rightOperand);
      final path = _path(left is NullLiteral ? right : left);
      if (left is! NullLiteral && right is! NullLiteral || path == null) return;
      final dot = path.lastIndexOf('.');
      if (dot < 0) return;
      final base = path.substring(0, dot);
      if (receiver != null && base != receiver) return;
      receiver = base;
      members.add(path.substring(dot + 1));
    }
    if (members.length != 3 ||
        !members.containsAll({'approval', 'pendingQuestion', 'secureInput'}) ||
        !_capturedRuntime(receiver!, node)) {
      return;
    }
    findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        'ProfileTranscript.needsInput',
        'Read runtime.needsInput; keep pending-input classification in its canonical observation.',
      ),
    );
  }
}

Expression _unwrapped(Expression expression) =>
    expression is ParenthesizedExpression
    ? _unwrapped(expression.expression)
    : expression;

String? _path(Expression expression) {
  final value = _unwrapped(expression);
  if (value is SimpleIdentifier) return value.name;
  if (value is PrefixedIdentifier) {
    return '${value.prefix.name}.${value.identifier.name}';
  }
  if (value is PropertyAccess && value.target != null) {
    final target = _path(value.target!);
    return target == null ? null : '$target.${value.propertyName.name}';
  }
  return null;
}

bool _capturedRuntime(String receiver, AstNode use) {
  if (receiver == 'widget.chat.runtime') return _unshadowedWidget(use);
  if (!receiver.endsWith('.runtime')) return false;
  final capture = receiver.substring(0, receiver.length - '.runtime'.length);
  if (capture.contains('.')) return false;
  // Bind only the actual immutable block-local capture, respecting nearer
  // declarations. Closures/parameters and arbitrary aliases are not inferred.
  for (AstNode? scope = use.parent; scope != null; scope = scope.parent) {
    if (scope is FunctionExpression || _shadows(scope, capture)) return false;
    if (scope is Block) {
      for (final statement
          in scope.statements.whereType<VariableDeclarationStatement>()) {
        for (final variable in statement.variables.variables) {
          if (variable.name.lexeme != capture) continue;
          return statement.variables.isFinal &&
              variable.offset < use.offset &&
              variable.initializer != null &&
              _path(variable.initializer!) == 'widget.chat' &&
              _unshadowedWidget(variable);
        }
      }
    }
    if (scope is MethodDeclaration) return false;
  }
  return false;
}

bool _unshadowedWidget(AstNode use) {
  for (AstNode? scope = use.parent; scope != null; scope = scope.parent) {
    if (_shadows(scope, 'widget')) return false;
    final parameters = switch (scope) {
      MethodDeclaration value => value.parameters,
      FunctionExpression value => value.parameters,
      _ => null,
    };
    if (parameters?.parameters.any(
          (parameter) => parameter.name?.lexeme == 'widget',
        ) ==
        true) {
      return false;
    }
    if (scope is Block &&
        scope.statements.whereType<VariableDeclarationStatement>().any(
          (statement) => statement.variables.variables.any(
            (variable) => variable.name.lexeme == 'widget',
          ),
        )) {
      return false;
    }
    if (scope is ClassDeclaration) return true;
  }
  return false;
}

// Bind only ordinary immutable captures. A nearer loop, catch or pattern
// declaration prevents attributing its receiver to the outer view owner.
bool _shadows(AstNode scope, String name) {
  final bindings = _ScopedBindings(name);
  if (scope is ForStatement) {
    scope.forLoopParts.accept(bindings);
  } else if (scope is CatchClause) {
    return scope.exceptionParameter?.name.lexeme == name ||
        scope.stackTraceParameter?.name.lexeme == name;
  } else if (scope is SwitchExpressionCase) {
    scope.guardedPattern.accept(bindings);
  } else if (scope is SwitchPatternCase) {
    scope.guardedPattern.accept(bindings);
  } else if (scope is IfStatement) {
    for (final child in scope.childEntities.whereType<AstNode>()) {
      if (child is CaseClause || child is DartPattern) child.accept(bindings);
    }
  } else if (scope is Block) {
    for (final statement
        in scope.statements.whereType<PatternVariableDeclarationStatement>()) {
      statement.accept(bindings);
    }
  }
  return bindings.found;
}

class _ScopedBindings extends RecursiveAstVisitor<void> {
  _ScopedBindings(this.name);
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

bool _coreList(
  Snapshot snapshot,
  Source source,
  ClassDeclaration owner,
  NamedType type,
) {
  if (type.name.lexeme != 'List' || type.question != null) return false;
  final prefix = type.importPrefix?.name.lexeme;
  if (prefix == null && _shadowed(source.ast, owner, 'List')) return false;
  final core = source.ast.directives.whereType<ImportDirective>().where(
    (node) => node.uri.stringValue == 'dart:core',
  );
  if (prefix != null || core.isNotEmpty) {
    if (core
            .where(
              (node) => node.prefix?.name == prefix && _visible(node, 'List'),
            )
            .length !=
        1) {
      return false;
    }
  }
  for (final node in source.ast.directives.whereType<ImportDirective>().where(
    (node) =>
        node.prefix?.name == prefix &&
        _visible(node, 'List') &&
        node.uri.stringValue != 'dart:core',
  )) {
    if (prefix != null) return false;
    for (final edge in source.dependencies.where(
      (edge) => edge.kind == 'import' && edge.uri == node.uri.stringValue,
    )) {
      if (edge.target case final target?) {
        final imported = _directImportedUnit(snapshot, target);
        if (_declares(imported.ast, 'List')) return false;
      }
    }
  }
  return true;
}

bool _canonicalType(
  Snapshot snapshot,
  Source source,
  ClassDeclaration owner,
  TypeAnnotation? type,
  String expected,
  String canonicalModel,
) {
  if (type is! NamedType ||
      type.name.lexeme != expected ||
      type.question != null ||
      type.typeArguments != null) {
    return false;
  }
  final prefix = type.importPrefix?.name.lexeme;
  if (prefix == null && _shadowed(source.ast, owner, expected)) return false;
  final visible = source.ast.directives
      .whereType<ImportDirective>()
      .where((node) => node.prefix?.name == prefix && _visible(node, expected))
      .toList();
  final canonical = visible.where(
    (node) => source.dependencies.any(
      (edge) =>
          edge.kind == 'import' &&
          edge.uri == node.uri.stringValue &&
          edge.target != null &&
          Uri(path: edge.target!).normalizePath().path == canonicalModel,
    ),
  );
  if (canonical.length != 1) return false;
  // Explicit direct local homonyms cannot certify the canonical import.
  for (final node in visible.where((node) => !canonical.contains(node))) {
    if (prefix != null) return false;
    for (final edge in source.dependencies.where(
      (edge) => edge.kind == 'import' && edge.uri == node.uri.stringValue,
    )) {
      final target = edge.target;
      if (target != null) {
        final unit = _directImportedUnit(snapshot, target);
        if (_declares(unit.ast, expected)) return false;
      }
    }
  }
  return true;
}

Source _directImportedUnit(Snapshot snapshot, String target) {
  final path = Uri(path: target).normalizePath().path;
  final source = snapshot.sources[path];
  if (source == null ||
      snapshot.libraries[path] != path ||
      source.ast.directives.any(
        (node) =>
            node is ExportDirective ||
            node is PartDirective ||
            node is PartOfDirective,
      )) {
    throw FormatException('Unsupported direct reading type namespace: $path');
  }
  return source;
}

bool _visible(ImportDirective node, String name) {
  for (final combinator in node.combinators) {
    if (combinator is ShowCombinator &&
        !combinator.shownNames.any((n) => n.name == name)) {
      return false;
    }
    if (combinator is HideCombinator &&
        combinator.hiddenNames.any((n) => n.name == name)) {
      return false;
    }
  }
  return true;
}

bool _shadowed(CompilationUnit unit, ClassDeclaration owner, String name) =>
    owner.namePart.typeParameters?.typeParameters.any(
          (p) => p.name.lexeme == name,
        ) ==
        true ||
    _declares(unit, name);

bool _declares(CompilationUnit unit, String name) => unit.declarations.any(
  (node) => switch (node) {
    ClassDeclaration node => node.namePart.typeName.lexeme == name,
    EnumDeclaration node => node.namePart.typeName.lexeme == name,
    MixinDeclaration node => node.name.lexeme == name,
    TypeAlias node => node.name.lexeme == name,
    ExtensionTypeDeclaration node =>
      node.primaryConstructor.typeName.lexeme == name,
    _ => false,
  },
);

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
