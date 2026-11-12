import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../models/bots.dart';
import '../../models/profile_colors.dart';
import '../../services/bots_session.dart';
import '../../services/bot_group_draft_session.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/bot_avatar.dart';
import '../../widgets/bot_group_picture.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/studio_select.dart';
import '../../widgets/wing_app_bar.dart';

Future<BotGroup?> openGroupEditor(
  BuildContext context,
  BotsSession session,
  BotGroup group, {
  required Future<void> Function(BuildContext, BotRecord) onOpenMemberChat,
}) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => BotsCreateScreen(
        session: session,
        group: true,
        editGroup: group,
        onOpenMemberChat: onOpenMemberChat,
      ),
    ),
  );
  if (!context.mounted || saved != true) return null;
  return session.state.groups
      .where((room) => room.key == group.key)
      .firstOrNull;
}

/// Local input only. The roster owner admits, targets and settles saving.
class BotsCreateScreen extends StatefulWidget {
  const BotsCreateScreen({
    super.key,
    required this.session,
    required this.group,
    this.clone,
    this.createGroupDraft,
    this.editGroup,
    this.onOpenMemberChat,
  }) : assert(editGroup == null || onOpenMemberChat != null);
  final BotsSession session;
  final bool group;
  final BotRecord? clone;
  final BotGroupDraftSession Function()? createGroupDraft;
  final BotGroup? editGroup;
  final Future<void> Function(BuildContext, BotRecord)? onOpenMemberChat;
  @override
  State<BotsCreateScreen> createState() => _BotsCreateScreenState();
}

class _BotsCreateScreenState extends State<BotsCreateScreen> {
  final _name = TextEditingController();
  late final _opening = widget.session.state;
  late final _group = widget.group
      ? widget.createGroupDraft?.call() ??
            BotGroupDraftSession(widget.session, existing: widget.editGroup)
      : null;
  final _search = TextEditingController();
  late String? _identity =
      widget.clone?.scope.connectionIdentity ??
      _opening.instances.firstOrNull?.identity;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (_group != null) _name.text = _group.name;
    _group?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _group?.dispose();
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  bool _canUse() => mounted && ModalRoute.of(context)?.isCurrent == true;

  Future<void> _saveGroup() async {
    final saved = await _group!.save(canUse: _canUse);
    if (mounted && saved) Navigator.pop(context, true);
  }

  Future<void> _generatePicture() async {
    final draft = _group!;
    final generate = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => StudioDialog(
          title: Text(
            'Room picture',
            style: Theme.of(context).dialogTheme.titleTextStyle,
          ),
          content: SizedBox(
            width: 392,
            child: viewportSelection(
              TextFormField(
                initialValue: draft.picturePrompt,
                onChanged: (value) =>
                    updateDialog(() => draft.setPicturePrompt(value)),
                style: Theme.of(context).textTheme.bodyMedium,
                minLines: 4,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context),
              cancelLabel: 'Cancel picture generation',
              onConfirm: draft.picturePrompt.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              confirmLabel: 'Generate picture',
              confirmIcon: Icons.auto_awesome_outlined,
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (generate == true) {
      await draft.generatePicture(draft.picturePrompt, canUse: _canUse);
    } else {
      await draft.rememberPicturePrompt();
    }
  }

  Future<void> _chooseColor() async {
    final draft = _group!;
    final choice = await showModalBottomSheet<ProfileColorChoice>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => BotAvatarScope(
        session: widget.session,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Icon color', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final color in ProfileColorChoice.values.where(
                    (color) => color.slot != null,
                  ))
                    Semantics(
                      selected: draft.iconColor == color,
                      child: StudioButtonPress(
                        child: IconButton.filledTonal(
                          key: ValueKey('group-color-${color.name}'),
                          tooltip:
                              '${color.name[0].toUpperCase()}${color.name.substring(1)}',
                          isSelected: draft.iconColor == color,
                          onPressed: () => Navigator.pop(context, color),
                          icon: BotGroupPicture(
                            avatars: draft.iconMembers,
                            color: color,
                            size: 32,
                          ),
                          selectedIcon: Stack(
                            children: [
                              BotGroupPicture(
                                avatars: draft.iconMembers,
                                color: color,
                                size: 32,
                              ),
                              const Positioned(
                                right: 0,
                                bottom: 0,
                                child: Icon(Icons.check_circle, size: 16),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && choice != null) draft.chooseColor(choice);
  }

  Widget _buildGroup(BuildContext context) {
    final draft = _group!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final editable = draft.editable;
    final hint = draft.frozen && !draft.saving
        ? 'Retry with the same room details'
        : draft.memberCount < 2
        ? 'Choose 2–6 bots'
        : '${draft.memberCount} bots · ${draft.instance}';
    final name = viewportSelection(
      TextField(
        key: const ValueKey('group-name'),
        controller: _name,
        enabled: editable,
        maxLength: 64,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        decoration: InputDecoration(
          labelText: draft.editing ? 'Group name' : 'Group name (optional)',
          hintText: draft.suggestedName.isEmpty
              ? 'e.g. Launch team'
              : draft.suggestedName,
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (value) {
          draft.setName(value);
          if (_name.text != draft.name) {
            _name.value = TextEditingValue(
              text: draft.name,
              selection: TextSelection.collapsed(offset: draft.name.length),
            );
          }
        },
      ),
    );
    final picture = Stack(
      alignment: Alignment.center,
      children: [
        BotGroupPicture(
          avatars: draft.iconMembers,
          color: draft.iconColor,
          image: draft.picture,
          size: 64,
        ),
        if (draft.pictureBusy)
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: 'Preparing room picture',
            ),
          ),
      ],
    );
    final pictureActions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Choose icon color',
            onPressed: editable ? _chooseColor : null,
            icon: const Icon(Icons.palette_outlined),
          ),
        ),
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Upload room picture',
            onPressed: editable && !draft.pictureBusy
                ? () => draft.pickPicture(canUse: _canUse)
                : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
        ),
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Generate room picture',
            onPressed: draft.canGenerate ? _generatePicture : null,
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
        ),
        if (draft.picture != null)
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Remove room picture',
              onPressed: editable && !draft.pictureBusy
                  ? draft.removePicture
                  : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ),
      ],
    );
    return Scaffold(
      appBar: WingAppBar(
        context: context,
        title: Text(draft.editing ? 'Edit group' : 'New group'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(WingSpacing.lg),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (draft.error != null) ...[
                  StudioError(draft.error!),
                  const SizedBox(height: WingSpacing.lg),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final stacked =
                        constraints.maxWidth < 340 ||
                        MediaQuery.textScalerOf(context).scale(16) > 20;
                    if (stacked) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              picture,
                              const SizedBox(width: 12),
                              pictureActions,
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            draft.editing
                                ? 'Changes are saved to Hermes'
                                : 'Saved to Hermes when you create the group',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          name,
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Row(
                          children: [
                            picture,
                            const SizedBox(width: 16),
                            Expanded(child: name),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            pictureActions,
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                draft.editing
                                    ? 'Changes are saved to Hermes'
                                    : 'Saved to Hermes when you create the group',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: WingSpacing.md),
                if (!draft.editing && draft.hosts.length > 1)
                  StudioSelect<String>(
                    value: draft.identity,
                    label: 'Hermes instance',
                    options: [
                      for (final host in draft.hosts)
                        (value: host.identity, label: host.label),
                    ],
                    onChanged: editable
                        ? (value) {
                            draft.chooseInstance(value);
                            _search.clear();
                          }
                        : null,
                  )
                else if (draft.instance.isNotEmpty)
                  Text(
                    'On ${draft.instance}',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: WingSpacing.lg),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text('Members', style: theme.textTheme.titleSmall),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        draft.editing
                            ? '${draft.memberCount} bots'
                            : '${draft.selected.length} of 6 selected',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: WingSpacing.md),
                if (draft.editing) ...[
                  const Text('Members are fixed when the group is created.'),
                  const SizedBox(height: 8),
                  for (final member in draft.existing!.members)
                    _ExistingGroupMember(
                      member: member,
                      bot: draft.appearance(member),
                      onOpenChat:
                          !draft.saving && widget.onOpenMemberChat != null
                          ? (bot) => widget.onOpenMemberChat!(context, bot)
                          : null,
                    ),
                ] else if (draft.identity == null)
                  const Text(
                    'Group chats are unavailable. Return to Bots and check that your Hermes instance is ready.',
                  )
                else if (draft.bots.length < 2)
                  const Text(
                    'This instance needs at least 2 bots. Return to Bots to create them, or choose another instance.',
                  ),
                if (!draft.editing && draft.bots.isNotEmpty) ...[
                  if (draft.selected.isNotEmpty) ...[
                    _PickedGroupMembers(
                      members: draft.selected,
                      onRemove: editable
                          ? (bot) => draft.select(bot, false)
                          : null,
                    ),
                    const SizedBox(height: WingSpacing.md),
                  ],
                  viewportSelection(
                    TextField(
                      key: ValueKey('group-member-search-${draft.identity}'),
                      controller: _search,
                      enabled: editable,
                      decoration: InputDecoration(
                        hintText: 'Search bots',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: draft.query.isEmpty
                            ? null
                            : StudioButtonPress(
                                child: IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: editable
                                      ? () {
                                          _search.clear();
                                          draft.search('');
                                        }
                                      : null,
                                  icon: const Icon(Icons.close),
                                ),
                              ),
                      ),
                      onChanged: draft.search,
                    ),
                  ),
                  const SizedBox(height: WingSpacing.sm),
                  if (draft.matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        draft.query.trim().isEmpty &&
                                draft.selected.length == draft.bots.length
                            ? 'All bots have been picked.'
                            : 'No bots match your search.',
                      ),
                    )
                  else
                    for (final bot in draft.matches)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: StudioButtonPress(
                          child: ListTile(
                            key: ValueKey('group-member-${bot.id}'),
                            enabled: draft.canSelect(bot),
                            onTap: draft.canSelect(bot)
                                ? () => draft.select(bot, true)
                                : null,
                            minTileHeight: 48,
                            minVerticalPadding: 8,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Row(
                              children: [
                                ExcludeSemantics(
                                  child: BorrowedBotAvatar(
                                    bot: bot,
                                    name: bot.title,
                                    size: 32,
                                  ),
                                ),
                                const SizedBox(width: WingSpacing.md),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        bot.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '@bot_${bot.profile.name}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    BotGroupPicture(
                      avatars: draft.iconMembers,
                      color: draft.iconColor,
                      image: draft.picture,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              draft.effectiveName.isEmpty
                                  ? 'Your new group'
                                  : draft.effectiveName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              hint,
                              maxLines:
                                  draft.memberCount >= 2 &&
                                      (!draft.frozen || draft.saving)
                                  ? 1
                                  : null,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StudioFormActions(
                      confirmKey: ValueKey(
                        draft.editing ? 'group-save' : 'group-create',
                      ),
                      onCancel: draft.saving
                          ? null
                          : () => Navigator.maybePop(context),
                      onConfirm: draft.canSave ? _saveGroup : null,
                      confirmLabel: draft.editing
                          ? 'Save changes'
                          : 'Create group',
                      busy: draft.saving,
                      progressLabel: draft.editing
                          ? 'Saving group'
                          : 'Creating group',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_identity == null || _busy) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a profile name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final saved = await widget.session.createBot(
      _identity!,
      _name.text.trim(),
      clone: widget.clone,
      canUse: _canUse,
    );
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error =
          widget.session.state.errors.firstOrNull ??
          'Creation could not be confirmed.';
    });
  }

  @override
  Widget build(BuildContext context) => BotAvatarScope(
    session: widget.session,
    child: _buildWithAvatars(context),
  );

  Widget _buildWithAvatars(BuildContext context) => widget.group
      ? _buildGroup(context)
      : PopScope(
          canPop: !_busy,
          child: Scaffold(
            appBar: WingAppBar(
              context: context,
              title: Text(widget.clone == null ? 'New bot' : 'Duplicate bot'),
            ),
            bottomNavigationBar: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  16 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: StudioFormActions(
                  onCancel: _busy ? null : () => Navigator.maybePop(context),
                  onConfirm: _busy || _identity == null ? null : _save,
                  confirmLabel: 'Create bot',
                  busy: _busy,
                  progressLabel: 'Creating bot',
                ),
              ),
            ),
            body: StudioLoadingRegion(
              available: !_busy,
              busy: _busy,
              label: 'Creating bot',
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: StudioError(_error!),
                    ),
                  if (_identity == null)
                    const Text(
                      'No instance is ready to create bots. Return to Bots and check your Hermes connection.',
                    ),
                  if (widget.clone == null && _identity != null)
                    StudioSelect<String>(
                      value: _identity,
                      label: 'Hermes instance',
                      options: [
                        for (final instance in _opening.instances)
                          (value: instance.identity, label: instance.label),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) => setState(() {
                              _identity = value;
                            }),
                    ),
                  if (widget.clone != null)
                    Text(
                      'Copy ${widget.clone!.title} on ${widget.clone!.instance}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 16),
                  viewportSelection(
                    TextField(
                      controller: _name,
                      enabled: !_busy,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Profile name',
                        helperText:
                            'Lowercase letters, numbers, hyphens and underscores',
                        helperMaxLines: 4,
                      ),
                      textCapitalization: TextCapitalization.none,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.clone == null
                        ? 'The new profile inherits this instance’s launch credentials and model defaults. You can change its name, avatar and settings after creation.'
                        : 'Copies profile settings, credentials and skills. Channel bindings are excluded, so the copy will not take over existing messaging channels.',
                  ),
                ],
              ),
            ),
          ),
        );
}

/// Picked membership has one home; the roster below is only an add action.
class _PickedGroupMembers extends StatelessWidget {
  const _PickedGroupMembers({required this.members, required this.onRemove});
  final List<BotRecord> members;
  final ValueChanged<BotRecord>? onRemove;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final bot in members)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                key: ValueKey('group-picked-${bot.id}'),
                container: true,
                selected: true,
                child: Material(
                  color: colors.primaryContainer,
                  borderRadius: WingRadius.control,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 8),
                      ExcludeSemantics(
                        child: BorrowedBotAvatar(
                          bot: bot,
                          name: bot.title,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          bot.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                      ),
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: 'Remove ${bot.title}',
                          onPressed: onRemove == null
                              ? null
                              : () => onRemove!(bot),
                          icon: const Icon(Icons.close, size: 18),
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExistingGroupMember extends StatelessWidget {
  const _ExistingGroupMember({
    required this.member,
    required this.bot,
    required this.onOpenChat,
  });
  final BotGroupMember member;
  final BotRecord? bot;
  final ValueChanged<BotRecord>? onOpenChat;
  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: ListTile(
      onTap: bot != null && onOpenChat != null ? () => onOpenChat!(bot!) : null,
      contentPadding: EdgeInsets.zero,
      leading: bot == null
          ? const SizedBox.square(
              dimension: 32,
              child: Icon(Icons.smart_toy_outlined),
            )
          : BorrowedBotAvatar(bot: bot!, name: member.name, size: 32),
      title: Text(member.name),
      subtitle: Text(
        '@${member.handle}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}
