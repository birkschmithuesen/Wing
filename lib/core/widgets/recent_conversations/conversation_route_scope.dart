import 'package:flutter/widgets.dart';
import '../app_drawer.dart';
import '../../services/workspace_recents_session.dart';

/// Borrowed chat windows return through their workspace's canonical menu owner.
class RecentConversationRouteScope extends InheritedWidget {
  const RecentConversationRouteScope({
    super.key,
    required this.recents,
    required this.origin,
    required this.onLeave,
    required super.child,
  });
  final WorkspaceRecentsSession recents;
  final AppDestination origin;
  final ValueChanged<AppDestination> onLeave;
  static RecentConversationRouteScope? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<RecentConversationRouteScope>();
  @override
  bool updateShouldNotify(RecentConversationRouteScope oldWidget) =>
      recents != oldWidget.recents ||
      origin != oldWidget.origin ||
      onLeave != oldWidget.onLeave;
}

/// Visibility of the mounted discussion underneath shared Recents cards.
class ConversationPresentationScope extends InheritedWidget {
  const ConversationPresentationScope({
    super.key,
    required this.visible,
    required this.onRecordingChanged,
    required super.child,
  });
  final bool visible;
  final ValueChanged<bool> onRecordingChanged;
  static ConversationPresentationScope? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ConversationPresentationScope>();
  @override
  bool updateShouldNotify(ConversationPresentationScope oldWidget) =>
      visible != oldWidget.visible;
}
