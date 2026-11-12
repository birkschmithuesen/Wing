import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import '../model.dart';

const id = 'ARCH_PUBLIC_OWNER_STATE';
const owners = {
  'lib/core/controllers/voice_input_controller.dart': {
    'VoiceInputController': {'phase', 'partial', 'error', 'seconds'},
  },
  'lib/core/controllers/voice_output_controller.dart': {
    'VoiceOutputController': {'owner', 'preparing', 'error'},
  },
  'lib/core/services/scheduled_tasks_controller.dart': {
    'ScheduledTasksController': {
      'tasks',
      'loading',
      'error',
      'notice',
      'checkedAt',
      'busy',
      'uncertain',
    },
  },
  'lib/core/services/administration_health_session.dart': {
    'AdministrationHealthSession': {'overviews', 'persistenceError'},
  },
  'lib/core/services/administration_overview.dart': {
    'AdministrationOverview': {'observations', 'connectorChecks'},
    'AdministrationObservation': {'data', 'checkedAt', 'error', 'loading'},
  },
};

/// Checks declarations, not getter results or collection contents. Missing or
/// unsupported owner surfaces fail input rather than certify unknown ancestry.
List<Finding> check(Directory directory) {
  final root = directory.resolveSymbolicLinksSync();
  final findings = <Finding>[];
  for (final library in owners.entries) {
    final file = File('$root/${library.key}');
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    final unit = parsed.unit;
    if (parsed.errors.isNotEmpty ||
        unit.directives.any(
          (d) => d is PartDirective || d is PartOfDirective,
        ) ||
        unit.directives.whereType<NamespaceDirective>().any(
          (d) => d.configurations.isNotEmpty,
        )) {
      throw FormatException(
        '${library.key}: invalid or unsupported owner unit',
      );
    }
    for (final owner in library.value.entries) {
      final classes = unit.declarations
          .whereType<ClassDeclaration>()
          .where((d) => d.namePart.typeName.lexeme == owner.key)
          .toList();
      if (classes.length != 1 || classes.single.body is! BlockClassBody) {
        throw FormatException(
          '${library.key}: expected one ${owner.key} class',
        );
      }
      final declaration = classes.single;
      final value = owner.key == 'AdministrationObservation';
      _ancestry(unit, declaration, value, library.key);
      final surface = <String>{};
      final before = findings.length;
      var unsupportedValueGetter = false;
      void invalid(AstNode node, String name, String message) {
        findings.add(
          Finding(
            id,
            library.key,
            parsed.lineInfo.getLocation(node.offset).lineNumber,
            '${owner.key}.$name',
            message,
          ),
        );
      }

      for (final member in (declaration.body as BlockClassBody).members) {
        if (member is FieldDeclaration) {
          for (final field in member.fields.variables) {
            final name = field.name.lexeme;
            if (!owner.value.contains(name)) continue;
            if (member.isStatic) {
              throw FormatException(
                '${library.key}: $name must be instance state',
              );
            }
            surface.add(name);
            if (!value ||
                !member.fields.isFinal ||
                member.fields.isLate && field.initializer == null) {
              invalid(
                field,
                name,
                value
                    ? 'Capture this observation in a final field without a public late-write slot.'
                    : 'Keep authoritative state private and expose an instance getter.',
              );
            }
          }
        } else if (member is MethodDeclaration &&
            owner.value.contains(member.name.lexeme)) {
          final name = member.name.lexeme;
          if (member.isStatic) {
            throw FormatException(
              '${library.key}: $name must be instance state',
            );
          }
          if (member.isSetter) {
            surface.add(name);
            invalid(
              member,
              name,
              'Remove the public setter; mutate authoritative state through its owner commands.',
            );
          }
          if (member.isGetter) {
            if (member.body is EmptyFunctionBody) {
              throw FormatException(
                '${library.key}: unsupported $name observation surface',
              );
            }
            unsupportedValueGetter |= value;
            surface.add(name);
          }
        }
      }
      if (unsupportedValueGetter && findings.length == before) {
        throw FormatException(
          '${library.key}: observation requires final captured fields',
        );
      }
      if (!surface.containsAll(owner.value)) {
        throw FormatException(
          '${library.key}: missing ${owner.key} observation members',
        );
      }
    }
  }
  return findings..sort();
}

void _ancestry(
  CompilationUnit unit,
  ClassDeclaration declaration,
  bool value,
  String path,
) {
  if (declaration.withClause != null || declaration.implementsClause != null) {
    throw FormatException('$path: inherited state requires separate proof');
  }
  final parent = declaration.extendsClause?.superclass;
  if (value) {
    if (parent != null) {
      throw FormatException('$path: value ancestry unsupported');
    }
    return;
  }
  if (parent == null ||
      parent.name.lexeme != 'ChangeNotifier' ||
      parent.typeArguments != null) {
    throw FormatException('$path: unknown owner ancestry');
  }
  final prefix = parent.importPrefix?.name.lexeme;
  final framework = unit.directives.whereType<ImportDirective>().any((d) {
    if (d.uri.stringValue != 'package:flutter/foundation.dart' ||
        d.prefix?.name != prefix) {
      return false;
    }
    var visible = true;
    for (final combinator in d.combinators) {
      if (combinator is ShowCombinator) {
        visible &= combinator.shownNames.any((n) => n.name == 'ChangeNotifier');
      } else if (combinator is HideCombinator) {
        visible &= !combinator.hiddenNames.any(
          (n) => n.name == 'ChangeNotifier',
        );
      }
    }
    return visible;
  });
  final shadow =
      declaration.namePart.typeParameters?.typeParameters.any(
            (p) => p.name.lexeme == 'ChangeNotifier',
          ) ==
          true ||
      unit.declarations.any(
        (d) => switch (d) {
          ClassDeclaration d => d.namePart.typeName.lexeme == 'ChangeNotifier',
          EnumDeclaration d => d.namePart.typeName.lexeme == 'ChangeNotifier',
          MixinDeclaration d => d.name.lexeme == 'ChangeNotifier',
          TypeAlias d => d.name.lexeme == 'ChangeNotifier',
          ExtensionTypeDeclaration d =>
            d.primaryConstructor.typeName.lexeme == 'ChangeNotifier',
          _ => false,
        },
      );
  if (!framework || prefix == null && shadow) {
    throw FormatException('$path: ChangeNotifier origin unproved');
  }
}

void main(List<String> arguments) {
  try {
    if (arguments.isNotEmpty &&
        (arguments.length != 2 || arguments.first != '--root')) {
      throw const FormatException('Use [--root PATH]');
    }
    final findings = check(Directory(arguments.isEmpty ? '.' : arguments.last));
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
