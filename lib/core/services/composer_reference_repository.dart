import '../models/server_reference.dart';

import '../models/hermes_profile.dart';
import 'server_files_repository.dart';

typedef ReferenceCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Composer roster and bounded shell enumeration. The preparation owner decides
/// timing, budgets, cancellation and whole-message failure.
final class ComposerReferenceRepository {
  ComposerReferenceRepository({required this.read, required this.call})
    : files = ServerFilesRepository(read: read, write: null);
  final ServerFilesRead read;
  final ServerFilesRepository files;
  final ReferenceCall call;
  Future<List<HermesProfile>> agents() async {
    final response = await read('profiles', const {});
    final rows = response['profiles'];
    if (rows is! List) {
      throw const FormatException('Agent list is unavailable.');
    }
    final agents = rows.map((row) {
      if (row is! Map) throw const FormatException('Invalid agent identity.');
      return HermesProfile.fromJson(Map<String, dynamic>.from(row));
    }).toList()..sort(HermesProfile.compareForDisplay);
    if (agents.map((p) => p.name).toSet().length != agents.length) {
      throw const FormatException('Duplicate agent identity.');
    }
    return List.unmodifiable(agents);
  }

  Future<List<String>?> ignoredFilePaths(
    String directory,
    String cwd, {
    required void Function() requireCurrent,
  }) async {
    ServerReferencePath.admit(directory);
    ServerReferencePath.admit(cwd);
    // Each page is framed. The stock stdout tail cap must never look complete.
    // Single-thread traversal keeps repeated pages in the same order.
    // Re-enumeration is checked with a checksum of the bounded first 200 hits.
    final scan =
        'cd ${_quote(cwd)} && rg --files --threads 1 -- ${_quote(directory)} | head -n 200';
    final paths = <String>[];
    String? fingerprint;
    for (var offset = 1; offset <= 200; offset += 8) {
      requireCurrent();
      final command =
          "printf 'WING_BEGIN\\n'; ($scan) | cksum; "
          "($scan) | sed -n '$offset,${offset + 7}p'; printf 'WING_END\\n'";
      final result = await call('shell.exec', {'command': command});
      requireCurrent();
      if (result['code'] != 0 ||
          result['stderr'] is! String ||
          (result['stderr'] as String).isNotEmpty) {
        return null;
      }
      final output = result['stdout'];
      if (output is! String ||
          !output.startsWith('WING_BEGIN\n') ||
          !output.endsWith('WING_END\n')) {
        throw const FormatException('Folder listing was incomplete. Retry.');
      }
      final lines = output.split('\n');
      final stamp = lines[1];
      if (!RegExp(r'^\d+ \d+$').hasMatch(stamp) ||
          fingerprint != null && fingerprint != stamp) {
        throw const FormatException('Folder changed while reading. Retry.');
      }
      fingerprint = stamp;
      final page = lines.sublist(2, lines.length - 2);
      for (final path in page) {
        ServerReferencePath.admit(path);
        if (!ServerReferencePath.pathContext.isWithin(directory, path) ||
            !paths.addUnique(path)) {
          throw const FormatException('Invalid folder listing. Retry.');
        }
      }
      if (page.length < 8) {
        return paths.isEmpty ? null : List.unmodifiable(paths);
      }
    }
    return List.unmodifiable(paths);
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
}

extension on List<String> {
  bool addUnique(String value) {
    if (contains(value)) return false;
    add(value);
    return true;
  }
}
