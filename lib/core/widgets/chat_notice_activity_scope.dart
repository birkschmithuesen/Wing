import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/recent_conversation.dart';

/// Application composition supplies the journal's read-only activity signal.
class ChatNoticeActivityScope extends InheritedWidget {
  const ChatNoticeActivityScope({
    super.key,
    required this.activity,
    required super.child,
  });
  final ValueListenable<ChatNoticeActivity?> activity;

  static ValueListenable<ChatNoticeActivity?> of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ChatNoticeActivityScope>();
    if (scope == null) {
      throw StateError('Notification activity scope is required');
    }
    return scope.activity;
  }

  @override
  bool updateShouldNotify(ChatNoticeActivityScope oldWidget) =>
      activity != oldWidget.activity;
}
