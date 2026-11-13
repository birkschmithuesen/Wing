import 'dart:async';
import 'administration_fixture.dart';

class GitReviewFixture extends AdministrationFixture {
  GitReviewFixture() {
    this.override = readGit;
  }
  Completer<void>? listGate, diffGate;
  bool fail = false;
  static const sourceDiff =
      'diff --git a/lib/phone.dart b/lib/phone.dart\n'
      '--- a/lib/phone.dart\n+++ b/lib/phone.dart\n'
      '@@ -8,2 +8,3 @@ class Phone {\n'
      '-  return oldValue;\n+  final value = await loadWorkspace();\n'
      '+  return value;\n }\n';
  Future<Map<String, dynamic>> readGit(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (method != 'GET' || body != null) throw StateError('Read-only review');
    if (path == 'git/review/list') await listGate?.future;
    if (path == 'git/file-diff' || path == 'git/review/diff') {
      await diffGate?.future;
    }
    if (fail) throw StateError('Review offline');
    return switch (path) {
      'git/review/list' => {
        'files': [
          {
            'path': 'lib/phone.dart',
            'added': 2,
            'removed': 1,
            'status': 'M',
            'staged': true,
          },
          {
            'path': 'notes/phone-review.txt',
            'added': 1,
            'removed': 0,
            'status': '?',
            'staged': false,
          },
        ],
        'base': null,
      },
      'git/file-diff' || 'git/review/diff' => {'diff': sourceDiff},
      _ => throw StateError('Unexpected Git read $path'),
    };
  }
}
