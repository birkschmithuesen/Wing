import 'package:analyzer/dart/ast/ast.dart';
import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_WORKSPACE_CANONICAL_STATE';
const library = 'lib/core/services/profile_workspace_controller.dart';
const observations = {
  'ProfileChat': {
    'archived',
    'changingIntelligence',
    'context',
    'intelligenceRuntime',
    'key',
    'lastActive',
    'markReadFailed',
    'model',
    'parentSessionId',
    'processes',
    'processesError',
    'processesLoading',
    'projectId',
    'projectLoading',
    'projectLookupFailed',
    'provider',
    'reasoningEffort',
    'reviewNotices',
    'sessionControl',
    'sessionControlError',
    'sessionControlLoading',
    'sessionControlNotice',
    'sessionControlWorking',
    'sideQuestionDeliveries',
    'source',
    'subagents',
    'subagentsError',
    'subagentsLoading',
    'title',
    'todoRevision',
    'todos',
    'unconfirmedSubagentIds',
    'yolo',
  },
  'ProfileWorkspaceData': {
    'archivedOnly',
    'chats',
    'deletedSessions',
    'loaded',
    'mutatingSessions',
    'nextSessionOffset',
    'offlineSnapshot',
    'projectGeneration',
    'projectSessions',
    'projectSessionsError',
    'projectSessionsLoading',
    'projects',
    'projectsError',
    'quarantinedSessions',
    'reconnectAttempt',
    'reconnectError',
    'recovering',
    'selectedProject',
    'selectedSession',
    'sessionGeneration',
    'sessions',
    'sessionsLoadingMore',
    'sessionsPageError',
  },
  'ProfileWorkspaceController': {
    'activityLoading',
    'activityProfileErrors',
    'current',
    'discovery',
    'error',
    'initialized',
    'recentsAvailableProfiles',
    'recentsLoaded',
    'recentsLoading',
    'recentsProfileErrors',
  },
};
const _compositionFields = {
  'ProfileChat': {'reading'},
  'ProfileWorkspaceData': {'gateway'},
  'ProfileWorkspaceController': {
    'access',
    'connectionIdentity',
    'preferences',
    'appPreferences',
    'attachments',
    'onAttention',
    'onNotificationInputs',
    'onNotificationRead',
    'notificationResultFor',
    'connectionStatus',
  },
};
const _retired = {'commandCatalog', 'retry', 'reconnectFuture'};

/// Declaration boundary only. Deep values and captured asynchronous command
/// admission require behavioral evidence; this does not infer getter purity.
List<Finding> check(Snapshot snapshot) {
  final sources = snapshot.sources.values
      .where((source) => snapshot.libraries[source.path] == library)
      .toList();
  if (!snapshot.sources.containsKey(library) || sources.isEmpty) {
    throw const FormatException('Missing canonical workspace library');
  }
  final findings = <Finding>[];
  for (final owner in observations.entries) {
    final matches = [
      for (final source in sources)
        for (final declaration
            in source.ast.declarations.whereType<ClassDeclaration>())
          if (declaration.namePart.typeName.lexeme == owner.key)
            (source, declaration),
    ];
    if (matches.length != 1 || matches.single.$2.body is! BlockClassBody) {
      throw FormatException('Missing/ambiguous ${owner.key}');
    }
    final (source, declaration) = matches.single;
    if (declaration.withClause != null ||
        declaration.implementsClause != null ||
        declaration.namePart.typeParameters != null) {
      throw FormatException('Unproved ${owner.key} inherited state');
    }
    final parent = declaration.extendsClause?.superclass;
    if (owner.key == 'ProfileWorkspaceController') {
      if (parent == null ||
          parent.name.lexeme != 'ChangeNotifier' ||
          parent.importPrefix != null ||
          parent.typeArguments != null ||
          !snapshot.sources[library]!.ast.directives
              .whereType<ImportDirective>()
              .any(
                (d) =>
                    d.uri.stringValue == 'package:flutter/foundation.dart' &&
                    d.prefix == null &&
                    d.combinators.isEmpty,
              ) ||
          sources.any(
            (source) => source.ast.declarations.any(
              (node) => switch (node) {
                ClassDeclaration node =>
                  node.namePart.typeName.lexeme == 'ChangeNotifier',
                ClassTypeAlias node => node.name.lexeme == 'ChangeNotifier',
                EnumDeclaration node =>
                  node.namePart.typeName.lexeme == 'ChangeNotifier',
                MixinDeclaration node => node.name.lexeme == 'ChangeNotifier',
                TypeAlias node => node.name.lexeme == 'ChangeNotifier',
                ExtensionTypeDeclaration node =>
                  node.primaryConstructor.typeName.lexeme == 'ChangeNotifier',
                _ => false,
              },
            ),
          )) {
        throw const FormatException('Unproved workspace notifier ancestry');
      }
    } else if (parent != null) {
      throw FormatException('Unproved ${owner.key} ancestry');
    }
    final surface = <String>{};
    void reject(AstNode node, String name) => findings.add(
      Finding(
        id,
        source.path,
        source.lineAt(node.offset),
        '${owner.key}.$name',
        'Keep canonical state private; expose readonly facts and existing explicit owner commands.',
      ),
    );
    for (final member in (declaration.body as BlockClassBody).members) {
      if (member is FieldDeclaration && !member.isStatic) {
        for (final field in member.fields.variables) {
          final name = field.name.lexeme;
          if (name.startsWith('_')) continue;
          surface.add(name);
          if (!member.fields.isFinal ||
              !_compositionFields[owner.key]!.contains(name)) {
            reject(field, name);
          }
        }
      } else if (member is MethodDeclaration && !member.isStatic) {
        final name = member.name.lexeme;
        if (name.startsWith('_')) continue;
        if (member.isSetter) {
          surface.add(name);
          reject(member, name);
        }
        if (member.isGetter) {
          surface.add(name);
          if (member.body is EmptyFunctionBody) {
            throw FormatException('Unsupported ${owner.key}.$name getter');
          }
          if (owner.key == 'ProfileWorkspaceController' &&
              name == 'discovery') {
            final body = member.body;
            final storedName = body is ExpressionFunctionBody
                ? switch (body.expression) {
                    SimpleIdentifier expression => expression.name,
                    PropertyAccess expression
                        when expression.target is ThisExpression =>
                      expression.propertyName.name,
                    _ => null,
                  }
                : null;
            final retained =
                storedName != null &&
                storedName.startsWith('_') &&
                (declaration.body as BlockClassBody).members
                    .whereType<FieldDeclaration>()
                    .any(
                      (field) =>
                          !field.isStatic &&
                          field.fields.variables.any(
                            (value) => value.name.lexeme == storedName,
                          ),
                    );
            if (!retained) reject(member, name);
          }
        }
        if (owner.key == 'ProfileWorkspaceData' && _retired.contains(name)) {
          reject(member, name);
        }
      }
    }
    if (!surface.containsAll(owner.value)) {
      throw FormatException('Missing ${owner.key} canonical observations');
    }
  }
  return findings..sort();
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
