import '../conversation_page.dart';
import '../conversation_reading_scope.dart';
import '../conversation_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../models/recent_conversation.dart';
import '../bot_avatar.dart';
import '../bot_group_conversation.dart';
import '../bot_group_identity.dart';
import '../composer_icon_button.dart';
import '../voice_input_activity.dart';
import '../../models/transcript_message.dart';
import '../../models/connection.dart';
import '../../services/server_connection_status.dart';
import '../profile_message.dart';
import '../server_connection_label.dart';
import '../../theme/wing_theme.dart';
import '../wing_app_bar.dart';

/// Passive saved-page rendition using the normal message and Markdown widgets.
/// It acquires no runtime or external image resources and is mounted only while
/// preparing pixels, never as a moving card.
class ConversationPreview extends StatelessWidget {
  const ConversationPreview({
    super.key,
    required this.card,
    required this.connectionLabel,
    this.connectionIcon,
    this.connectionStatus,
  });
  final RecentConversationCard card;
  final String connectionLabel;
  final ConnectionIcon? connectionIcon;
  final ServerConnectionStatus? connectionStatus;

  @override
  Widget build(BuildContext context) =>
      ConversationReadingScope(key: ValueKey(card.entry.key), builder: _build);

  Widget _build(BuildContext context) {
    if (card.entry.group != null) {
      return IgnorePointer(
        child: _SavedGroupPage(
          card: card,
          instanceHeader: ServerConnectionLabel(
            label: card.entry.group!.instance,
            icon: connectionIcon,
            status: connectionStatus,
          ),
        ),
      );
    }
    final preview = card.preview;
    final rows = preview?.reading.messages ?? const <Map<String, dynamic>>[];
    final messages = rows
        .map(TranscriptMessage.fromRow)
        .where((message) => message.kind == TranscriptMessageKind.dialogue)
        .toList()
        .reversed
        .toList();
    final colors = Theme.of(context).colorScheme;
    final stackedScope =
        card.bot == null &&
        !ConversationReadingScope.compact(context) &&
        MediaQuery.textScalerOf(context).scale(12) > 18 &&
        MediaQuery.sizeOf(context).width < 480;
    final scopeStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: colors.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    final server = ServerConnectionLabel(
      label: connectionLabel,
      icon: connectionIcon,
      status: connectionStatus,
      style: scopeStyle,
    );
    final project = Text(
      preview?.scopeLabel ??
          card.entry.key.chat?.workspace.profileName ??
          'Bot group',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: scopeStyle,
    );
    return IgnorePointer(
      child: ConversationPage(
        header: WingAppBar(
          context: context,
          leading: const StudioButtonPress(
            child: IconButton(
              onPressed: null,
              icon: Icon(Icons.menu),
              tooltip: 'Open navigation menu',
            ),
          ),
          title: BotConversationTitle(
            title: preview?.entry.title ?? card.entry.title,
            bot: card.bot,
            mood: null,
          ),
          inlineContext: ConversationReadingScope.compact(context),
          contextHeight: stackedScope ? 96 : 48,
          contextRow: card.bot != null
              ? server
              : stackedScope
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    server,
                    SizedBox(
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: project,
                      ),
                    ),
                  ],
                )
              : LayoutBuilder(
                  builder: (_, constraints) => Row(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * .5,
                        ),
                        child: server,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('·', style: scopeStyle),
                      ),
                      Expanded(child: project),
                    ],
                  ),
                ),
          actions: const [
            StudioButtonPress(
              child: IconButton(
                onPressed: null,
                icon: Icon(Icons.more_vert),
                tooltip: 'Chat actions',
              ),
            ),
          ],
        ),
        body: ConversationLayout(
          needsInput: false,
          transcript: ListView.builder(
            reverse: true,
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: WingSpacing.sm),
            itemCount: messages.length,
            itemBuilder: (_, index) {
              final message = messages[index];
              return Padding(
                padding: EdgeInsets.only(
                  left: WingSpacing.lg,
                  right: WingSpacing.xs,
                ),
                child: ProfileMessage(
                  message: message,
                  loadImages: false,
                  showEditAction: message.role == 'user',
                  showRestoreAction: message.role == 'user',
                ),
              );
            },
          ),
          footerBuilder: (context, constraints) => ConversationFooter(
            constraints: constraints,
            child: _SavedChatComposer(
              draft: preview?.draft ?? '',
              modelLabel: preview?.modelLabel ?? '',
            ),
          ),
        ),
      ),
    );
  }
}

/// Passive native field state only; never creates an execution owner.
class _SavedChatComposer extends StatefulWidget {
  const _SavedChatComposer({required this.draft, required this.modelLabel});
  final String draft, modelLabel;
  @override
  State<_SavedChatComposer> createState() => _SavedChatComposerState();
}

class _SavedChatComposerState extends State<_SavedChatComposer> {
  final _focus = FocusNode();
  late final _draft = TextEditingController(text: widget.draft);
  @override
  void didUpdateWidget(_SavedChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.draft != oldWidget.draft) _draft.text = widget.draft;
  }

  @override
  void dispose() {
    _focus.dispose();
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConversationComposer(
    focusNode: _focus,
    field: ConversationComposerField(
      controller: _draft,
      focusNode: _focus,
      readOnly: true,
      hintText: 'Message Hermes or type /',
      microphone: VoiceInputButton(enabled: true, onPressed: () {}),
    ),
    controls: Row(
      children: [
        const StudioButtonPress(
          child: IconButton(
            onPressed: null,
            tooltip: 'Attach file',
            icon: Icon(Icons.add),
          ),
        ),
        Expanded(
          child: Text(
            widget.modelLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
    primaryAction: ComposerIconButton(
      focused: false,
      label: 'Send message',
      onPressed: null,
      icon: const ComposerActionGlyph(
        icon: Icons.arrow_upward,
        identity: 'send',
      ),
    ),
  );
}

/// Lightweight saved identity while transcript pixels are unavailable.
class ConversationCardPlaceholder extends StatelessWidget {
  const ConversationCardPlaceholder({super.key, required this.card});
  final RecentConversationCard card;

  @override
  Widget build(BuildContext context) => ConversationPage(
    header: WingAppBar(
      context: context,
      automaticallyImplyLeading: false,
      titleSpacing: WingSpacing.lg,
      title: card.entry.group != null
          ? WingConversationTitle(
              title: card.entry.group!.name,
              avatar: BotGroupIdentity(
                group: card.entry.group!,
                bots: card.groupAppearance.byHandle.values,
                size: 32,
              ),
            )
          : BotConversationTitle(
              title: card.entry.title,
              bot: card.bot,
              mood: null,
            ),
      contextRow: switch (ServerConnectionScope.of(context)) {
        final status? => ServerConnectionLabel(
          label: status.label,
          status: status,
        ),
        null => const SizedBox.shrink(),
      },
    ),
    body: const SizedBox.expand(),
  );
}

/// Owns only passive text/scroll controls; no room session or backend authority.
class _SavedGroupPage extends StatefulWidget {
  const _SavedGroupPage({required this.card, required this.instanceHeader});
  final RecentConversationCard card;
  final Widget instanceHeader;
  @override
  State<_SavedGroupPage> createState() => _SavedGroupPageState();
}

class _SavedGroupPageState extends State<_SavedGroupPage> {
  final _focus = FocusNode();
  late final _draft = TextEditingController(
    text: widget.card.preview?.draft ?? '',
  );
  @override
  void dispose() {
    _focus.dispose();
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.card.entry.group!;
    final preview = widget.card.preview?.group;
    final messages = preview?.messages ?? const <TranscriptMessage>[];
    return BotGroupConversation(
      group: group,
      instanceHeader: widget.instanceHeader,
      appearances: widget.card.groupAppearance.byHandle.values,
      onBack: () {},
      actions: [
        StudioButtonPress(
          child: IconButton(
            onPressed: () {},
            tooltip: 'Group options',
            icon: const Icon(Icons.more_horiz),
          ),
        ),
      ],
      transcript: ListView.builder(
        reverse: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: messages.isEmpty ? 1 : messages.length,
        itemBuilder: (_, index) => messages.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Start a discussion. Mention a bot to focus the reply, or ask the whole group.',
                ),
              )
            : BotGroupMessage(
                group: group,
                senderAvatarVisible: true,
                message: messages[messages.length - 1 - index],
                appearance:
                    widget
                        .card
                        .groupAppearance
                        .byHandle[messages[messages.length - 1 - index]
                        .senderHandle],
                loadImages: false,
              ),
      ),
      composer: ConversationComposer(
        focusNode: _focus,
        field: ConversationComposerField(
          fieldKey: const ValueKey('group-message-composer'),
          controller: _draft,
          focusNode: _focus,
          hintText: 'Message the group',
          readOnly: true,
          microphone: VoiceInputButton(enabled: true, onPressed: () {}),
        ),
        primaryAction: ComposerIconButton(
          focused: false,
          label: 'Send group message',
          onPressed: _draft.text.trim().isEmpty ? null : () async {},
          icon: const ComposerActionGlyph(
            icon: Icons.arrow_upward,
            identity: 'send',
          ),
        ),
      ),
    );
  }
}
