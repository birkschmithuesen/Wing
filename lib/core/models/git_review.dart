/// A stock Git review row. Paths remain relative to the captured workspace.
class GitReviewFile {
  const GitReviewFile({
    required this.path,
    required this.added,
    required this.removed,
    required this.status,
    required this.staged,
  });
  final String path;
  final int added, removed;
  final String status;
  final bool staged;

  static List<GitReviewFile> decode(Map<String, dynamic> response) {
    final rows = response['files'];
    if (rows is! List) throw const FormatException('Missing changed files');
    return List.unmodifiable(
      rows.map((row) {
        if (row is! Map ||
            row['path'] is! String ||
            row['added'] is! int ||
            row['removed'] is! int ||
            row['status'] is! String ||
            row['staged'] is! bool) {
          throw const FormatException('Invalid changed file');
        }
        final path = row['path'] as String;
        if (path.isEmpty ||
            path.startsWith('/') ||
            path.split('/').contains('..') ||
            path.contains('\x00')) {
          throw const FormatException('Invalid changed file path');
        }
        return GitReviewFile(
          path: path,
          added: row['added'],
          removed: row['removed'],
          status: row['status'],
          staged: row['staged'],
        );
      }),
    );
  }
}

enum GitReviewComparison { all, staged }

class GitReviewLine {
  const GitReviewLine(
    this.text, {
    this.oldLine,
    this.newLine,
    this.hunk = false,
  });
  final String text;
  final int? oldLine, newLine;
  final bool hunk;
  bool get added => !hunk && oldLine == null && newLine != null;
  bool get removed => !hunk && newLine == null && oldLine != null;
  bool get canReference => hunk || added || removed;
  String reference(String path, GitReviewComparison comparison) {
    final scope = comparison == GitReviewComparison.staged
        ? 'staged'
        : 'working tree vs HEAD';
    if (hunk) return '$path ($scope)\n$text';
    if (removed) return '$path:$oldLine (removed, old version; $scope)\n$text';
    return '$path:$newLine ($scope)\n$text';
  }
}

class GitReviewDiff {
  GitReviewDiff(String text) : lines = _parse(text);
  final List<GitReviewLine> lines;
  static final _header = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  static List<GitReviewLine> _parse(String text) {
    if (text.isEmpty) return const [];
    int? oldLine, newLine;
    final result = <GitReviewLine>[];
    final lines = text.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    for (final line in lines) {
      final header = _header.firstMatch(line);
      if (header != null) {
        oldLine = int.parse(header[1]!);
        newLine = int.parse(header[2]!);
        result.add(GitReviewLine(line, hunk: true));
      } else if (oldLine != null && newLine != null && line.startsWith('+')) {
        result.add(GitReviewLine(line, newLine: newLine++));
      } else if (oldLine != null && newLine != null && line.startsWith('-')) {
        result.add(GitReviewLine(line, oldLine: oldLine++));
      } else if (oldLine != null && newLine != null && line.startsWith(' ')) {
        result.add(GitReviewLine(line, oldLine: oldLine++, newLine: newLine++));
      } else {
        if (line.startsWith('diff --git ')) oldLine = newLine = null;
        result.add(GitReviewLine(line));
      }
    }
    return List.unmodifiable(result);
  }
}
