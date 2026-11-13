import 'package:analyzer/dart/ast/ast.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_DOWNLOAD_FILE_VALUE';
const library = 'lib/core/services/remote_files_client.dart';

/// Finite construction contract for the published authenticated download value.
List<Finding> check(Snapshot snapshot) {
  final source = snapshot.sources[library];
  if (source == null ||
      snapshot.libraries[library] != library ||
      source.ast.directives.any(
        (d) => d is PartDirective || d is PartOfDirective,
      ) ||
      source.ast.directives.whereType<NamespaceDirective>().any(
        (d) => d.configurations.isNotEmpty,
      )) {
    throw const FormatException('Unsupported canonical download library');
  }
  final classes = source.ast.declarations
      .whereType<ClassDeclaration>()
      .where((c) => c.namePart.typeName.lexeme == 'RemoteFileDownload')
      .toList();
  if (classes.length != 1 || classes.single.body is! BlockClassBody) {
    throw const FormatException('Missing canonical download value');
  }
  final owner = classes.single;
  final members = (owner.body as BlockClassBody).members;
  final fields = members
      .whereType<FieldDeclaration>()
      .where((f) => f.fields.variables.any((v) => v.name.lexeme == 'bytes'))
      .toList();
  final constructors = members.whereType<ConstructorDeclaration>().toList();
  if (fields.length != 1 ||
      constructors.length != 1 ||
      constructors.single.name != null) {
    throw const FormatException('Unsupported canonical download construction');
  }
  final field = fields.single;
  final captured = constructors.single.initializers
      .whereType<ConstructorFieldInitializer>()
      .where((i) => i.fieldName.name == 'bytes')
      .toList();
  final expression = captured.length == 1
      ? captured.single.expression.toSource().replaceAll(RegExp(r'\s+'), '')
      : '';
  final valid =
      owner.finalKeyword != null &&
      field.fields.isFinal &&
      !field.fields.isLate &&
      field.fields.type?.toSource() == 'Uint8List' &&
      !field.isStatic &&
      expression == 'Uint8List.fromList(bytes).asUnmodifiableView()';
  if (valid) return const [];
  return [
    Finding(
      id,
      library,
      source.lineAt(field.offset),
      'RemoteFileDownload.bytes',
      'Publish a sealed file value with final copied read-only bytes.',
    ),
  ];
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
