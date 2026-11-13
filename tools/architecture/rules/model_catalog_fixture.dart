import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../model.dart';

const id = 'ARCH_MODEL_CATALOG_FIXTURE';

/// Literal catalog responses in model/options branches have stock wire shapes.
/// This is a syntax contract for fixture producers, not HTTP route resolution.
List<Finding> checkSource(String source, String path) {
  final parsed = parseString(content: source, path: path);
  if (parsed.errors.isNotEmpty) {
    throw FormatException('$path: invalid Dart fixture input');
  }
  final findings = <Finding>[];
  void invalid(AstNode node, String message) => findings.add(
    Finding(
      id,
      path,
      parsed.lineInfo.getLocation(node.offset).lineNumber,
      'catalog:${node.offset}',
      message,
    ),
  );
  parsed.unit.accept(
    _Branches((expression) {
      if (expression is! SetOrMapLiteral) {
        throw FormatException(
          '$path: computed catalog requires guard adaptation',
        );
      }
      final map = _entries(expression, path);
      final rows = map['providers'];
      if (rows is! ListLiteral) {
        throw FormatException('$path: providers must be a literal list');
      }
      for (final row in _elements(rows.elements, path)) {
        if (row is! SetOrMapLiteral) {
          invalid(row, 'Provider rows must be stock catalog objects.');
          continue;
        }
        final fields = _entries(row, path);
        if (!_nonempty(fields['slug']) || _literal(fields['name']) == null) {
          invalid(row, 'Use a nonempty stock provider slug and string name.');
        }
        final models = fields['models'];
        if (models is! ListLiteral) {
          throw FormatException('$path: models must be a literal list');
        }
        for (final model in _elements(models.elements, path)) {
          if (!_nonempty(model)) {
            invalid(model, 'Stock catalog model IDs must be nonempty strings.');
          }
        }
      }
    }),
  );
  return findings..sort();
}

String? _literal(AstNode? node) =>
    node is StringLiteral ? node.stringValue : null;
bool _nonempty(AstNode? node) => _literal(node)?.trim().isNotEmpty == true;

Map<String, Expression> _entries(SetOrMapLiteral map, String path) {
  final result = <String, Expression>{};
  for (final element in map.elements) {
    if (element is! MapLiteralEntry || _literal(element.key) == null) {
      throw FormatException(
        '$path: computed catalog entries require adaptation',
      );
    }
    final key = _literal(element.key)!;
    if (result.containsKey(key)) {
      throw FormatException('$path: duplicate catalog field $key');
    }
    result[key] = element.value;
  }
  return result;
}

Iterable<AstNode> _elements(
  Iterable<CollectionElement> elements,
  String path,
) sync* {
  for (final element in elements) {
    if (element is IfElement) {
      yield* _elements([element.thenElement], path);
      if (element.elseElement case final other?) {
        yield* _elements([other], path);
      }
    } else if (element is Expression) {
      yield element;
    } else {
      throw FormatException('$path: computed catalog rows require adaptation');
    }
  }
}

class _Branches extends RecursiveAstVisitor<void> {
  _Branches(this.catalog);
  final void Function(Expression) catalog;

  @override
  void visitIfStatement(IfStatement node) {
    final condition = node.expression;
    bool endpoint(Expression value) => _literal(value) == 'model/options';
    if (condition is BinaryExpression &&
        condition.operator.lexeme == '==' &&
        (endpoint(condition.leftOperand) || endpoint(condition.rightOperand))) {
      node.thenStatement.accept(_Returns(catalog));
    }
    super.visitIfStatement(node);
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    final pattern = node.guardedPattern.pattern;
    if (pattern is ConstantPattern &&
        _literal(pattern.expression) == 'model/options') {
      catalog(node.expression);
    }
    super.visitSwitchExpressionCase(node);
  }
}

class _Returns extends RecursiveAstVisitor<void> {
  _Returns(this.catalog);
  final void Function(Expression) catalog;
  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final expression?) catalog(expression);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {}
}

List<Finding> check(Directory root) {
  final findings = <Finding>[];
  for (final area in ['test', 'integration_test', 'test_driver', 'tools']) {
    final directory = Directory('${root.path}/$area');
    if (!directory.existsSync()) continue;
    final files =
        directory
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final path = file.path.substring(root.path.length + 1);
      findings.addAll(checkSource(file.readAsStringSync(), path));
    }
  }
  return findings..sort();
}

void main(List<String> args) {
  try {
    if (args.isNotEmpty && (args.length != 2 || args.first != '--root')) {
      throw const FormatException('Use --root PATH or no options.');
    }
    final root = Directory(args.isEmpty ? '.' : args.last).absolute;
    if (!Directory('${root.path}/test').existsSync()) {
      throw const FormatException('Root must contain test/.');
    }
    final findings = check(root);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
