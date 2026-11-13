import '../cli.dart';
import '../model.dart';

const id = 'ARCH_VIEW_LOWLEVEL_DEPENDENCY';
List<Finding> check(Snapshot snapshot) {
  // Direct adapter imports are precise. Transitive feature ownership is allowed:
  // the view may import a controller which legitimately depends on its adapter.
  final result = <Finding>[];
  for (final source in snapshot.sources.values) {
    if (snapshot.roleOf(source.path) != 'view') continue;
    for (final dependency in source.dependencies) {
      if (dependency.kind != 'import') continue;
      if (dependency.uri == 'dart:io' ||
          [
            'package:http/',
            'package:web_socket_channel/',
            'package:shared_preferences/',
            'package:flutter_secure_storage/',
            'package:path_provider/',
          ].any(dependency.uri.startsWith)) {
        result.add(
          Finding(
            id,
            source.path,
            dependency.line,
            dependency.subject,
            'Use a typed feature command; low-level I/O belongs in an adapter.',
          ),
        );
      }
    }
  }
  return result;
}

void main(List<String> args) => run(args, {id: check});
