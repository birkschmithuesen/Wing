import 'dart:async';

import '../models/server_reference.dart';
import '../widgets/selection_viewport.dart';
import '../widgets/studio_form_actions.dart';
import '../models/project_icon.dart';
import '../theme/project_icon_glyphs.dart';
import '../widgets/project_icon_picker.dart';
import '../services/server_files_browser.dart';
import '../widgets/studio_error.dart';
import '../widgets/project_folder_picker.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';
import '../theme/wing_icons.dart';
import '../widgets/workspace_action_menu.dart';

import '../models/chat_list_view.dart';
import '../models/browser_actions.dart';
import '../services/chat_browser_data.dart';

const _projectColors = <String>[
  'hsl(0 68% 58%)',
  'hsl(30 68% 58%)',
  'hsl(60 68% 58%)',
  'hsl(90 68% 58%)',
  'hsl(120 68% 58%)',
  'hsl(150 68% 58%)',
  'hsl(180 68% 58%)',
  'hsl(210 68% 58%)',
  'hsl(240 68% 58%)',
  'hsl(270 68% 58%)',
  'hsl(300 68% 58%)',
  'hsl(330 68% 58%)',
];

Future<void> showProjectActions(
  BuildContext context,
  BrowserActionSession session,
) async {
  final choice = await showWorkspaceActionMenu(
    context,
    session.title,
    session.scope.profileName,
    [
      for (final choice in session.choices)
        (
          choice.action == BrowserAction.newChat ? 'new' : choice.action.name,
          choice.label,
          switch (choice.action) {
            BrowserAction.newChat => WingIcons.newChat,
            BrowserAction.editProject => Icons.edit_outlined,
            _ => Icons.delete_outline,
          },
          choice.enabled,
        ),
    ],
    keyPrefix: 'project-action',
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'new') {
    if (!await session.perform(BrowserAction.newChat) &&
        session.state.error != null) {
      throw StateError(session.state.error!);
    }
    return;
  }
  final action = BrowserAction.values.byName(choice);
  if (action == BrowserAction.editProject) {
    await showDialog<void>(
      context: context,
      builder: (_) => ProjectEditorDialog.edit(
        project: session.project!,
        createFolders: session.createFilesBrowser,
        save: (draft) async {
          final saved = await session.perform(
            BrowserAction.editProject,
            name: draft.name,
            path: draft.replaceFolder ? draft.path : null,
            color: draft.color,
            icon: draft.icon,
          );
          if (!saved) {
            throw StateError(
              session.state.error ?? 'Could not save the project. Try again.',
            );
          }
        },
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => _ProjectDeleteDialog(session: session),
  );
}

Widget projectAvatar(
  BuildContext context,
  BrowserProject project, {
  double size = 36,
}) {
  final scheme = Theme.of(context).colorScheme;
  final color = _parseProjectColor(project.color) ?? scheme.secondary;
  final icon = ProjectIconGlyphs.of(project.icon);
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: WingRadius.control,
    ),
    alignment: Alignment.center,
    child: Icon(icon, size: (size * 0.55).clamp(16.0, 24.0), color: color),
  );
}

class _ProjectDeleteDialog extends StatefulWidget {
  const _ProjectDeleteDialog({required this.session});
  final BrowserActionSession session;

  @override
  State<_ProjectDeleteDialog> createState() => _ProjectDeleteDialogState();
}

class _ProjectDeleteDialogState extends State<_ProjectDeleteDialog> {
  bool get _pending => widget.session.state.submitting;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  Future<void> _delete() async {
    if (await widget.session.perform(BrowserAction.delete) && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_pending,
    child: StudioDialog(
      scrollable: true,
      title: const Text('Delete project?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Remove "${widget.session.title}" from Hermes? Its chats will remain in Recents and All chats. Files on the host will not be deleted.',
          ),
          if (widget.session.state.error case final failure?) ...[
            const SizedBox(height: 12),
            StudioError(failure),
          ],
        ],
      ),
      actions: [
        StudioFormActions(
          onCancel: _pending ? null : () => Navigator.pop(context),
          onConfirm: _pending ? null : _delete,
          confirmKey: const ValueKey('project-delete-confirm'),
          confirmLabel: 'Delete project',
          confirmIcon: Icons.delete_outline,
          destructive: true,
          busy: _pending,
          progressLabel: 'Deleting project',
        ),
      ],
    ),
  );
}

class _ProjectAppearancePicker extends StatelessWidget {
  const _ProjectAppearancePicker({
    required this.color,
    required this.icon,
    required this.enabled,
    required this.onColor,
    required this.onIcon,
  });

  final String color;
  final String icon;
  final bool enabled;
  final ValueChanged<String> onColor;
  final ValueChanged<String> onIcon;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Color'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ChoiceButton(
            key: const ValueKey('project-color-none'),
            selected: color.isEmpty,
            label: 'Default color',
            onPressed: !enabled ? null : () => onColor(''),
            child: const Icon(Icons.block, size: 20),
          ),
          for (var index = 0; index < _projectColors.length; index++)
            _ChoiceButton(
              key: ValueKey('project-color-$index'),
              selected: color == _projectColors[index],
              label: 'Color ${index + 1}',
              onPressed: !enabled ? null : () => onColor(_projectColors[index]),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _parseProjectColor(_projectColors[index]),
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 20),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      const Text('Icon'),
      const SizedBox(height: 8),
      Row(
        children: [
          StudioButtonPress(
            child: IconButton(
              key: const ValueKey('project-choose-icon'),
              tooltip: 'Choose project icon',
              style: IconButton.styleFrom(
                backgroundColor:
                    (_parseProjectColor(color) ??
                            Theme.of(context).colorScheme.primary)
                        .withValues(alpha: .16),
                foregroundColor:
                    _parseProjectColor(color) ??
                    Theme.of(context).colorScheme.primary,
              ),
              onPressed: !enabled
                  ? null
                  : () async {
                      final chosen = await showProjectIconPicker(
                        context,
                        initialIcon: icon,
                        color: _parseProjectColor(color),
                      );
                      if (chosen != null && context.mounted) onIcon(chosen);
                    },
              icon: Icon(ProjectIconGlyphs.of(icon)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(projectIconLabel(icon))),
        ],
      ),
    ],
  );
}

/// Creation and editing share one name, primary-folder and appearance draft.
class ProjectEditorDialog extends StatefulWidget {
  const ProjectEditorDialog.create({
    super.key,
    required this.createFolders,
    required this.save,
    required Future<String> Function() this.loadDefaultFolder,
  }) : project = null;

  const ProjectEditorDialog.edit({
    super.key,
    required BrowserProject this.project,
    required this.createFolders,
    required this.save,
  }) : loadDefaultFolder = null;

  final Future<String> Function()? loadDefaultFolder;
  final BrowserProject? project;
  final ServerFilesBrowser Function() createFolders;
  final Future<void> Function(ProjectDraft) save;

  @override
  State<ProjectEditorDialog> createState() => _ProjectEditorDialogState();
}

class _ProjectEditorDialogState extends State<ProjectEditorDialog> {
  late final _name = TextEditingController(text: widget.project?.name ?? '');
  final _errorScroll = ScrollController();
  late final _location = TextEditingController(
    text: widget.project?.directory ?? '',
  );
  String get _path => _location.text.trim();
  String? _defaultFolder;
  bool _customFolder = false;
  bool _loadingFolder = false;
  String? _folderFailure;
  late String _color = widget.project?.color ?? '';
  late String _icon = widget.project?.icon ?? 'folder-library';
  bool get _editing => widget.project != null;
  bool _pending = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    if (!_editing) unawaited(_loadDefaultFolder());
  }

  Future<void> _loadDefaultFolder() async {
    setState(() {
      _loadingFolder = true;
      _folderFailure = null;
    });
    try {
      final folder = await widget.loadDefaultFolder!();
      if (!mounted) return;
      setState(() {
        _defaultFolder = folder;
        _suggestFolder();
      });
    } catch (_) {
      if (mounted && !_customFolder) {
        setState(() {
          _folderFailure =
              'Could not load the profile folder. Retry or choose a location.';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingFolder = false);
    }
  }

  void _suggestFolder() {
    final base = _defaultFolder;
    if (_editing || _customFolder || base == null) return;
    final folderName = _name.text
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (m) => '${m[1]}-${m[2]}',
        )
        .replaceAllMapped(
          RegExp(r'([A-Z])([A-Z][a-z])'),
          (m) => '${m[1]}-${m[2]}',
        )
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    _location.text = folderName.isEmpty
        ? base
        : ServerReferencePath.pathContext.join(base, folderName);
  }

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _errorScroll.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => ProjectFolderPickerDialog(
        createBrowser: widget.createFolders,
        initialPath: _editing || _customFolder
            ? (_path.isEmpty ? null : _path)
            : _defaultFolder,
      ),
    );
    if (!mounted || path == null) return;
    setState(() {
      _customFolder = true;
      _location.text = path;
      _folderFailure = null;
    });
  }

  Future<void> _save() async {
    if (_pending || _name.text.trim().isEmpty || _path.isEmpty) return;
    setState(() {
      _pending = true;
      _failure = null;
    });
    try {
      await widget.save((
        name: _name.text.trim(),
        path: _path,
        color: _color,
        icon: _icon,
        replaceFolder: !_editing || _customFolder,
      ));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = error is StateError
              ? error.message.toString()
              : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_pending,
    child: StudioDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(_editing ? 'Edit project' : 'New project'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                projectAvatar(
                  context,
                  BrowserProject(
                    id: 'draft',
                    name: _name.text,
                    color: _color,
                    icon: _icon,
                  ),
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: viewportSelection(
                    TextField(
                      key: const ValueKey('project-name-field'),
                      controller: _name,
                      enabled: !_pending,
                      maxLength: 200,
                      onChanged: (_) => setState(_suggestFolder),
                      decoration: const InputDecoration(
                        labelText: 'Project name',
                        counterText: '',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _editing
                      ? Text(
                          _path,
                          key: const ValueKey('project-chosen-folder'),
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : viewportSelection(
                          TextField(
                            key: const ValueKey('project-folder-field'),
                            controller: _location,
                            enabled: !_pending,
                            onChanged: (_) => setState(() {
                              _customFolder = true;
                              _folderFailure = null;
                            }),
                            decoration: const InputDecoration(
                              labelText: 'Folder location',
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                if (_loadingFolder)
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      value: MediaQuery.disableAnimationsOf(context)
                          ? .75
                          : null,
                      strokeWidth: 2,
                      semanticsLabel: 'Loading profile folder',
                    ),
                  ),
                StudioButtonPress(
                  child: IconButton.outlined(
                    key: const ValueKey('project-choose-folder'),
                    tooltip: _editing
                        ? 'Change project folder'
                        : 'Choose project folder',
                    onPressed: _pending ? null : _chooseFolder,
                    icon: const Icon(Icons.folder_open_outlined),
                  ),
                ),
              ],
            ),
            if (_folderFailure case final failure?)
              Row(
                children: [
                  Expanded(child: StudioError(failure)),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Retry profile folder',
                      onPressed: _loadingFolder || _pending
                          ? null
                          : () => unawaited(_loadDefaultFolder()),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                ],
              ),
            if (_editing) ...[
              const SizedBox(height: 4),
              Text(
                'Choosing a folder replaces the project’s folder links. Chats keep their working folders.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 20),
            _ProjectAppearancePicker(
              color: _color,
              icon: _icon,
              enabled: !_pending,
              onColor: (value) => setState(() => _color = value),
              onIcon: (value) => setState(() => _icon = value),
            ),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_failure != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: Scrollbar(
                    controller: _errorScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      key: const ValueKey('project-save-error'),
                      controller: _errorScroll,
                      primary: false,
                      child: DefaultTextStyle.merge(
                        style: Theme.of(context).textTheme.bodySmall,
                        child: StudioError(_failure!),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              StudioFormActions(
                onCancel: _pending ? null : () => Navigator.pop(context),
                onConfirm:
                    _pending || _name.text.trim().isEmpty || _path.isEmpty
                    ? null
                    : _save,
                confirmLabel: _editing ? 'Save changes' : 'Create project',
                busy: _pending,
                progressLabel: _editing ? 'Saving project' : 'Creating project',
                confirmKey: ValueKey(
                  _editing ? 'project-edit-confirm' : 'project-create-confirm',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    super.key,
    required this.selected,
    required this.label,
    required this.onPressed,
    required this.child,
  });

  final bool selected;
  final String label;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    selected: selected,
    child: StudioButtonPress(
      child: IconButton(
        tooltip: label,
        isSelected: selected,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
          ),
          side: WidgetStateProperty.resolveWith((states) {
            final colors = Theme.of(context).colorScheme;
            if (states.contains(WidgetState.disabled)) {
              return BorderSide(color: colors.outlineVariant);
            }
            if (states.contains(WidgetState.focused)) {
              return BorderSide(color: colors.primary, width: 3);
            }
            return null;
          }),
        ),
        onPressed: onPressed,
        icon: child,
      ),
    ),
  );
}

Color? _parseProjectColor(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').firstMatch(value);
  if (hex != null) {
    var digits = hex.group(1)!;
    if (digits.length == 3) {
      digits = digits.split('').map((digit) => '$digit$digit').join();
    }
    return Color(0xff000000 | int.parse(digits, radix: 16));
  }
  final hsl = RegExp(
    r'^hsl\(\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(\d+(?:\.\d+)?)%\s*[, ]\s*(\d+(?:\.\d+)?)%\s*\)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (hsl == null) return null;
  final hue = double.parse(hsl.group(1)!) % 360;
  final saturation = double.parse(hsl.group(2)!).clamp(0, 100) / 100;
  final lightness = double.parse(hsl.group(3)!).clamp(0, 100) / 100;
  return HSLColor.fromAHSL(
    1,
    hue < 0 ? hue + 360 : hue,
    saturation,
    lightness,
  ).toColor();
}
