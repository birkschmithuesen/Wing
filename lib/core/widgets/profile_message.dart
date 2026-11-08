import 'selection_viewport.dart';
import 'dart:async';
import 'bot_mention_scope.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';
import '../theme/wing_icons.dart';
import '../theme/bot_bubble_colors.dart';
import 'anchored_expansion_tile.dart';
import 'package:flutter/services.dart';

import '../models/chat_output.dart';
import '../models/user_message_content.dart';
import '../models/bots.dart';
import '../models/transcript_message.dart';
import 'markdown_message_content.dart';
import 'profile_tool_activity.dart';
import 'profile_review_notice_card.dart';
import 'user_message_attachment.dart';
import 'bot_avatar.dart';

/// One message design shared by groups and canonical bot chats.
/// Routes supply identity and action authority; this scope owns no reads or writes.
class BotConversationScope extends InheritedTheme {
  const BotConversationScope({
    super.key,
    required this.bot,
    required this.name,
    required super.child,
    this.onSenderTap,
  });
  final BotRecord? bot;
  final String? name;
  final void Function(BuildContext anchor)? onSenderTap;
  static const avatarInset = 12.0;
  static const avatarSize = 54.0;
  static const avatarSurround = 5.0;
  static const avatarClearance = 12.0;
  static const userInset =
      1 + avatarInset + avatarSize + avatarSurround + avatarClearance;
  static const messageGap = 32.0;
  static BotConversationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BotConversationScope>();
  @override
  Widget wrap(BuildContext context, Widget child) => BotConversationScope(
    bot: bot,
    name: name,
    onSenderTap: onSenderTap,
    child: child,
  );
  @override
  bool updateShouldNotify(BotConversationScope oldWidget) =>
      bot != oldWidget.bot ||
      name != oldWidget.name ||
      onSenderTap != oldWidget.onSenderTap;
}

/// User attachments and explicit assistant deliverables render inline;
/// server paths are resolved only by the owning chat's loader.
class ProfileMessage extends StatelessWidget {
  final TranscriptMessage message;
  bool get streaming => message.streaming;
  final bool showCopyHeader;
  final BotRecord? senderAppearance;
  final bool senderAvatarVisible;
  final BotBubbleColors? botBubbleColors;
  final void Function(BuildContext anchor)? onSenderTap;

  /// Passive snapshots render resource labels without acquiring image bytes.
  final bool loadImages;
  final bool attachmentImagesAvailable;
  final Future<void> Function(ChatOutput output)? onOpenRemoteFile;
  final Future<void> Function(ChatOutput output)? onShareRemoteFile;
  final Future<bool> Function(ChatOutput output)? onDownloadRemoteFile;
  final UserAttachmentImageLoader? loadAttachmentImage;
  final VoidCallback? onReply;
  final VoidCallback? onReadAloud;
  final bool readingAloud;
  final Widget? actions;
  final bool showEditAction;
  final VoidCallback? onEdit;
  final bool showRestoreAction;
  final VoidCallback? onRestore;
  const ProfileMessage({
    super.key,
    required this.message,
    this.showCopyHeader = true,
    this.senderAppearance,
    this.senderAvatarVisible = true,
    this.botBubbleColors,
    this.onSenderTap,
    this.loadImages = true,
    this.attachmentImagesAvailable = true,
    this.onOpenRemoteFile,
    this.onShareRemoteFile,
    this.onDownloadRemoteFile,
    this.loadAttachmentImage,
    this.onReply,
    this.onReadAloud,
    this.readingAloud = false,
    this.actions,
    this.showEditAction = false,
    this.onEdit,
    this.showRestoreAction = false,
    this.onRestore,
  });

  static Widget copyAction(BuildContext context, TranscriptMessage message) =>
      _MessageCopyButton(message: message, compact: false);

  /// Shared presentation admission, also used to clear a preceding activity row.
  static bool usesBotFrame(BuildContext context, TranscriptMessage message) =>
      message.kind == TranscriptMessageKind.botMessage ||
      message.kind == TranscriptMessageKind.discussionPass ||
      (message.kind == TranscriptMessageKind.discussion &&
          message.role != 'user') ||
      (message.role == 'assistant' &&
          message.kind == TranscriptMessageKind.dialogue &&
          BotConversationScope.maybeOf(context)?.name != null);

  Widget _userBubble(
    BuildContext context,
    String content,
    ({Widget widget, double width})? timestamp,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final footerColor = Color.lerp(
      colors.surface,
      colors.primaryContainer,
      .5,
    )!;
    return LayoutBuilder(
      builder: (context, bounds) {
        final enlarged = MediaQuery.textScalerOf(context).scale(12) > 18;
        final inset = enlarged ? 20.0 : bounds.maxWidth * .17;
        final framed =
            BotConversationScope.maybeOf(context) != null ||
            message.kind == TranscriptMessageKind.discussion;
        final bubbleWidth = math.max(
          1.0,
          math.min(
            bounds.maxWidth - 44 - inset,
            bounds.maxWidth - (framed ? BotConversationScope.userInset : 0),
          ),
        );
        return Align(
          alignment: AlignmentDirectional.centerEnd,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: bubbleWidth),
            child: IntrinsicWidth(
              child: ClipRRect(
                key: ValueKey(('user-message-bubble', message.id)),
                borderRadius: WingRadius.card,
                child: ColoredBox(
                  color: colors.primaryContainer,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (content.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                          child: viewportSelection(
                            SelectableText.rich(
                              BotMentionScope.of(
                                    context,
                                  )?.text(content, colors.primary) ??
                                  TextSpan(text: content),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                height: 1.45,
                                color: colors.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                      if (message.attachments.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          child: UserMessageAttachments(
                            attachments: message.attachments,
                            width: math.min(320, bubbleWidth - 20),
                            loadImages: loadImages,
                            loadImage: loadAttachmentImage,
                            imageServerAvailable: attachmentImagesAvailable,
                            onDownload: onDownloadRemoteFile == null
                                ? null
                                : _downloadAttachment,
                          ),
                        ),
                      Material(
                        key: ValueKey(('user-message-footer', message.id)),
                        color: footerColor,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: 10,
                            end: 2,
                          ),
                          child: _footer(
                            context,
                            timestamp,
                            true,
                            userWidth: bubbleWidth - 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _botBubble(BuildContext context) {
    final theme = Theme.of(context);
    final scope = BotConversationScope.maybeOf(context);
    final incoming = message.sender != null;
    final appearance = senderAppearance ?? (incoming ? null : scope?.bot);
    final name = appearance?.title ?? message.sender ?? scope!.name!;
    final seed = BotAvatar.resolveColor(appearance?.color ?? '', name);
    final palette = botBubbleColors ?? BotBubbleColors.fromAvatar(seed, theme);
    final fill = palette.fill;
    final tile = theme.brightness == Brightness.dark
        ? Color.lerp(fill, theme.colorScheme.onSurface, .09)!
        : Color.lerp(fill, theme.colorScheme.surfaceContainerLowest, .75)!;
    final frame = Color.lerp(seed, theme.colorScheme.outlineVariant, .55)!;
    final date = _timestamp(context, color: palette.timestamp);
    final tap = onSenderTap ?? (incoming ? null : scope?.onSenderTap);
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: BotConversationScope.messageGap / 2,
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          var width = bounds.maxWidth;
          if (!streaming &&
              message.text.length <= 80 &&
              !message.text.contains('\n') &&
              !message.text.contains('[') &&
              message.attachments.isEmpty) {
            final style = theme.textTheme.bodyLarge!;
            final painter = TextPainter(
              text: TextSpan(
                text: message.text.replaceAll(RegExp(r'[*_`]'), ''),
                style: style,
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final measure = TextPainter(
              text: TextSpan(text: '0' * 26, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            width = math.min(
              width,
              math.max(240, math.min(painter.width, measure.width) + 26),
            );
            painter.dispose();
            measure.dispose();
          }
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    key: ValueKey(('bot-message-bubble', message.id)),
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: WingRadius.card,
                      border: Border.all(color: frame),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            82,
                            6,
                            12,
                            16,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 26),
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                name,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: palette.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                          child:
                              message.kind ==
                                  TranscriptMessageKind.discussionPass
                              ? Text(
                                  message.text,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: palette.text,
                                    fontStyle: FontStyle.italic,
                                  ),
                                )
                              : Theme(
                                  data: palette.markdownTheme(theme),
                                  child: MarkdownMessageContent(
                                    data: message.text,
                                    loadImages: loadImages,
                                    streaming: streaming,
                                    loadImage: loadAttachmentImage,
                                    onOpenRemoteFile: onOpenRemoteFile,
                                    onDownloadRemoteFile: onDownloadRemoteFile,
                                    deliverables: !incoming,
                                  ),
                                ),
                        ),
                        for (final attachment in message.attachments)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: UserMessageAttachmentTile(
                              attachment: attachment,
                              loadImages: loadImages,
                              loadImage: loadAttachmentImage,
                              imageServerAvailable: attachmentImagesAvailable,
                              onDownload: onDownloadRemoteFile == null
                                  ? null
                                  : _downloadAttachment,
                            ),
                          ),
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(WingRadius.md),
                          ),
                          child: Material(
                            key: ValueKey(('bot-message-footer', message.id)),
                            color: Color.lerp(
                              theme.colorScheme.surface,
                              fill,
                              .5,
                            )!,
                            child: Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 12,
                                end: 2,
                              ),
                              child: _footer(
                                context,
                                date,
                                false,
                                // The frame contributes one pixel on each side.
                                userWidth: width - 16,
                                botBubble: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PositionedDirectional(
                    start: BotConversationScope.avatarInset + 1,
                    top: -22,
                    child: Visibility(
                      visible: senderAvatarVisible,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Builder(
                        builder: (anchor) {
                          final portrait = Container(
                            key: ValueKey((
                              'bot-message-avatar-frame',
                              message.id,
                            )),
                            width: BotConversationScope.avatarSize,
                            height: BotConversationScope.avatarSize,
                            decoration: BoxDecoration(
                              color: tile,
                              borderRadius: WingRadius.card,
                              border: Border.all(color: frame),
                              boxShadow: [
                                BoxShadow(
                                  color: theme.colorScheme.surface,
                                  spreadRadius:
                                      BotConversationScope.avatarSurround,
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Semantics(
                              label: '$name avatar',
                              image: true,
                              child: appearance == null
                                  ? Icon(
                                      Icons.smart_toy_outlined,
                                      size: 34,
                                      color: seed,
                                    )
                                  : BorrowedBotAvatar(
                                      bot: appearance,
                                      name: name,
                                      size: 34,
                                    ),
                            ),
                          );
                          return tap == null
                              ? portrait
                              : Tooltip(
                                  message: 'Options for $name',
                                  child: Semantics(
                                    button: true,
                                    child: StudioButtonPress(
                                      child: InkWell(
                                        borderRadius: WingRadius.card,
                                        onTap: () => tap(anchor),
                                        child: portrait,
                                      ),
                                    ),
                                  ),
                                );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _footer(
    BuildContext context,
    ({Widget widget, double width})? timestamp,
    bool user, {
    double userWidth = 0,
    bool botBubble = false,
  }) {
    final compactActionStyle = IconButton.styleFrom(
      minimumSize: const Size(48, 32),
      maximumSize: const Size(48, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      foregroundColor: Theme.of(context).colorScheme.onSurface,
    );
    final controls = [
      if (onReply != null)
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Reply to message',
            style: compactActionStyle,
            onPressed: streaming ? null : onReply,
            icon: const Icon(Icons.reply_outlined, size: 18),
          ),
        ),
      if (user && showEditAction)
        StudioButtonPress(
          child: IconButton(
            key: ValueKey('edit-message-${message.id}'),
            tooltip: 'Edit message',
            style: compactActionStyle,
            onPressed: streaming ? null : onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
        ),
      if (user && showRestoreAction)
        StudioButtonPress(
          child: IconButton(
            key: ValueKey('restore-message-${message.id}'),
            tooltip: 'Restore checkpoint',
            style: compactActionStyle,
            onPressed: streaming ? null : onRestore,
            icon: const Icon(Icons.undo, size: 18),
          ),
        ),
      if (!user && !botBubble && actions != null) actions!,
      if (!user && actions == null && onReadAloud != null)
        StudioButtonPress(
          child: IconButton(
            tooltip: readingAloud ? 'Stop reading aloud' : 'Read aloud',
            style: botBubble ? compactActionStyle : null,
            onPressed: streaming ? null : onReadAloud,
            icon: Icon(
              readingAloud ? Icons.stop : Icons.volume_up_outlined,
              size: 18,
            ),
          ),
        ),
      if ((user || botBubble) &&
          message.kind != TranscriptMessageKind.discussionPass)
        _MessageCopyButton(
          message: message,
          compact: true,
          disabled: streaming,
        ),
    ];
    final date = timestamp == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(right: 4),
            child: timestamp.widget,
          );
    final enlarged = MediaQuery.textScalerOf(context).scale(12) > 18;
    final stacked =
        (user || botBubble) &&
        controls.isNotEmpty &&
        (enlarged ||
            (timestamp?.width ?? 0) + 4 + controls.length * 48 > userWidth);
    final content = stacked
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?date,
              Align(
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: controls),
              ),
            ],
          )
        : (user || botBubble) && controls.isEmpty
        ? Align(alignment: Alignment.centerLeft, child: date)
        : (user || botBubble)
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              date ?? const SizedBox.shrink(),
              if (controls.isNotEmpty)
                Row(mainAxisSize: MainAxisSize.min, children: controls),
            ],
          )
        : Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [?date, ...controls],
          );
    final footer = ConstrainedBox(
      constraints: BoxConstraints(minHeight: user || botBubble ? 32 : 48),
      child: Align(alignment: Alignment.centerRight, child: content),
    );
    return footer;
  }

  Future<bool> _downloadAttachment(UserMessageAttachment attachment) =>
      onDownloadRemoteFile!(
        ChatOutput(
          kind: attachment.isImage ? ChatOutputKind.image : ChatOutputKind.file,
          path: attachment.target,
          url: null,
          label: attachment.name,
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (message.kind == TranscriptMessageKind.hidden) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final role = message.role;
    if (usesBotFrame(context, message)) {
      final bubble = _botBubble(context);
      return actions == null
          ? bubble
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [bubble, actions!],
            );
    }
    final notice = message.text;
    if (message.kind == TranscriptMessageKind.notice) {
      final result = message.noticeResult;
      final label = Text(
        notice,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
      final noticeBody = result == null
          ? Center(child: label)
          : _TranscriptNotice(
              key: ValueKey(('transcript-notice', message.id)),
              title: label,
              subtitle: Text(message.noticeDisclosure),
              actions: actions,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: message.noticePlainText
                      ? viewportSelection(
                          SelectableText(
                            result,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: message.noticeMonospace
                                  ? 'monospace'
                                  : null,
                            ),
                          ),
                        )
                      : MarkdownMessageContent(
                          data: result,
                          loadImages: loadImages,
                          onOpenRemoteFile: onOpenRemoteFile,
                          onDownloadRemoteFile: onDownloadRemoteFile,
                          loadImage: loadAttachmentImage,
                          deliverables: true,
                        ),
                ),
              ],
            );
      return Padding(
        padding: actions == null
            ? const EdgeInsets.symmetric(vertical: 8, horizontal: 8)
            : EdgeInsets.zero,
        child: actions == null || result != null
            ? noticeBody
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: noticeBody),
                  actions!,
                ],
              ),
      );
    }
    if (message.kind == TranscriptMessageKind.review) {
      return ProfileReviewNoticeRow(text: message.text);
    }
    if (message.kind == TranscriptMessageKind.steering) {
      final style = theme.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        color: theme.colorScheme.onSurfaceVariant,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Center(
          child: FractionallySizedBox(
            widthFactor: .86,
            child: Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    WingIcons.steer,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text('steered', style: style),
                  Text(' · ', style: style),
                  Flexible(
                    child: viewportSelection(
                      SelectableText(message.text, style: style),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final content = message.text;
    if (message.kind == TranscriptMessageKind.system) {
      final multiline = message.systemMultiline;
      final text = content;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Center(
          child: viewportSelection(
            SelectableText(
              text,
              textAlign: multiline ? TextAlign.left : TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    if (message.kind == TranscriptMessageKind.tool) {
      return ProfileToolActivity(
        results: [message.tool!],
        loadImage: loadAttachmentImage,
        onOpenResource: onOpenRemoteFile,
        onShareResource: onShareRemoteFile,
      );
    }
    if (message.kind == TranscriptMessageKind.voice) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: WingSpacing.xs),
            child: Text(
              '${role == 'user' ? 'You · voice' : 'GPT-Live'} · Not saved to Hermes',
              textAlign: role == 'user' ? TextAlign.end : TextAlign.start,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _dialogue(context, content, role),
        ],
      );
    }
    return _dialogue(context, content, role);
  }

  Widget _dialogue(BuildContext context, String content, String role) {
    final theme = Theme.of(context);
    final user = role == 'user';
    final timestamp = _timestamp(
      context,
      color: user ? theme.colorScheme.onSurface : null,
    );
    if (user) {
      return Padding(
        padding:
            BotConversationScope.maybeOf(context) != null ||
                message.kind == TranscriptMessageKind.discussion
            ? const EdgeInsets.symmetric(
                vertical: BotConversationScope.messageGap / 2,
              )
            : const EdgeInsets.only(bottom: WingSpacing.md),
        child: _userBubble(context, content, timestamp),
      );
    }
    final answer = MarkdownMessageContent(
      data: content,
      loadImages: loadImages,
      streaming: streaming,
      onOpenRemoteFile: onOpenRemoteFile,
      onDownloadRemoteFile: onDownloadRemoteFile,
      loadImage: loadAttachmentImage,
      deliverables: true,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: WingSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showCopyHeader)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: answer),
                streaming
                    ? const SizedBox(width: 44, height: 48)
                    : copyAction(context, message),
              ],
            ),
          if (!showCopyHeader && content.isNotEmpty)
            Padding(padding: const EdgeInsets.only(right: 12), child: answer),
          for (final attachment in message.attachments)
            Padding(
              padding: const EdgeInsets.only(right: 12, top: 8),
              child: UserMessageAttachmentTile(
                key: ValueKey(attachment.target),
                attachment: attachment,
                loadImages: loadImages,
                loadImage: loadAttachmentImage,
                imageServerAvailable: attachmentImagesAvailable,
                onDownload: onDownloadRemoteFile == null
                    ? null
                    : _downloadAttachment,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _footer(context, timestamp, user),
          ),
        ],
      ),
    );
  }

  ({Widget widget, double width})? _timestamp(
    BuildContext context, {
    Color? color,
  }) {
    final date = message.timestamp;
    if (date == null) return null;
    final localizations = MaterialLocalizations.of(context);
    final time = TimeOfDay.fromDateTime(date);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final compact =
        '${date.day.toString().padLeft(2, '0')} ${months[date.month - 1]}, ${localizations.formatTimeOfDay(time, alwaysUse24HourFormat: true)}';
    final full =
        '${localizations.formatFullDate(date)}, '
        '${localizations.formatTimeOfDay(time, alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 12,
      height: 1,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final painter = TextPainter(
      text: TextSpan(text: compact, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    final widget = Tooltip(
      message: full,
      excludeFromSemantics: true,
      child: Text(compact, semanticsLabel: full, maxLines: 1, style: style),
    );
    return (widget: widget, width: width);
  }
}

/// Keep answer actions centered on the disclosure header, not its expanded body.
class _TranscriptNotice extends StatefulWidget {
  const _TranscriptNotice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.actions,
  });

  final Widget title;
  final Widget subtitle;
  final List<Widget> children;
  final Widget? actions;

  @override
  State<_TranscriptNotice> createState() => _TranscriptNoticeState();
}

class _TranscriptNoticeState extends State<_TranscriptNotice> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => AnchoredExpansionTile(
    title: widget.title,
    subtitle: widget.subtitle,
    minTileHeight: widget.actions == null ? null : 56,
    shape: const Border(),
    tilePadding: widget.actions == null
        ? null
        : const EdgeInsets.only(left: WingSpacing.lg),
    trailing: widget.actions == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 48,
                child: Center(
                  child: AnimatedRotation(
                    turns: _expanded ? .5 : 0,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : WingMotion.standard,
                    curve: WingMotion.curve,
                    child: const Icon(Icons.expand_more),
                  ),
                ),
              ),
              widget.actions!,
            ],
          ),
    onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
    children: widget.children,
  );
}

/// Copy keeps its footprint and accessible action name through pending and failure.
class _MessageCopyButton extends StatefulWidget {
  const _MessageCopyButton({
    required this.message,
    required this.compact,
    this.disabled = false,
  });
  final TranscriptMessage message;
  final bool compact, disabled;
  @override
  State<_MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<_MessageCopyButton> {
  bool _busy = false, _copied = false;
  Timer? _reset;
  Future<void> _copy() async {
    if (_busy) return;
    _reset?.cancel();
    setState(() {
      _busy = true;
      _copied = false;
    });
    try {
      await Clipboard.setData(ClipboardData(text: widget.message.copyText));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _copied = true;
      });
      _reset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not copy message. Try again.')),
      );
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.compact ? const Size(48, 32) : const Size(44, 48);
    return StudioButtonPress(
      child: IconButton(
        tooltip: 'Copy message',
        constraints: BoxConstraints.tight(size),
        style: IconButton.styleFrom(
          minimumSize: size,
          maximumSize: size,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        ),
        onPressed: widget.disabled || _busy ? null : _copy,
        icon: _busy
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  value: MediaQuery.disableAnimationsOf(context) ? .75 : null,
                  semanticsLabel: 'Copying message',
                ),
              )
            : Icon(
                _copied ? Icons.check : Icons.copy_outlined,
                size: widget.compact ? 18 : 17,
              ),
      ),
    );
  }
}
