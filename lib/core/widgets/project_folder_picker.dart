import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/server_reference.dart';
import '../services/server_files_browser.dart';
import '../theme/wing_theme.dart';
import 'composer_icon_button.dart';
import 'studio_error.dart';
import 'studio_loading.dart';

/// Folder-selection presentation over the shared server filesystem browser.
class ProjectFolderPickerDialog extends StatefulWidget {
  const ProjectFolderPickerDialog({
    super.key,
    required this.createBrowser,
    this.initialPath,
  });
  final ServerFilesBrowser Function() createBrowser;
  final String? initialPath;

  @override
  State<ProjectFolderPickerDialog> createState() =>
      _ProjectFolderPickerDialogState();
}

class _ProjectFolderPickerDialogState extends State<ProjectFolderPickerDialog> {
  late final ServerFilesBrowser _browser;
  final _name = TextEditingController();
  final _scroll = ScrollController();
  final _errorKey = GlobalKey();
  bool _naming = false;

  @override
  void initState() {
    super.initState();
    _browser = widget.createBrowser();
    unawaited(_browser.open(widget.initialPath));
  }

  @override
  void dispose() {
    _browser.dispose();
    _name.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final created = await _browser.createFolder(_name.text);
    if (!mounted) return;
    if (created) {
      setState(() => _naming = false);
      _name.clear();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final errorContext = _errorKey.currentContext;
        if (errorContext != null) {
          unawaited(Scrollable.ensureVisible(errorContext));
        }
      });
    }
  }

  Widget _tools() => Row(
    children: [
      StudioButtonPress(
        child: IconButton(
          key: const ValueKey('project-folder-up'),
          tooltip: 'Up one level',
          onPressed: _browser.busy || _browser.directory?.parent == null
              ? null
              : () => unawaited(_browser.up()),
          icon: const Icon(Icons.arrow_upward),
        ),
      ),
      StudioButtonPress(
        child: IconButton(
          key: const ValueKey('project-folder-home'),
          tooltip: 'Browse Hermes folders',
          onPressed: _browser.busy ? null : () => unawaited(_browser.open()),
          icon: const Icon(Icons.home_outlined),
        ),
      ),
      const Spacer(),
      StudioButtonPress(
        child: IconButton(
          tooltip: _naming ? 'Close new folder' : 'New folder',
          onPressed: !_browser.canCreate
              ? null
              : () => setState(() => _naming = !_naming),
          icon: ComposerActionGlyph(
            icon: _naming ? Icons.close : Icons.create_new_folder_outlined,
            identity: _naming ? 'stop' : 'new-folder',
          ),
        ),
      ),
      StudioButtonPress(
        child: IconButton(
          tooltip: 'Refresh folders',
          onPressed: _browser.busy ? null : () => unawaited(_browser.refresh()),
          icon: const Icon(Icons.refresh),
        ),
      ),
    ],
  );

  Widget _folder(ServerReferenceEntry folder) => StudioButtonPress(
    child: ListTile(
      key: ValueKey('project-folder-${folder.path}'),
      contentPadding: EdgeInsets.zero,
      visualDensity: const VisualDensity(vertical: -2),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .14),
          borderRadius: WingRadius.control,
        ),
        child: Icon(
          Icons.folder_outlined,
          color: Theme.of(context).colorScheme.primary,
          size: 22,
        ),
      ),
      title: Text(folder.name),
      trailing: const Icon(Icons.chevron_right),
      onTap: _browser.busy ? null : () => unawaited(_browser.open(folder.path)),
    ),
  );

  Widget _body() => Scrollbar(
    controller: _scroll,
    thumbVisibility: true,
    child: CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message: _browser.displayedPath ?? 'Hermes folders',
                child: Text(
                  _browser.displayedPath ?? 'Hermes folders',
                  key: const ValueKey('project-folder-location'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              _tools(),
              if (_naming) ...[
                Row(
                  children: [
                    Expanded(
                      child: viewportSelection(
                        TextField(
                          key: const ValueKey('project-new-folder-name'),
                          controller: _name,
                          enabled: !_browser.busy,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => unawaited(_createFolder()),
                          decoration: const InputDecoration(
                            labelText: 'Folder name',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StudioButtonPress(
                      child: IconButton.filled(
                        key: const ValueKey('project-new-folder-create'),
                        tooltip: 'Create folder',
                        onPressed: _browser.busy || _name.text.trim().isEmpty
                            ? null
                            : () => unawaited(_createFolder()),
                        icon: const Icon(Icons.check),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_browser.error case final error?)
                Row(
                  key: _errorKey,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: Theme.of(context).textTheme.bodySmall,
                        child: StudioError(error),
                      ),
                    ),
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Retry folder loading',
                        onPressed: _browser.busy
                            ? null
                            : () => unawaited(_browser.retry()),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ],
                ),
              const Divider(height: 16),
            ],
          ),
        ),
        if (_browser.directory != null &&
            !(_browser.busy &&
                _browser.displayedPath != _browser.directory?.path))
          if (_browser.folders.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No folders here')),
            )
          else
            SliverList.builder(
              itemCount: _browser.folders.length,
              itemBuilder: (_, index) => _folder(_browser.folders[index]),
            ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _browser,
    builder: (context, _) => PopScope(
      canPop: !_browser.creating,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: StudioLoadingFrame(
          child: StudioLoadingRegion(
            busy: _browser.busy,
            available: !_browser.busy,
            label: _browser.creating ? 'Creating folder' : 'Loading folders',
            child: SizedBox(
              width: 440,
              height: MediaQuery.sizeOf(context).height * .9,
              child: Padding(
                padding: const EdgeInsets.all(WingSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StudioFormHeader(
                      title: const Text(
                        'Choose folder',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(child: _body()),
                    const Divider(height: WingSpacing.sm),
                    StudioFormActions(
                      cancelLabel: 'Cancel folder selection',
                      onCancel: _browser.creating
                          ? null
                          : () => Navigator.pop(context),
                      onConfirm: _browser.canSelect && !_naming
                          ? () =>
                                Navigator.pop(context, _browser.directory!.path)
                          : null,
                      confirmKey: const ValueKey('project-folder-continue'),
                      confirmLabel: 'Use this folder',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
