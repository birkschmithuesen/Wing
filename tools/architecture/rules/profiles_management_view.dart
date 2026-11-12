import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import '../dart_sdk.dart';
import '../model.dart';
import '../semantic_context.dart';

const id = 'ARCH_PROFILES_MANAGEMENT_VIEW';
const completedView =
    'lib/core/screens/administration/admin_profiles_page.dart';
const _session = 'lib/core/services/profiles_management_session.dart';
const _helper = 'lib/core/screens/administration/admin_widgets.dart';
const _loading = 'lib/core/widgets/studio_loading.dart';
const _formActions = 'lib/core/widgets/studio_form_actions.dart';
const _selectionViewport = 'lib/core/widgets/selection_viewport.dart';
const _error = 'lib/core/widgets/studio_error.dart';
const _theme = 'lib/core/theme/wing_theme.dart';
const _navigation = 'lib/core/screens/administration/admin_navigation.dart';
const _presentation = 'lib/core/models/profiles_management.dart';
const _renderPackages = {
  'flutter',
  'sky_engine',
  'characters',
  'vector_math',
  'meta',
};
const _nativeChannelOwners = {
  'package:flutter/src/services/platform_channel.dart': {
    'MethodChannel',
    'OptionalMethodChannel',
    'BasicMessageChannel',
    'EventChannel',
  },
  'package:flutter/src/services/binary_messenger.dart': {'BinaryMessenger'},
  'package:flutter/src/services/system_channels.dart': {'SystemChannels'},
};
const _dart = {'dart:core', 'dart:async', 'dart:math', 'dart:ui'};

/// Finite canonical import/type/factory boundary, not a temporal or universal
/// business-meaning proof. Real containing-library identity follows all parts.
Future<List<Finding>> check(Directory directory, {String? sdkPath}) async {
  final root = directory.resolveSymbolicLinksSync();
  final path = '$root/$completedView';
  final sdk = dartSdkPath(root, configured: sdkPath);
  final contexts = semanticContextCollection(
    root: root,
    sdk: sdk,
    includedPaths: [path],
    cacheNamespace: 'profiles-view',
  );
  final findings = <Finding>[];
  try {
    final library = await contexts
        .contextFor(path)
        .currentSession
        .getResolvedLibrary(path);
    if (library is! ResolvedLibraryResult) {
      throw const FormatException('Cannot resolve profiles view library');
    }
    if (library.units.any(
      (unit) => unit.diagnostics.any(
        (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
      ),
    )) {
      throw FormatException(
        'Profiles view has invalid Dart input: '
        '${library.units.expand((unit) => unit.diagnostics).where((diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR').map((diagnostic) => diagnostic.diagnosticCode.lowerCaseName).toSet().join(', ')}',
      );
    }
    if (!library.units.any((unit) => unit.path == path)) {
      throw const FormatException(
        'Selected view is not its containing library',
      );
    }
    final paths = <String>{};
    for (final unit in library.units) {
      final physical = File(unit.path).resolveSymbolicLinksSync();
      if (!physical.startsWith('$root/')) {
        throw const FormatException('View part outside authored checkout');
      }
      paths.add(physical);
    }
    final seen = <String>{};
    for (final unit in library.units) {
      for (final directive
          in unit.unit.directives.whereType<ImportDirective>()) {
        final target = directive.libraryImport?.importedLibrary;
        if (target == null) {
          throw const FormatException('Missing imported library');
        }
        _validateNamespace(root, target, seen);
      }
      final visitor = _Boundary(root, unit, paths, findings);
      unit.unit.accept(visitor);
    }
    final classes = library.units
        .expand((unit) => unit.unit.declarations)
        .whereType<ClassDeclaration>()
        .where((node) => node.namePart.typeName.lexeme == 'AdminProfilesPage')
        .toList();
    if (classes.length != 1) {
      throw const FormatException(
        'One canonical AdminProfilesPage is required',
      );
    }
    final page = classes.single.declaredFragment!.element;
    final field = page.fields
        .where((value) => value.name == 'createSession')
        .singleOrNull;
    bool factory(DartType? type) =>
        type is FunctionType &&
        type.nullabilitySuffix == NullabilitySuffix.none &&
        type.formalParameters.isEmpty &&
        type.returnType is InterfaceType &&
        type.returnType.nullabilitySuffix == NullabilitySuffix.none &&
        (type.returnType as InterfaceType).element.name ==
            'ProfilesManagementSession' &&
        (type.returnType as InterfaceType)
                .element
                .library
                .firstFragment
                .source
                .fullName ==
            '$root/$_session';
    if (field == null ||
        !field.isFinal ||
        !factory(field.type) ||
        page.constructors.isEmpty ||
        page.constructors.any((constructor) {
          final parameter = constructor.formalParameters
              .where((value) => value.name == 'createSession')
              .singleOrNull;
          return parameter == null ||
              !parameter.isRequiredNamed ||
              !factory(parameter.type);
        })) {
      findings.add(
        Finding(
          id,
          completedView,
          1,
          'required-session-factory',
          'Require an immutable ProfilesManagementSession Function() '
              'createSession input on every page constructor.',
        ),
      );
    }
  } finally {
    await contexts.dispose();
  }
  return findings..sort();
}

void _validateNamespace(String root, LibraryElement library, Set<String> seen) {
  final path = library.firstFragment.source.fullName;
  if (!path.startsWith('$root/') || !seen.add(path)) return;
  for (final fragment in library.fragments) {
    final parsed = parseString(
      content: File(fragment.source.fullName).readAsStringSync(),
      path: fragment.source.fullName,
      featureSet: FeatureSet.latestLanguageVersion(
        flags: ['private-named-parameters'],
      ),
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw const FormatException('Invalid authored namespace Dart');
    }
    if (parsed.unit.directives.whereType<NamespaceDirective>().any(
      (directive) => directive.configurations.isNotEmpty,
    )) {
      throw const FormatException(
        'Conditional authored namespace needs all-branch proof',
      );
    }
  }
  for (final exported in library.exportedLibraries) {
    _validateNamespace(root, exported, seen);
  }
}

class _Boundary extends RecursiveAstVisitor<void> {
  _Boundary(this.root, this.result, this.parts, this.findings);
  final String root;
  final ResolvedUnitResult result;
  final Set<String> parts;
  final List<Finding> findings;
  final reported = <(int, String)>{};

  String? origin(Element? element) =>
      element?.baseElement.library?.firstFragment.source.fullName;
  bool allowed(Element? raw, {bool importing = false}) {
    final element = raw?.baseElement;
    if (element == null) return true;
    final source = origin(element);
    if (source == null) return true;
    final uri = element.library!.uri.toString();
    if (!importing) {
      for (
        Element? owner = element;
        owner != null;
        owner = owner.enclosingElement
      ) {
        if (_nativeChannelOwners[uri]?.contains(owner.name) == true) {
          return false;
        }
      }
      if (uri == 'package:flutter/src/services/binding.dart' &&
          element.name == 'defaultBinaryMessenger') {
        return false;
      }
      if (element is ConstructorElement) {
        // An implicit default/super-parameter invocation also creates a second
        // owner. Inspect the semantic constructor chain, not just source tokens.
        final seen = <ConstructorElement>{};
        for (
          var constructor = element.superConstructor;
          constructor != null && seen.add(constructor);
          constructor = constructor.superConstructor
        ) {
          if (!allowed(constructor)) return false;
        }
      }
    }

    final parsedUri = Uri.parse(uri);
    if (_dart.contains(uri) ||
        !source.startsWith('$root/') &&
            parsedUri.scheme == 'package' &&
            parsedUri.pathSegments.isNotEmpty &&
            _renderPackages.contains(parsedUri.pathSegments.first)) {
      return true;
    }
    if (!importing &&
        source == '$root/$_session' &&
        element is ConstructorElement &&
        element.enclosingElement.name == 'ProfilesManagementSession') {
      return false;
    }
    if (source == '$root/$_selectionViewport' &&
        element is TopLevelFunctionElement &&
        element.name == 'viewportSelection') {
      return true;
    }
    if (parts.contains(source) ||
        source == '$root/$_session' ||
        source == '$root/$_helper' ||
        source == '$root/$_loading' ||
        source == '$root/$_formActions' ||
        source == '$root/$_error' ||
        source == '$root/$_theme' ||
        source == '$root/$_navigation') {
      return true;
    }
    // Passive inferred projection values are read here, never imported as a
    // separate domain policy API or constructed by this view.
    if (!importing &&
        source == '$root/$_presentation' &&
        element is! ConstructorElement) {
      return true;
    }
    return false;
  }

  void report(AstNode node, String subject, String remedy) {
    if (reported.add((node.offset, subject))) {
      findings.add(
        Finding(
          id,
          result.path.substring(root.length + 1),
          result.lineInfo.getLocation(node.offset).lineNumber,
          '$subject:${node.offset}',
          remedy,
        ),
      );
    }
  }

  void inspect(AstNode node, Element? element) {
    if (!allowed(element)) {
      report(
        node,
        'owner-authority',
        'Use typed ProfilesManagementSession facts and commands; keep '
            'transport, wire parsing and profile policy in the owner.',
      );
    }
  }

  bool rawMap(DartType? type) {
    if (type is! InterfaceType ||
        type.element.name != 'Map' ||
        type.element.library.uri.toString() != 'dart:core' ||
        type.typeArguments.length != 2) {
      return false;
    }
    final value = type.typeArguments[1];
    return value is DynamicType ||
        value is InterfaceType &&
            value.element.name == 'Object' &&
            value.element.library.uri.toString() == 'dart:core';
  }

  void inspectType(AstNode node, DartType? type) {
    if (type is FunctionType) {
      inspectType(node, type.returnType);
      for (final parameter in type.formalParameters) {
        inspectType(node, parameter.type);
      }
    } else if (type is InterfaceType) {
      inspect(node, type.element);
      for (final argument in type.typeArguments) {
        inspectType(node, argument);
      }
    }
    if (rawMap(type)) {
      report(
        node,
        'protocol-container',
        'Render typed owner projections instead of dynamic/Object Map '
            'protocol containers; typed presentation maps remain supported.',
      );
    }
  }

  void namespace(NamespaceDirective node) {
    if (node.configurations.isNotEmpty) {
      throw const FormatException(
        'Conditional view namespace needs all-branch proof',
      );
    }
    if (node is ExportDirective) {
      report(
        node,
        'view-export',
        'Keep this completed view a rendering library.',
      );
    } else if (node is ImportDirective) {
      final import = node.libraryImport;
      if (import?.importedLibrary == null) {
        throw const FormatException('Unresolved profiles view namespace');
      }
      final target = import!.importedLibrary!;
      final uri = target.uri.toString();
      if (uri.startsWith('dart:') && !_dart.contains(uri) ||
          import.namespace.definedNames2.values.any(
            (element) => !allowed(element, importing: true),
          )) {
        report(
          node,
          'view-import',
          'Import the typed profiles session and presentation helpers; '
              'do not import settings, transport, storage or profile policy.',
        );
      }
    }
  }

  @override
  void visitImportDirective(ImportDirective node) {
    namespace(node);
    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    namespace(node);
    super.visitExportDirective(node);
  }

  @override
  void visitNamedType(NamedType node) {
    inspectType(node, node.type);
    inspect(node, node.element);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext() &&
        node.parent is! Combinator &&
        node.parent is! Label &&
        node.inGetterContext()) {
      inspect(node, node.element);
      inspectType(node, node.staticType);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    for (final constructor in node.declaredFragment!.element.constructors) {
      inspect(node, constructor);
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    inspect(node, node.element);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    inspect(node.constructorName, node.constructorName.element);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    inspect(node.constructorName, node.constructorName.element);
    super.visitConstructorReference(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    inspectType(node, node.declaredFragment?.element.type);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    inspectType(node, node.staticType);
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    inspectType(node, node.realTarget.staticType);
    super.visitIndexExpression(node);
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
