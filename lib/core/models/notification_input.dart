import 'chat_notification_content.dart';
import 'notification_focus.dart';

/// An immutable input snapshot. Secret values never belong here.
class NotificationInput {
  final NotificationFocus focus;
  final ChatNotificationContent content;
  final List<String> choices;
  final int count;
  final bool submitting;
  final String? error;
  NotificationInput({
    required this.focus,
    required this.content,
    Iterable<String> choices = const [],
    this.count = 1,
    this.submitting = false,
    this.error,
  }) : choices = List.unmodifiable(choices);
  Map<String, dynamic> toJson() => {
    'focus': focus.toJson(),
    'content': content.toJson(),
    'choices': choices,
    'count': count,
    'submitting': submitting,
    'error': error,
  };
  factory NotificationInput.fromJson(
    Map<String, dynamic> data,
  ) => NotificationInput(
    focus: NotificationFocus.fromJson(Map<String, dynamic>.from(data['focus'])),
    content: ChatNotificationContent.fromJson(
      Map<String, dynamic>.from(data['content']),
    ),
    choices: List<String>.from(data['choices']),
    count: data['count'] as int,
    // A process restart cannot leave the UI stuck in an in-flight submission.
    error: data['error'] as String?,
  );
}
