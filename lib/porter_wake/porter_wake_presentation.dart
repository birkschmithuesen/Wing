import 'porter_wake_notice.dart';

class PorterButton {
  const PorterButton({required this.action, required this.label, required this.value});
  final String action;
  final String label;
  final String value;

  Map<String, String> get feedbackBody => {'action': action, 'value': value};
  Map<String, String> toJson() => {'action': action, 'label': label, 'value': value};
}

/// What the native renderer posts. „Öffnen“ is the content tap; every other
/// server action becomes a button with the server's label.
class PorterNotificationSpec {
  const PorterNotificationSpec({
    required this.connectionId,
    required this.noticeId,
    required this.title,
    required this.body,
    required this.expanded,
    required this.openProfile,
    required this.buttons,
    this.neutral = false,
  });

  static const notificationId = 214700;
  static const channel = 'wing_attention_notifications';
  static const neutralTitle = 'Pforte: neue Nachricht';

  final String connectionId;
  final String noticeId;
  final String title;
  final String body;
  final String expanded;
  final String openProfile;
  final List<PorterButton> buttons;
  final bool neutral;

  factory PorterNotificationSpec.fromNotice(String connectionId, PorterNotice notice) =>
      PorterNotificationSpec(
        connectionId: connectionId,
        noticeId: notice.noticeId,
        title: notice.title,
        body: notice.lines.isEmpty ? '' : notice.lines.first,
        expanded: notice.lines.take(2).join('\n'),
        openProfile: notice.openProfile,
        buttons: [
          for (final action in notice.actions)
            if (action.id == 'snooze')
              PorterButton(action: 'snooze', label: action.label, value: action.defaultValue ?? 'default')
            else if (action.id == 'rate' && action.value != null)
              PorterButton(action: 'rate', label: action.label, value: action.value!),
        ],
      );

  /// Shown when the fetch fails (contract §6.7). It carries no notice text.
  factory PorterNotificationSpec.neutral(String connectionId, String noticeId) =>
      PorterNotificationSpec(
        connectionId: connectionId,
        noticeId: noticeId,
        title: neutralTitle,
        body: '',
        expanded: '',
        openProfile: 'pforte',
        buttons: const [],
        neutral: true,
      );

  Map<String, Object?> toJson() => {
    'id': notificationId,
    'channel': channel,
    'connection': connectionId,
    'notice_id': noticeId,
    'title': title,
    'body': body,
    'expanded': expanded,
    'open_profile': openProfile,
    'tap': 'open',
    'buttons': [for (final b in buttons) b.toJson()],
    'neutral': neutral,
  };
}
