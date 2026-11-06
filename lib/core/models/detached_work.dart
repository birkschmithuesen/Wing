/// Process-local work owned by a durable session, without runtime authority.
class DetachedWork {
  final String sessionId;
  final int subagents;
  final int background;

  const DetachedWork({
    required this.sessionId,
    required this.subagents,
    required this.background,
  });

  bool get isRunning => subagents > 0 || background > 0;

  /// Validate the whole snapshot before allowing absence to retire presence.
  static List<DetachedWork> parseRoster(Map<String, dynamic> response) {
    final rows = response['sessions'];
    if (rows is! List) {
      throw const FormatException('Missing detached work roster');
    }
    final seen = <String>{};
    final result = <DetachedWork>[];
    for (final row in rows) {
      if (row is! Map) {
        throw const FormatException('Invalid detached work row');
      }
      final id = row['session_id'];
      final subagents = row['subagents'];
      final background = row['background'];
      if (id is! String ||
          id.trim().isEmpty ||
          !seen.add(id) ||
          subagents is! int ||
          subagents < 0 ||
          background is! int ||
          background < 0) {
        throw const FormatException('Invalid detached work row');
      }
      result.add(
        DetachedWork(
          sessionId: id,
          subagents: subagents,
          background: background,
        ),
      );
    }
    return List.unmodifiable(result);
  }
}
