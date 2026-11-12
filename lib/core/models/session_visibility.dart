/// Hermes source labels for scheduled and internal runs. Unknown sources remain
/// visible in Chats; a source label cannot prove that a person started a session.
enum SessionVisibility {
  chats,
  all;

  /// This display preference follows the saved connection across sign-ins.
  /// Authenticated workspace ownership continues to use its separate identity.
  static const preferencePrefix = 'session_visibility_v2_';
  static String preferenceKey(String connectionId) =>
      '$preferencePrefix$connectionId';

  static const automatedSources = {
    'cron',
    'tool',
    'subagent',
    'kanban',
    'oneshot',
    'bot_room',
  };

  Map<String, String> get queryParameters => switch (this) {
    chats => {'exclude_sources': automatedSources.join(',')},
    all => const {},
  };

  bool includes(String? source, {bool hidden = false}) => switch (this) {
    chats => !hidden && !automatedSources.contains(source),
    all => true,
  };
}
