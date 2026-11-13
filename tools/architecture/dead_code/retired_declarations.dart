import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart';
import '../model.dart';

const id = 'ARCH_RETIRED_DECLARATION';
const _supportedKinds = {'any', 'field'};

/// Declaration identity needs parsed ownership, not use-site symbol resolution.
/// Parts use the actual containing library from the shared snapshot.
List<Finding> check(Snapshot snapshot) {
  final data = jsonDecode(
    File(
      '${snapshot.root}/tools/architecture/dead_code/retired.json',
    ).readAsStringSync(),
  );
  if (data is! Map || data['schema'] != 2 || data['entries'] is! List) {
    throw const FormatException('Invalid retired-declaration manifest');
  }
  final retired = <String, Map<String, String>>{};
  for (final row in data['entries'] as List) {
    if (row is! Map ||
        row['library'] is! String ||
        row['symbol'] is! String ||
        row['kind'] is! String ||
        !_supportedKinds.contains(row['kind']) ||
        !(row['library'] as String).startsWith('lib/') ||
        !(row['library'] as String).endsWith('.dart') ||
        (row['symbol'] as String).isEmpty) {
      throw const FormatException('Invalid retired-declaration identity');
    }
    final entries = retired.putIfAbsent(row['library'] as String, () => {});
    if (entries.containsKey(row['symbol'])) {
      throw const FormatException('Duplicate retired-declaration identity');
    }
    entries[row['symbol'] as String] = row['kind'] as String;
  }
  final findings = <Finding>[];
  for (final source in snapshot.sources.values) {
    final library = snapshot.libraries[source.path];
    final isPart = source.partOf != null || source.namedPartOf;
    final owners = snapshot.partOwners[source.path] ?? const <String>[];
    if (isPart &&
        (owners.length != 1 ||
            library != owners.single ||
            (source.partOf != null && source.partOf != owners.single))) {
      throw const FormatException('Unverifiable containing library');
    }
    final banned = retired[library];
    if (banned == null) continue;
    source.ast.accept(_Declarations(source, banned, findings));
  }
  return findings..sort();
}

class _Declarations extends RecursiveAstVisitor<void> {
  _Declarations(this.source, this.retired, this.findings);
  final Source source;
  final Map<String, String> retired;
  final List<Finding> findings;

  void declaration(
    AstNode node,
    String name,
    int offset, {
    String kind = 'any',
  }) {
    final owners = <String>[];
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      final owner = switch (parent) {
        ClassDeclaration p => p.namePart.typeName.lexeme,
        EnumDeclaration p => p.namePart.typeName.lexeme,
        MixinDeclaration p => p.name.lexeme,
        ExtensionDeclaration p => p.name?.lexeme,
        ExtensionTypeDeclaration p => p.primaryConstructor.typeName.lexeme,
        _ => null,
      };
      if (owner != null) owners.insert(0, owner);
    }
    final symbol = [...owners, name].join('.');
    if (retired[symbol] == 'any' || retired[symbol] == kind) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(offset),
          symbol,
          'Remove the retired API; use the active feature/transport owner.',
        ),
      );
    }
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    declaration(
      node,
      node.namePart.typeName.lexeme,
      node.namePart.typeName.offset,
    );
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    declaration(
      node,
      node.namePart.typeName.lexeme,
      node.namePart.typeName.offset,
    );
    super.visitEnumDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    declaration(node, node.name.lexeme, node.name.offset);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    declaration(node, node.name.lexeme, node.name.offset);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    declaration(node, node.name.lexeme, node.name.offset);
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    declaration(node, node.name.lexeme, node.name.offset);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name;
    if (name != null) declaration(node, name.lexeme, name.offset);
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    final name = node.primaryConstructor.typeName;
    declaration(node, name.lexeme, name.offset);
    super.visitExtensionTypeDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // A same-name local closure is not the retired top-level API.
    if (node.parent is CompilationUnit) {
      declaration(node, node.name.lexeme, node.name.offset);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final name = node.name;
    declaration(node, name?.lexeme ?? 'new', name?.offset ?? node.offset);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    declaration(node, node.name.lexeme, node.name.offset);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final variable in node.fields.variables) {
      declaration(
        node,
        variable.name.lexeme,
        variable.name.offset,
        kind: 'field',
      );
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      declaration(node, variable.name.lexeme, variable.name.offset);
    }
    super.visitTopLevelVariableDeclaration(node);
  }
}

void main(List<String> args) => run(args, {id: check});
