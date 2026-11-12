import 'conversation_reading_scope.dart';
import 'conversation_page.dart';
import 'package:flutter/material.dart';

import '../models/bots.dart';
import '../models/transcript_message.dart';
import '../theme/wing_theme.dart';
import '../theme/bot_bubble_colors.dart';
import 'bot_avatar.dart';
import 'bot_group_identity.dart';
import 'bot_mention_scope.dart';
import 'profile_message.dart';
import 'user_message_attachment.dart';
import '../models/chat_output.dart';
import 'wing_app_bar.dart';

/// One discussion frame for live chats and passive Recents preparation.
/// Callers supply content and action authority; this widget owns only paint.
class BotGroupConversation extends StatelessWidget {
  const BotGroupConversation({
    super.key,
    required this.group,
    required this.appearances,
    required this.instanceHeader,
    required this.transcript,
    required this.composer,
    required this.actions,
    required this.onBack,
    this.beforeComposer = const [],
    this.suggestions,
    this.composerController,
    this.membersAnchor,
    this.onMembers,
    this.onEdit,
    this.showMembers = true,
  });
  final BotGroup group;
  final Iterable<BotRecord> appearances;
  final Widget instanceHeader;
  final Widget transcript, composer;
  final List<Widget> actions, beforeComposer;
  final Widget? suggestions;
  final TextEditingController? composerController;
  final GlobalKey? membersAnchor;
  final VoidCallback? onMembers, onEdit;
  final VoidCallback onBack;
  final bool showMembers;

  @override
  Widget build(BuildContext context) =>
      ConversationReadingScope(key: ValueKey(group.key), builder: _build);

  Widget _build(BuildContext context) {
    final reading = ConversationReadingScope.maybeOf(context)!;
    final landscape = ConversationReadingScope.compact(context);
    final hideContext = reading.active && !landscape;
    final bots = {for (final bot in appearances) bot.scope.profileName: bot};
    final palette = botBubblePalette({
      for (final member in group.members)
        member.handle: BotAvatar.resolveColor(
          bots[member.profile]?.color ?? '',
          bots[member.profile]?.title ?? member.name,
        ),
    }, Theme.of(context));
    return ConversationPage(
      header: WingAppBar(
        context: context,
        inlineContext: landscape || reading.active,
        leading: StudioButtonPress(
          child: BackButton(onPressed: reading.active ? reading.exit : onBack),
        ),
        title: Builder(
          builder: (context) {
            final title = WingConversationTitle(
              title: group.name,
              avatar: BotGroupIdentity(
                group: group,
                bots: appearances,
                size: 32,
              ),
            );
            return onEdit == null
                ? title
                : Tooltip(
                    message: 'Edit group',
                    child: Semantics(
                      button: true,
                      child: StudioButtonPress(
                        child: InkWell(
                          onTap: onEdit,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: title,
                          ),
                        ),
                      ),
                    ),
                  );
          },
        ),
        actions: actions,
        contextRow: hideContext ? null : instanceHeader,
        contextActions: [
          if (showMembers && !hideContext)
            SizedBox(
              key: membersAnchor,
              child: StudioButtonPress(
                child: IconButton(
                  key: const ValueKey('group-members-entry'),
                  tooltip: 'Show group members · ${group.members.length} bots',
                  onPressed: onMembers,
                  icon: const Icon(Icons.group_outlined, size: 18),
                ),
              ),
            ),
        ],
      ),
      body: BotConversationScope(
        bot: null,
        name: null,
        child: _GroupBubblePalette(
          colors: palette,
          child: ConversationLayout(
            needsInput: false,
            transcript: transcript,
            footerBuilder: (context, constraints) => ConversationFooter(
              constraints: constraints,
              controller: composerController,
              suggestions: suggestions,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [...beforeComposer, composer],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupBubblePalette extends InheritedWidget {
  const _GroupBubblePalette({required this.colors, required super.child});
  final Map<String, BotBubbleColors> colors;
  static BotBubbleColors? forMessage(BuildContext context, String? handle) =>
      context
          .dependOnInheritedWidgetOfExactType<_GroupBubblePalette>()
          ?.colors[handle];
  @override
  bool updateShouldNotify(_GroupBubblePalette oldWidget) =>
      colors != oldWidget.colors;
}

/// Shared discussion message, including the room's resolved mention styling.
class BotGroupMessage extends StatelessWidget {
  const BotGroupMessage({
    super.key,
    required this.group,
    required this.message,
    required this.appearance,
    required this.senderAvatarVisible,
    this.loadImages = true,
    this.onSenderTap,
    this.onReply,
    this.loadAttachmentImage,
    this.onDownloadAttachment,
  });
  final UserAttachmentImageLoader? loadAttachmentImage;
  final Future<bool> Function(ChatOutput)? onDownloadAttachment;
  final BotGroup group;
  final TranscriptMessage message;
  final BotRecord? appearance;
  final bool senderAvatarVisible;
  final bool loadImages;
  final void Function(BuildContext anchor)? onSenderTap;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) => BotMentionScope(
    names: {for (final member in group.members) member.handle: member.name},
    child: ProfileMessage(
      message: message,
      senderAppearance: appearance,
      senderAvatarVisible: senderAvatarVisible,
      botBubbleColors: message.sender == null
          ? null
          : _GroupBubblePalette.forMessage(context, message.senderHandle),
      onSenderTap: onSenderTap,
      onReply: onReply,
      loadImages: loadImages,
      loadAttachmentImage: loadAttachmentImage,
      onDownloadRemoteFile: onDownloadAttachment,
    ),
  );
}
