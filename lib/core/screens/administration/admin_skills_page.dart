import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/activity/activity_detail_actions.dart';
import '../../widgets/activity/skill_document_viewer.dart';
import 'package:flutter/material.dart';
import '../../models/profile_skills.dart';
import '../../presentation/skill_document.dart';
import '../../theme/wing_theme.dart';
import '../../services/profile_skills_session.dart';
import '../../services/administration_operation_session.dart';
import '../../widgets/compact_switch.dart';
import '../../widgets/read_recovery.dart';
import 'admin_widgets.dart';
import 'admin_operations_page.dart';

Future<void> _showResult(
  BuildContext context,
  ProfileSkillsSession session,
  AdministrationOperationSession operation,
  String title,
) => adminPush(
  context,
  (context) => AdminActionPage(
    operation: operation,
    title: title,
    scope: session.scopeLabel,
  ),
);

class AdminSkillLibraryPage extends StatefulWidget {
  const AdminSkillLibraryPage({super.key, required this.createSession});
  final ProfileSkillsSession Function() createSession;
  @override
  State<AdminSkillLibraryPage> createState() => _AdminSkillLibraryPageState();
}

class _AdminSkillLibraryPageState extends State<AdminSkillLibraryPage> {
  late final _session = widget.createSession();
  final _search = TextEditingController();
  String _query = '';
  bool _usageOrder = false;
  @override
  void initState() {
    super.initState();
    _session.refresh();
  }

  @override
  void dispose() {
    _session.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(InstalledSkill skill) async {
    final route = _session.openSkill(skill);
    try {
      await adminPush(
        context,
        (_) => AdminSkillDetail(session: _session, route: route),
      );
    } finally {
      _session.releaseDetail(route);
    }
    await _session.refresh();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Skill library',
    scope: _session.scopeLabel,
    child: _SkillsRead(
      session: _session,
      retry: _session.refresh,
      builder: (state) {
        final rows = [...state.installed];
        if (_usageOrder) rows.sort((a, b) => b.usage.compareTo(a.usage));
        final matches = rows.where((s) => s.matches(_query)).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            viewportSelection(
              TextField(
                controller: _search,
                decoration: const InputDecoration(
                  labelText: 'Search installed skills',
                ),
                onChanged: (value) =>
                    setState(() => _query = value.toLowerCase()),
              ),
            ),
            CompactSwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Order by recorded usage'),
              value: _usageOrder,
              onChanged: (value) => setState(() => _usageOrder = value),
            ),
            for (final skill in matches)
              StudioButtonPress(
                child: ListTile(
                  title: Text(skill.name),
                  subtitle: Text(
                    '${skill.provenance} · ${skill.usage} recorded uses${skill.locked ? ' · Locked against agent edits' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: state.canMutate ? () => _open(skill) : null,
                ),
              ),
            if (rows.isEmpty)
              const AdminNotice('No skills reported for this profile.')
            else if (matches.isEmpty) ...[
              const AdminNotice('No installed skills match this search.'),
              StudioButtonPress(
                child: TextButton(
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                  child: const Text('Clear search'),
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class AdminSkillDetail extends StatefulWidget {
  const AdminSkillDetail({
    super.key,
    required this.session,
    required this.route,
  });
  final ProfileSkillsSession session;
  final SkillDetailRoute route;
  @override
  State<AdminSkillDetail> createState() => _AdminSkillDetailState();
}

class _AdminSkillDetailState extends State<AdminSkillDetail> {
  late final _session = widget.session;
  late final _route = widget.route;
  @override
  void initState() {
    super.initState();
    _session.loadDetail(_route);
  }

  @override
  void dispose() {
    _session.releaseDetail(_route);
    super.dispose();
  }

  Future<void> _edit() async {
    final editor = _session.openEditor(_route);
    try {
      await adminPush(
        context,
        (_) =>
            AdminSkillEditor(session: _session, route: editor, detail: _route),
      );
    } finally {
      _session.releaseEditor(editor);
    }
    await _session.loadDetail(_route);
  }

  Future<void> _archive() async {
    final removed = await _session.archive(
      _route,
      () => adminConfirm(
        context,
        'Archive ${_route.skill.name}?',
        'Move this local or learned skill out of the active skill library for ${_session.profileName}.',
        action: 'Archive',
        actionIcon: Icons.archive_outlined,
        destructive: true,
      ),
    );
    if (!mounted) return;
    if (removed) {
      Navigator.pop(context);
    } else if (_session.state.error case final error?) {
      adminMessage(context, error, isError: true);
    }
  }

  Future<void> _uninstall() => _session.uninstall(
    _route,
    confirm: () => adminConfirm(
      context,
      'Uninstall ${_route.skill.name}?',
      'Remove this Hub skill from ${_session.profileName}.',
      action: 'Uninstall',
      actionIcon: Icons.delete_outline,
      destructive: true,
    ),
    showResult: (operation) async {
      if (mounted) {
        await _showResult(context, _session, operation, 'Uninstall skill');
      }
    },
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.state;
      final instructions = state.instructions;
      if (instructions == null) {
        return AdminPage(
          title: _route.skill.name,
          scope: _session.scopeLabel,
          child: _SkillsRead(
            session: _session,
            retry: () => _session.loadDetail(_route),
            builder: (_) => const SizedBox.shrink(),
          ),
        );
      }
      final current = _session.currentSkill(_route) ?? _route.skill;
      final document = SkillDocument.fromReceived(
        name: instructions.name,
        content: instructions.content,
        sourcePath: instructions.sourcePath,
        description: current.description,
      );
      return SkillDocumentViewer(
        document: document,
        createReader: () => _session.reader(document.readerTarget),
        actions: [
          ActivityDetailAction(
            label: current.locked
                ? 'Unlock agent edits'
                : 'Lock against agent edits',
            icon: current.locked
                ? Icons.lock_outline
                : Icons.lock_open_outlined,
            onPressed: _session.canSetLocked(_route)
                ? () async {
                    await _session.setLocked(_route, !current.locked);
                  }
                : null,
          ),
          if (current.editable) ...[
            ActivityDetailAction(
              label: 'Edit instructions',
              icon: Icons.edit_outlined,
              onPressed: _session.canEdit(_route) ? _edit : null,
            ),
            ActivityDetailAction(
              label: 'Archive skill',
              icon: Icons.archive_outlined,
              onPressed: _session.canEdit(_route) ? _archive : null,
            ),
          ],
          if (current.uninstallable)
            ActivityDetailAction(
              label: 'Uninstall Hub skill',
              icon: Icons.delete_outline,
              onPressed: _session.canUninstall(_route) ? _uninstall : null,
            ),
          ActivityDetailAction(
            label: 'Refresh skill',
            icon: Icons.refresh,
            onPressed: state.busy ? null : () => _session.loadDetail(_route),
          ),
        ],
        bodyBuilder: (context, body) => StudioPageLoading(
          active: state.saving || state.phase == SkillsPhase.reading,
          label: state.saving ? 'Saving skill' : 'Refreshing skill',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WingSpacing.md,
                  vertical: WingSpacing.xs,
                ),
                child: Text(
                  current.locked
                      ? 'Locked against agent edits'
                      : 'Agent edits are not locked',
                ),
              ),
              Expanded(
                child: _SkillsRead(
                  session: _session,
                  retry: () => _session.loadDetail(_route),
                  builder: (_) => body,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class AdminSkillEditor extends StatefulWidget {
  const AdminSkillEditor({
    super.key,
    required this.session,
    required this.route,
    required this.detail,
  });
  final ProfileSkillsSession session;
  final SkillEditorRoute route;
  final SkillDetailRoute detail;
  @override
  State<AdminSkillEditor> createState() => _AdminSkillEditorState();
}

class _AdminSkillEditorState extends State<AdminSkillEditor> {
  late final _session = widget.session;
  late final _route = widget.route;
  late final _detail = widget.detail;
  late final _input = TextEditingController(text: _route.initial);
  @override
  void dispose() {
    _session.releaseEditor(_route);
    _input.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (await _session.requestClose(
          _route,
          () => adminConfirm(
            context,
            'Discard instruction edits?',
            'The unsaved instructions will be discarded.',
            action: 'Discard',

            actionIcon: Icons.delete_outline,
            destructive: true,
          ),
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _save() async {
    await _session.save(_route);
    if (mounted) {
      if (_session.state.notice case final notice?) {
        adminMessage(context, notice);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.state;
      return PopScope(
        canPop: state.canPopEditor,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: AdminPage(
          title: 'Edit ${_route.name}',
          scope: _session.scopeLabel,
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: StudioFormActions(
                onCancel: state.busy ? null : _close,
                onConfirm: state.canSave ? _save : null,
                confirmLabel: 'Save skill',
                busy: state.saving,
                progressLabel: 'Saving skill',
              ),
            ),
          ),
          child: Column(
            children: [
              if (state.error ?? state.edit?.validationError case final error?)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: AdminNotice.error(
                      error,
                      retry: state.busy
                          ? null
                          : () => _session.loadDetail(_detail),
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: viewportSelection(
                    TextField(
                      controller: _input,
                      enabled: !state.busy,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        labelText: 'Instructions',
                      ),
                      onChanged: (value) => _session.edit(_route, value),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class AdminSkillHubPage extends StatefulWidget {
  const AdminSkillHubPage({super.key, required this.createSession});
  final ProfileSkillsSession Function() createSession;
  @override
  State<AdminSkillHubPage> createState() => _AdminSkillHubPageState();
}

class _AdminSkillHubPageState extends State<AdminSkillHubPage> {
  late final _session = widget.createSession();
  @override
  void initState() {
    super.initState();
    _session.refresh();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _open(HubSkill skill) async {
    final route = _session.openPreview(skill);
    try {
      await adminPush(
        context,
        (_) => AdminSkillPreview(session: _session, route: route),
      );
    } finally {
      _session.releasePreview(route);
    }
    await _session.refresh();
  }

  Future<void> _update() => _session.update(
    confirm: () => adminConfirm(
      context,
      'Update installed Hub skills?',
      'Hermes will update installed Hub skills in ${_session.profileName} as a group.',
      action: 'Update skills',
      actionIcon: Icons.system_update_alt,
      destructive: false,
    ),
    showResult: (operation) async {
      if (mounted) {
        await _showResult(context, _session, operation, 'Update skills');
      }
    },
  );
  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Skill Hub',
    scope: _session.scopeLabel,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: viewportSelection(
            TextField(
              decoration: const InputDecoration(
                labelText: 'Search catalogs',
                helperMaxLines: 4,
                helperText: 'Submit to search configured sources.',
              ),
              onSubmitted: (value) => _session.refresh(query: value),
            ),
          ),
        ),
        Expanded(
          child: _SkillsRead(
            session: _session,
            retry: _session.refresh,
            builder: (state) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                StudioButtonPress(
                  child: TextButton(
                    onPressed: state.canMutate ? _update : null,
                    child: const Text('Update installed Hub skills'),
                  ),
                ),
                if (state.partial)
                  const AdminNotice(
                    'Some sources did not respond. Showing partial results.',
                  ),
                if (state.catalog.isEmpty)
                  const AdminNotice('No skills found.'),
                for (final skill in state.catalog)
                  StudioButtonPress(
                    child: ListTile(
                      title: Text(skill.name),
                      subtitle: Text('${skill.source} · ${skill.description}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: state.canMutate ? () => _open(skill) : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class AdminSkillPreview extends StatefulWidget {
  const AdminSkillPreview({
    super.key,
    required this.session,
    required this.route,
  });
  final ProfileSkillsSession session;
  final SkillPreviewRoute route;
  @override
  State<AdminSkillPreview> createState() => _AdminSkillPreviewState();
}

class _AdminSkillPreviewState extends State<AdminSkillPreview> {
  late final _session = widget.session;
  late final _route = widget.route;
  @override
  void initState() {
    super.initState();
    _session.loadPreview(_route);
  }

  @override
  void dispose() {
    _session.releasePreview(_route);
    super.dispose();
  }

  Future<void> _install() => _session.install(
    _route,
    confirm: () => adminConfirm(
      context,
      'Install this skill?',
      'Install ${_route.skill.identifier} into ${_session.profileName}. Review its source and instructions first.',
      action: 'Install',
      actionIcon: Icons.download_outlined,
      destructive: false,
    ),
    showResult: (operation) async {
      if (mounted) {
        await _showResult(context, _session, operation, 'Install skill');
      }
    },
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.state;
      final preview = state.preview;
      if (preview == null) {
        return AdminPage(
          title: 'Skill preview',
          scope: _session.scopeLabel,
          child: _SkillsRead(
            session: _session,
            retry: () => _session.loadPreview(_route),
            builder: (_) => const SizedBox.shrink(),
          ),
        );
      }
      final document = SkillDocument.fromReceived(
        name: preview.name,
        content: preview.content,
        description: _route.skill.description,
      );
      return SkillDocumentViewer(
        document: document,
        actions: [
          ActivityDetailAction(
            label: 'Install skill',
            icon: Icons.download_outlined,
            busy: state.saving,
            onPressed: state.canMutate ? _install : null,
          ),
        ],
        bodyBuilder: (context, body) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(WingSpacing.sm),
              child: Text(
                '${_session.scopeLabel} · ${preview.source} · ${preview.trust}',
                style: WingTokens.of(context).typography.label.copyWith(
                  color: WingTokens.of(context).muted,
                ),
              ),
            ),
            Expanded(
              child: _SkillsRead(
                session: _session,
                retry: () => _session.loadPreview(_route),
                builder: (_) => body,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Read progress/recovery are presentation; the session decides retry eligibility.
class _SkillsRead extends StatelessWidget {
  const _SkillsRead({
    required this.session,
    required this.retry,
    required this.builder,
  });
  final ProfileSkillsSession session;
  final Future<void> Function() retry;
  final Widget Function(ProfileSkillsState) builder;
  @override
  Widget build(BuildContext context) => ReadRecovery(
    shouldRetry: () => session.canRecoverRead,
    retry: retry,
    child: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.state;
        return StudioLoadingRegion(
          available: state.hasObservation,
          busy: state.phase == SkillsPhase.reading || state.saving,
          label: 'Loading skills',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.error case final error?)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AdminNotice.error(
                      error,
                      retry: state.busy ? null : retry,
                    ),
                  ),
                ),
              if (state.notice case final notice?)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AdminNotice(notice),
                ),
              if (state.hasObservation)
                Expanded(key: const ValueKey('content'), child: builder(state)),
            ],
          ),
        );
      },
    ),
  );
}
