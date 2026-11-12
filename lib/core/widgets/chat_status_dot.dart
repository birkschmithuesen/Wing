import 'package:wing/core/models/chat_list_status.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';

class ChatStatusDot extends StatelessWidget {
  const ChatStatusDot(this.status, {super.key, this.detail});
  final ChatListStatus status;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final color = switch (status) {
      ChatListStatus.needsInput => tokens.warning,
      ChatListStatus.working => tokens.accent,
      ChatListStatus.unread => tokens.success,
      ChatListStatus.draft || ChatListStatus.idle => tokens.muted,
    };
    final hollow = status == ChatListStatus.draft;
    final size = status == ChatListStatus.idle ? 5.0 : 7.0;
    final label = detail == null ? status.label : '${status.label} · $detail';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hollow ? Colors.transparent : color,
                border: hollow ? Border.all(color: color, width: 1.5) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
