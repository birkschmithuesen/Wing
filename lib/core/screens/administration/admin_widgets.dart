import '../../widgets/studio_form_actions.dart';
import '../../widgets/wing_app_bar.dart';
import 'dart:async';
export 'admin_navigation.dart';
import '../../theme/wing_theme.dart';
import '../../theme/wing_icons.dart';
import '../../widgets/server_connection_label.dart';
import '../../widgets/workspace_picker.dart';
import 'package:flutter/material.dart';

import '../../widgets/studio_error.dart';

class AdminPage extends StatelessWidget {
  final String title;
  final String scope;
  final WorkspacePickerMode? pickerMode;
  final Widget child;
  final List<Widget> actions;
  final Widget? bottomNavigationBar;
  const AdminPage({
    super.key,
    required this.title,
    required this.scope,
    this.pickerMode,
    required this.child,
    this.actions = const [],
    this.bottomNavigationBar,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: WingAppBar(
      context: context,

      title: Text(title, maxLines: 6, softWrap: true),
      actions: actions,
      contextRow: ServerConnectionScope.of(context) == null
          ? Text(scope, style: Theme.of(context).textTheme.bodySmall)
          : ServerConnectionLabel(
              label: scope,
              pickerMode: pickerMode,
              includeProfiles:
                  scope != ServerConnectionScope.of(context)?.label,
              status: ServerConnectionScope.of(context),
            ),
    ),
    bottomNavigationBar: bottomNavigationBar == null
        ? null
        : Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: bottomNavigationBar,
          ),
    body: child,
  );
}

class AdminGroup extends StatelessWidget {
  final List<Widget> children;
  final bool selected;
  const AdminGroup({super.key, required this.children, this.selected = false});
  @override
  Widget build(BuildContext context) => Card(
    color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
    shape: selected
        ? RoundedRectangleBorder(
            borderRadius: WingRadius.card,
            side: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          )
        : null,
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          children[i],
        ],
      ],
    ),
  );
}

class AdminEditorActions extends StatelessWidget {
  const AdminEditorActions({
    super.key,
    required this.dirtyCount,
    required this.saving,
    required this.onClose,
    required this.onSave,
  });
  final int dirtyCount;
  final bool saving;
  final VoidCallback onClose;
  final VoidCallback? onSave;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            dirtyCount == 0
                ? 'No unsaved changes'
                : '$dirtyCount unsaved ${dirtyCount == 1 ? 'change' : 'changes'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          StudioFormActions(
            onCancel: saving ? null : onClose,
            onConfirm: saving ? null : onSave,
            confirmLabel: 'Save changes',
            busy: saving,
            progressLabel: 'Saving changes',
          ),
        ],
      ),
    ),
  );
}

class AdminRow extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool emphasizeChanges;
  final String? attention;
  final String? detail;
  final IconData icon;
  final Color? iconColor;
  final VoidCallback? onTap;
  const AdminRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.emphasizeChanges = false,
    this.attention,
    this.detail,
    required this.icon,
    this.iconColor,
    this.onTap,
  });
  @override
  State<AdminRow> createState() => _AdminRowState();
}

class _AdminRowState extends State<AdminRow> {
  Timer? _timer;
  bool _changed = false;
  @override
  void didUpdateWidget(AdminRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.emphasizeChanges &&
        oldWidget.subtitle != widget.subtitle &&
        !oldWidget.subtitle.toLowerCase().contains('loading') &&
        !oldWidget.subtitle.contains('Schedules unavailable') &&
        !MediaQuery.disableAnimationsOf(context)) {
      _timer?.cancel();
      _changed = true;
      _timer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _changed = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    animationDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    color: _changed
        ? Theme.of(context).colorScheme.primaryContainer
        : Colors.transparent,
    child: StudioButtonPress(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        minTileHeight: 64,
        minVerticalPadding: 8,
        leading: Icon(widget.icon, size: 22, color: widget.iconColor),
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.attention != null) ...[
              const SizedBox(height: 4),
              AdminAttention(widget.attention!),
              const SizedBox(height: 4),
            ],
            if (widget.detail != null)
              Text(
                widget.detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Text(widget.subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: widget.onTap == null
            ? null
            : const Icon(Icons.chevron_right, size: 20),
        onTap: widget.onTap,
      ),
    ),
  );
}

/// A finding stays distinct from ordinary configuration metadata.
class AdminAttention extends StatelessWidget {
  const AdminAttention(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => StudioError(
    label,
    severity: StudioErrorSeverity.noResult,
    announce: false,
    framed: false,
  );
}

class AdminNotice extends StatelessWidget {
  final String text;
  final VoidCallback? retry;
  final bool isError;
  const AdminNotice(this.text, {super.key, this.retry, this.isError = false});
  const AdminNotice.error(this.text, {super.key, this.retry}) : isError = true;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isError)
          StudioError(text)
        else
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
        if (retry != null)
          StudioButtonPress(
            child: IconButton(
              onPressed: retry,
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh),
            ),
          ),
      ],
    ),
  );
}

/// Bring a failed/partial save into view without moving focus into an input.
void revealAdminNotice(BuildContext context, GlobalKey anchor) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = anchor.currentContext;
    if (!context.mounted || target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
    );
  });
}

Future<bool> adminConfirm(
  BuildContext context,
  String title,
  String detail, {
  required String action,
  required IconData actionIcon,
  required bool destructive,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        scrollable: true,
        title: Text(title),
        content: Text(detail),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: action,
            confirmIcon: actionIcon,
            destructive: destructive,
          ),
        ],
      ),
    ) ??
    false;

void adminMessage(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  if (isError) {
    showStudioError(context, message);
  } else {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Shared diagnostic chat action for Doctor findings and failed schedules.
class AdminAskHermesButton extends StatelessWidget {
  const AdminAskHermesButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(WingIcons.newChat, size: 18),
      label: Text(label),
    ),
  );
}
