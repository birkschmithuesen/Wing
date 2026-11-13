import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

const id = 'ARCH_DART_MAIN_ROOT_COVERAGE';
const manifestPath = 'tools/architecture/roots.json';

// Existing manifest kinds explicitly identifying executable entrypoints.
const executableKinds = {
  'dart-main',
  'alternate-dart-main',
  'host-test',
  'device-or-live-test',
  'device-driver',
  'guard-cli',
  'guard-runner',
  'guard-fixture-cli',
  'opt-in-qa-cli',
  'manual-or-ci-cli',
  'fixture-cli',
};

String _path(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Canonical checkout-relative path required');
  }
  return value;
}

bool _excluded(String path) {
  final parts = path.split('/');
  return (parts.length > 1 &&
          const {'.git', 'build', '.dart_tool'}.contains(parts.first)) ||
      parts
          .take(parts.length - 1)
          .any(const {'node_modules', '__pycache__'}.contains);
}

String _git(Directory root, List<String> args) {
  final result = Process.runSync('git', ['-C', root.path, ...args]);
  if (result.exitCode != 0) {
    throw const FormatException('Git input unavailable');
  }
  return result.stdout as String;
}

String _display(String path) => jsonEncode(path);

/// Scope coverage only: no call resolution, root reachability or liveness claim.
List<String> check(Directory directory) {
  final root = Directory(directory.resolveSymbolicLinksSync());
  final repository = _git(root, ['rev-parse', '--show-toplevel']);
  final repositoryPath = repository.endsWith('\n')
      ? repository.substring(0, repository.length - 1)
      : repository;
  if (Directory(repositoryPath).resolveSymbolicLinksSync() != root.path) {
    throw const FormatException('Root must be the application Git checkout');
  }
  final document = jsonDecode(
    File('${root.path}/$manifestPath').readAsStringSync(),
  );
  if (document is! Map ||
      document['schema'] is! int ||
      document['schema'] != 1 ||
      document['files'] is! List ||
      document['roots'] is! List) {
    throw const FormatException('Root inventory schema 1 required');
  }
  final declared = <String>{};
  var hostDiscovery = false;
  final rootIds = <String>{};
  for (final row in document['roots'] as List) {
    if (row is! Map ||
        row['id'] is! String ||
        (row['id'] as String).trim().isEmpty ||
        !rootIds.add(row['id'] as String) ||
        row['kind'] is! String ||
        row['purpose'] is! String ||
        (row['purpose'] as String).trim().isEmpty ||
        row['source'] is! String ||
        (row['source'] as String).trim().isEmpty ||
        !const {
          'supported',
          'reference',
          'needs-decision',
        }.contains(row['status'])) {
      throw const FormatException('Invalid executable root row');
    }
    final path = _path(row['path']);
    if (row['kind'] == 'dart-test-discovery') {
      final selector = row['selector'];
      if (path != 'test' ||
          selector is! Map ||
          selector.length != 2 ||
          selector['declaration'] != 'main' ||
          selector['pattern'] != '**/*_test.dart') {
        throw const FormatException(
          'Only typed host test discovery is supported',
        );
      }
      hostDiscovery = true;
    } else if (path.endsWith('.dart') &&
        executableKinds.contains(row['kind'])) {
      final selector = row['selector'];
      final namedMain =
          selector == null ||
          selector == 'main' ||
          (selector is List &&
              selector.contains('main') &&
              selector.every(
                (value) => value is String && value.trim().isNotEmpty,
              ) &&
              selector.toSet().length == selector.length);
      if (!namedMain) {
        throw const FormatException('Dart entry selector must be main');
      }
      declared.add(path);
    }
  }
  final paths = <String>{};
  for (final entry in document['files'] as List) {
    if (entry is! Map) throw const FormatException('Invalid census row');
    paths.add(_path(entry['path']));
  }
  paths.addAll(
    _git(root, [
      'ls-files',
      '--cached',
      '--others',
      '--exclude-standard',
      '-z',
    ]).split('\u0000').where((path) => path.isNotEmpty).map(_path),
  );
  final dartPaths =
      paths.where((path) => path.endsWith('.dart') && !_excluded(path)).toList()
        ..sort();
  final parsedFiles = <String, CompilationUnit>{};
  final lineAt = <String, int Function(int)>{};
  for (final path in dartPaths) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      if (FileSystemEntity.isLinkSync(file.path)) {
        throw const FormatException('Dart symlink source unsupported');
      }
      continue; // Tracked deletion is separately checked by the census guard.
    }
    // Never follow authored symlinks into installed or external source trees.
    if (file.resolveSymbolicLinksSync() != file.absolute.path) {
      throw const FormatException('Dart symlink source unsupported');
    }
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw const FormatException('Dart source cannot be parsed');
    }
    parsedFiles[path] = parsed.unit;
    lineAt[path] = (offset) => parsed.lineInfo.getLocation(offset).lineNumber;
  }
  String relative(String owner, String? uri) {
    if (uri == null) {
      throw const FormatException('Part requires a relative URI');
    }
    final parsedUri = Uri.parse(uri);
    if (parsedUri.hasScheme ||
        parsedUri.hasAuthority ||
        parsedUri.hasQuery ||
        parsedUri.hasFragment ||
        uri.startsWith('/')) {
      throw const FormatException('Part requires a relative URI');
    }
    return _path(Uri(path: owner).resolve(uri).path);
  }

  final owners = <String, String>{};
  for (final entry in parsedFiles.entries) {
    for (final part in entry.value.directives.whereType<PartDirective>()) {
      final target = relative(entry.key, part.uri.stringValue);
      final targetUnit = parsedFiles[target];
      if (targetUnit == null || owners.containsKey(target)) {
        throw const FormatException('Missing or duplicate part ownership');
      }
      final partOf = targetUnit.directives
          .whereType<PartOfDirective>()
          .toList();
      if (partOf.length != 1 ||
          targetUnit.directives.whereType<PartDirective>().isNotEmpty) {
        throw const FormatException('Part must declare exactly one owner');
      }
      final directive = partOf.single;
      if (directive.uri != null) {
        if (relative(target, directive.uri!.stringValue) != entry.key) {
          throw const FormatException('Part owner URI does not match');
        }
      } else {
        final libraries = entry.value.directives
            .whereType<LibraryDirective>()
            .toList();
        if (libraries.length != 1 ||
            libraries.single.name?.toSource() !=
                directive.libraryName?.toSource()) {
          throw const FormatException('Named part owner does not match');
        }
      }
      owners[target] = entry.key;
    }
  }
  final findings = <String>[];
  for (final entry in parsedFiles.entries) {
    final path = entry.key;
    final isPart = entry.value.directives
        .whereType<PartOfDirective>()
        .isNotEmpty;
    if (isPart && !owners.containsKey(path)) {
      throw const FormatException('Part lacks a containing authored library');
    }
    final library = owners[path] ?? path;
    for (final declaration
        in entry.value.declarations.whereType<FunctionDeclaration>()) {
      if (declaration.name.lexeme != 'main' ||
          declaration.isGetter ||
          declaration.isSetter) {
        continue;
      }
      final covered =
          declared.contains(library) ||
          (hostDiscovery &&
              library.startsWith('test/') &&
              library.endsWith('_test.dart'));
      if (!covered) {
        final line = lineAt[path]!(declaration.name.offset);
        findings.add(
          '${_display(path)}:$line [$id] Top-level main lacks an executable root row or typed test discovery.',
        );
      }
    }
  }
  return findings;
}

void main(List<String> args) {
  try {
    Directory root;
    if (args.isEmpty) {
      root = Directory.current;
    } else if (args.length == 2 && args.first == '--root') {
      root = Directory(args.last);
    } else {
      throw const FormatException('Usage: dart_main_roots.dart [--root PATH]');
    }
    final findings = check(root);
    for (final finding in findings) {
      stdout.writeln(finding);
    }
    stdout.writeln('$id: ${findings.length} uncovered main declarations');
    exitCode = findings.isEmpty ? 0 : 1;
  } catch (_) {
    stderr.writeln(
      '$manifestPath:1 [${id}_INPUT] Invalid checkout, root inventory or Dart source.',
    );
    exitCode = 2;
  }
}
