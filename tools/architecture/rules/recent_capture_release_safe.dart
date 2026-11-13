import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_RECENT_CAPTURE_RELEASE_SAFE';
const owner =
    'lib/core/widgets/recent_conversations/recent_conversation_switcher.dart';

Future<List<Finding>> checkSnapshot(Snapshot snapshot) =>
    check(Directory(snapshot.root));

/// Flutter's debugNeedsPaint getter initializes its result only inside assert.
/// Capturing a recent conversation must never evaluate it in a release build.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final path = '$root/$owner';
  if (!File(path).existsSync()) {
    throw const FormatException('Missing recent conversation capture owner');
  }
  final parsed = parseString(
    content: File(path).readAsStringSync(),
    path: path,
    throwIfDiagnostics: false,
  );
  if (parsed.errors.isNotEmpty ||
      parsed.unit.directives.any(
        (directive) =>
            directive is PartDirective ||
            directive is PartOfDirective ||
            directive is NamespaceDirective &&
                directive.configurations.isNotEmpty,
      )) {
    throw const FormatException('Unsupported recent capture library');
  }
  final contexts = semanticContextCollection(
    root: root,
    sdk: dartSdkPath(root, configured: sdkPath),
    includedPaths: [path],
    cacheNamespace: 'recent-capture-release-safe',
  );
  try {
    final result = await contexts
        .contextFor(path)
        .currentSession
        .getResolvedUnit(path);
    if (result is! ResolvedUnitResult) {
      throw const FormatException('Recent capture owner cannot be resolved');
    }
    final findings = <Finding>[];
    result.unit.accept(_GetterReads(result, findings));
    return findings..sort();
  } finally {
    await contexts.dispose();
  }
}

class _GetterReads extends RecursiveAstVisitor<void> {
  _GetterReads(this.result, this.findings);

  final ResolvedUnitResult result;
  final List<Finding> findings;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element?.baseElement;
    if (node.name == 'debugNeedsPaint' &&
        node.inGetterContext() &&
        !node.inDeclarationContext() &&
        element == null) {
      throw const FormatException('Unresolved recent capture paint read');
    }
    if (node.inGetterContext() &&
        !node.inDeclarationContext() &&
        element is GetterElement &&
        element.name == 'debugNeedsPaint' &&
        element.enclosingElement.name == 'RenderObject' &&
        element.library.uri.toString() ==
            'package:flutter/src/rendering/object.dart' &&
        node.thisOrAncestorOfType<AssertStatement>() == null &&
        node.thisOrAncestorOfType<AssertInitializer>() == null) {
      findings.add(
        Finding(
          id,
          owner,
          result.lineInfo.getLocation(node.offset).lineNumber,
          'runtime-debug-needs-paint:${node.offset}',
          'Read RenderObject.debugNeedsPaint only inside assert; await the paint frame before capturing.',
        ),
      );
    }
    super.visitSimpleIdentifier(node);
  }
}

Future<void> main(List<String> args) async {
  try {
    var root = Directory.current.path;
    String? sdk;
    for (var index = 0; index < args.length; index += 2) {
      if (index + 1 >= args.length ||
          !{'--root', '--sdk'}.contains(args[index])) {
        throw const FormatException('Expected --root PATH or --sdk PATH');
      }
      if (args[index] == '--root') root = args[index + 1];
      if (args[index] == '--sdk') sdk = args[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdk);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
