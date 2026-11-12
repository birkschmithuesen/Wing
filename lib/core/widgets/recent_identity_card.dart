import 'studio_loading.dart';
import 'package:flutter/material.dart';
import '../models/bots.dart';
import '../models/profile_live_activity.dart';
import '../models/profile_colors.dart';
import '../services/profile_workspace_controller.dart';
import '../theme/profile_colors.dart';
import '../theme/wing_theme.dart';
import '../screens/profile_project_actions.dart' show projectAvatar;
import 'bot_avatar.dart';
import 'bot_group_identity.dart';

class RecentIdentityCard extends StatelessWidget {
  const RecentIdentityCard({
    super.key,
    required this.item,
    required this.bots,
    required this.now,
    required this.profileChoice,
    required this.isDefault,
    required this.onTap,
  });
  final WorkspaceRecentItem item;
  final Iterable<BotRecord> bots;
  final DateTime now;
  final ProfileColorChoice? profileChoice;
  final bool isDefault;
  final VoidCallback? onTap;
  String get statusLabel =>
      item.group?.blocked == true ||
          item.chat?.state == ProfileLiveActivityState.needsInput
      ? 'Needs your input'
      : item.group?.working == true || item.chat?.activity != null
      ? 'Running'
      : '';
  Widget _profileMarker(BuildContext context, String profile) {
    final color =
        profileChoiceColor(profile, profileChoice) ??
        WingTokens.of(context).muted;
    return Tooltip(
      message: 'Profile: $profile',
      child: Semantics(
        label: 'Profile: $profile',
        child: ExcludeSemantics(
          child: Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: isDefault
                ? Icon(Icons.home_outlined, size: 14, color: color)
                : Text(
                    profile.characters.first.toUpperCase(),
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = item;
    final large = MediaQuery.textScalerOf(context).scale(16) >= 24;
    final textScaler = MediaQuery.textScalerOf(context);
    final bodyHeight =
        textScaler.scale(20) +
        6 +
        textScaler.scale(14.4).clamp(20.0, double.infinity);
    final t = WingTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = Theme.of(context).colorScheme.primaryContainer;
    final tint = t.recentUnreadTint(selected);
    final body = row.unread
        ? Color.lerp(t.raised, tint.withValues(alpha: 1), tint.a)!
        : t.raised;
    final border = row.unread ? t.recentUnreadBorder : t.border;
    final band = row.unread
        ? selected
        : Color.lerp(t.raised, t.surface, dark ? 0.35 : 0.7)!;
    final seconds = (now.millisecondsSinceEpoch / 1000 - row.lastMessage).clamp(
      0,
      double.infinity,
    );
    final minutes = seconds ~/ 60;
    final age = row.lastMessage <= 0
        ? '—'
        : minutes == 0
        ? 'now'
        : minutes < 60
        ? '${minutes}m'
        : '${minutes ~/ 60}h';
    final time = Text(
      age,
      style: TextStyle(
        fontSize: 12,
        height: 1.3,
        color: row.lastMessage > 0 && seconds < 1800 ? t.accent : t.muted,
      ),
    );
    final unread = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: t.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'New answer',
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: t.accent,
            ),
          ),
        ),
      ],
    );
    final active = statusLabel.isNotEmpty;
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (statusLabel == 'Running')
          StudioWorkingIndicator.independent(
            label: statusLabel,
            size: 14,
            color: t.accent,
          )
        else
          Icon(Icons.chat_bubble_outline, size: 14, color: t.accent),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            statusLabel,
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: t.accent,
            ),
          ),
        ),
      ],
    );
    final right = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (row.unread) ...[Flexible(child: unread), const SizedBox(width: 12)],
        time,
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: ValueKey(
          row.group == null
              ? 'activity-${row.chat!.key.workspace.profileName}-${row.chat!.key.sessionId}'
              : 'recent-group-${row.group!.key}',
        ),
        color: body,
        shape: RoundedRectangleBorder(
          borderRadius: WingRadius.card,
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: StudioButtonPress(
          child: InkWell(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: BoxConstraints(minHeight: bodyHeight + 16),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: row.bot != null || row.group != null
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.group?.name ??
                                  row.bot?.title ??
                                  row.chat!.title,
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.25,
                                letterSpacing: -.192,
                                fontWeight: row.unread
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                            if (row.group != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                'Bot group',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.2,
                                  color: t.muted,
                                ),
                              ),
                            ],
                            if (row.bot == null && row.group == null) ...[
                              const SizedBox(height: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 20,
                                ),
                                child: Row(
                                  children: [
                                    if (row.chat!.project != null) ...[
                                      projectAvatar(
                                        context,
                                        row.chat!.project!,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Flexible(
                                      child: Text(
                                        row.chat!.project?.name ?? 'No project',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.2,
                                          color: t.muted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (row.bot != null)
                        BorrowedBotAvatar(
                          bot: row.bot!,
                          name: row.bot!.title,
                          size: 46,
                        )
                      else if (row.group != null)
                        BotGroupIdentity(
                          group: row.group!,
                          bots: bots,
                          size: 46,
                        )
                      else
                        _profileMarker(
                          context,
                          row.chat!.key.workspace.profileName,
                        ),
                    ],
                  ),
                ),
                if (row.messagePreview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: SizedBox(
                      height: textScaler.scale(13) * 1.45 * 2,
                      child: Text(
                        row.messagePreview,
                        key: ValueKey('recent-message-${row.identity}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: t.muted,
                        ),
                      ),
                    ),
                  ),
                Container(
                  constraints: const BoxConstraints(minHeight: 26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: band,
                    border: Border(
                      top: BorderSide(color: border.withValues(alpha: .5)),
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final boundedRight = ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: right,
                      );
                      return large && row.unread && active
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                status,
                                const SizedBox(height: 4),
                                boundedRight,
                              ],
                            )
                          : Row(
                              children: [
                                if (active)
                                  Expanded(child: status)
                                else if (!row.unread)
                                  Expanded(
                                    child: Text(
                                      'Read',
                                      style: TextStyle(
                                        fontSize: 13,
                                        height: 1.3,
                                        color: t.muted,
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                boundedRight,
                              ],
                            );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
