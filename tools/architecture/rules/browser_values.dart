import 'package:analyzer/dart/ast/ast.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_BROWSER_VALUES';
const library = 'lib/core/models/chat_list_view.dart';
const _types = {
  'ChatListEntry': {
    'WorkspaceScope',
    'String',
    'String?',
    'bool',
    'num',
    'int?',
    'ChatListStatus',
    'BrowserProject?',
  },
  'ChatListGroup': {
    'String',
    'List<ChatListEntry>',
    'BrowserProject?',
    'WorkspaceScope?',
  },
  'BrowserProject': {'String', 'bool'},
  'BrowserProfileRead': {'String?', 'bool', 'Set<String>'},
  'BrowserReadState': {'bool', 'String?', 'Map<String,BrowserProfileRead>'},
};
const _copies = {
  'ChatListGroup': ('entries', 'List.unmodifiable(entries)'),
  'BrowserProfileRead': ('searchMatches', 'Set.unmodifiable(searchMatches)'),
  'BrowserReadState': ('profiles', 'Map.unmodifiable(profiles)'),
};

/// The published canonical DTOs have scalar/typed final fields and finite
/// read-only collection construction. Admission parameters may be raw maps.
List<Finding> check(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.any(
        (d) => d is PartDirective || d is PartOfDirective,
      )) {
    throw const FormatException(
      'Missing/unsupported canonical browser value library',
    );
  }
  final classes = <String, ClassDeclaration>{};
  for (final declaration
      in source.ast.declarations.whereType<ClassDeclaration>()) {
    final name = declaration.namePart.typeName.lexeme;
    if (!_types.containsKey(name)) continue;
    if (classes.containsKey(name) || declaration.body is! BlockClassBody) {
      throw const FormatException('Ambiguous browser value declaration');
    }
    classes[name] = declaration;
  }
  final findings = <Finding>[];
  void inspect(String name) {
    final owner = classes[name];
    if (owner == null) throw FormatException('Missing browser value: $name');
    final members = (owner.body as BlockClassBody).members;
    final fields = members.whereType<FieldDeclaration>().toList();
    for (final field in fields) {
      final type = field.fields.type?.toSource().replaceAll(RegExp(r'\s+'), '');
      if (owner.finalKeyword == null ||
          !field.fields.isFinal ||
          field.fields.isLate ||
          field.isStatic ||
          !_types[name]!.contains(type)) {
        findings.add(
          Finding(
            id,
            library,
            source.lineAt(field.offset),
            '$name.${field.fields.variables.first.name.lexeme}',
            'Publish sealed final scalar/typed browser facts; admit raw rows inside the owner.',
          ),
        );
      }
    }
    final copy = _copies[name];
    if (copy == null) return;
    final constructors = members
        .whereType<ConstructorDeclaration>()
        .where((c) => c.name == null)
        .toList();
    if (constructors.length != 1) {
      throw FormatException('Unsupported browser value construction: $name');
    }
    final captures = constructors.single.initializers
        .whereType<ConstructorFieldInitializer>()
        .where((i) => i.fieldName.name == copy.$1)
        .toList();
    final expression = captures.length == 1
        ? captures.single.expression.toSource().replaceAll(RegExp(r'\s+'), '')
        : '';
    if (expression != copy.$2) {
      findings.add(
        Finding(
          id,
          library,
          source.lineAt(constructors.single.offset),
          '$name.${copy.$1}',
          'Copy the published collection into its explicit read-only value at construction.',
        ),
      );
    }
  }

  // Both existed in the original source: raw payloads produce strict exit 1,
  // rather than being hidden behind newly introduced model declarations.
  inspect('ChatListEntry');
  inspect('ChatListGroup');
  if (findings.isNotEmpty) return findings;
  for (final name in _types.keys.where(
    (n) => n != 'ChatListEntry' && n != 'ChatListGroup',
  )) {
    inspect(name);
  }
  return findings;
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
