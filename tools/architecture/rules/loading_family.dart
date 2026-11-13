import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart';
import '../flutter_widget_identity.dart' show flutterNameIsLocallyBound;
import '../model.dart';

const id = 'ARCH_LOADING_FAMILY';
const owner = 'lib/core/widgets/studio_loading.dart';
const desktopChatRows = 'lib/core/screens/profile_workspace_browser.dart';
const workStatusOwners = {
  'lib/core/widgets/profile_chat_indicator.dart',
  'lib/core/widgets/profile_activity_status.dart',
  'lib/core/screens/bots/bot_group_screen.dart',
  'lib/core/widgets/tool_activity_details.dart',
  'lib/core/widgets/recent_identity_card.dart',
  'lib/core/screens/bots/bots_content.dart',
  'lib/core/screens/administration/scheduled_task_widgets.dart',
};
const headerOwners = {
  'lib/core/widgets/studio_form_actions.dart',
  'lib/core/widgets/wing_app_bar.dart',
  'lib/core/widgets/deleted_chat_recovery_notice.dart',
  'lib/core/widgets/text_size_settings_card.dart',
  'lib/core/widgets/recent_conversations/recent_conversation_switcher.dart',
  'lib/core/widgets/chat_find_sheet.dart',
  'lib/core/widgets/profile_default_model_sheet.dart',
  'lib/core/screens/bots/bot_screen_view.dart',
};
const _retired = {
  'StudioLoadingOverlay',
  'StudioActivityIndicator',
  'StudioWorkProgress',
  'ActivityShimmer',
};
const _symbols = {
  'StudioLoading',
  'StudioLoadingSlot',
  'StudioWorkingIndicator',
  'ChatWorkingBorder',
  ..._retired,
};

/// Restricts references to branded progress widgets to their presentation owners.
/// Native component indicators are allowed. Runtime admission, elected header
/// priority and route visibility belong to behavioral tests, not this rule.
List<Finding> check(Snapshot snapshot) {
  final namespace = _Namespace(snapshot);
  final findings = <Finding>[];
  for (final source in snapshot.sources.values) {
    final visitor = _References(namespace, source.path);
    source.ast.accept(visitor);
    for (final offset in visitor.offsets.toList()..sort()) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(offset),
          'shared-owner',
          'Keep Wing progress in its shared header or work-status owner; use a native indicator or static semantic glyph in components.',
        ),
      );
    }
  }
  return findings;
}

class _Namespace {
  _Namespace(this.snapshot) {
    for (final source in snapshot.sources.values) {
      for (final alias
          in source.ast.declarations.whereType<GenericTypeAlias>()) {
        names.add(alias.name.lexeme);
      }
    }
  }
  final names = {..._symbols};
  final _units = <String, List<Source>>{};
  final Snapshot snapshot;
  String library(String path) => snapshot.libraries[path] ?? path;
  Iterable<Source> units(String path) => _units.putIfAbsent(
    library(path),
    () => snapshot.sources.values
        .where((s) => library(s.path) == library(path))
        .toList(),
  );

  // Follow only authored namespaces. Matching is by declaration provenance,
  // so an unrelated local/imported widget with the same spelling stays valid.
  String? symbol(
    String path,
    String name, {
    String? prefix,
    bool exported = false,
    Set<String>? seen,
  }) {
    final visited = {...?seen};
    if (!visited.add('$path:$name:$prefix:$exported')) return null;
    if (prefix == null) {
      for (final unit in units(path)) {
        for (final declaration in unit.ast.declarations) {
          if (declaration is ClassDeclaration &&
              declaration.namePart.typeName.lexeme == name) {
            final origin = library(unit.path);
            if (origin == owner ||
                origin == 'lib/core/widgets/chat_working_border.dart' ||
                origin == 'lib/core/widgets/activity_shimmer.dart') {
              return name;
            }
            return null;
          }
          if (declaration is GenericTypeAlias &&
              declaration.name.lexeme == name &&
              declaration.type is NamedType) {
            final type = declaration.type as NamedType;
            return symbol(
              unit.path,
              type.name.lexeme,
              prefix: type.importPrefix?.name.lexeme,
              seen: visited,
            );
          }
        }
      }
    }
    for (final unit in units(path)) {
      for (final directive
          in unit.ast.directives.whereType<NamespaceDirective>()) {
        if (exported && directive is! ExportDirective) continue;
        if (directive is ImportDirective && directive.prefix?.name != prefix) {
          continue;
        }
        if (directive is ExportDirective && prefix != null) continue;
        if (directive.combinators.any(
          (c) =>
              c is ShowCombinator && !c.shownNames.any((n) => n.name == name) ||
              c is HideCombinator && c.hiddenNames.any((n) => n.name == name),
        )) {
          continue;
        }
        for (final uri in [
          directive.uri.stringValue,
          ...directive.configurations.map((c) => c.uri.stringValue),
        ]) {
          final target = unit.dependencies
              .where((d) => d.uri == uri)
              .firstOrNull
              ?.target;
          if (target == null) continue;
          // Retired declarations deliberately no longer exist in production.
          if (_retired.contains(name) &&
              (target == owner ||
                  target == 'lib/core/widgets/activity_shimmer.dart')) {
            return name;
          }
          final resolved = symbol(target, name, exported: true, seen: visited);
          if (resolved != null) return resolved;
        }
      }
    }
    return null;
  }
}

class _References extends RecursiveAstVisitor<void> {
  _References(this.namespace, this.path);
  final _Namespace namespace;
  final String path;
  final offsets = <int>{};
  bool forbidden(String? symbol) =>
      symbol != null &&
      (_retired.contains(symbol) ||
          symbol == 'StudioLoading' && path != owner ||
          symbol == 'StudioLoadingSlot' &&
              path != owner &&
              !headerOwners.contains(path) ||
          symbol == 'StudioWorkingIndicator' &&
              path != owner &&
              !workStatusOwners.contains(path) ||
          symbol == 'ChatWorkingBorder' &&
              path != desktopChatRows &&
              path != 'lib/core/widgets/chat_working_border.dart');
  void inspect(AstNode node, String name, String? prefix, int offset) {
    if (!namespace.names.contains(name) ||
        ((node is! NamedType || node.parent is ConstructorName) &&
            flutterNameIsLocallyBound(node, prefix ?? name))) {
      return;
    }
    if (forbidden(namespace.symbol(path, name, prefix: prefix))) {
      offsets.add(offset);
    }
  }

  @override
  void visitNamedType(NamedType node) {
    if (node.name.lexeme == 'page' &&
        !flutterNameIsLocallyBound(
          node,
          node.importPrefix?.name.lexeme ?? '',
        ) &&
        node.importPrefix != null &&
        namespace.symbol(path, node.importPrefix!.name.lexeme) ==
            'StudioLoading') {
      offsets.add(node.offset);
    }
    if (node.parent case ConstructorName(name: final name?)
        when name.name == 'page' &&
            !flutterNameIsLocallyBound(
              node,
              node.importPrefix?.name.lexeme ?? node.name.lexeme,
            )) {
      if (namespace.symbol(
            path,
            node.name.lexeme,
            prefix: node.importPrefix?.name.lexeme,
          ) ==
          'StudioLoading') {
        offsets.add(node.offset);
      }
    }
    inspect(
      node,
      node.name.lexeme,
      node.importPrefix?.name.lexeme,
      node.offset,
    );
    super.visitNamedType(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'page') {
      final target = node.target;
      final (String?, String?) name = switch (target) {
        SimpleIdentifier() => (target.name, null),
        PrefixedIdentifier() => (target.identifier.name, target.prefix.name),
        _ => (null, null),
      };
      if (name.$1 != null &&
          !flutterNameIsLocallyBound(node, name.$2 ?? name.$1!) &&
          namespace.symbol(path, name.$1!, prefix: name.$2) ==
              'StudioLoading') {
        offsets.add(node.offset);
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName.name == 'page') {
      final target = node.target;
      if (target is SimpleIdentifier &&
              !flutterNameIsLocallyBound(node, target.name) &&
              namespace.symbol(path, target.name) == 'StudioLoading' ||
          target is PrefixedIdentifier &&
              !flutterNameIsLocallyBound(node, target.prefix.name) &&
              namespace.symbol(
                    path,
                    target.identifier.name,
                    prefix: target.prefix.name,
                  ) ==
                  'StudioLoading') {
        offsets.add(node.offset);
      }
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.parent case PrefixedIdentifier(
      identifier: final member,
      prefix: final target,
    ) when member.name == 'page' && identical(member, node)) {
      if (!flutterNameIsLocallyBound(node, target.name) &&
          namespace.symbol(path, target.name) == 'StudioLoading') {
        offsets.add(node.parent!.offset);
      }
    }
    if (node.inDeclarationContext()) return;
    final parent = node.parent;
    if (parent is PrefixedIdentifier && identical(parent.identifier, node)) {
      inspect(node, node.name, parent.prefix.name, parent.offset);
    } else if (parent is MethodInvocation &&
        identical(parent.methodName, node)) {
      final target = parent.target;
      inspect(
        node,
        node.name,
        target is SimpleIdentifier ? target.name : null,
        parent.offset,
      );
    } else {
      inspect(node, node.name, null, node.offset);
    }
    super.visitSimpleIdentifier(node);
  }
}

Future<void> main(List<String> args) => run(args, {id: check});
