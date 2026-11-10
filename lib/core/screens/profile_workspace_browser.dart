import '../widgets/selection_viewport.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/wing_app_bar.dart';
import '../models/profile_session_key.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_list_view.dart';
import '../models/chat_browser_preferences.dart';
import '../models/session_visibility.dart';
import '../services/chat_browser_data.dart';
import '../models/browser_actions.dart';
import '../models/connection.dart';
import '../services/server_connection_status.dart';
import '../services/profile_colors_session.dart';
import '../theme/wing_theme.dart';
import '../theme/wing_icons.dart';
import '../widgets/chat_list_menu.dart';
import '../widgets/read_recovery.dart';
import '../widgets/chat_profile_bar.dart';
import '../widgets/chat_status_dot.dart';
import '../widgets/chat_working_border.dart';
import '../widgets/bot_avatar.dart';
import '../widgets/profile_selector.dart';
import '../widgets/server_connection_label.dart';
import '../widgets/studio_error.dart';
import '../widgets/workspace_connection_status.dart';
import '../widgets/workspace_options_menu.dart';
import 'profile_row_actions.dart';
import 'profile_project_actions.dart';

/// Readonly facts from the mounted browser's existing owner.
abstract interface class BrowserWorkspaceObservation {
  BrowserWorkspaceState get workspace;
}

class ProfileWorkspaceBrowser extends StatefulWidget {
  const ProfileWorkspaceBrowser({
    super.key,
    required this.createData,
    required this.connectionLabel,
    required this.connectionIcon,
    required this.connectionStatus,
    required this.createColors,
    required this.deletionRecovery,
    required this.newProject,
    required this.onOpenBotChat,
    this.drawer,
    this.searchFocusNode,
  });
  final ChatBrowserData Function() createData;
  final String connectionLabel;
  final ConnectionIcon connectionIcon;
  final ServerConnectionStatus connectionStatus;
  final ProfileColorsSession Function() createColors;
  final Widget deletionRecovery;
  final Future<void> Function(ChatBrowserData) newProject;
  final ValueChanged<String> onOpenBotChat;
  final Widget? drawer;
  final FocusNode? searchFocusNode;
  @override
  State<ProfileWorkspaceBrowser> createState() =>
      _ProfileWorkspaceBrowserState();
}

class _ProfileWorkspaceBrowserState extends State<ProfileWorkspaceBrowser>
    with WidgetsBindingObserver
    implements BrowserWorkspaceObservation {
  @override
  BrowserWorkspaceState get workspace => _data.workspace;
  late final ChatBrowserData _data;
  final _search = TextEditingController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _optionsKey = GlobalKey();
  BrowserPreferencesFact get _view => _data.viewPreferences;
  Set<String> get _statuses =>
      _view.display?.filter(BrowserFilter.status) ?? const {};
  Set<String> get _profiles => _view.display?.profiles ?? const {};
  Set<String> get _projects => _view.display?.projects ?? const {};
  final _collapsed = <String>{};
  final _visibleCounts = <String, int>{};
  Set<ChatDetail> get _show => _view.display?.show ?? const {};
  ChatGrouping? get _grouping => _view.display?.grouping;
  ChatOrdering? get _ordering => _view.display?.ordering;
  bool get _archivedOnly => _data.state.archived;
  bool get _pending => _data.busy;
  String _query = '';
  List<ChatListEntry> _allEntries = [], _visibleEntries = [];
  List<ChatListGroup> _currentGroups = [];

  List<ChatListEntry> get _matches => [
    for (final entry in _visibleEntries) _data.row(entry.sessionKey).value,
  ];
  List<ChatListGroup> get _groups => _currentGroups;
  Timer? _debounce;
  bool _showProjectFab = false;

  void _dismissProjectFab() {
    if (_showProjectFab) setState(() => _showProjectFab = false);
  }

  @override
  void initState() {
    super.initState();
    _data = widget.createData()..addListener(_dataChanged);
    final binding = WidgetsBinding.instance;
    _data.setReadActive(
      binding.lifecycleState == null ||
          binding.lifecycleState == AppLifecycleState.resumed,
    );
    binding.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _data.start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _data.setReadActive(state == AppLifecycleState.resumed);
    if (state != AppLifecycleState.resumed) _dismissProjectFab();
  }

  void _dataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _search.dispose();

    _data.dispose();
    super.dispose();
  }

  void _chooseView(BrowserPreferenceIntent intent) {
    unawaited(_data.chooseView(intent));
  }

  void _notice(String message) => showStudioError(context, message);
  Future<void> _run(Future<void> Function() action) async {
    await _data.run(action);
    if (mounted) {
      if (_data.notice case final notice?) _notice(notice);
    }
  }

  Future<void> _refresh() => _data.refresh(archivedOnly: _archivedOnly);

  void _setQuery(String value) {
    _debounce?.cancel();
    setState(() => _query = value.trim().toLowerCase());
    unawaited(_data.search(''));
    if (_query.isNotEmpty) {
      _debounce = Timer(
        const Duration(milliseconds: 350),
        () => _data.search(_query),
      );
    }
  }

  String _groupKey(ChatListGroup group) =>
      '${_grouping?.name ?? 'neutral'}/${group.key}';

  int _visibleCount(ChatListGroup group) => group.key == 'pinned'
      ? group.entries.length
      : _visibleCounts[_groupKey(group)] ?? 3;
  static IconData _groupIcon(ChatGrouping value) => switch (value) {
    ChatGrouping.project => Icons.folder_outlined,
    ChatGrouping.updated => Icons.schedule,
    ChatGrouping.status => Icons.monitor_heart_outlined,
    ChatGrouping.profile => Icons.person_outline,
  };
  Future<void> _filter(BuildContext anchor, String kind) {
    final filter = switch (kind) {
      'Status' => BrowserFilter.status,
      'Profile' => BrowserFilter.profile,
      _ => BrowserFilter.project,
    };
    return showChatListMenu(
      anchor,
      choicesChanges: _data,
      title: kind,
      searchHint: kind == 'Status' ? null : 'Search ${kind.toLowerCase()}s',
      choices: () => [
        for (final choice in _data.filterChoices(filter))
          ChatMenuChoice(
            choice.id,
            choice.label,
            switch (choice.decoration) {
              BrowserChoiceDecoration.status => ChatStatusDot(choice.status!),
              BrowserChoiceDecoration.profile => const Icon(
                Icons.person_outline,
              ),
              BrowserChoiceDecoration.project => projectAvatar(
                context,
                choice.project!,
                size: 20,
              ),
              BrowserChoiceDecoration.home => const Icon(
                Icons.category_outlined,
              ),
            },
            fontStyle: choice.decoration == BrowserChoiceDecoration.home
                ? FontStyle.italic
                : FontStyle.normal,
            selected: choice.selected,
          ),
      ],
      multiple: true,
      onSelected: (id) => _chooseView(
        _data
            .filterChoices(filter)
            .singleWhere((choice) => choice.id == id)
            .intent,
      ),
      onClear: () => _chooseView(BrowserPreferenceIntent.clear(filter)),
    );
  }

  Widget _filterControl(String label, Set<String> selected) => Builder(
    builder: (anchor) => Semantics(
      button: true,
      label:
          '$label filter, ${selected.isEmpty ? 'all' : '${selected.length} selected'}',
      child: StudioButtonPress(
        child: InkWell(
          key: ValueKey('chat-filter-${label.toLowerCase()}'),
          onTap: _view.canChoose ? () => _filter(anchor, label) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected.isEmpty
                      ? Colors.transparent
                      : Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: WingRadius.control,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            selected.isEmpty
                                ? label
                                : '$label ${selected.length}',
                            style: const TextStyle(fontSize: 11),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (MediaQuery.textScalerOf(context).scale(12) < 18)
                          const Icon(Icons.expand_more, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _filterControls() => LayoutBuilder(
    builder: (context, constraints) {
      final controls = [
        _filterControl('Status', _statuses),
        _filterControl('Profile', _profiles),
        _filterControl('Project', _projects),
      ];
      // Three 80 dp slots keep labels, chevrons and accent padding readable.
      if (constraints.maxWidth < 240 ||
          MediaQuery.textScalerOf(context).scale(16) > 20) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: controls,
        );
      }
      return Row(
        children: [for (final control in controls) Expanded(child: control)],
      );
    },
  );

  Widget _filters() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 4,
            bottom: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: WingTokens.of(context).border),
                borderRadius: WingRadius.control,
              ),
            ),
          ),
          Row(
            children: [
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.filter_alt_outlined, size: 19),
              ),
              Expanded(child: _filterControls()),
              SizedBox(
                width: 48,
                height: 48,
                child: StudioButtonPress(
                  child: IconButton(
                    key: const ValueKey('workspace-clear-filters'),
                    padding: EdgeInsets.zero,
                    tooltip: 'Clear all filters',
                    color: WingTokens.of(context).onSurface,
                    icon: const SizedBox.square(
                      dimension: 22,
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Icon(Icons.filter_alt_outlined, size: 19),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 1,
                            child: Icon(Icons.close, size: 9),
                          ),
                        ],
                      ),
                    ),
                    onPressed:
                        _statuses.isEmpty &&
                            _profiles.isEmpty &&
                            _projects.isEmpty
                        ? null
                        : () => _chooseView(
                            const BrowserPreferenceIntent.clearFilters(),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  void _menuAction(String id) {
    switch (id) {
      case 'group-by':
      case 'sort-by':
      case 'show-details':
        if (!_view.canChoose) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            showChatListMenu(
              _optionsKey.currentContext!,
              choicesChanges: _data,
              title: switch (id) {
                'group-by' => 'Group by',
                'sort-by' => 'Sort by',
                _ => 'Show details',
              },
              multiple: id == 'show-details',
              choices: () => switch (id) {
                'group-by' => [
                  for (final value in ChatGrouping.values)
                    ChatMenuChoice(
                      value.name,
                      value.label,
                      Icon(_groupIcon(value)),
                      selected: _grouping == value,
                    ),
                ],
                'sort-by' => [
                  for (final value in ChatOrdering.values)
                    ChatMenuChoice(
                      value.name,
                      value.label,
                      Icon(switch (value) {
                        ChatOrdering.updated => Icons.schedule,
                        ChatOrdering.created => Icons.calendar_today_outlined,
                        ChatOrdering.status => Icons.monitor_heart_outlined,
                        ChatOrdering.tokens => Icons.tag,
                        ChatOrdering.cost => Icons.attach_money,
                      }),
                      selected: _ordering == value,
                    ),
                ],
                _ => [
                  for (final value in ChatDetail.values)
                    ChatMenuChoice(
                      value.name,
                      value == ChatDetail.updated
                          ? 'Updated time'
                          : value.label,
                      Icon(switch (value) {
                        ChatDetail.updated => Icons.schedule,
                        ChatDetail.tokens => Icons.tag,
                        ChatDetail.cost => Icons.attach_money,
                        ChatDetail.profile => Icons.person_outline,
                      }),
                      selected: _show.contains(value),
                    ),
                ],
              },
              onSelected: (choice) {
                switch (id) {
                  case 'group-by':
                    _chooseView(_data.groupingIntent(choice));
                    setState(() {
                      _collapsed.clear();
                      _visibleCounts.clear();
                    });
                  case 'sort-by':
                    _chooseView(_data.orderingIntent(choice));
                  case 'show-details':
                    _chooseView(_data.detailIntent(choice));
                }
              },
            ),
          );
        });
      case 'include-automated':
        unawaited(_run(_data.toggleVisibility));
      case 'collapse':
        setState(() {
          final keys = _groups.map(_groupKey).toSet();
          if (keys.every(_collapsed.contains)) {
            _collapsed.clear();
          } else {
            _collapsed.addAll(keys);
          }
        });
      case 'mark-read':
        unawaited(_run(() => _data.markVisibleRead(_query)));
      case 'archived':
        setState(() {
          _collapsed.clear();
          _visibleCounts.clear();
        });
        unawaited(_data.refresh(archivedOnly: !_archivedOnly));
      case 'new-project':
        _dismissProjectFab();
        unawaited(
          _run(() async {
            final name = await _chooseOwner();
            if (name != null && await _data.chooseCreationProfile(name)) {
              await widget.newProject(_data);
            }
          }),
        );
    }
  }

  Future<String?> _chooseOwner() async {
    final profiles = _data.creationProfiles;
    String? name = _data.suggestedCreationProfile;
    if (name != null) {
      return name;
    } else {
      await showChatListMenu(
        _optionsKey.currentContext!,
        choicesChanges: _data,
        title: 'Choose profile',
        choices: () => [
          for (final p in profiles)
            ChatMenuChoice(p.name, p.label, const Icon(Icons.person_outline)),
        ],
        onSelected: (id) => name = id,
      );
    }
    return mounted ? name : null;
  }

  String _age(ChatListEntry entry) {
    final time = entry.updatedAt;
    if (time <= 0) return '';
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch((time * 1000).round()),
    );
    return age.inMinutes < 1
        ? 'now'
        : age.inHours < 1
        ? '${age.inMinutes}m'
        : age.inDays < 1
        ? '${age.inHours}h'
        : age.inDays < 7
        ? '${age.inDays}d'
        : '${age.inDays ~/ 7}w';
  }

  Future<void> _chatActions(BuildContext anchor, ChatListEntry entry) async {
    final actions = await _data.actionsFor(entry);
    if (actions == null) return;
    try {
      if (anchor.mounted) await showChatActions(anchor, actions);
    } finally {
      actions.dispose();
    }
  }

  Future<void> _openChat(ChatListEntry entry) async {
    await _data.open(entry);
    if (mounted) {
      if (_data.notice case final notice?) _notice(notice);
    }
  }

  Widget _session(ChatListEntry entry) => ValueListenableBuilder<ChatListEntry>(
    key: ValueKey(('chat-row', entry.sessionKey)),
    valueListenable: _data.row(entry.sessionKey),
    builder: (context, entry, _) => _sessionContent(context, entry),
  );

  Widget _sessionContent(BuildContext context, ChatListEntry e) {
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 20;
    final showTokens = _show.contains(ChatDetail.tokens);
    final showUpdated = _show.contains(ChatDetail.updated);
    final age = _age(e);
    final hasMetrics = showTokens || showUpdated;
    final metricsStyle = TextStyle(
      fontSize: 12,
      color: WingTokens.of(context).muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final metrics = [
      if (showTokens)
        Text(
          '${compactTokens(e.tokens)}${largeText ? ' tokens' : ''}',
          semanticsLabel: '${e.tokens} tokens',
          style: metricsStyle,
          textAlign: TextAlign.right,
        ),
      if (showUpdated)
        Text(
          age,
          semanticsLabel: age.isEmpty
              ? 'Updated time unknown'
              : age == 'now'
              ? 'Updated now'
              : 'Updated $age ago',
          style: metricsStyle,
          textAlign: TextAlign.right,
        ),
    ];
    final titleText = Text(
      e.title.trim().isNotEmpty ? e.title : 'Untitled chat',
      maxLines: largeText ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        fontWeight: e.unread ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final bot = _data.botAppearance(e.sessionKey);
    final title = e.isBotChat
        ? Row(
            children: [
              if (bot != null)
                Semantics(
                  label: '${bot.title} bot avatar',
                  image: true,
                  child: BorrowedBotAvatar(
                    key: ValueKey('bot-chat-avatar-${e.profile}-${e.id}'),
                    bot: bot,
                    name: bot.profile.name,
                    size: 20,
                  ),
                )
              else
                const SizedBox.square(dimension: 20),
              const SizedBox(width: 6),
              Expanded(child: titleText),
            ],
          )
        : titleText;
    final detail = [
      if (e.archived) 'Archived',
      if (e.snippet != null) e.snippet!,
      if (_show.contains(ChatDetail.cost)) '\$${e.cost.toStringAsFixed(2)}',
      if (_show.contains(ChatDetail.profile)) e.profile,
      if (e.runtimeLabel != null) e.runtimeLabel!,
    ];
    return Builder(
      builder: (anchor) => Padding(
        padding: const EdgeInsets.only(left: 28, right: 8),
        child: ChatWorkingBorder(
          working: e.status == ChatListStatus.working,
          child: StudioButtonPress(
            child: ListTile(
              key: ValueKey('chat-${e.profile}-${e.id}'),
              contentPadding: EdgeInsets.zero,
              minTileHeight: 48,
              minVerticalPadding: largeText ? 6 : 0,
              horizontalTitleGap: 6,
              minLeadingWidth: 18,
              leading: ChatStatusDot(e.status),
              title: largeText || !hasMetrics
                  ? title
                  : Row(
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 8),
                        if (showTokens)
                          SizedBox(width: 56, child: metrics.first),
                        if (showTokens && showUpdated) const SizedBox(width: 8),
                        if (showUpdated)
                          SizedBox(width: 28, child: metrics.last),
                      ],
                    ),
              subtitle: detail.isEmpty && !(largeText && hasMetrics)
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (largeText && hasMetrics)
                          Wrap(spacing: 12, children: metrics),
                        if (detail.isNotEmpty)
                          Text(
                            detail.join(' · '),
                            style: TextStyle(
                              fontSize: 11,
                              color: WingTokens.of(context).muted,
                            ),
                          ),
                      ],
                    ),
              trailing: Builder(
                builder: (button) => StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Chat actions',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onPressed: _pending || workspace.switching
                        ? null
                        : () => _run(() => _chatActions(button, e)),
                  ),
                ),
              ),
              onLongPress: _pending || workspace.switching
                  ? null
                  : () => _run(() => _chatActions(anchor, e)),
              onTap: _pending ? null : () => _openChat(e),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _projectActions(BuildContext anchor, ChatListGroup group) async {
    final actions = await _data.projectActionsFor(group.scope!, group.project!);
    if (actions == null) return;
    try {
      if (anchor.mounted) await showProjectActions(anchor, actions);
    } finally {
      actions.dispose();
    }
  }

  Widget _liveGroupHeading(ChatListGroup group) =>
      !_show.contains(ChatDetail.tokens)
      ? _groupHeading(group)
      : ListenableBuilder(
          listenable: Listenable.merge(
            group.entries.map((entry) => _data.row(entry.sessionKey)).toList(),
          ),
          builder: (_, _) => _groupHeading(
            ChatListGroup(
              group.key,
              group.label,
              [
                for (final entry in group.entries)
                  _data.row(entry.sessionKey).value,
              ],
              project: group.project,
              scope: group.scope,
            ),
          ),
        );

  Widget _groupHeading(ChatListGroup group) {
    final key = _groupKey(group);
    final isUnassigned =
        _grouping == ChatGrouping.project &&
        group.project == null &&
        group.key != 'pinned';
    final collapsed = _collapsed.contains(key);
    final tokensReady =
        (group.scope == null ||
            _data.hasCompleteSnapshot(group.scope!.profileName)) &&
        group.entries.every((e) => _data.hasCompleteSnapshot(e.profile));
    return Builder(
      builder: (headingContext) => Padding(
        key: group.project == null
            ? null
            : ValueKey(
                'project-${group.scope!.profileName}-${group.project!.id}',
              ),
        padding: const EdgeInsets.only(top: 2, left: 12, right: 8),
        child: Row(
          children: [
            Expanded(
              child: StudioButtonPress(
                child: InkWell(
                  key: ValueKey('chat-group-$key'),
                  onLongPress: group.project == null || _pending
                      ? null
                      : () =>
                            _run(() => _projectActions(headingContext, group)),
                  onTap: () => setState(() {
                    if (!_collapsed.remove(key)) _collapsed.add(key);
                  }),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 0, 0),
                      child: Row(
                        children: [
                          if (group.project != null)
                            projectAvatar(context, group.project!, size: 20)
                          else
                            Icon(
                              group.key == 'pinned'
                                  ? Icons.push_pin_outlined
                                  : _grouping == ChatGrouping.project
                                  ? Icons.category_outlined
                                  : _grouping == null
                                  ? Icons.chat_bubble_outline
                                  : _groupIcon(_grouping!),
                              size: 18,
                              color: WingTokens.of(context).muted,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              group.project != null &&
                                      _groups
                                              .where(
                                                (g) => g.label == group.label,
                                              )
                                              .length >
                                          1
                                  ? '${group.label} · ${group.scope!.profileName}'
                                  : group.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                fontStyle: isUnassigned
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ),
                          if (_show.contains(ChatDetail.tokens))
                            Tooltip(
                              message: tokensReady
                                  ? '${group.tokens} tokens across ${group.entries.length} matching chats'
                                  : 'Loading the complete group total',
                              child: Text(
                                tokensReady ? compactTokens(group.tokens) : '…',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: WingTokens.of(context).muted,
                                ),
                              ),
                            ),
                          const SizedBox(width: 4),
                          Icon(
                            collapsed ? Icons.chevron_right : Icons.expand_more,
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (group.project != null)
              Builder(
                builder: (anchor) => StudioButtonPress(
                  child: IconButton(
                    padding: const EdgeInsets.only(top: 12),
                    tooltip: 'Project actions',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onPressed: _pending
                        ? null
                        : () => _run(() => _projectActions(anchor, group)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tree() {
    final groups = _groups;
    final entries = _allEntries;
    return [
      if (_data.state.searchLimited)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Message search returns up to 100 matches per profile. Narrow your search for more specific results.',
          ),
        ),
      ..._draftRows(entries),
      for (final group in groups) ...[
        _liveGroupHeading(group),
        if (!_collapsed.contains(_groupKey(group))) ...[
          for (final entry in group.entries.take(_visibleCount(group)))
            _session(entry),
          if (group.entries.length > _visibleCount(group))
            Padding(
              padding: const EdgeInsets.only(left: 46, right: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: StudioButtonPress(
                  child: TextButton(
                    key: ValueKey('chat-show-more-${_groupKey(group)}'),
                    onPressed: () => setState(() {
                      _visibleCounts[_groupKey(group)] =
                          _visibleCount(group) + 10;
                    }),
                    child: const Text(
                      'Show more',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
      if (workspace.scope == null && !workspace.repairRequired)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Opening your chats'),
        ),
      if (workspace.scope != null && groups.isEmpty && !_data.state.loading)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _query.isNotEmpty ||
                        _statuses.isNotEmpty ||
                        _profiles.isNotEmpty ||
                        _projects.isNotEmpty
                    ? 'No matching chats'
                    : _archivedOnly
                    ? 'No archived chats'
                    : 'No chats here yet',
              ),
              if (_projects.isNotEmpty ||
                  _profiles.isNotEmpty ||
                  _statuses.isNotEmpty)
                StudioButtonPress(
                  child: TextButton(
                    onPressed: () => _chooseView(
                      const BrowserPreferenceIntent.clearFilters(),
                    ),
                    child: const Text('Clear filters'),
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  String? get _loadingLabel {
    final submitting = workspace.mutating;
    final label = submitting
        ? 'Updating chats…'
        : _data.state.searching
        ? 'Searching chats…'
        : _data.state.loading
        ? 'Refreshing chats…'
        : null;
    return label;
  }

  Widget _readFailure(String message, VoidCallback retry) {
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 20;
    final explanation = DefaultTextStyle(
      style: Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 12),
      child: StudioError(message),
    );
    final action = StudioButtonPress(
      child: TextButton(onPressed: retry, child: const Text('Retry')),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: largeText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                explanation,
                Align(alignment: Alignment.centerRight, child: action),
              ],
            )
          : Row(
              children: [
                Expanded(child: explanation),
                const SizedBox(width: 12),
                action,
              ],
            ),
    );
  }

  List<Widget> _draftRows(List<ChatListEntry> entries) {
    final rows = <Widget>[];
    for (final draft in _data.savedDrafts(_query, entries)) {
      rows.add(_savedDraft(draft));
    }
    return [
      if (rows.isNotEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Saved drafts',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ...rows,
    ];
  }

  Widget _savedDraft(BrowserDraft draft) {
    final preview = draft.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final attachmentLabel =
        '${draft.attachmentCount} staged attachment${draft.attachmentCount == 1 ? '' : 's'}';
    final queueLabel =
        '${draft.queuedCount} queued message${draft.queuedCount == 1 ? '' : 's'}';
    final title = preview.isNotEmpty
        ? preview
        : draft.attachmentCount > 0
        ? attachmentLabel
        : queueLabel;
    final details = [
      if (draft.submissionUncertain) 'Delivery uncertain',
      if (preview.isNotEmpty && draft.attachmentCount > 0) attachmentLabel,
      if (draft.queuedCount > 0 &&
          (preview.isNotEmpty || draft.attachmentCount > 0))
        queueLabel,
    ];
    return Builder(
      builder: (rowContext) {
        void actions([BuildContext? anchor]) => unawaited(
          _run(() async {
            final issued = await _data.draftActionsFor(draft);
            if (issued == null) return;
            try {
              if ((anchor ?? rowContext).mounted) {
                await showSavedDraftActions(
                  anchor ?? rowContext,
                  issued,
                  draft,
                  title,
                );
              }
            } finally {
              issued.dispose();
            }
          }),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Material(
            color: Colors.transparent,
            borderRadius: WingRadius.card,
            clipBehavior: Clip.antiAlias,
            child: GestureDetector(
              onSecondaryTap: workspace.switching ? null : actions,
              child: StudioButtonPress(
                child: ListTile(
                  key: ValueKey('saved-draft-${draft.key.sessionId}'),
                  contentPadding: const EdgeInsets.only(left: 16, right: 0),
                  leading: const ChatStatusDot(ChatListStatus.draft),
                  title: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  subtitle: Text(
                    details.isEmpty
                        ? 'Draft · Tap to continue'
                        : details.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Builder(
                    builder: (buttonContext) => StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Draft actions',
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          visualDensity: VisualDensity.standard,
                        ),
                        icon: const Icon(Icons.more_horiz, size: 20),
                        onPressed: workspace.switching
                            ? null
                            : () => actions(buttonContext),
                      ),
                    ),
                  ),
                  onLongPress: workspace.switching ? null : actions,
                  onTap: workspace.switching
                      ? null
                      : () => _run(() => _data.openDraft(draft)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => BotAvatarScope(
    session: _data.avatarOwner,
    child: _buildWithAvatars(context),
  );

  Widget _buildWithAvatars(BuildContext context) => ReadRecovery(
    shouldRetry: () => _data.needsRecovery,
    retry: _data.recover,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    _allEntries = _data.entries;
    final projection = _data.project(_query);
    _visibleEntries = projection.entries;
    _currentGroups = projection.groups;
    final tokens = WingTokens.of(context);
    final enabled =
        workspace.scope != null && !workspace.switching && !_pending;
    final groups = _groups;
    final notices = <Widget>[
      if (_view.error case final error?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StudioError(error),
              Wrap(
                children: [
                  if (_view.validity == BrowserPreferencesValidity.invalid)
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: _view.busy
                            ? null
                            : () => _chooseView(
                                const BrowserPreferenceIntent.reset(),
                              ),
                        child: const Text('Reset chat view'),
                      ),
                    ),
                  if (_view.validity == BrowserPreferencesValidity.unverified)
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: _view.busy
                            ? null
                            : _data.verifyViewPreferences,
                        child: const Text('Reload chat view'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      WorkspaceConnectionStatus(status: widget.connectionStatus),
      if (workspace.visibilityNotice case final notice?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(notice),
              Wrap(
                children: [
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: !workspace.canChooseVisibility
                          ? null
                          : () => _run(
                              () => _data.chooseVisibility(
                                SessionVisibility.chats,
                              ),
                            ),
                      child: const Text('Chats only'),
                    ),
                  ),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: !workspace.canChooseVisibility
                          ? null
                          : () => _run(
                              () =>
                                  _data.chooseVisibility(SessionVisibility.all),
                            ),
                      child: const Text('All sessions'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (workspace.visibilityError case final error?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: StudioError(error),
        ),
      widget.deletionRecovery,
      if (_data.readFailure case final failure?)
        _readFailure(failure, _refresh),
      if (_data.state.searchError != null)
        _readFailure(_data.state.searchError!, () => _data.search(_query)),
      if (workspace.repairRequired)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (workspace.error case final error?) StudioError(error),
              const SizedBox(height: 8),
              ProfileSelector(
                profiles: workspace.profiles,
                selectedProfile: workspace.scope?.profileName,
                createColors: widget.createColors,
                padding: EdgeInsets.zero,
                onSelected: workspace.repairBusy
                    ? null
                    : (name) => unawaited(
                        _run(() async {
                          await _data.selectProfile(name);
                        }),
                      ),
              ),
            ],
          ),
        )
      else if (workspace.error != null)
        ListTile(
          title: StudioError(workspace.error!),
          trailing: StudioButtonPress(
            child: TextButton(
              onPressed: () => _run(_data.retryConnection),
              child: const Text('Retry'),
            ),
          ),
        ),
    ];
    return PopScope(
      canPop: widget.drawer == null && !_archivedOnly && !_showProjectFab,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showProjectFab) {
          _dismissProjectFab();
        } else if (_archivedOnly) {
          unawaited(_data.refresh(archivedOnly: false));
        } else if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          unawaited(SystemNavigator.pop());
        } else {
          _scaffoldKey.currentState?.openDrawer();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: widget.drawer,
        backgroundColor: tokens.surface,
        appBar: WingAppBar(
          context: context,
          backgroundColor: tokens.surface,
          surfaceTintColor: Colors.transparent,

          centerTitle: false,
          leading: _archivedOnly
              ? StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Back to chats',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      unawaited(_data.refresh(archivedOnly: false));
                    },
                  ),
                )
              : null,
          title: Text(_archivedOnly ? 'Archived chats' : 'Chats'),
          contextRow: Row(
            children: [
              SizedBox(
                width: 104,
                child: ServerConnectionLabel(
                  label: widget.connectionLabel,
                  icon: widget.connectionIcon,
                  status: widget.connectionStatus,
                  style: TextStyle(fontSize: 12, color: tokens.muted),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ChatProfileBar(
                  profiles: workspace.profiles,
                  createColors: widget.createColors,
                  selectedProfiles: _profiles,
                  onOpenBotChat: widget.onOpenBotChat,
                  onSelected: (name) => _chooseView(
                    BrowserPreferenceIntent.exclusiveProfile(name),
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          actions: [
            ValueListenableBuilder<Set<ProfileSessionKey>>(
              valueListenable: _data.rowChanges,
              builder: (_, _, _) => WorkspaceOptionsMenu(
                key: _optionsKey,
                enabled: enabled,
                archived: _archivedOnly,
                includeAutomated: workspace.visibility == SessionVisibility.all,
                collapsed:
                    groups.isNotEmpty &&
                    groups.every((g) => _collapsed.contains(_groupKey(g))),
                hasUnread: _matches.any((e) => e.unread),
                onSelected: _menuAction,
              ),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: StudioLoadingRegion(
            busy: _loadingLabel != null,
            available: _data.state.available && !workspace.mutating,
            label: _loadingLabel ?? 'Loading chats',
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: viewportSelection(
                    TextField(
                      key: const ValueKey('workspace-search'),
                      controller: _search,
                      focusNode: widget.searchFocusNode,
                      onChanged: _setQuery,
                      decoration: const InputDecoration(
                        hintText: 'Search chats',
                        prefixIcon: Icon(Icons.search, size: 20),
                      ),
                    ),
                  ),
                ),
                _filters(),
                if (!workspace.repairRequired) ...notices,
                Expanded(
                  child: StudioRefresh(
                    available: _data.state.available,
                    label: 'Refreshing chats',
                    onRefresh: _refresh,
                    child: Builder(
                      builder: (context) {
                        final rows = _tree();
                        final padding = EdgeInsets.only(
                          bottom: 88 + MediaQuery.paddingOf(context).bottom,
                        );
                        if (workspace.repairRequired) {
                          return CustomScrollView(
                            key: ValueKey('chat-list-$_archivedOnly'),
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverToBoxAdapter(
                                child: Column(children: notices),
                              ),
                              SliverPadding(
                                padding: padding,
                                sliver: SliverList.builder(
                                  itemCount: rows.length,
                                  itemBuilder: (_, index) => rows[index],
                                ),
                              ),
                            ],
                          );
                        }
                        return ListView.builder(
                          key: ValueKey('chat-list-$_archivedOnly'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: padding,
                          itemCount: rows.length,
                          itemBuilder: (_, index) => rows[index],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: TapRegion(
          onTapOutside: (_) => _dismissProjectFab(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showProjectFab) ...[
                StudioButtonPress(
                  child: FloatingActionButton(
                    key: const ValueKey('workspace-new-project'),
                    heroTag: 'workspace-new-project',
                    tooltip: 'New project',
                    elevation: 2,
                    onPressed:
                        !enabled || workspace.offline || workspace.recovering
                        ? null
                        : () => _menuAction('new-project'),
                    child: const Icon(Icons.create_new_folder_outlined),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Tooltip(
                message: 'New chat',
                triggerMode: TooltipTriggerMode.manual,
                child: Semantics(
                  hint: 'Long press to show New project',
                  child: GestureDetector(
                    onLongPress:
                        !enabled || workspace.offline || workspace.recovering
                        ? null
                        : () {
                            unawaited(Feedback.forLongPress(context));
                            setState(() => _showProjectFab = !_showProjectFab);
                          },
                    child: StudioButtonPress(
                      child: FloatingActionButton(
                        key: const ValueKey('workspace-new-chat'),
                        heroTag: 'workspace-new-chat',
                        elevation: 2,
                        onPressed:
                            !enabled ||
                                workspace.offline ||
                                workspace.recovering
                            ? null
                            : () {
                                _dismissProjectFab();
                                unawaited(
                                  _run(() async {
                                    final name = await _chooseOwner();
                                    if (name != null) await _data.newChat(name);
                                  }),
                                );
                              },
                        child: const Icon(WingIcons.newChat),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
