import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:flutter/widgets.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

/// Owns one standalone preview's controller and its shared preferences owner.
/// WingApp-based fixtures use WingApp's corresponding lifetime instead.
class ProfileFixtureRoot extends StatefulWidget {
  ProfileFixtureRoot({required this.controller, required this.child})
    : super(key: ObjectKey(controller));

  final ProfileWorkspaceController controller;
  final Widget child;

  @override
  State<ProfileFixtureRoot> createState() => _ProfileFixtureRootState();
}

class _ProfileFixtureRootState extends State<ProfileFixtureRoot> {
  final _activity = ValueNotifier<ChatNoticeActivity?>(null);
  @override
  Widget build(BuildContext context) =>
      ChatNoticeActivityScope(activity: _activity, child: widget.child);

  @override
  void dispose() {
    _activity.dispose();
    widget.controller.dispose();
    widget.controller.appPreferences.dispose();
    super.dispose();
  }
}
