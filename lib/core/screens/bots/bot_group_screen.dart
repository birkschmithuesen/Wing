import '../../widgets/conversation_composer.dart';
import '../../widgets/gateway_approval_panel.dart';
import '../../models/gateway_approval.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import '../profile_transcript.dart';
import '../../models/transcript_timeline.dart';
import '../../widgets/studio_loading.dart';
import '../../widgets/bot_group_conversation.dart';
import '../../widgets/recent_conversations/conversation_route_scope.dart';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import '../../services/android_share_intent_service.dart';
import '../../services/remote_file_saver.dart';
import '../../models/attachment_draft.dart';
import '../../presentation/attachment_preview_image.dart';
import '../../widgets/composer_attachment_tile.dart';
import 'package:flutter/material.dart';

import '../../widgets/selection_viewport.dart';
import '../../services/bot_group_session.dart';
import '../../services/bot_group_history_session.dart';
import 'bot_group_history_screen.dart';
import '../../models/bots.dart';
import '../../widgets/server_connection_label.dart';
import '../../widgets/bot_avatar.dart';
import '../../widgets/profile_message.dart';
import '../../widgets/conversation_activity_status.dart';
import '../../widgets/composer_icon_button.dart';
import '../../models/composer_reference.dart';
import '../../widgets/mention_suggestions.dart';
import '../../widgets/slash_command_suggestions.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/studio_error.dart';
import '../../controllers/voice_input_controller.dart';
import '../../models/voice_processing_settings.dart';
import '../../services/android_voice.dart';
import '../../widgets/voice_input_activity.dart';
import '../../widgets/studio_form_actions.dart';
import 'bot_group_context_sheet.dart';

enum _GroupBotAction { history, chat, settings }

class BotGroupScreen extends StatefulWidget {
  const BotGroupScreen({
    super.key,
    required this.createSession,
    required this.voiceInputSettings,
    required this.stopVoicePlayback,
    this.voiceDevice,
    this.onCapturePhoto,
    this.onEdit,
    this.onOpenBotChat,
    this.onOpenBotSettings,
  });
  final BotGroupSession Function() createSession;
  final VoiceInputSettings? Function() voiceInputSettings;
  final Future<void> Function() stopVoicePlayback;
  final VoiceDevice? voiceDevice;
  final Future<void> Function()? onCapturePhoto;
  final Future<BotGroup?> Function(BotGroup)? onEdit;
  final Future<void> Function(BotRecord)? onOpenBotChat, onOpenBotSettings;
  @override
  State<BotGroupScreen> createState() => _BotGroupScreenState();
}

class _BotGroupScreenState extends State<BotGroupScreen>
    with WidgetsBindingObserver {
  late final _session = widget.createSession();
  late final _voiceInput = VoiceInputController(
    device: widget.voiceDevice ?? AndroidVoice.instance,
  );
  final _composer = SkillComposerController();
  final _focus = FocusNode();
  final _membersAnchor = GlobalKey();
  bool get _showReferences =>
      _session.pendingText == null &&
      !_session.sending &&
      !_voiceInput.active &&
      MentionQuery.at(
            _composer.text,
            _composer.selection.extentOffset,
            collapsed: _composer.selection.isCollapsed,
          ) !=
          null;

  final _transcript = ConversationTranscriptController();
  bool _capturing = false, _foreground = true;
  bool _launchingCamera = false;
  bool _inspectingDetails = false, _refreshingGroup = false;
  Object? _inspectedAvatarMessage;
  bool _presentationVisible = true, _restoreComposerFocus = false;
  bool get _visible =>
      _presentationVisible &&
      _foreground &&
      !_capturing &&
      !_inspectingDetails &&
      ModalRoute.isCurrentOf(context) != false;
  void _syncVisibility() {
    _session.setVisible(_visible);
    _voiceInput.retainTarget(_visible ? _session.voiceTarget : null);
  }

  void _reportRecording() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ConversationPresentationScope.maybeOf(
          context,
        )?.onRecordingChanged(_voiceInput.active);
      }
    });
  }

  void _voiceChanged() {
    _changed();
    _reportRecording();
  }

  void _composerChanged() {
    _session.editMentions(_composer.text);
    _changed();
  }

  Future<void> _refreshGroup() async {
    if (_refreshingGroup) return;
    setState(() => _refreshingGroup = true);
    try {
      await _session.refresh();
    } finally {
      if (mounted) setState(() => _refreshingGroup = false);
    }
  }

  Future<void> _pickAttachments({required bool photos}) async {
    if (!_session.canAddAttachments) return;
    _focus.unfocus();
    try {
      final files = await FilePicker.pickFiles(
        type: photos ? FileType.image : FileType.any,
      );
      if (!mounted || files.isEmpty) return;
      if (files.any((file) => file.path == null)) {
        throw StateError('A selected file could not be opened.');
      }
      await _session.addAttachments([
        for (final file in files)
          AndroidSharedFile(
            path: file.path!,
            name: file.name,
            byteLength: file.lengthSync() ?? 0,
            mediaType: switch (file.extension?.toLowerCase()) {
              'png' => 'image/png',
              'jpg' || 'jpeg' => 'image/jpeg',
              'webp' => 'image/webp',
              'pdf' => 'application/pdf',
              'txt' || 'md' || 'csv' => 'text/plain',
              _ => 'application/octet-stream',
            },
          ),
      ]);
    } catch (_) {
      if (mounted) {
        showStudioError(
          context,
          'Files could not be opened. Choose them again.',
        );
      }
    }
  }

  Future<void> _dictate() async {
    final capture = _session.captureVoiceDraft();
    final selection = _composer.selection;
    _focus.unfocus();
    await _voiceInput.dictate(
      target: _session.voiceTarget,
      draft: VoiceDraft(
        text: capture.text,
        selectionStart: selection.start,
        selectionEnd: selection.end,
      ),
      settings: widget.voiceInputSettings,
      stopPlayback: widget.stopVoicePlayback,
      admitsTarget: _session.admitsDictation,
      admitPresentation: () => mounted && _visible,
      createRemote: _session.voiceForGroup,
      applyDraft: (text) => _session.applyVoiceDraft(capture, text),
      onApplied: (result) {
        _composer.value = TextEditingValue(
          text: result.text,
          selection: TextSelection.collapsed(offset: result.selectionEnd),
        );
      },
      onNotice: (notice) => showStudioError(context, notice),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final presentation = ConversationPresentationScope.maybeOf(context);
    final visible = presentation?.visible ?? true;
    if (_presentationVisible && !visible && _focus.hasFocus) {
      _restoreComposerFocus = MediaQuery.viewInsetsOf(context).bottom > 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_presentationVisible) _focus.unfocus();
      });
    }
    final revealed = !_presentationVisible && visible;
    _presentationVisible = visible;
    _syncVisibility();
    if (revealed) {
      _acknowledgeReading();
      if (_restoreComposerFocus) {
        _restoreComposerFocus = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _visible) _focus.requestFocus();
        });
      }
    }
  }

  void _acknowledgeReading([int? visibleSequence]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_visible ||
          ModalRoute.of(context)?.isCurrent != true ||
          _capturing ||
          _inspectingDetails) {
        return;
      }
      final sequence =
          visibleSequence ?? _session.reading.readingPosition.readThrough;
      if (sequence != null) {
        unawaited(_session.acknowledgeVisibleMessages(sequence));
      }
    });
  }

  void _captureChanged(bool active) {
    _capturing = active;
    _session.setCapturing(active);
    _syncVisibility();
  }

  Widget _message(TranscriptTimelineEntry entry) {
    final user = entry.role == 'user';
    final member = _session.group.members
        .where((member) => member.handle == entry.message.senderHandle)
        .firstOrNull;
    return BotGroupMessage(
      key: ValueKey<(String, int)>(entry.presentationId as (String, int)),
      group: _session.group,
      message: entry.message,
      loadAttachmentImage: (target) async =>
          (await _session.downloadAttachment(target)).bytes,
      onDownloadAttachment: (output) async =>
          saveRemoteFile(await _session.downloadAttachment(output.target)),
      appearance: user || member == null
          ? null
          : _session.appearance(member.profile),
      senderAvatarVisible: _inspectedAvatarMessage != entry.presentationId,
      onSenderTap: user || member == null
          ? null
          : (anchor) => unawaited(
              _showBotActions(anchor, member, entry.presentationId),
            ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _composer.text = _session.draftText;
    _composer.observeReferences(_session.composerReferences);
    _session.addListener(_changed);
    _composer.addListener(_composerChanged);
    _voiceInput.addListener(_voiceChanged);
    _session.setVisible(true);
  }

  void _changed() {
    if (!mounted) return;
    if (_composer.text != _session.draftText) {
      _composer.value = TextEditingValue(
        text: _session.draftText,
        selection: TextSelection.collapsed(offset: _session.draftText.length),
      );
    }
    _composer.observeReferences(_session.composerReferences);
    setState(() {});
  }

  Future<void> _showMembers() async {
    final source = _membersAnchor.currentContext;
    if (source == null) return;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final box = source.findRenderObject()! as RenderBox;
    RelativeRect position() {
      final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
      return RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, rect.bottom + WingSpacing.xs, rect.width, 0),
        Offset.zero & overlay.size,
      );
    }

    var lastPosition = position();
    await showMenu<void>(
      context: context,
      semanticLabel: 'Group members',
      requestFocus: true,
      positionBuilder: (_, _) {
        if (box.attached &&
            overlay.attached &&
            box.hasSize &&
            overlay.hasSize) {
          lastPosition = position();
        }
        return lastPosition;
      },
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      elevation: 4,
      menuPadding: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
      popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(duration: Duration(milliseconds: 160)),
      items: [
        for (final member in _session.group.members)
          _GroupMenuEntry<void>(
            key: ValueKey(('group-member', member.id)),
            child: Builder(
              builder: (context) {
                final bot = _session.appearance(member.profile);
                final name = bot?.title ?? member.name;
                return Row(
                  children: [
                    BorrowedBotAvatar(bot: bot, name: name, size: 24),
                    const SizedBox(width: WingSpacing.sm),
                    Expanded(
                      child: Text(
                        name,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
    if (mounted) _acknowledgeReading();
  }

  Widget _approvalPanel(BotGroupAction action, {required int pendingCount}) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GatewayApprovalPanel(
            request: GatewayApprovalRequest.fromEventData({
              'command': action.command,
              'description': action.description,
              'choices': action.choices,
              'allow_session': false,
              'allow_permanent': false,
            }),
            total: pendingCount,
            enabled: _session.canResolve(action),
            onRespond: (choice) =>
                _session.resolve(action, choice: choice.wireValue),
          ),
          if (_session.approvalError(action) case final error?)
            StudioError(error),
        ],
      );

  Future<void> _confirmDiscard(BotGroupAction action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StudioDialog(
        title: const Text('Discard unknown attempt?'),
        content: const Text(
          'The outcome is unknown. Discard abandons this attempt so the group can recover. It does not undo side effects, prove that nothing happened, or stop a running process.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(dialogContext, false),
            onConfirm: () => Navigator.pop(dialogContext, true),
            confirmLabel: 'Discard unknown attempt',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await _session.discard(action);
  }

  Future<void> _showMemberActivity() async {
    final activities = _session.runtime?.memberActivity ?? const [];
    String time(DateTime value) {
      final local = value.toLocal();
      return '${MaterialLocalizations.of(context).formatMediumDate(local)} ${TimeOfDay.fromDateTime(local).format(context)}';
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StudioDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Member activity',
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
            ),
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Close member activity',
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final activity in activities)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _session.group.members
                              .where((member) => member.id == activity.memberId)
                              .firstOrNull
                              ?.name ??
                          'Bot',
                      style: Theme.of(dialogContext).textTheme.titleSmall,
                    ),
                    Text(activity.status),
                    if (activity.tool case final tool?) Text('Using $tool'),
                    if (activity.startedAt case final started?)
                      Text('Started ${time(started)}'),
                    if (activity.progressAt case final progress?)
                      Text('Last activity ${time(progress)}'),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Raw details'),
                      children: [
                        viewportSelection(
                          SelectableText(
                            'Member: ${activity.memberId}\nThread: ${activity.threadId}\nRound: ${activity.roundIndex ?? 'unknown'}',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            const Text('Times are reported by Hermes.'),
          ],
        ),
      ),
    );
  }

  Widget _activityStatus(BuildContext context) {
    final runtime = _session.runtime;
    final needsApproval = _session.pendingApprovals.isNotEmpty;
    final interrupted =
        runtime?.blocked == true || runtime?.actions.isNotEmpty == true;
    final memberActivity = <String>[
      for (final activity
          in runtime?.memberActivity ?? const <BotGroupMemberActivity>[])
        if (_session.group.members
                .where((member) => member.id == activity.memberId)
                .firstOrNull
            case final member?)
          '${member.name} · ${activity.tool == null ? activity.status : 'Using ${activity.tool}'}',
    ].join(' · ');
    final String? label;
    final bool active;
    final IconData? icon;
    final pendingAction =
        _session.sending ||
        _session.acting ||
        _launchingCamera ||
        (_session.awaitingStopFence && _session.error == null);
    if (_session.pendingText != null && !pendingAction) {
      label = 'Message not confirmed · Retry the same message';
      active = false;
      icon = Icons.error_outline;
    } else if (_session.error != null && !pendingAction) {
      label = 'Group needs attention';
      active = false;
      icon = Icons.error_outline;
    } else if (needsApproval) {
      label = memberActivity.isEmpty
          ? 'Waiting for your approval'
          : 'Waiting for your approval · $memberActivity';
      active = false;
      icon = Icons.help_rounded;
    } else if (interrupted) {
      label = memberActivity.isEmpty
          ? 'Group work is interrupted'
          : 'Group work is interrupted · $memberActivity';
      active = false;
      icon = Icons.pause_circle_outline;
    } else if (runtime?.working == true) {
      label = memberActivity.isEmpty ? 'Bots are working…' : memberActivity;
      active = true;
      icon = null;
    } else {
      label = null;
      active = false;
      icon = Icons.chat_bubble_outline;
    }
    final tokens = WingTokens.of(context);
    return StudioPageLoading(
      active: pendingAction,
      label: _session.sending ? 'Sending message' : 'Updating group work',
      child: ConversationActivityStatus(
        label: label,
        wrap: true,
        leading: active
            ? StudioWorkingIndicator(
                conversation: true,
                label: label ?? 'Group status',
                color: tokens.running,
              )
            : Icon(
                icon,
                size: 18,
                color: needsApproval || interrupted
                    ? tokens.blocked
                    : tokens.muted,
              ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncVisibility();
    if (_foreground) _acknowledgeReading();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    _voiceInput.removeListener(_voiceChanged);
    _voiceInput.dispose();
    _session.dispose();
    _composer.removeListener(_composerChanged);
    _composer.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final submitted = _session.pendingText ?? _composer.text;
    unawaited(_transcript.showLatest());
    await _session.send(submitted);
  }

  Future<void> _showBotActions(
    BuildContext anchor,
    BotGroupMember member,
    Object messageIdentity,
  ) async {
    if (!_visible) return;
    final bot = _session.appearance(member.profile);
    final name = bot?.title ?? member.name;
    final tokens = WingTokens.of(context);
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final box = anchor.findRenderObject()! as RenderBox;
    const menuAvatarSize = 32.0;
    RelativeRect position() {
      final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
      return RelativeRect.fromRect(
        Rect.fromLTWH(
          rect.center.dx - WingSpacing.md - menuAvatarSize / 2,
          rect.top,
          0,
          0,
        ),
        Offset.zero & overlay.size,
      );
    }

    var lastPosition = position();
    ModalRoute<dynamic>? menuRoute;
    setState(() {
      _inspectedAvatarMessage = messageIdentity;
      _inspectingDetails = true;
    });
    _syncVisibility();
    try {
      final action = await showMenu<_GroupBotAction>(
        context: context,
        semanticLabel: 'Options for $name',
        requestFocus: true,
        positionBuilder: (_, _) {
          if (box.attached &&
              overlay.attached &&
              box.hasSize &&
              overlay.hasSize) {
            lastPosition = position();
          }
          return lastPosition;
        },
        constraints: const BoxConstraints.tightFor(width: 240),
        color: tokens.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: WingRadius.card,
          side: BorderSide(color: tokens.border),
        ),
        elevation: 4,
        menuPadding: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
        popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(duration: Duration(milliseconds: 160)),
        items: [
          _GroupMenuEntry<_GroupBotAction>(
            child: Builder(
              builder: (menuContext) {
                menuRoute = ModalRoute.of(menuContext);
                return Row(
                  key: const ValueKey('group-bot-card-identity'),
                  children: [
                    ExcludeSemantics(
                      child: Transform.translate(
                        // Center the face on the 54 dp invoking tile without
                        // changing the existing header or card dimensions.
                        offset: const Offset(
                          0,
                          (BotConversationScope.avatarSize - menuAvatarSize) /
                                  2 -
                              WingSpacing.xs * 2,
                        ),
                        child: BorrowedBotAvatar(
                          bot: bot,
                          name: name,
                          size: menuAvatarSize,
                        ),
                      ),
                    ),
                    const SizedBox(width: WingSpacing.sm),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const PopupMenuDivider(height: 9),
          for (final (action, label, icon, enabled) in [
            (
              _GroupBotAction.history,
              'View working history',
              Icons.history_outlined,
              true,
            ),
            (
              _GroupBotAction.chat,
              'Chat directly',
              Icons.chat_bubble_outline,
              bot != null && widget.onOpenBotChat != null,
            ),
            (
              _GroupBotAction.settings,
              'Bot settings',
              Icons.tune_outlined,
              bot != null && widget.onOpenBotSettings != null,
            ),
          ])
            StudioPopupMenuItem<_GroupBotAction>(
              key: ValueKey(('group-bot-action', action.name)),
              value: action,
              enabled: enabled,
              height: 48,
              padding: const EdgeInsets.symmetric(
                horizontal: WingSpacing.md,
                vertical: WingSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: enabled
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).disabledColor,
                  ),
                  const SizedBox(width: WingSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        height: 1.3,
                        color: enabled
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
      if (!mounted || ModalRoute.isCurrentOf(context) != true) return;
      final currentBot = _session.appearance(member.profile);
      switch (action) {
        case _GroupBotAction.history:
          await _openWorkingHistories(member);
        case _GroupBotAction.chat:
          if (currentBot != null) await widget.onOpenBotChat?.call(currentBot);
        case _GroupBotAction.settings:
          if (currentBot != null) {
            await widget.onOpenBotSettings?.call(currentBot);
          }
        case null:
          break;
      }
    } catch (error) {
      if (mounted) showStudioError(context, error.toString());
    } finally {
      unawaited(_restoreBotAvatar(menuRoute, messageIdentity));
      _inspectingDetails = false;
      if (mounted) {
        _syncVisibility();
        _acknowledgeReading();
      }
    }
  }

  Future<void> _restoreBotAvatar(
    ModalRoute<dynamic>? menuRoute,
    Object messageIdentity,
  ) async {
    // showMenu returns when dismissal starts. Keep the original hidden until
    // the popup has finished painting its closing animation.
    await menuRoute?.completed;
    if (mounted && _inspectedAvatarMessage == messageIdentity) {
      setState(() => _inspectedAvatarMessage = null);
    }
  }

  Future<void> _editGroup() async {
    _focus.unfocus();
    _inspectingDetails = true;
    _syncVisibility();
    try {
      final updated = await widget.onEdit!(_session.group);
      if (mounted && updated != null) {
        _session.updateDetails(updated);
      }
    } finally {
      _inspectingDetails = false;
      if (mounted) _syncVisibility();
    }
  }

  Future<void> _openWorkingHistories([BotGroupMember? member]) async {
    _focus.unfocus();
    _inspectingDetails = true;
    _syncVisibility();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => InheritedTheme.captureAll(
            context,
            BotGroupHistoryScreen(
              initialMemberId: member?.id,
              appearanceForMember: _session.appearance,
              createSession: () => BotGroupHistorySession(
                _session.repository,
                _session.group,
                readingPositions: _session.preferences.readingPositions,
              ),
            ),
          ),
        ),
      );
    } finally {
      _inspectingDetails = false;
      if (mounted) _syncVisibility();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final enlargedText = MediaQuery.textScalerOf(context).scale(16) >= 24;
    final reading = _session.reading;
    final timeline = TranscriptTimeline.project(
      reading.messages,
      presentationId: reading.messagePresentationId,
      requestActivities: reading.requestActivities,
      messageProjection: reading.messageForRow,
    );
    final canStop =
        _session.canStopGroupWork &&
        (_session.runtime?.working == true ||
            _session.runtime?.blocked == true);
    final stopping =
        canStop &&
        !_session.sending &&
        _session.pendingText == null &&
        _composer.text.trim().isEmpty &&
        _session.attachments.isEmpty;
    final locked =
        _session.pendingText != null || _session.sending || _voiceInput.active;
    return BotGroupConversation(
      group: _session.group,
      instanceHeader: ServerConnectionLabel(
        label: _session.group.instance,
        status: ServerConnectionScope.of(context),
      ),
      appearances: [
        for (final member in _session.group.members)
          ?_session.appearance(member.profile),
      ],
      onBack: () => Navigator.of(context).maybePop(),
      membersAnchor: _membersAnchor,
      onMembers: _showMembers,
      onEdit: widget.onEdit == null ? null : _editGroup,
      showMembers: !_showReferences && (!keyboardOpen || !enlargedText),
      actions: [
        StudioButtonPress(
          child: PopupMenuButton<String>(
            tooltip: 'Group options',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) async {
              switch (action) {
                case 'histories':
                  await _openWorkingHistories();
                case 'refresh':
                  await _refreshGroup();
                case 'stop':
                  await _session.stop();
                case 'context':
                  await showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    isDismissible: false,
                    enableDrag: false,
                    builder: (_) => BotGroupContextSheet(session: _session),
                  );
                case 'activity':
                  await _showMemberActivity();
              }
            },
            itemBuilder: (_) => [
              const StudioPopupMenuItem(
                value: 'histories',
                child: Text('Bot working histories'),
              ),
              if (_session.canEditContext)
                const StudioPopupMenuItem(
                  value: 'context',
                  child: Text('Shared settings'),
                ),
              if (_session.runtime?.memberActivity.isNotEmpty == true)
                const StudioPopupMenuItem(
                  value: 'activity',
                  child: Text('Member activity'),
                ),
              StudioPopupMenuItem(
                value: 'refresh',
                enabled: !_session.loading && !_refreshingGroup,
                child: const Text('Refresh group'),
              ),
              if (_session.canStopGroupWork)
                const StudioPopupMenuItem(
                  value: 'stop',
                  child: Text('Stop group work'),
                ),
            ],
          ),
        ),
      ],
      transcript: StudioPageLoading(
        active: _refreshingGroup,
        label: 'Refreshing group',
        child: ProfileTranscript(
          key: ValueKey(('discussion', _session.group.id)),
          controller: _transcript,
          presentation: TranscriptPresentation.capture(
            identity: _session.group.key,
            reader: reading,
            timeline: timeline,
            needsInput: false,
            turnAdmissionBlocked: _session.runtime?.working == true,
          ),
          onRefreshHistory: _refreshGroup,
          messageBuilder: _message,
          onCaptureChanged: _captureChanged,
          onReadThrough: _acknowledgeReading,
          emptyContent: const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Start a discussion. Mention a bot to focus the reply, or ask the whole group.',
            ),
          ),
          tail: [
            if (_session.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: StudioError(_session.error!),
              ),
            if (_session.pendingApprovals.firstOrNull case final action?)
              _approvalPanel(
                action,
                pendingCount: _session.pendingApprovals.length,
              ),
            if (_session.runtime case final runtime?) ...[
              if (runtime.lastError case final error? when error.isNotEmpty)
                StudioError(error),
              if (runtime.blocked && runtime.actions.isEmpty)
                const Text(
                  'Group work is interrupted. Refresh to check its recovery options.',
                ),
              for (final action in runtime.actions.where(
                (action) =>
                    (action.kind == 'retry' || action.kind == 'discard') &&
                    runtime.supports(action.kind),
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.kind == 'discard'
                            ? '${_session.group.members.where((member) => member.id == action.member).firstOrNull?.name ?? 'Bot'} has an unknown outcome. Review before discarding this attempt.'
                            : '${_session.group.members.where((member) => member.id == action.member).firstOrNull?.name ?? 'Bot'} could not finish. Retry this attempt.',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: action.kind == 'discard'
                              ? 'Discard unknown group attempt'
                              : 'Retry group attempt',
                          onPressed: !_session.canResolve(action)
                              ? null
                              : () => action.kind == 'discard'
                                    ? _confirmDiscard(action)
                                    : _session.resolve(action),
                          icon: Icon(
                            action.kind == 'discard'
                                ? Icons.delete_outline
                                : Icons.refresh,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              for (final continuation in _session.boundedDiscussions)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (continuation.text.isNotEmpty)
                      Text(
                        continuation.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    const Text('Round limit reached.'),
                    if (runtime.maxContinues != null &&
                        continuation.grant > runtime.maxContinues!)
                      const Text('All extensions have been used.')
                    else if (runtime.supports('continue') &&
                        runtime.maxContinues != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${runtime.maxRounds == null ? 'More rounds' : '${runtime.maxRounds} more rounds'} · Extension ${continuation.grant} of ${runtime.maxContinues}',
                            ),
                          ),
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Continue discussion',
                              onPressed: _session.canContinue(continuation)
                                  ? () => _session.continueDiscussion(
                                      continuation,
                                    )
                                  : null,
                              icon: const Icon(Icons.play_arrow),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
      composerController: _composer,
      suggestions: _showReferences
          ? MentionSuggestions(
              composer: _composer,
              composerFocus: _focus,
              load: (query, directory, canRead) async =>
                  _session.completeMentions(query),
              select: (text, reference) async {
                _session.editMentions(text, selected: reference);
                _composer.observeReferences(_session.composerReferences);
                _changed();
              },
            )
          : null,
      beforeComposer: [_activityStatus(context)],
      composer: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _composer,
        builder: (context, _, _) => ConversationComposer(
          beforeField: [
            if (_session.attachments.isNotEmpty ||
                _session.attachmentPreparation != null)
              ComposerAttachmentStrip(
                preparing: _session.attachmentPreparation != null,
                children: [
                  for (final (index, attachment)
                      in _session.attachments.indexed)
                    ComposerAttachmentSlot(
                      key: ValueKey(('group-attachment-slot', index)),
                      child: ComposerAttachmentTile(
                        key: ValueKey(attachment.id),
                        name: attachment.name,
                        kind: _session.attachmentPreview(attachment) == null
                            ? AttachmentDraftKind.genericFile
                            : AttachmentDraftKind.image,
                        previewImage:
                            _session.attachmentPreview(attachment) == null
                            ? null
                            : AttachmentPreviewImage(
                                _session.attachmentPreview(attachment)!,
                              ),
                        onRemove: !_session.canAddAttachments
                            ? null
                            : () => _session.removeAttachment(attachment),
                      ),
                    ),
                  if (_session.attachmentPreparation case final preparation?)
                    ComposerAttachmentSlot(
                      key: ValueKey((
                        'group-attachment-slot',
                        _session.attachments.length,
                      )),
                      child: ComposerPendingAttachmentTile(
                        preparation: preparation,
                      ),
                    ),
                ],
              ),
            VoiceInputActivity(context: this.context, controller: _voiceInput),
          ],
          focusNode: _focus,
          field: ConversationComposerField(
            fieldKey: const ValueKey('group-message-composer'),
            controller: _composer,
            focusNode: _focus,
            readOnly: locked,
            hintText: 'Message the group',
            microphone: VoiceInputButton(
              enabled: _voiceInput.canDictate(_session.canDictate),
              onPressed: () => unawaited(
                _dictate().catchError((Object failure) {
                  if (mounted && _visible) {
                    showStudioError(this.context, voiceFailureMessage(failure));
                  }
                }),
              ),
            ),
          ),
          controls: StudioButtonPress(
            child: PopupMenuButton<String>(
              tooltip: 'Add group attachment',
              enabled:
                  _session.canAddAttachments &&
                  !_voiceInput.active &&
                  !_launchingCamera,
              icon: const Icon(Icons.add),
              onSelected: (choice) async {
                if (choice != 'camera') {
                  await _pickAttachments(photos: choice == 'photos');
                  return;
                }
                setState(() => _launchingCamera = true);
                try {
                  await widget.onCapturePhoto!();
                } catch (_) {
                  if (context.mounted) {
                    showStudioError(
                      context,
                      'The camera could not open. Try again.',
                    );
                  }
                } finally {
                  if (mounted) setState(() => _launchingCamera = false);
                }
              },
              itemBuilder: (_) => [
                if (widget.onCapturePhoto != null)
                  const StudioPopupMenuItem(
                    value: 'camera',
                    child: Text('Camera'),
                  ),
                const StudioPopupMenuItem(
                  value: 'photos',
                  child: Text('Photos'),
                ),
                const StudioPopupMenuItem(value: 'files', child: Text('Files')),
              ],
            ),
          ),
          primaryAction: ComposerIconButton(
            focused: false,
            label: stopping
                ? 'Stop group work'
                : _session.pendingText == null
                ? 'Send group message'
                : 'Retry same message',
            onPressed: _voiceInput.active
                ? null
                : stopping
                ? _session.stop
                : _session.sending ||
                      _session.acting ||
                      _session.attachmentPreparation != null ||
                      (_session.pendingText == null &&
                          _composer.text.trim().isEmpty &&
                          _session.attachments.isEmpty)
                ? null
                : _send,
            icon: ComposerActionGlyph(
              icon: stopping
                  ? Icons.stop
                  : _session.pendingText == null
                  ? Icons.arrow_upward
                  : Icons.refresh,
              identity: stopping
                  ? 'stop'
                  : _session.pendingText == null
                  ? 'send'
                  : 'retry',
            ),
          ),
        ),
      ),
    );
  }
}

// The body scrolls independently; the decision pair never leaves its panel.

class _GroupMenuEntry<T> extends PopupMenuEntry<T> {
  const _GroupMenuEntry({super.key, required this.child});
  final Widget child;
  @override
  double get height => 0;
  @override
  bool represents(T? value) => false;
  @override
  State<_GroupMenuEntry<T>> createState() => _GroupMenuEntryState<T>();
}

class _GroupMenuEntryState<T> extends State<_GroupMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: WingSpacing.md,
      vertical: WingSpacing.xs,
    ),
    child: widget.child,
  );
}
