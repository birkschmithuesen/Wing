import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:flutter/material.dart';
import '../../widgets/studio_loading.dart';
import '../../models/bots.dart';
import '../../widgets/bot_group_identity.dart';
import '../../services/bot_profile_edit_session.dart';
import '../../services/bot_screen_session.dart';
import '../../services/bots_session.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/bot_avatar.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/wing_app_bar.dart';
import '../../widgets/workspace_action_menu.dart';
import 'bot_profile_editor.dart';
import 'bot_screen_view.dart';
import 'bot_settings_screen.dart';
import 'bots_create_screen.dart';

/// Presentation choices live with the workspace route, so Back from a bot chat
/// returns to the same tab and search without giving them I/O authority.
@immutable
class BotsViewState {
  const BotsViewState({this.tab = 0, this.query = '', this.showHidden = false});
  final int tab;
  final String query;
  final bool showHidden;
}

class BotsContent extends StatefulWidget {
  const BotsContent({
    super.key,
    required this.session,
    required this.instanceHeader,
    required this.viewState,
    required this.onViewChanged,
    required this.onOpenMenu,
    required this.onOpenChat,
    required this.onOpenGroupMemberChat,
    required this.onOpenGroup,
  });
  final BotsSession session;
  final Widget instanceHeader;
  final BotsViewState viewState;
  final ValueChanged<BotsViewState> onViewChanged;
  final VoidCallback onOpenMenu;
  final Future<void> Function(BotRecord) onOpenChat;
  final Future<void> Function(BuildContext, BotRecord) onOpenGroupMemberChat;
  final Future<void> Function(BotGroup) onOpenGroup;
  @override
  State<BotsContent> createState() => _BotsContentState();
}

class _BotsContentState extends State<BotsContent> {
  late final _search = TextEditingController(text: widget.viewState.query);
  BotsViewState get view => widget.viewState;
  bool _canUse() => mounted && ModalRoute.of(context)?.isCurrent == true;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _change({int? tab, String? query, bool? hidden}) {
    widget.onViewChanged(
      BotsViewState(
        tab: tab ?? view.tab,
        query: query ?? view.query,
        showHidden: hidden ?? view.showHidden,
      ),
    );
  }

  Future<void> _push(Widget page) async {
    widget.session.setVisible(false);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => BotAvatarScope(session: widget.session, child: page),
        ),
      );
    } finally {
      if (mounted) widget.session.setVisible(true);
    }
  }

  Future<void> _open(BotRecord bot) => widget.onOpenChat(bot);

  Future<void> _editAppearance(BotRecord bot) {
    final repository = widget.session.repository(bot.scope.connectionIdentity);
    return _push(
      BotProfileEditor(
        createSession: () => BotProfileEditSession(
          repository,
          bot,
          avatars: widget.session.createAvatarBorrower(),
          validateImage: (bot) => widget.session.reloadAvatar(bot.scope),
          onSaved: (bot, image, assetSaved) => widget.session.acceptAppearance(
            bot,
            image: image,
            assetSaved: assetSaved,
          ),
        ),
      ),
    );
  }

  Future<void> _botMenu(BuildContext anchor, BotRecord bot) async {
    final repository = widget.session.repository(bot.scope.connectionIdentity);
    final server = repository.server;
    final action = await showWorkspaceActionMenu(
      anchor,
      bot.title,
      '${bot.instance} · ${bot.profile.name}',
      [
        ('screen', 'View screen', Icons.desktop_windows_outlined, true),
        ('pin', bot.pinned ? 'Unpin' : 'Pin', Icons.push_pin_outlined, true),
        (
          'hide',
          bot.hidden ? 'Show bot' : 'Hide bot',
          Icons.visibility_outlined,
          true,
        ),
        ('settings', 'Bot settings', Icons.tune_outlined, server != null),
      ],
      keyPrefix: 'bot-menu',
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'pin':
        await widget.session.setPinned(bot, canUse: _canUse);
      case 'hide':
        await widget.session.setHidden(bot, canUse: _canUse);
      case 'screen':
        await _push(
          BotScreenView(
            createSession: () => BotScreenSession(repository, bot),
            conversation: widget.session,
            readConversation: () => [],
            readRequest: () =>
                'Open the screen from a bot chat to see its conversation here.',
            sendMessage: null,
          ),
        );
      case 'settings':
        if (server != null) {
          await _push(
            BotSettingsScreen(
              profile: server.profile(bot.profile.name),
              bot: bot,
              session: widget.session,
            ),
          );
        }
    }
  }

  Future<void> _groupMenu(BuildContext anchor, BotGroup group) async {
    final action =
        await showWorkspaceActionMenu(anchor, group.name, group.instance, [
          ('open', 'Open discussion', Icons.forum_outlined, true),
          (
            'pin',
            group.pinned ? 'Unpin' : 'Pin to top',
            Icons.push_pin_outlined,
            true,
          ),
          ('edit', 'Edit group', Icons.edit_outlined, true),
          ('stop', 'Stop group work', Icons.stop_outlined, true),
          ('delete', 'Disband group', Icons.delete_outline, true),
        ], keyPrefix: 'group-menu');
    if (!mounted) return;
    if (action == 'open') {
      await _openGroup(group);
      return;
    }
    if (action == 'edit') await _editGroup(group);
    if (action == 'stop') {
      await widget.session.groupAction(group, 'stop', canUse: _canUse);
    }
    if (action == 'pin') {
      await widget.session.setGroupPinned(group, canUse: _canUse);
    }
    if (!mounted) return;
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: Text('Disband ${group.name}?'),
          content: const Text(
            'Stops group work and removes this room. The bots and their private chats stay available.',
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Disband group',
              confirmIcon: Icons.group_remove_outlined,
              destructive: true,
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) {
        await widget.session.groupAction(group, 'disband', canUse: _canUse);
      }
    }
  }

  Future<BotGroup?> _editGroup(
    BotGroup group, {
    bool fromDiscussion = false,
  }) async {
    if (fromDiscussion) {
      return openGroupEditor(
        context,
        widget.session,
        group,
        onOpenMemberChat: widget.onOpenGroupMemberChat,
      );
    }
    widget.session.setVisible(false);
    try {
      return await openGroupEditor(
        context,
        widget.session,
        group,
        onOpenMemberChat: widget.onOpenGroupMemberChat,
      );
    } finally {
      if (mounted) widget.session.setVisible(true);
    }
  }

  Future<void> _openGroup(BotGroup group) async {
    widget.session.setVisible(false);
    try {
      await widget.onOpenGroup(group);
    } finally {
      if (mounted) widget.session.setVisible(true);
    }
  }

  @override
  Widget build(BuildContext context) => BotAvatarScope(
    session: widget.session,
    child: _buildWithAvatars(context),
  );

  Widget _buildWithAvatars(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final state = widget.session.state;
      final query = view.query.trim().toLowerCase();
      final bots =
          state.bots
              .where(
                (bot) =>
                    (view.showHidden || !bot.hidden) &&
                    '${bot.title} ${bot.profile.name} ${bot.instance} ${bot.profile.description ?? ''}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList()
            ..sort(BotRecord.compareForRoster);
      final groups =
          state.groups
              .where(
                (group) =>
                    '${group.name} ${group.instance} ${group.members.map((m) => m.name).join(' ')}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList()
            ..sort((a, b) {
              final pin = (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0);
              return pin != 0 ? pin : a.name.compareTo(b.name);
            });
      return DefaultTabController(
        length: 2,
        initialIndex: view.tab,
        child: Scaffold(
          appBar: WingAppBar(
            context: context,
            leading: StudioButtonPress(
              child: IconButton(
                tooltip: 'Open menu',
                onPressed: widget.onOpenMenu,
                icon: const Icon(Icons.menu),
              ),
            ),
            title: const Text('Bots'),
            contextRow: widget.instanceHeader,
            actions: [
              StudioButtonPress(
                child: PopupMenuButton<String>(
                  tooltip: 'Roster options',
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (_) => _change(hidden: !view.showHidden),
                  itemBuilder: (_) => [
                    StudioCheckedPopupMenuItem(
                      entry: CheckedPopupMenuItem(
                        value: 'hidden',
                        checked: view.showHidden,
                        child: const Text('Show hidden bots'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                TabBar(
                  onTap: (tab) => _change(tab: tab),
                  tabs: const [
                    StudioButtonPress(child: Tab(text: 'Bots')),
                    StudioButtonPress(child: Tab(text: 'Groups')),
                  ],
                ),
                Expanded(
                  child: StudioLoadingRegion(
                    busy: state.loading || state.busy,
                    available:
                        !state.busy &&
                        (view.tab == 0
                            ? state.botsAvailable
                            : state.groupsAvailable),
                    label: 'Loading bots and groups',
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                      children: [
                        viewportSelection(
                          TextField(
                            key: const ValueKey('bots-search'),
                            controller: _search,
                            onChanged: (text) => _change(query: text),
                            decoration: InputDecoration(
                              hintText: view.tab == 0
                                  ? 'Search bots'
                                  : 'Search groups',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: view.query.isEmpty
                                  ? null
                                  : StudioButtonPress(
                                      child: IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () {
                                          _search.clear();
                                          _change(query: '');
                                        },
                                        icon: const Icon(Icons.close),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        for (final error in state.errors)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: StudioError(error),
                          ),
                        const SizedBox(height: 16),
                        if ((view.tab == 0 ? bots.isEmpty : groups.isEmpty) &&
                            !state.loading)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: Text(
                              query.isNotEmpty
                                  ? 'No matches. Try another search.'
                                  : view.tab == 0
                                  ? 'Your saved profiles appear here as bots.'
                                  : 'No groups yet. Create a group to bring bots into one discussion.',
                            ),
                          ),
                        if (view.tab == 0 && bots.isNotEmpty)
                          _roster(context, [
                            for (final bot in bots)
                              _botRow(context, bot, state.busy),
                          ]),
                        if (view.tab == 1 && groups.isNotEmpty)
                          _roster(context, [
                            for (final group in groups)
                              _groupRow(context, group, state.busy),
                          ]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: StudioButtonPress(
            child: FloatingActionButton(
              key: const ValueKey('bots-create'),
              tooltip: view.tab == 0 ? 'Create bot' : 'Create group',
              elevation: 2,
              onPressed:
                  state.busy ||
                      state.instances.isEmpty ||
                      view.tab == 1 && state.groupHosts.isEmpty
                  ? null
                  : () => _push(
                      BotsCreateScreen(
                        session: widget.session,
                        group: view.tab == 1,
                      ),
                    ),
              child: const Icon(Icons.add),
            ),
          ),
        ),
      );
    },
  );
  Widget _roster(BuildContext context, List<Widget> rows) =>
      Column(children: rows);
  Widget status(String label) {
    final t = WingTokens.of(context);
    final running = label == 'Running' || label == 'Group running';
    final active = running || label == 'Needs input';
    final c = label == 'Needs input'
        ? t.warning
        : running
        ? t.running
        : t.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (active) ...[
          if (running)
            StudioWorkingIndicator.independent(label: label, size: 14, color: c)
          else
            Icon(Icons.chat_bubble_outline, size: 14, color: c),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(label, style: TextStyle(fontSize: 12, color: c)),
        ),
      ],
    );
  }

  Widget card({
    required String identity,
    required Widget main,
    required Widget footer,
  }) {
    final t = WingTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        key: ValueKey(identity),
        color: t.raised,
        shape: RoundedRectangleBorder(
          borderRadius: WingRadius.card,
          side: BorderSide(color: t.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            main,
            Container(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  t.muted.withValues(alpha: .04),
                  t.raised,
                ),
                border: Border(top: BorderSide(color: t.border)),
              ),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }

  Widget _botRow(BuildContext context, BotRecord bot, bool busy) {
    final t = WingTokens.of(context);
    final key = GlobalKey();
    final label = bot.presence == BotPresence.working
        ? 'Running'
        : bot.presence == BotPresence.groupWorking
        ? 'Group running'
        : bot.presence == BotPresence.needsInput
        ? 'Needs input'
        : bot.presence == BotPresence.unknown
        ? 'Unknown'
        : 'Ready';
    return card(
      identity: 'bot-${bot.id}',
      main: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: StudioButtonPress(
                child: InkWell(
                  onTap: busy ? null : () => _open(bot),
                  onLongPress: busy
                      ? null
                      : () => _botMenu(key.currentContext!, bot),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        children: [
                          Text(
                            bot.title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                          ),
                          if (bot.pinned)
                            Tooltip(
                              message: 'Pinned',
                              child: Icon(
                                Icons.push_pin_outlined,
                                size: 13,
                                color: t.muted,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        bot.preview.isEmpty
                            ? 'Start a conversation'
                            : bot.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: t.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 56,
              height: 56,
              child: StudioButtonPress(
                child: IconButton(
                  tooltip: 'Edit name & appearance for ${bot.title}',
                  padding: const EdgeInsets.all(4),
                  onPressed: busy ? null : () => _editAppearance(bot),
                  icon: LiveBotAvatar(
                    bot: bot,
                    name: bot.profile.name,
                    size: 48,
                    // The footer owns work feedback; the face keeps identity motion.
                    mood: bot.presence == BotPresence.needsInput
                        ? BotAvatarMood.think
                        : BotAvatarMood.idle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Expanded(child: status(label)),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.textScalerOf(context).scale(16) >= 24
                    ? 100
                    : 110,
              ),
              child: Text(
                bot.instance,
                style: TextStyle(fontSize: 11, color: t.muted),
              ),
            ),
            StudioButtonPress(
              child: IconButton(
                key: key,
                tooltip: 'Actions for ${bot.title}',
                onPressed: busy
                    ? null
                    : () => _botMenu(key.currentContext!, bot),
                icon: const Icon(Icons.more_horiz),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupRow(BuildContext context, BotGroup group, bool busy) {
    final t = WingTokens.of(context);
    final key = GlobalKey();
    return card(
      identity: 'group-${group.key}',
      main: StudioButtonPress(
        child: InkWell(
          onTap: busy ? null : () => _openGroup(group),
          onLongPress: busy
              ? null
              : () => _groupMenu(key.currentContext!, group),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            group.name,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                          ),
                          if (group.pinned)
                            Tooltip(
                              message: 'Pinned',
                              child: Icon(
                                Icons.push_pin_outlined,
                                size: 13,
                                color: t.muted,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Bot group · ${group.members.length}',
                        style: TextStyle(fontSize: 11, color: t.muted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        group.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: t.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Edit group ${group.name}',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: busy ? null : () => _editGroup(group),
                    icon: BotGroupIdentity(
                      group: group,
                      bots: widget.session.state.bots,
                      size: 48,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Expanded(
              child: status(
                group.blocked
                    ? 'Needs input'
                    : group.working
                    ? 'Running'
                    : 'Ready',
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.textScalerOf(context).scale(16) >= 24
                    ? 100
                    : 110,
              ),
              child: Text(
                group.instance,
                style: TextStyle(fontSize: 11, color: t.muted),
              ),
            ),
            StudioButtonPress(
              child: IconButton(
                key: key,
                tooltip: 'Actions for ${group.name}',
                onPressed: busy
                    ? null
                    : () => _groupMenu(key.currentContext!, group),
                icon: const Icon(Icons.more_horiz),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
