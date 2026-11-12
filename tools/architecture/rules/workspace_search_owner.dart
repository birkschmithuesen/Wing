import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../cli.dart' as cli;
import '../model.dart';

const id = 'ARCH_WORKSPACE_SEARCH_OWNER';
const library = 'lib/core/services/profile_workspace_controller.dart';
const ownerClass = 'ProfileWorkspaceController';
const metadataSeams = {
  'refreshActivity',
  '_reconcileNotificationActivity',
  '_pendingChatTitle',
};

Expression? _unwrap(Expression? value) {
  while (true) {
    if (value is ParenthesizedExpression) {
      value = value.expression;
    } else if (value is PostfixExpression && value.operator.lexeme == '!') {
      value = value.operand;
    } else {
      return value;
    }
  }
}

// Syntactic member access, not gateway type identity or alias resolution.
bool _gatewayProperty(Expression? value) => switch (_unwrap(value)) {
  PropertyAccess access => access.propertyName.name == 'gateway',
  PrefixedIdentifier access => access.identifier.name == 'gateway',
  _ => false,
};

String? _libraryName(Source source) {
  final declarations = source.ast.directives.whereType<LibraryDirective>();
  return declarations.length == 1 ? declarations.single.name?.toSource() : null;
}

String? _partName(Source source) {
  final declarations = source.ast.directives.whereType<PartOfDirective>();
  return declarations.length == 1
      ? declarations.single.libraryName?.toSource()
      : null;
}

List<Source> _scope(Snapshot snapshot) {
  final containing = snapshot.sources[library];
  if (containing == null ||
      snapshot.libraries[library] != library ||
      containing.partOf != null ||
      containing.namedPartOf) {
    throw const FormatException('Missing canonical workspace library');
  }
  final scope = <Source>[containing];
  final declared = containing.partTargets.toSet();
  for (final path in containing.partTargets) {
    final part = snapshot.sources[path];
    final owners = snapshot.partOwners[path];
    if (part == null ||
        owners == null ||
        owners.length != 1 ||
        owners.single != library ||
        part.partTargets.isNotEmpty ||
        (part.partOf != library &&
            !(part.namedPartOf &&
                _libraryName(containing) != null &&
                _partName(part) == _libraryName(containing)))) {
      throw const FormatException('Invalid actual workspace part ownership');
    }
    scope.add(part);
  }
  for (final source in snapshot.sources.values) {
    if (!declared.contains(source.path) &&
        (source.partOf == library ||
            source.namedPartOf &&
                _libraryName(containing) != null &&
                _partName(source) == _libraryName(containing))) {
      throw const FormatException('Detached workspace part');
    }
  }
  return scope;
}

/// A finite boundary: physical .gateway.search calls in the actual workspace
/// library stay in its three captured metadata seams. This is not a semantic
/// proof of exact-ID filtering, transport identity, or publication lifetime.
List<Finding> check(Snapshot snapshot) {
  final scope = _scope(snapshot);
  final owners = scope
      .expand((source) => source.ast.declarations.whereType<ClassDeclaration>())
      .where((node) => node.namePart.typeName.lexeme == ownerClass)
      .toList();
  if (owners.length != 1 || owners.single.body is! BlockClassBody) {
    throw const FormatException(
      'Missing or ambiguous canonical workspace owner',
    );
  }
  final findings = <Finding>[];
  for (final source in scope) {
    source.ast.accept(_SearchCalls(source, owners.single, findings));
  }
  return findings..sort();
}

class _SearchCalls extends RecursiveAstVisitor<void> {
  _SearchCalls(this.source, this.owner, this.findings);
  final Source source;
  final ClassDeclaration owner;
  final List<Finding> findings;

  bool _metadataSeam(AstNode node) {
    for (var parent = node.parent; parent != null; parent = parent.parent) {
      // A separately named local helper is a new seam, even inside an allowed
      // method. Anonymous closures stay with their owning member.
      if (parent is FunctionDeclaration) return false;
      if (parent is MethodDeclaration) {
        return identical(parent.parent, owner.body) &&
            metadataSeams.contains(parent.name.lexeme);
      }
    }
    return false;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'search' &&
        _gatewayProperty(node.realTarget) &&
        !_metadataSeam(node)) {
      findings.add(
        Finding(
          id,
          source.path,
          source.lineAt(node.methodName.offset),
          'gateway.search@${node.methodName.offset}',
          'Keep interactive search in ChatBrowserData; workspace gateway search belongs only to captured activity, notification ownership, and title metadata recovery.',
        ),
      );
    }
    super.visitMethodInvocation(node);
  }
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
