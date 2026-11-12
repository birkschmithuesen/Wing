import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_CHAT_RUNTIME_OBSERVATION';
const owner = 'lib/core/services/profile_workspace_controller.dart';
const runtime = 'lib/core/services/chat_runtime.dart';
const runtimeQuestions = 'lib/core/services/chat_runtime_questions.dart';
const model = 'lib/core/models/chat_runtime.dart';
const stored = {
  'ChatApproval': {
    'correlation',
    'requestId',
    'serverRequestId',
    'request',
    'eventId',
  },
  'ChatQuestions': {'correlation', 'questions', 'answeredIds', 'lockedAnswers'},
  'ChatRuntimeObservation': {
    'runtimeId',
    'execution',
    'recovery',
    'liveSessionConfirmed',
    'openingError',
    'mainActivity',
    'mainToolActivity',
    'toolActivities',
    'activityEntries',
    'approvals',
    'approvalPosition',
    'approvalTotal',
    'approvalResponding',
    'questions',
    'secureInput',
    'secureResponding',
    'commandRunning',
    'changingAnswer',
    'error',
    'decisionError',
    'decisionErrorRequestId',
  },
};
ClassDeclaration _class(CompilationUnit unit, String name, String path) {
  final matches = unit.declarations
      .whereType<ClassDeclaration>()
      .where((node) => node.namePart.typeName.lexeme == name)
      .toList();
  if (matches.length != 1 || matches.single.body is! BlockClassBody) {
    throw FormatException('$path: missing/ambiguous canonical $name');
  }
  return matches.single;
}

void _noAncestry(ClassDeclaration node, String path) {
  if (node.extendsClause != null ||
      node.withClause != null ||
      node.implementsClause != null) {
    throw FormatException(
      '$path: inherited observation surface is unsupported',
    );
  }
}

bool _canonical(DartType? type, String root, String path, String name) =>
    type is InterfaceType &&
    type.nullabilitySuffix == NullabilitySuffix.none &&
    type.element.name == name &&
    type.element.library.firstFragment.source.fullName == '$root/$path';

/// Finite declaration/type boundary; no mutation, copying or async proof.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final units = <String, CompilationUnit>{};
  final lines = <String, int Function(int)>{};
  var hasRuntimeQuestions = false;
  for (final path in [owner, runtime, model]) {
    final file = File('$root/$path');
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty ||
        parsed.unit.directives.any(
          (node) =>
              node is PartOfDirective ||
              node is NamespaceDirective && node.configurations.isNotEmpty ||
              path != owner &&
                  node is PartDirective &&
                  !(path == runtime &&
                      node.uri.stringValue == 'chat_runtime_questions.dart'),
        )) {
      throw FormatException('$path: invalid or unsupported canonical unit');
    }
    units[path] = parsed.unit;
    lines[path] = (offset) => parsed.lineInfo.getLocation(offset).lineNumber;
    if (path == runtime) {
      final parts = parsed.unit.directives.whereType<PartDirective>().toList();
      if (parts.length > 1) {
        throw const FormatException('Duplicate canonical runtime part');
      }
      hasRuntimeQuestions = parts.isNotEmpty;
    }
  }
  if (hasRuntimeQuestions) {
    final file = File('$root/$runtimeQuestions');
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    final directives = parsed.unit.directives;
    final declarations = parsed.unit.declarations;
    if (parsed.errors.isNotEmpty ||
        directives.length != 1 ||
        directives.single is! PartOfDirective ||
        (directives.single as PartOfDirective).uri?.stringValue !=
            'chat_runtime.dart' ||
        declarations.length != 1 ||
        declarations.single is! ExtensionDeclaration) {
      throw const FormatException('Invalid canonical runtime questions part');
    }
    final extension = declarations.single as ExtensionDeclaration;
    if (extension.name?.lexeme != '_RuntimeQuestions' ||
        extension.typeParameters != null ||
        extension.body.members.any(
          (member) =>
              member is! MethodDeclaration ||
              member.isStatic ||
              !member.name.lexeme.startsWith('_'),
        )) {
      throw const FormatException('Unsupported runtime questions surface');
    }
  }
  _class(units[runtime]!, 'ChatRuntime', runtime);
  final chat = _class(units[owner]!, 'ProfileChat', owner);
  _noAncestry(chat, owner);
  final findings = <Finding>[];
  void reject(String path, AstNode node, String subject, String message) {
    findings.add(
      Finding(id, path, lines[path]!(node.offset), subject, message),
    );
  }

  for (final entry in stored.entries) {
    final value = _class(units[model]!, entry.key, model);
    _noAncestry(value, model);
    final seen = <String>{};
    for (final member in (value.body as BlockClassBody).members) {
      if (member is FieldDeclaration) {
        for (final field in member.fields.variables) {
          final name = field.name.lexeme;
          if (name.startsWith('_')) continue;
          if (entry.value.contains(name)) seen.add(name);
          if (member.isStatic && entry.value.contains(name)) {
            throw FormatException('$model: $name is not stored instance state');
          }
          if (!member.isStatic &&
              (!member.fields.isFinal ||
                  member.fields.isLate && field.initializer == null)) {
            reject(
              model,
              field,
              '${entry.key}.$name',
              'Capture passive runtime facts in final fields without public write slots.',
            );
          }
        }
      } else if (member is MethodDeclaration &&
          member.isSetter &&
          !member.name.lexeme.startsWith('_')) {
        reject(
          model,
          member,
          '${entry.key}.${member.name.lexeme}',
          'Remove the public setter from this passive runtime fact.',
        );
      }
    }
    if (!seen.containsAll(entry.value)) {
      throw FormatException('$model: missing ${entry.key} stored facts');
    }
  }
  final members = (chat.body as BlockClassBody).members;
  if (!members.whereType<MethodDeclaration>().any(
    (node) => node.name.lexeme == 'runtime' && node.isGetter,
  )) {
    reject(
      owner,
      chat,
      'ProfileChat.runtime',
      'Expose the canonical runtime through its passive observation getter.',
    );
  }
  // Validate authorities before diagnosing the original missing boundary.
  if (findings.isNotEmpty) return findings..sort();
  final contexts = semanticContextCollection(
    root: root,
    sdk: dartSdkPath(root, configured: sdkPath),
    includedPaths: ['$root/$owner'],
    cacheNamespace: 'chat-runtime-observation',
  );
  try {
    if (hasRuntimeQuestions) {
      final execution = await contexts
          .contextFor('$root/$owner')
          .currentSession
          .getResolvedLibrary('$root/$runtime');
      if (execution is! ResolvedLibraryResult ||
          execution.units.map((unit) => unit.path).toSet().length != 2 ||
          !execution.units.any(
            (unit) => unit.path == '$root/$runtimeQuestions',
          )) {
        throw const FormatException('Cannot resolve canonical runtime part');
      }
      final part = execution.units.singleWhere(
        (unit) => unit.path == '$root/$runtimeQuestions',
      );
      final extension = part.unit.declarations.single as ExtensionDeclaration;
      if (!_canonical(
        extension.onClause?.extendedType.type,
        root,
        runtime,
        'ChatRuntime',
      )) {
        throw const FormatException(
          'Runtime questions target is not canonical',
        );
      }
    }
    final result = await contexts
        .contextFor('$root/$owner')
        .currentSession
        .getResolvedLibrary('$root/$owner');
    if (result is! ResolvedLibraryResult) {
      throw const FormatException('Cannot resolve canonical chat library');
    }
    final unit = result.units.singleWhere(
      (unit) => unit.path == '$root/$owner',
    );
    final resolved = _class(unit.unit, 'ProfileChat', owner);
    if (result.units
            .expand((unit) => unit.unit.declarations)
            .whereType<ClassDeclaration>()
            .where((node) => node.namePart.typeName.lexeme == 'ProfileChat')
            .length !=
        1) {
      throw const FormatException('Ambiguous actual ProfileChat library');
    }
    final body = (resolved.body as BlockClassBody).members;
    final private = <(FieldDeclaration, VariableDeclaration)>[
      for (final field in body.whereType<FieldDeclaration>())
        for (final variable in field.fields.variables)
          if (variable.name.lexeme == '_runtime') (field, variable),
    ];
    final public = body
        .whereType<MethodDeclaration>()
        .where((node) => node.name.lexeme == 'runtime' && node.isGetter)
        .toList();
    if (private.length != 1 || public.length != 1) {
      throw const FormatException(
        'Missing canonical private runtime/getter surface',
      );
    }
    final (field, variable) = private.single;
    if (field.isStatic ||
        !field.fields.isFinal ||
        field.fields.isLate && variable.initializer == null ||
        !_canonical(
          variable.declaredFragment?.element.type,
          root,
          runtime,
          'ChatRuntime',
        )) {
      reject(
        owner,
        variable,
        'ProfileChat._runtime',
        'Retain one private final canonical ChatRuntime owner.',
      );
    }
    final getter = public.single;
    if (getter.isStatic ||
        getter.body is EmptyFunctionBody ||
        !_canonical(
          getter.declaredFragment?.element.returnType,
          root,
          model,
          'ChatRuntimeObservation',
        )) {
      reject(
        owner,
        getter,
        'ProfileChat.runtime',
        'Expose a nonnullable getter of the canonical ChatRuntimeObservation.',
      );
    }
    for (final member in body) {
      if (member is MethodDeclaration &&
          member.isGetter &&
          !member.name.lexeme.startsWith('_') &&
          _canonical(
            member.declaredFragment?.element.returnType,
            root,
            runtime,
            'ChatRuntime',
          )) {
        reject(
          owner,
          member,
          'ProfileChat.${member.name.lexeme}',
          'Keep runtime execution authority private.',
        );
      }
      if (member is MethodDeclaration &&
          member.isSetter &&
          {'runtime', '_runtime'}.contains(member.name.lexeme)) {
        reject(
          owner,
          member,
          'ProfileChat.${member.name.lexeme}',
          'Remove runtime setters; commands belong to the runtime owner.',
        );
      }
      if (member is FieldDeclaration) {
        for (final variable in member.fields.variables) {
          if (!variable.name.lexeme.startsWith('_') &&
              _canonical(
                variable.declaredFragment?.element.type,
                root,
                runtime,
                'ChatRuntime',
              )) {
            reject(
              owner,
              variable,
              'ProfileChat.${variable.name.lexeme}',
              'Keep runtime execution authority private.',
            );
          }
        }
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

Future<void> main(List<String> args) async {
  try {
    var root = '.';
    String? sdk;
    final seen = <String>{};
    for (var i = 0; i < args.length; i += 2) {
      if (i + 1 == args.length ||
          !{'--root', '--sdk'}.contains(args[i]) ||
          !seen.add(args[i])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (args[i] == '--root') root = args[i + 1];
      if (args[i] == '--sdk') sdk = args[i + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdk);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
