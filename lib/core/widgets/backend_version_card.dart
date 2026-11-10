import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'studio_loading.dart';
import 'package:flutter/material.dart';

import '../models/backend_update.dart';
import '../screens/backend_update_changes_screen.dart';
import '../services/backend_update_controller.dart';

/// Backend identity and host-wide update controls for one captured connection.
class BackendVersionCard extends StatefulWidget {
  final String? connectionLabel;
  final BackendUpdateController updateController;

  const BackendVersionCard({
    super.key,
    this.connectionLabel,
    required this.updateController,
  });

  @override
  State<BackendVersionCard> createState() => _BackendVersionCardState();
}

class _BackendVersionCardState extends State<BackendVersionCard>
    with SingleTickerProviderStateMixin {
  final _logScroll = ScrollController();
  late final _refreshRotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _logScroll.dispose();
    _refreshRotation.dispose();
    super.dispose();
  }

  late BackendUpdateController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.updateController;
    _checkOnOpen();
  }

  @override
  void didUpdateWidget(covariant BackendVersionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final suppliedControllerChanged = !identical(
      oldWidget.updateController,
      widget.updateController,
    );
    if (!suppliedControllerChanged) return;
    _controller = widget.updateController;
    _checkOnOpen();
  }

  void _checkOnOpen() {
    final controller = _controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(controller, _controller) &&
          controller.phase == BackendUpdatePhase.idle) {
        controller.checkForUpdate();
      }
    });
  }

  Future<void> _confirmAndStart() async {
    final controller = _controller;
    final approvedChannel = controller.channel;
    if (!controller.canStart || approvedChannel == null) {
      return;
    }
    final label = widget.connectionLabel?.trim();
    final host = label == null || label.isEmpty ? 'this server' : label;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        insetPadding: const EdgeInsets.all(WingSpacing.md),

        scrollable: true,
        title: Text('Update backend on $host?'),
        content: Text(
          '${controller.check?.rollbackTo != null || approvedChannel.rollback ? 'This moves the server back to release ${approvedChannel.targetVersion ?? controller.check?.rollbackTo ?? approvedChannel.name}. ' : ''}'
          'Update the whole server using ${approvedChannel.name}. All profiles may disconnect while Hermes restarts.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Update backend',
            confirmIcon: Icons.system_update_alt,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !identical(controller, _controller)) {
      return;
    }
    await controller.startUpdate(
      approvedChannel: approvedChannel,
      canDispatch: () => mounted && identical(controller, _controller),
    );
  }

  Future<void> _editChannel() async {
    final controller = _controller;
    final channel = controller.channel;
    if (!controller.canOpenChannelEditor) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackendChannelDialog(
        controller: controller,
        initial: channel,
        host: widget.connectionLabel ?? 'this server',
        isCurrent: () => mounted && identical(controller, _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final controller = _controller;
      final check = controller.check;
      final channel = controller.channel;
      final status = controller.status;
      final tokens = WingTokens.of(context);
      final logStyle = tokens.typography.mono;
      final logLineHeight =
          MediaQuery.textScalerOf(context).scale(logStyle.fontSize!) *
          logStyle.height!;
      final initialCheck =
          !controller.cloudManaged &&
          check == null &&
          controller.phase == BackendUpdatePhase.idle;
      final checking =
          controller.checking ||
          initialCheck ||
          (controller.channelSaving && check == null);
      final current =
          controller.phase == BackendUpdatePhase.ready &&
          check?.updateAvailable == false &&
          check?.behind == 0;
      final checkMessage =
          controller.phase == BackendUpdatePhase.unknown &&
              !controller.requestOutstanding &&
              status == null
          ? controller.message
          : null;
      final hideAvailability =
          checking &&
          (check == null ||
              (check.updateAvailable != true &&
                  !(check.updateAvailable == false && check.behind == 0)));
      final connectionLabel = widget.connectionLabel ?? 'Hermes backend';
      final busy =
          checking ||
          controller.versionLoading ||
          controller.channelSaving ||
          controller.starting ||
          controller.statusLoading;
      final animateRefresh =
          busy &&
          !MediaQuery.disableAnimationsOf(context) &&
          (ModalRoute.isCurrentOf(context) ?? true) &&
          TickerMode.valuesOf(context).enabled;
      if (animateRefresh) {
        if (!_refreshRotation.isAnimating) _refreshRotation.repeat();
      } else {
        _refreshRotation.stop();
        _refreshRotation.value = 0;
      }
      final showUpdate =
          controller.updateAttempt > 0 ||
          status != null ||
          controller.statusLoading;
      final lines = status?.lines ?? const <String>[];
      return StudioPageLoading(
        active: busy,
        label: controller.channelSaving
            ? 'Saving update channel'
            : controller.starting
            ? 'Starting backend update'
            : controller.statusLoading
            ? 'Checking update progress'
            : controller.versionLoading && !checking
            ? 'Loading server version'
            : 'Checking for updates',
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              WingSpacing.md,
              WingSpacing.md,
              WingSpacing.md,
              WingSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.cloud_outlined,
                        size: 24,
                        color: tokens.muted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Server version',
                            style: tokens.typography.label.copyWith(
                              color: tokens.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            controller.installedVersion ??
                                (controller.versionLoading || initialCheck
                                    ? '—'
                                    : 'Version unavailable'),
                            style: tokens.typography.title,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: WingSpacing.sm),
                if (controller.versionStale) ...[
                  const StudioError(
                    'Could not refresh server version.',
                    detail: 'Showing the last known version.',
                  ),
                  const SizedBox(height: WingSpacing.sm),
                ],
                if (controller.cloudManaged)
                  Text(
                    'Updates are managed by Hermes Cloud.',
                    style: tokens.typography.body,
                  ),
                if (!controller.cloudManaged) ...[
                  if (check?.installMethod case final method?)
                    Text(
                      'Install method: $method',
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  if (channel != null || check?.canApply != false)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            channel?.label ?? 'Channel unavailable',
                            style: tokens.typography.label.copyWith(
                              color: tokens.muted,
                            ),
                          ),
                        ),
                        if (channel?.canSelect != false)
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Change update channel',
                              onPressed: controller.canOpenChannelEditor
                                  ? _editChannel
                                  : null,
                              icon: const Icon(Icons.tune, size: 18),
                            ),
                          ),
                      ],
                    ),
                  if (channel?.targetVersion case final version?)
                    Text(
                      'Release: $version',
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  const Divider(height: WingSpacing.lg),
                  if (checkMessage != null)
                    StudioError(checkMessage)
                  else
                    Visibility(
                      visible: !hideAvailability,
                      maintainSize: true,
                      maintainState: true,
                      maintainAnimation: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              current
                                  ? Icons.check_circle_outline
                                  : check?.updateAvailable == true
                                  ? Icons.system_update_alt
                                  : Icons.help_outline,
                              size: 20,
                              color: current
                                  ? tokens.success
                                  : check?.updateAvailable == true
                                  ? tokens.accent
                                  : tokens.muted,
                            ),
                          ),
                          const SizedBox(width: WingSpacing.md),
                          Expanded(
                            child: Text(
                              _checkStatus(check, channel, controller.phase),
                              style: tokens.typography.body,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!hideAvailability &&
                      checkMessage == null &&
                      channel?.name == 'main' &&
                      check?.updateAvailable == true &&
                      check?.behind == null &&
                      check?.commits.isEmpty == true) ...[
                    const SizedBox(height: WingSpacing.sm),
                    Text(
                      BackendUpdateChangesScreen.comparisonUnavailableMessage,
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  ],
                  if (check?.canApply == false)
                    const Text('Updates must be applied from the server host.'),
                  if (controller.phase != BackendUpdatePhase.idle &&
                      controller.phase != BackendUpdatePhase.ready &&
                      controller.message == null)
                    Text(_phaseLabel(controller.phase)),
                  if (controller.message case final message?
                      when message != checkMessage)
                    const {
                          BackendUpdatePhase.failed,
                          BackendUpdatePhase.refused,
                          BackendUpdatePhase.partial,
                        }.contains(controller.phase)
                        ? StudioError(message)
                        : Text(message),
                  if (showUpdate)
                    ExpansionTile(
                      key: ValueKey((controller, controller.updateAttempt)),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: const Text('Update logs'),
                      subtitle: Text(
                        lines.isEmpty
                            ? controller.starting ||
                                      controller.phase ==
                                          BackendUpdatePhase.running
                                  ? 'Waiting for update output'
                                  : 'No update output received'
                            : '${lines.length} lines',
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: 16 * logLineHeight,
                            ),
                            child: Scrollbar(
                              controller: _logScroll,
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                key: const ValueKey(
                                  'backend-update-log-scroll',
                                ),
                                controller: _logScroll,
                                primary: false,
                                child: viewportSelection(
                                  SelectableText(
                                    lines.isEmpty
                                        ? 'No update output received.'
                                        : lines.reversed.join('\n'),
                                    style: logStyle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (check?.updateAvailable == true)
                        StudioButtonPress(
                          child: IconButton(
                            tooltip: 'Changes in this update',
                            onPressed:
                                controller.checking || controller.starting
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          BackendUpdateChangesScreen(
                                            check: check!,
                                            connectionLabel: connectionLabel,
                                          ),
                                    ),
                                  ),
                            icon: const Icon(Icons.notes_outlined, size: 18),
                          ),
                        ),
                      if (check?.canStart == true &&
                          channel?.error == null &&
                          channel?.targetSha != null)
                        StudioButtonPress(
                          child: IconButton.filled(
                            tooltip: 'Update backend',
                            onPressed: controller.canStart
                                ? _confirmAndStart
                                : null,
                            icon: const Icon(Icons.system_update_alt, size: 18),
                          ),
                        ),
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: controller.requestOutstanding
                              ? 'Check update progress'
                              : controller.cloudManaged
                              ? 'Refresh server version'
                              : 'Check for updates',
                          onPressed: busy
                              ? null
                              : controller.requestOutstanding
                              ? controller.refreshStatus
                              : controller.checkForUpdate,
                          icon: RotationTransition(
                            turns: _refreshRotation,
                            child: const Icon(Icons.sync, size: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

String _checkStatus(
  BackendUpdateCheck? check,
  BackendUpdateChannel? channel,
  BackendUpdatePhase phase,
) {
  if (check == null) {
    return phase == BackendUpdatePhase.unknown
        ? 'Could not check for updates.'
        : 'Update availability unknown.';
  }
  if (check.failed) return 'Could not check for updates.';
  if (channel?.aheadOfRelease == true) return 'Newer than the stable release';
  if (check.rollbackTo != null || channel?.rollback == true) {
    return 'Switch to an older release';
  }
  if (check.updateAvailable == true) {
    final behind = check.behind;
    return behind != null && behind > 0
        ? 'Update available · $behind commits behind${channel?.branch == null ? '' : ' ${channel!.branch}'}'
        : channel != null && channel.name != 'main'
        ? 'Release update available'
        : check.commits.isEmpty
        ? 'Update available · comparison unavailable'
        : 'Update available · commit count unavailable';
  }
  return check.updateAvailable == false && check.behind == 0
      ? channel == null
            ? 'Up to date'
            : 'Up to date on ${channel.name}'
      : 'Update availability unknown.';
}

String _phaseLabel(BackendUpdatePhase phase) => switch (phase) {
  BackendUpdatePhase.idle => 'Update availability unknown.',
  BackendUpdatePhase.ready => 'Update check complete',
  BackendUpdatePhase.starting => 'Starting backend update…',
  BackendUpdatePhase.running => 'Backend update running',
  BackendUpdatePhase.succeeded => 'Backend update succeeded',
  BackendUpdatePhase.partial => 'Backend update partially completed',
  BackendUpdatePhase.refused => 'Backend update refused',
  BackendUpdatePhase.failed => 'Backend update failed',
  BackendUpdatePhase.unknown => 'Backend update state unknown',
};

class _BackendChannelDialog extends StatefulWidget {
  const _BackendChannelDialog({
    required this.controller,
    required this.initial,
    required this.host,
    required this.isCurrent,
  });
  final BackendUpdateController controller;
  final BackendUpdateChannel? initial;
  final String host;
  final bool Function() isCurrent;
  @override
  State<_BackendChannelDialog> createState() => _BackendChannelDialogState();
}

class _BackendChannelDialogState extends State<_BackendChannelDialog> {
  late BackendUpdateChannel? _initial = widget.initial;
  late String? _choice = widget.initial?.name;
  bool _pending = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_initial == null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _readChannel();
      });
    }
  }

  Future<void> _reload() async {
    if (_loading || _pending || !widget.isCurrent()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _readChannel();
  }

  Future<void> _readChannel() async {
    await widget.controller.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!widget.isCurrent()) {
        _error = 'This server is no longer selected. Close this editor.';
      } else if (widget.controller.canSelectChannel) {
        _initial = widget.controller.channel;
        if (!{'stable', 'main', _initial!.name}.contains(_choice)) {
          _choice = _initial!.name;
        }
      } else {
        _error =
            'The current channel is unavailable. Check again to enable saving.';
      }
    });
  }

  Future<void> _save() async {
    final initial = _initial;
    final choice = _choice;
    if (_pending ||
        _loading ||
        initial == null ||
        choice == null ||
        !widget.isCurrent()) {
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    final owner = widget.controller;
    if (owner.channel == null) await owner.checkForUpdate();
    if (!mounted) return;
    if (!widget.isCurrent()) {
      setState(() {
        _pending = false;
        _error = 'This server is no longer selected. Close this editor.';
      });
      return;
    }
    final track = owner.channel;
    final sameInstall =
        track != null &&
        track.installId == initial.installId &&
        track.installPath == initial.installPath &&
        track.home == initial.home;
    final saved =
        sameInstall &&
        (choice == track.name ||
            await owner.selectChannel(
              choice,
              track,
              canDispatch: () => mounted && widget.isCurrent(),
            ));
    if (!mounted) return;
    if (saved && widget.isCurrent()) {
      Navigator.pop(context);
    } else {
      setState(() {
        _pending = false;
        _error = owner.message ?? 'The channel could not be saved. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_pending,
    child: StudioDialog(
      insetPadding: const EdgeInsets.all(WingSpacing.md),

      scrollable: true,
      title: const Text('Update channel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.host),
          const SizedBox(height: 16),
          StudioButtonPress(
            child: DropdownButtonFormField<String>(
              key: ValueKey(_initial?.name),
              initialValue: _choice,
              hint: const Text('Unavailable'),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Channel'),
              items: [
                const DropdownMenuItem(
                  value: 'stable',
                  child: Text('Stable releases'),
                ),
                const DropdownMenuItem(
                  value: 'main',
                  child: Text('Main branch'),
                ),
                if (_initial != null &&
                    !{'stable', 'main'}.contains(_initial!.name))
                  DropdownMenuItem(
                    value: _initial!.name,
                    child: Text(_initial!.name),
                  ),
              ],
              onChanged: _pending || _loading || _initial == null
                  ? null
                  : (value) => setState(() => _choice = value!),
            ),
          ),
          const SizedBox(height: 12),
          if (_choice != null)
            Text(
              _choice == 'main'
                  ? 'Follow commits on main.'
                  : _choice == 'stable'
                  ? 'Follow published releases.'
                  : 'Keep the configured preview channel.',
            ),
          const Text('Changes the whole server without installing an update.'),
          if (_error != null) StudioError(_error!),
        ],
      ),
      actions: [
        Row(
          children: [
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Check update channel',
                onPressed: _loading || _pending ? null : _reload,
                icon: _loading
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          value: MediaQuery.disableAnimationsOf(context)
                              ? 0.75
                              : null,
                          strokeWidth: 2,
                          semanticsLabel: 'Checking update channel',
                        ),
                      )
                    : const Icon(Icons.sync),
              ),
            ),
            Expanded(
              child: StudioFormActions(
                onCancel: () => Navigator.pop(context),
                onConfirm:
                    _loading || _initial == null || _choice == _initial?.name
                    ? null
                    : _save,
                confirmLabel: 'Save update channel',
                busy: _pending,
                progressLabel: 'Saving update channel',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
