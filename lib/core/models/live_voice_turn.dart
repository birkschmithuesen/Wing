/// Received speech for local display only. Never a Hermes saved-history row.
final class LiveVoiceTurn {
  const LiveVoiceTurn({
    required this.id,
    required this.user,
    required this.text,
    required this.timestamp,
    required this.complete,
  });
  final String id;
  final bool user;
  final String text;
  final DateTime timestamp;
  final bool complete;
}
