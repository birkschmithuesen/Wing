import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/source.dart' as analyzer_source;
import 'package:analyzer/src/generated/source.dart' show SourceFactory;

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_BROWSER_ROW_WORK';
const browserLibrary = 'lib/core/services/chat_browser_data.dart';
const controllerLibrary = 'lib/core/services/profile_workspace_controller.dart';
const _member = 'browserResource';

/// Ban one canonical index accessor inside one canonical row refresh. The name
/// prefilter never produces findings: candidates use actual resolved elements.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final sdk = dartSdkPath(root, configured: sdkPath);
  final path = '$root/$browserLibrary';
  // The locked analyzer predates the pinned SDK's private named parameters.
  // Enable that actual SDK feature in memory; no application bytes are changed.
  final optionsPath = '$root/analysis_options.yaml';
  var options = File(optionsPath).existsSync()
      ? File(optionsPath).readAsStringSync()
      : '';
  if (options.contains('enable-experiment:')) {
    throw const FormatException('Experimental options require explicit review');
  }
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: [path],
    cacheNamespace: 'browser-row-work',
  );
  final findings = <Finding>[];
  try {
    final driver = contexts.contextFor(path).driver;
    final graph = _Parsed(root, driver.sourceFactory);
    graph.library('$root/$browserLibrary');
    graph.library('$root/$controllerLibrary');
    final row = _row(graph.ownerUnits('$root/$browserLibrary'));
    final controller = graph
        .ownerUnits('$root/$controllerLibrary')
        .expand((unit) => unit.declarations)
        .whereType<ClassDeclaration>()
        .where(
          (node) =>
              node.namePart.typeName.lexeme == 'ProfileWorkspaceController',
        )
        .toList();
    if (controller.length != 1 ||
        _members(controller.single)
                .whereType<MethodDeclaration>()
                .where((node) => node.name.lexeme == _member)
                .length !=
            1) {
      throw const FormatException(
        'One canonical controller accessor is required',
      );
    }
    // Initializer aliases may live outside the method, including imported fields.
    // This overapproximates lexical names; resolution establishes real bindings.
    final initializers = <String, List<AstNode>>{};
    for (final unit in graph.units.values) {
      unit.accept(
        _Initializers((variable) {
          final expression = variable.initializer;
          if (expression != null &&
              (variable.parent?.parent is TopLevelVariableDeclaration ||
                  variable.parent?.parent is FieldDeclaration ||
                  variable.thisOrAncestorOfType<MethodDeclaration>() == row)) {
            initializers
                .putIfAbsent(variable.name.lexeme, () => [])
                .add(expression);
          }
        }),
      );
      unit.accept(
        _TopGetters((getter) {
          if (getter.isGetter) {
            initializers
                .putIfAbsent(getter.name.lexeme, () => [])
                .add(getter.functionExpression.body);
          }
        }),
      );
      unit.accept(
        _Getters((getter) {
          if (getter.isGetter) {
            initializers
                .putIfAbsent(getter.name.lexeme, () => [])
                .add(getter.body);
          }
        }),
      );
    }
    final aliases = <String>{_member};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in initializers.entries) {
        if (!aliases.contains(entry.key) &&
            entry.value.any(
              (value) => _Names.of(value).any(aliases.contains),
            )) {
          changed = aliases.add(entry.key) || changed;
        }
      }
    }
    if (!_Names.of(row.body).any(aliases.contains)) return [];

    final session = contexts.contextFor(path).currentSession;
    final resolved = await session.getResolvedLibrary(path);
    if (resolved is! ResolvedLibraryResult) {
      throw const FormatException('Cannot resolve browser containing library');
    }
    void valid(ResolvedUnitResult unit) {
      if (unit.diagnostics.any(
        (value) => value.diagnosticCode.severity.name == 'ERROR',
      )) {
        throw FormatException(
          'Candidate input has semantic errors: ${unit.diagnostics.where((value) => value.diagnosticCode.severity.name == 'ERROR').map((value) => value.diagnosticCode.lowerCaseName).toSet().join(', ')}',
        );
      }
    }

    resolved.units.forEach(valid);
    final target = _row(resolved.units.map((unit) => unit.unit));
    final bindings = <Element, ({AstNode node, bool initializer})>{};
    // Resolve only authored units containing a possible initializer alias.
    for (final entry in graph.units.entries) {
      final variables = <VariableDeclaration>[];
      entry.value.accept(_Initializers(variables.add));
      final getters = <MethodDeclaration>[];
      entry.value.accept(_Getters(getters.add));
      final topGetters = <FunctionDeclaration>[];
      entry.value.accept(_TopGetters(topGetters.add));
      if (!topGetters.any(
            (node) => node.isGetter && aliases.contains(node.name.lexeme),
          ) &&
          !variables.any((node) => aliases.contains(node.name.lexeme)) &&
          !getters.any(
            (node) => node.isGetter && aliases.contains(node.name.lexeme),
          )) {
        continue;
      }
      final result = await session.getResolvedUnit(entry.key);
      if (result is! ResolvedUnitResult) {
        throw const FormatException('Cannot resolve alias input');
      }
      valid(result);
      result.unit.accept(
        _TopGetters((getter) {
          final element = getter.declaredFragment?.element;
          final body = getter.functionExpression.body;
          if (element != null && getter.isGetter) {
            bindings[element.baseElement] = (node: body, initializer: false);
          }
        }),
      );
      result.unit.accept(
        _Getters((getter) {
          final element = getter.declaredFragment?.element;
          if (element != null && getter.isGetter) {
            bindings[element.baseElement] = (
              node: getter.body,
              initializer: false,
            );
          }
        }),
      );
      result.unit.accept(
        _Initializers((variable) {
          final element = variable.declaredFragment?.element;
          if (element != null && variable.initializer != null) {
            bindings[element.baseElement] = (
              node: variable.initializer!,
              initializer: true,
            );
          }
        }),
      );
    }
    // Always include selected local aliases even when their lexical names are
    // shadowed by unrelated declarations elsewhere in the namespace.
    for (final unit in resolved.units) {
      unit.unit.accept(
        _Initializers((variable) {
          final element = variable.declaredFragment?.element;
          if (element != null && variable.initializer != null) {
            bindings[element.baseElement] = (
              node: variable.initializer!,
              initializer: true,
            );
          }
        }),
      );
    }
    bool forbidden(Element? raw) {
      final element = raw?.baseElement;
      return element is MethodElement &&
          element.name == _member &&
          element.enclosingElement?.name == 'ProfileWorkspaceController' &&
          element.library.firstFragment.source.fullName ==
              '$root/$controllerLibrary';
    }

    bool inspect(
      AstNode node,
      Set<Element> visiting, {
      bool initializer = false,
    }) {
      final names = _References();
      node.accept(names);
      for (final reference in names.values) {
        final raw = reference.element?.baseElement;
        if (raw == null && reference.name == _member) {
          throw const FormatException('Unknown browser accessor candidate');
        }
        if (forbidden(raw)) {
          final parent = reference.parent;
          final immediateCall =
              parent is MethodInvocation && parent.methodName == reference;
          var deferred = false;
          for (
            AstNode? ancestor = reference.parent;
            ancestor != null && ancestor != node.parent;
            ancestor = ancestor.parent
          ) {
            if (ancestor is FunctionExpression) deferred = true;
          }
          // A retained non-callable result produced once outside the row is
          // not a tear-off alias or per-row accessor invocation.
          if (!initializer || !immediateCall || deferred) return true;
        }
        final element = raw is PropertyAccessorElement
            ? raw.variable.baseElement
            : raw;
        final binding = bindings[raw] ?? bindings[element];
        if (element != null && binding != null && visiting.add(element)) {
          if (inspect(
            binding.node,
            visiting,
            initializer: binding.initializer,
          )) {
            return true;
          }
          visiting.remove(element);
        }
      }
      return false;
    }

    // Report actual references/captures at their use in the row body, rather
    // than the unrelated initializer's declaration location.
    final references = _References();
    target.body.accept(references);
    final unit = resolved.units.singleWhere(
      (unit) => unit.unit == target.thisOrAncestorOfType<CompilationUnit>(),
    );
    for (final reference in references.values) {
      if (inspect(reference, <Element>{})) {
        findings.add(
          Finding(
            id,
            graph.relative(unit.path),
            unit.lineInfo.getLocation(reference.offset).lineNumber,
            'row-index-access:${reference.offset}',
            'Use the retained captured-key chat observation in row refresh; '
                'keep connection-wide browserResource access outside _refreshRow.',
          ),
        );
      }
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

Iterable<ClassMember> _members(ClassDeclaration node) {
  final body = node.body;
  if (body is! BlockClassBody) {
    throw const FormatException('Canonical class needs a concrete body');
  }
  return body.members;
}

MethodDeclaration _row(Iterable<CompilationUnit> units) {
  final classes = units
      .expand((unit) => unit.declarations)
      .whereType<ClassDeclaration>()
      .where((node) => node.namePart.typeName.lexeme == 'ChatBrowserData')
      .toList();
  if (classes.length != 1) {
    throw const FormatException('One canonical ChatBrowserData is required');
  }
  final methods = _members(classes.single)
      .whereType<MethodDeclaration>()
      .where((node) => node.name.lexeme == '_refreshRow')
      .toList();
  if (methods.length != 1 || methods.single.body is EmptyFunctionBody) {
    throw const FormatException('One concrete row refresh is required');
  }
  return methods.single;
}

class _Initializers extends RecursiveAstVisitor<void> {
  _Initializers(this.visit);
  final void Function(VariableDeclaration) visit;
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    visit(node);
    super.visitVariableDeclaration(node);
  }
}

class _TopGetters extends RecursiveAstVisitor<void> {
  _TopGetters(this.visit);
  final void Function(FunctionDeclaration) visit;
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    visit(node);
    super.visitFunctionDeclaration(node);
  }
}

class _Getters extends RecursiveAstVisitor<void> {
  _Getters(this.visit);
  final void Function(MethodDeclaration) visit;
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    visit(node);
    super.visitMethodDeclaration(node);
  }
}

class _References extends RecursiveAstVisitor<void> {
  final values = <SimpleIdentifier>[];
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        !node.inDeclarationContext() &&
        node.parent is! Combinator &&
        node.parent is! Label) {
      values.add(node);
    }
    super.visitSimpleIdentifier(node);
  }
}

class _Names extends RecursiveAstVisitor<void> {
  final names = <String>{};
  static Set<String> of(AstNode node) {
    final visitor = _Names();
    node.accept(visitor);
    return visitor.names;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext() && node.parent is! Label) {
      names.add(node.name);
    }
    super.visitSimpleIdentifier(node);
  }
}

/// Authored namespace/part/syntax validation runs before the candidate filter.
/// Installed dependency contents are analyzer-owned, never masqueraded as app.
class _Parsed {
  _Parsed(this.root, this.factory) {
    final config = File('$root/.dart_tool/package_config.json');
    if (config.existsSync()) {
      final data = jsonDecode(config.readAsStringSync()) as Map;
      for (final value in (data['packages'] as List).cast<Map>()) {
        final base = config.uri.resolve(value['rootUri'] as String);
        final directory = base.replace(
          path: base.path.endsWith('/') ? base.path : '${base.path}/',
        );
        packages.add(directory.resolve(value['packageUri'] as String? ?? ''));
      }
    }
  }
  final String root;
  final SourceFactory factory;
  final packages = <Uri>[];
  final units = <String, CompilationUnit>{};
  final owners = <String, List<String>>{};
  final seen = <String>{};
  String relative(String path) => path.substring(root.length + 1);
  Iterable<CompilationUnit> ownerUnits(String path) =>
      owners[path]!.map((part) => units[part]!);
  String physical(analyzer_source.Source source) {
    if (!source.exists()) {
      throw const FormatException('Missing actual namespace source');
    }
    return File(source.fullName).resolveSymbolicLinksSync();
  }

  analyzer_source.Source resolve(analyzer_source.Source from, String text) {
    final target = factory.resolveUri(from, text);
    if (target == null || !target.exists()) {
      throw const FormatException('Missing actual namespace URI');
    }
    if (target.uri.scheme == 'dart') return target;
    if (!{'file', 'package'}.contains(target.uri.scheme)) {
      throw const FormatException('Unsupported namespace URI');
    }
    final path = physical(target);
    if (!path.startsWith('$root/') &&
        !packages.any(
          (base) =>
              base.scheme == 'file' &&
              Directory.fromUri(base).existsSync() &&
              path.startsWith(
                '${Directory.fromUri(base).resolveSymbolicLinksSync()}/',
              ),
        )) {
      throw const FormatException('Namespace outside declared inputs');
    }
    return target;
  }

  CompilationUnit parse(String path) => units.putIfAbsent(path, () {
    final result = parseString(
      content: File(path).readAsStringSync(),
      path: path,
      featureSet: FeatureSet.latestLanguageVersion(
        flags: ['private-named-parameters'],
      ),
      throwIfDiagnostics: false,
    );
    if (result.errors.isNotEmpty) {
      throw const FormatException('Invalid authored Dart');
    }
    final directives = result.unit.directives;
    if (directives.whereType<LibraryDirective>().any(
      (node) => node != directives.first,
    )) {
      throw const FormatException('Library directive must be first');
    }
    return result.unit;
  });
  void library(String path) {
    final uri = factory.pathToUri(path);
    final origin = uri == null ? null : factory.forUri2(uri);
    if (origin == null) {
      throw const FormatException('Unknown containing library origin');
    }
    validate(origin);
  }

  void validate(analyzer_source.Source origin) {
    final path = physical(origin);
    if (!path.startsWith('$root/') || !seen.add('$path\u0000${origin.uri}')) {
      return;
    }
    final unit = parse(path);
    if (unit.directives.any((node) => node is PartOfDirective)) {
      throw const FormatException('Namespace cannot import a part');
    }
    final parts = <String>[path];
    for (final directive in unit.directives.whereType<PartDirective>()) {
      final source = resolve(origin, directive.uri.stringValue!);
      final part = physical(source);
      if (!part.startsWith('$root/')) {
        throw const FormatException('Part outside authored inputs');
      }
      final parsed = parse(part);
      final declaration = parsed.directives
          .whereType<PartOfDirective>()
          .toList();
      if (declaration.length != 1 || parsed.directives.length != 1) {
        throw const FormatException('Invalid part ownership');
      }
      final ownerUri = declaration.single.uri?.stringValue;
      final name = unit.directives
          .whereType<LibraryDirective>()
          .singleOrNull
          ?.name
          ?.name;
      if (ownerUri != null
          ? physical(resolve(source, ownerUri)) != path
          : name == null || declaration.single.libraryName?.name != name) {
        throw const FormatException('Part belongs to a different library');
      }
      if (parts.contains(part) ||
          owners.entries.any(
            (entry) => entry.key != path && entry.value.contains(part),
          )) {
        throw const FormatException('Duplicate part ownership');
      }
      parts.add(part);
    }
    owners[path] = parts;
    for (final namespace in unit.directives.whereType<NamespaceDirective>()) {
      if (namespace.configurations.isNotEmpty) {
        throw const FormatException(
          'Conditional authored namespace needs all-branch proof',
        );
      }
      final target = resolve(origin, namespace.uri.stringValue!);
      if (target.uri.scheme != 'dart') validate(target);
    }
  }
}

Future<void> main(List<String> arguments) async {
  try {
    var root = '.';
    String? sdk;
    final seen = <String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 == arguments.length ||
          !{'--root', '--sdk'}.contains(arguments[index]) ||
          !seen.add(arguments[index])) {
        throw const FormatException('Use [--root PATH] [--sdk PATH]');
      }
      if (arguments[index] == '--root') root = arguments[index + 1];
      if (arguments[index] == '--sdk') sdk = arguments[index + 1];
    }
    final findings = await check(Directory(root), sdkPath: sdk);
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
