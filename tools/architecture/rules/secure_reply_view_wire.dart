import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import '../model.dart';

const id = 'ARCH_SECURE_REPLY_VIEW_WIRE';
const view = 'lib/core/widgets/gateway_sensitive_prompt_panel.dart';

/// Declared namespace dependency only: imports in command owners are private
/// to those owners; exports make a codec dependency available to this view.
List<Finding> check(Directory directory) {
  final root = directory.resolveSymbolicLinksSync();
  final cache = <String, CompilationUnit>{};
  final packages = <String, Uri>{'wing': Directory('$root/lib').uri};
  final config = File('$root/.dart_tool/package_config.json');
  if (config.existsSync()) {
    final data = jsonDecode(config.readAsStringSync()) as Map;
    for (final item in (data['packages'] as List).cast<Map>()) {
      final packageRoot = config.uri.resolve(item['rootUri'] as String);
      packages[item['name'] as String] = Directory.fromUri(
        packageRoot,
      ).uri.resolve(item['packageUri'] as String? ?? '');
    }
  }
  CompilationUnit load(String path) => cache.putIfAbsent(path, () {
    final parsed = parseString(
      content: File(path).readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw FormatException('Malformed namespace: $path');
    }
    return parsed.unit;
  });
  String? target(String from, String uri) {
    final parsed = Uri.parse(uri);
    if (parsed.scheme == 'dart') return null;
    final Uri resolved;
    if (parsed.scheme == 'package') {
      final segments = parsed.pathSegments;
      final package = packages[segments.first];
      if (package == null) {
        throw FormatException('Missing package namespace: $uri');
      }
      resolved = package.resolve(segments.skip(1).join('/'));
    } else if (parsed.scheme.isEmpty) {
      resolved = File(from).uri.resolveUri(parsed);
    } else {
      throw FormatException('Unsupported namespace URI: $uri');
    }
    if (resolved.scheme != 'file') {
      throw FormatException('Non-file namespace: $uri');
    }
    return File.fromUri(resolved).absolute.path;
  }

  List<String> uris(NamespaceDirective directive) => [
    ?directive.uri.stringValue,
    for (final configuration in directive.configurations)
      ?configuration.uri.stringValue,
  ];
  final path = '$root/$view';
  final primary = load(path);
  if (primary.directives.any((node) => node is PartOfDirective)) {
    throw const FormatException(
      'Canonical secure reply view must own its library',
    );
  }
  final units = <String, CompilationUnit>{path: primary};
  for (final directive in primary.directives.whereType<PartDirective>()) {
    final uri = directive.uri.stringValue;
    if (uri == null) throw const FormatException('Invalid secure view part');
    final partPath = target(path, uri);
    if (partPath == null || units.containsKey(partPath)) {
      throw const FormatException(
        'Invalid duplicate/non-file secure view part',
      );
    }
    final part = load(partPath);
    final claims = part.directives.whereType<PartOfDirective>().toList();
    final libraryNames = primary.directives
        .whereType<LibraryDirective>()
        .map((node) => node.name?.toSource())
        .whereType<String>()
        .toSet();
    if (claims.length != 1 ||
        part.directives.any(
          (node) => node is NamespaceDirective || node is PartDirective,
        ) ||
        (claims.single.uri != null
            ? target(partPath, claims.single.uri!.stringValue!) != path
            : !libraryNames.contains(claims.single.libraryName?.toSource()))) {
      throw const FormatException('Invalid secure view part ownership');
    }
    units[partPath] = part;
  }
  if (units.values
          .expand((unit) => unit.declarations)
          .whereType<ClassDeclaration>()
          .where(
            (node) =>
                node.namePart.typeName.lexeme == 'GatewaySensitivePromptPanel',
          )
          .length !=
      1) {
    throw const FormatException(
      'Missing/ambiguous canonical secure reply panel',
    );
  }
  bool exposes(String from, String uri, Set<String> seen) {
    if (uri == 'dart:convert') return true;
    final next = target(from, uri);
    if (next == null || !seen.add(next)) return false;
    final unit = load(next);
    if (unit.directives.any((node) => node is PartOfDirective)) {
      throw FormatException('Imported detached part: $next');
    }
    var found = false;
    for (final export in unit.directives.whereType<ExportDirective>()) {
      for (final alternate in uris(export)) {
        found = exposes(next, alternate, seen) || found;
      }
    }
    return found;
  }

  final parsed = parseString(
    content: File(path).readAsStringSync(),
    path: path,
  );
  return [
    for (final directive in primary.directives.whereType<NamespaceDirective>())
      if (uris(
        directive,
      ).map((uri) => exposes(path, uri, <String>{})).toList().any((v) => v))
        Finding(
          id,
          view,
          parsed.lineInfo.getLocation(directive.offset).lineNumber,
          'GatewaySensitivePromptPanel.namespace@${directive.offset}',
          'Keep secure reply encoding in GatewaySensitivePromptRequest; remove the view namespace dependency on dart:convert.',
        ),
  ]..sort();
}

void main(List<String> args) {
  try {
    if (args.isNotEmpty && (args.length != 2 || args.first != '--root')) {
      throw const FormatException('Use [--root PATH]');
    }
    final findings = check(Directory(args.isEmpty ? '.' : args.last));
    findings.forEach(stdout.writeln);
    exitCode = findings.isEmpty ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('[$id INPUT] $error');
    exitCode = 2;
  }
}
