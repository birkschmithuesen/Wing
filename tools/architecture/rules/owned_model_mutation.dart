import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../model.dart';
import '../semantic_context.dart';
import '../dart_sdk.dart';

const id = 'ARCH_OWNED_MODEL_MUTATION';
const owners = {
  'lib/core/services/profile_model_edit_session.dart':
      'ProfileGateway.postOwned',
  'lib/core/services/profile_fallback_edit_session.dart':
      'AdministrationRepository.ownedMutation',
  'lib/core/services/profile_model_defaults_session.dart':
      'AdministrationRepository.ownedMutation',
};
const _libraries = {
  'lib/core/services/profile_gateway.dart': 'ProfileGateway',
  'lib/core/services/administration_repository.dart':
      'AdministrationRepository',
};
const _generic = {
  'ProfileGateway.post',
  'ProfileGateway.put',
  'ProfileAdministration.write',
  'AdministrationRepository.request',
};
const _memberNames = {
  'post',
  'put',
  'write',
  'request',
  'postOwned',
  'ownedMutation',
};

bool _reference(SimpleIdentifier node) =>
    node.inGetterContext() &&
    !node.inDeclarationContext() &&
    node.parent is! Combinator;

bool _invoked(SimpleIdentifier node) {
  final parent = node.parent;
  if (parent is MethodInvocation && identical(parent.methodName, node)) {
    return true;
  }
  AstNode expression = node;
  if (parent is PrefixedIdentifier && identical(parent.identifier, node)) {
    expression = parent;
  } else if (parent is PropertyAccess && identical(parent.propertyName, node)) {
    expression = parent;
  }
  while (expression.parent is ParenthesizedExpression) {
    expression = expression.parent!;
  }
  final invocation = expression.parent;
  return invocation is FunctionExpressionInvocation &&
          identical(invocation.function, expression) ||
      invocation is MethodInvocation &&
          identical(invocation.target, expression) &&
          invocation.methodName.name == 'call';
}

Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  for (final path in _libraries.keys) {
    if (!File('$root/$path').existsSync()) {
      throw FormatException('Missing declared transport library $path');
    }
  }
  for (final path in owners.keys) {
    final parsed = parseString(
      content: File('$root/$path').readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty ||
        parsed.unit.directives.any(
          (node) =>
              node is PartDirective ||
              node is PartOfDirective ||
              node is NamespaceDirective && node.configurations.isNotEmpty,
        )) {
      throw FormatException(
        '$path: malformed, conditional or part owner requires guard adaptation',
      );
    }
  }
  final contexts = semanticContextCollection(
    root: root,
    includedPaths: [root],
    sdk: dartSdkPath(root, configured: sdkPath),
    cacheNamespace: 'owned-model-mutation',
    enableSdkExperiments: false,
  );
  final findings = <Finding>[];
  try {
    for (final entry in owners.entries) {
      final path = '$root/${entry.key}';
      final result = await contexts
          .contextFor(path)
          .currentSession
          .getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        throw FormatException('${entry.key}: owner cannot be resolved');
      }
      final visitor = _Owner(root, entry.key, entry.value, result, findings);
      result.unit.accept(visitor);
      if (visitor.invocations == 0) {
        findings.add(
          Finding(
            id,
            entry.key,
            1,
            'missing-owned-dispatch',
            'Use the explicit owned mutation capability ${entry.value}; generic transport dispatch cannot fence retired model commands.',
          ),
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

class _Owner extends RecursiveAstVisitor<void> {
  _Owner(this.root, this.path, this.requiredMember, this.result, this.findings);
  final String root, path, requiredMember;
  final ResolvedUnitResult result;
  final List<Finding> findings;
  int invocations = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_reference(node) && _memberNames.contains(node.name)) {
      final element = node.element?.baseElement;
      if (element == null) {
        throw FormatException(
          '$path: unresolved dispatch reference ${node.name}',
        );
      }
      final source = element.library?.firstFragment.source.fullName;
      final relative = source?.startsWith('$root/') == true
          ? source!.substring(root.length + 1)
          : null;
      final owner = element.enclosingElement?.name;
      final declared = _libraries[relative];
      final canonical =
          declared != null &&
          (owner == declared ||
              relative == 'lib/core/services/administration_repository.dart' &&
                  owner == 'ProfileAdministration');
      if (canonical) {
        final member = '$owner.${element.name}';
        if (_generic.contains(member)) {
          findings.add(
            Finding(
              id,
              path,
              result.lineInfo.getLocation(node.offset).lineNumber,
              'generic-dispatch:${node.offset}',
              'Use an owned model mutation capability instead of $member, including captured tearoffs.',
            ),
          );
        }
        if (member == requiredMember && _invoked(node)) invocations++;
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = '.';
    String? sdkPath;
    final seen = <String>{};
    for (var index = 0; index < args.length; index += 2) {
      if (index + 1 == args.length ||
          !{'--root', '--sdk'}.contains(args[index]) ||
          !seen.add(args[index])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (args[index] == '--root') root = args[index + 1];
      if (args[index] == '--sdk') sdkPath = args[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdkPath);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
