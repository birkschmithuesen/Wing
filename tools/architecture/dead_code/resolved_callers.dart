import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:crypto/crypto.dart';

import '../dart_sdk.dart';

/// An inventory query, not whole-program reachability or a deletion verdict.
/// Resolves authored units against their real SDK/package configuration.
Future<void> main(List<String> arguments) async {
  try {
    await _run(arguments);
  } catch (error) {
    // Source/manifest literals are not part of safe query diagnostics.
    stderr.writeln('[RESOLVED_CALLERS INPUT] ${error.runtimeType}');
    exitCode = 2;
  }
}

Future<void> _run(List<String> arguments) async {
  if (arguments.length != 3 &&
      !(arguments.length == 5 && arguments[3] == '--sdk')) {
    stderr.writeln(
      'Usage: resolved_callers.dart ROOT TARGETS_JSON OUTPUT_JSON [--sdk PATH]',
    );
    exitCode = 2;
    return;
  }
  final root = Directory(arguments[0]).resolveSymbolicLinksSync();
  final sdk = dartSdkPath(
    root,
    configured: arguments.length == 5 ? arguments[4] : null,
  );
  final manifest = jsonDecode(File(arguments[1]).readAsStringSync()) as Map;
  final targets = (manifest['targets'] as List).cast<Map>();
  final git = await Process.run('git', [
    '-C',
    root,
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  if (git.exitCode != 0) {
    stderr.writeln('Cannot enumerate authored Git scope');
    exitCode = 2;
    return;
  }
  List<String> authoredDart(String output) =>
      output
          .split('\u0000')
          .where((p) => p.endsWith('.dart'))
          .where((p) => File('$root/$p').existsSync())
          .where(
            (p) => [
              'lib/',
              'test/',
              'integration_test/',
              'test_driver/',
              'tools/',
            ].any(p.startsWith),
          )
          .toSet()
          .toList()
        ..sort();
  final paths = authoredDart(git.stdout as String);
  String hash(String content) =>
      sha256.convert(utf8.encode(content)).toString();
  final initialHashes = <String, String>{
    for (final path in paths)
      path: hash(File('$root/$path').readAsStringSync()),
  };
  final flags = (manifest['analyzer_feature_flags'] as List? ?? const [])
      .cast<String>();
  final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  if (flags.isNotEmpty) {
    // analyzer10.1 predates the pinned3.12 SDK's enabled private named fields.
    // Explicit flags are recorded proof inputs, never source/config mutations.
    final optionsPath = '$root/analysis_options.yaml';
    var options = File(optionsPath).existsSync()
        ? File(optionsPath).readAsStringSync()
        : '';
    if (options.contains('enable-experiment:')) {
      throw const FormatException(
        'Existing experimental flags need explicit merge review',
      );
    }
    final declaration =
        '  enable-experiment:\n${flags.map((f) => '    - $f\n').join()}';
    options = options.contains('\nanalyzer:\n')
        ? options.replaceFirst('\nanalyzer:\n', '\nanalyzer:\n$declaration')
        : '$options\nanalyzer:\n$declaration';
    overlay.setOverlay(optionsPath, content: options, modificationStamp: 0);
  }
  final collection = AnalysisContextCollection(
    includedPaths: [root],
    resourceProvider: overlay,
    sdkPath: sdk,
  );
  final refs = <Map<String, Object>>[];
  final inheritance = <Map<String, Object>>[];
  final unresolved = <Map<String, Object>>[];
  final failures = <Map<String, Object>>[];
  final sourceHashes = <String, String>{};
  final watch = Stopwatch()..start();
  try {
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      final absolute = '$root/$path';
      final result = await collection
          .contextFor(absolute)
          .currentSession
          .getResolvedUnit(absolute);
      if (result is! ResolvedUnitResult) {
        failures.add({'file': path, 'reason': result.runtimeType.toString()});
        continue;
      }
      final errors = result.diagnostics.where(
        (d) => d.diagnosticCode.severity.name == 'ERROR',
      );
      for (final error in errors) {
        failures.add({
          'file': path,
          'line': result.lineInfo.getLocation(error.offset).lineNumber,
          // Error messages can contain source literals; record codes only.
          'code': error.diagnosticCode.lowerCaseName,
        });
      }
      if (hash(result.content) != initialHashes[path]) {
        failures.add({
          'file': path,
          'reason': 'source changed while resolving',
        });
      }
      result.unit.accept(
        _References(root, path, result, targets, refs, unresolved, inheritance),
      );
      sourceHashes[path] = hash(result.content);
      if (i % 100 == 0) {
        stderr.writeln('Resolved ${i + 1}/${paths.length} authored units');
      }
    }
  } finally {
    await collection.dispose();
  }
  for (final path in paths) {
    if (hash(File('$root/$path').readAsStringSync()) != initialHashes[path]) {
      failures.add({'file': path, 'reason': 'source changed during query'});
    }
  }
  final finalCensus = await Process.run('git', [
    '-C',
    root,
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  if (finalCensus.exitCode != 0 ||
      jsonEncode(authoredDart(finalCensus.stdout as String)) !=
          jsonEncode(paths)) {
    failures.add({
      'file': '<authored-census>',
      'reason': 'authored Dart scope changed during query',
    });
  }
  int compare(Map<String, Object> a, Map<String, Object> b) =>
      jsonEncode(a).compareTo(jsonEncode(b));
  refs.sort(compare);
  unresolved.sort(compare);
  inheritance.sort(compare);
  failures.sort(compare);
  if (failures.isNotEmpty) {
    // Resolver diagnostics are failed inputs, never a caller-inventory proof.
    // Only codes and locations are safe: messages may contain source literals.
    stderr.writeln(jsonEncode({'resolution_failures': failures}));
    exitCode = 2;
    return;
  }
  File(arguments[2]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'purpose': 'resolved caller inventory; runtime roots and deletion closure require review', 'sdk': Platform.version.split(' on ').first, 'analysis_sdk_path': sdk, 'analysis_sdk_version': File('$sdk/version').readAsStringSync().trim(), 'analyzer_feature_flags': flags, 'authored_units': paths, 'resolved_source_sha256': sourceHashes, 'references': refs, 'target_owner_inheritance': inheritance, 'unresolved_candidate_spellings': unresolved, 'resolution_failures': failures, 'elapsed_ms_informational': watch.elapsedMilliseconds})}\n',
  );
  stdout.writeln(
    'Resolved ${paths.length} units: ${refs.length} references, '
    '${unresolved.length} unresolved candidate spellings, ${failures.length} errors',
  );
}

class _References extends RecursiveAstVisitor<void> {
  _References(
    this.root,
    this.file,
    this.result,
    this.targets,
    this.refs,
    this.unresolved,
    this.inheritance,
  );
  final String root, file;
  final ResolvedUnitResult result;
  final List<Map> targets;
  final List<Map<String, Object>> refs, unresolved;
  final List<Map<String, Object>> inheritance;
  final _seen = <String>{};

  String? _source(Element e) =>
      e.firstFragment.libraryFragment?.source.fullName;

  String _qualified(Element element) {
    final pieces = <String>[];
    Element? cursor = element.baseElement;
    while (cursor != null && cursor is! LibraryElement) {
      // Constructor displayName already contains its class. Its declared name
      // is instead `fromMap` or `new`, including through aliases/tear-offs.
      final name = cursor is ConstructorElement
          ? cursor.name ?? ''
          : cursor.displayName;
      if (name.isNotEmpty) pieces.insert(0, name);
      cursor = cursor.enclosingElement;
    }
    return pieces.join('.');
  }

  String _caller(AstNode node) {
    final pieces = <String>[];
    for (
      AstNode? cursor = node.parent;
      cursor != null;
      cursor = cursor.parent
    ) {
      if (cursor is MethodDeclaration) pieces.insert(0, cursor.name.lexeme);
      if (cursor is FunctionDeclaration) pieces.insert(0, cursor.name.lexeme);
      if (cursor is ConstructorDeclaration) {
        pieces.insert(0, cursor.name?.lexeme ?? 'new');
      }
      if (cursor is ClassDeclaration) {
        pieces.insert(0, cursor.namePart.typeName.lexeme);
      }
      if (cursor is EnumDeclaration) {
        pieces.insert(0, cursor.namePart.typeName.lexeme);
      }
      if (cursor is ExtensionDeclaration && cursor.name != null) {
        pieces.insert(0, cursor.name!.lexeme);
      }
      if (cursor is VariableDeclaration) pieces.insert(0, cursor.name.lexeme);
      if (cursor is GenericTypeAlias) pieces.insert(0, cursor.name.lexeme);
    }
    return pieces.isEmpty ? '<library>' : pieces.join('.');
  }

  void _record(AstNode node, Element? raw, String spelling) {
    if (raw == null) {
      if (targets.any(
        (t) => (t['symbol'] as String).split('.').last == spelling,
      )) {
        unresolved.add({
          'file': file,
          'line': result.lineInfo.getLocation(node.offset).lineNumber,
          'spelling': spelling,
          'caller': _caller(node),
          'syntax': node.runtimeType.toString().replaceAll('Impl', ''),
        });
      }
      return;
    }
    final element = raw.baseElement;
    final source = _source(element);
    if (source == null || !source.startsWith('$root/')) return;
    final ownerFile = source.substring(root.length + 1);
    final symbol = _qualified(element);
    for (final target in targets) {
      final wanted = target['symbol'] as String;
      if (target['file'] != ownerFile ||
          !(symbol == wanted ||
              (target['include_members'] == true &&
                  symbol.startsWith('$wanted.')))) {
        continue;
      }
      final key = '${target['id']}:$file:${node.offset}:$symbol';
      if (!_seen.add(key)) continue;
      refs.add({
        'target': target['id'] as String,
        'declaring_file': ownerFile,
        'symbol': symbol,
        'declaring_offset': element.firstFragment.offset,
        'declaring_line': element.firstFragment.libraryFragment!.lineInfo
            .getLocation(element.firstFragment.offset)
            .lineNumber,
        'file': file,
        'line': result.lineInfo.getLocation(node.offset).lineNumber,
        'offset': node.offset,
        'caller': _caller(node),
        'syntax': node.runtimeType.toString().replaceAll('Impl', ''),
      });
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    Element? element = node.element;
    if (element == null && node.inSetterContext()) {
      AstNode cursor = node;
      while (cursor.parent is PropertyAccess ||
          cursor.parent is PrefixedIdentifier) {
        cursor = cursor.parent!;
      }
      if (cursor.parent case CompoundAssignmentExpression assignment) {
        element = assignment.writeElement;
      }
    }
    // The enclosing constructor node owns one reference per syntax occurrence;
    // its named identifier is the same reference, not a second caller.
    final constructorChild =
        element is ConstructorElement &&
        (node.parent is ConstructorName ||
            node.parent is SuperConstructorInvocation ||
            node.parent is RedirectingConstructorInvocation);
    if (!node.inDeclarationContext() && !constructorChild) {
      _record(node, element, node.name);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final owners = <String>{
      for (final target in targets)
        if ((target['symbol'] as String).contains('.'))
          '${target['file']}#${(target['symbol'] as String).split('.').first}',
    };
    for (final type in [
      if (node.extendsClause != null) node.extendsClause!.superclass,
      ...?node.implementsClause?.interfaces,
      ...?node.withClause?.mixinTypes,
    ]) {
      final element = type.element;
      if (element == null) continue;
      final source = _source(element);
      if (source == null || !source.startsWith('$root/')) continue;
      final owner =
          '${source.substring(root.length + 1)}#${_qualified(element)}';
      if (!owners.contains(owner)) continue;
      inheritance.add({
        'file': file,
        'line': result.lineInfo.getLocation(type.offset).lineNumber,
        'class': node.namePart.typeName.lexeme,
        'target_owner': owner,
      });
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitNamedType(NamedType node) {
    _record(node, node.element, node.name.lexeme);
    super.visitNamedType(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _record(node, node.element, node.name?.name ?? 'new');
    super.visitConstructorName(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _record(node, node.element, node.constructorName?.name ?? 'new');
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _record(node, node.element, node.constructorName?.name ?? 'new');
    super.visitRedirectingConstructorInvocation(node);
  }
}
