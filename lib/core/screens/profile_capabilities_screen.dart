import '../widgets/selection_viewport.dart';
import '../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/wing_app_bar.dart';
import '../widgets/activity/skill_document_viewer.dart';
import '../widgets/studio_error.dart';
import 'package:flutter/material.dart';

import '../models/profile_capabilities.dart';
import '../services/profile_capabilities_session.dart';
import '../widgets/compact_switch.dart';
import '../widgets/studio_select.dart';
import '../presentation/skill_document.dart';

/// Controls the capabilities of the captured server profile, never a chat override.
class ProfileCapabilitiesScreen extends StatefulWidget {
  const ProfileCapabilitiesScreen({
    required this.createSession,
    required this.connectionLabel,
    required this.onToolSetup,
    required this.onLibrary,
    required this.onHub,
    required this.onPlugins,
    required this.onConnectedApps,
    required this.onMcpConnectors,
    super.key,
  });

  final ProfileCapabilitiesSession Function() createSession;
  final String connectionLabel;
  final Future<void> Function(String name) onToolSetup;
  final Future<void> Function() onLibrary;
  final Future<void> Function() onHub;
  final Future<void> Function() onPlugins;
  final Future<void> Function() onConnectedApps;
  final Future<void> Function() onMcpConnectors;

  @override
  State<ProfileCapabilitiesScreen> createState() =>
      _ProfileCapabilitiesScreenState();
}

class _ProfileCapabilitiesScreenState extends State<ProfileCapabilitiesScreen> {
  late final _session = widget.createSession();
  ProfileCapabilityKind _kind = ProfileCapabilityKind.tools;
  String _query = '';
  ProfileCapabilityFilter _filter = ProfileCapabilityFilter.all;
  ProfileCapabilitiesState get _state => _session.state;
  bool get _skills => _kind == ProfileCapabilityKind.skills;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _session.load(_kind);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  Future<bool> _confirmEnable(ProfileCapability row) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: Text('Enable ${row.title}?'),
          content: const Text(
            'This toolset still needs setup. Hermes may start its existing setup process on the server. Enabling it does not guarantee it is ready.',
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Enable capability',
              confirmIcon: Icons.toggle_on_outlined,
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _readSkill(String name) async {
    try {
      final instructions = await _session.instructions(name);
      if (!mounted || instructions == null) return;
      final document = SkillDocument.fromReceived(
        name: instructions.name,
        content: instructions.content,
        sourcePath: instructions.sourcePath,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SkillDocumentViewer(
            document: document,
            createReader: () => _session.reader(document.readerTarget),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      showStudioError(
        context,
        'Could not read this skill. Check the connection and try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadataStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rows = _state.rows
        .where(
          (row) =>
              row.matches(_query) && (_skills || row.matchesFilter(_filter)),
        )
        .toList();
    return Scaffold(
      appBar: WingAppBar(
        context: context,

        title: const Text('Skills and tools', maxLines: 6, softWrap: true),
        actions: [
          StudioButtonPress(
            child: PopupMenuButton<String>(
              tooltip: 'Manage capabilities',
              onSelected: (value) async {
                switch (value) {
                  case 'discover':
                    await widget.onHub();
                  case 'library':
                    await widget.onLibrary();
                  case 'plugins':
                    await widget.onPlugins();
                  case 'apps':
                    await widget.onConnectedApps();
                  case 'mcp':
                    await widget.onMcpConnectors();
                }
                if (mounted) await _session.load(_kind);
              },
              itemBuilder: (_) => const [
                StudioPopupMenuItem(
                  value: 'discover',
                  child: Text('Discover skills'),
                ),
                StudioPopupMenuItem(
                  value: 'library',
                  child: Text('Skill library'),
                ),
                StudioPopupMenuItem(
                  value: 'plugins',
                  child: Text('Agent plugins'),
                ),
                StudioPopupMenuItem(
                  value: 'apps',
                  child: Text('Connected apps'),
                ),
                StudioPopupMenuItem(
                  value: 'mcp',
                  child: Text('MCP connectors'),
                ),
              ],
            ),
          ),
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Refresh capabilities',
              onPressed: _state.loading || _state.busy
                  ? null
                  : () => _session.load(_kind),
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: StudioPageLoading(
              active: _state.loading || _state.saving,
              label: 'Loading capabilities',
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${widget.connectionLabel} · ${_session.profileName}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Changes are saved on Hermes and affect other clients using this profile.',
                          style: metadataStyle,
                        ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) =>
                              SegmentedButton<ProfileCapabilityKind>(
                                showSelectedIcon: false,
                                direction:
                                    constraints.maxWidth <
                                        MediaQuery.textScalerOf(
                                          context,
                                        ).scale(300)
                                    ? Axis.vertical
                                    : Axis.horizontal,
                                segments: const [
                                  ButtonSegment(
                                    value: ProfileCapabilityKind.tools,
                                    label: Text('Capabilities'),
                                  ),
                                  ButtonSegment(
                                    value: ProfileCapabilityKind.skills,
                                    label: Text('Installed skills'),
                                  ),
                                ],
                                selected: {_kind},
                                onSelectionChanged: _state.busy
                                    ? null
                                    : (value) {
                                        setState(() => _kind = value.single);
                                        _session.load(_kind);
                                      },
                              ),
                        ),
                        const SizedBox(height: 12),
                        viewportSelection(
                          TextField(
                            decoration: InputDecoration(
                              hintText: _kind == ProfileCapabilityKind.tools
                                  ? 'Find a capability'
                                  : 'Find a skill',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (value) =>
                                setState(() => _query = value),
                          ),
                        ),
                        if (!_skills) ...[
                          const SizedBox(height: 12),
                          StudioSelect<ProfileCapabilityFilter>(
                            value: _filter,
                            label: 'Show capabilities',
                            options: const [
                              (
                                value: ProfileCapabilityFilter.all,
                                label: 'All capabilities',
                              ),
                              (
                                value: ProfileCapabilityFilter.enabled,
                                label: 'Enabled',
                              ),
                              (
                                value: ProfileCapabilityFilter.needsSetup,
                                label: 'Needs setup',
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _filter = value);
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_state.notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(_state.notice!),
                    ),
                  if (_state.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          StudioError(_state.error!),
                          StudioButtonPress(
                            child: TextButton(
                              onPressed: _state.loading || _state.busy
                                  ? null
                                  : () => _session.load(_kind),
                              child: const Text('Retry'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!_state.loading && rows.isEmpty && _state.error == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  _query.isEmpty &&
                          (_skills || _filter == ProfileCapabilityFilter.all)
                      ? 'No ${_skills ? 'skills' : 'tools'} returned by this profile.'
                      : 'No matching capabilities.',
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                final name = row.name;
                final title = row.title;
                final tools = row.tools;
                final group = row.group;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_skills &&
                        (index == 0 || rows[index - 1].group != group))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          switch (group) {
                            ProfileCapabilityGroup.needsSetup => 'Needs setup',
                            ProfileCapabilityGroup.enabled =>
                              'Enabled capabilities',
                            ProfileCapabilityGroup.disabled => 'Not enabled',
                          },
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ExpansionTile(
                      key: ValueKey((_kind, name)),
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      minTileHeight: 56,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      title: Text(title, style: theme.textTheme.bodyLarge),
                      subtitle: Text(row.subtitle(_kind), style: metadataStyle),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_skills)
                            SizedBox.square(
                              dimension: 48,
                              child: StudioButtonPress(
                                child: IconButton(
                                  tooltip: 'Read instructions for $title',
                                  onPressed: () => _readSkill(name),
                                  icon: const Icon(Icons.visibility_outlined),
                                ),
                              ),
                            ),
                          CompactSwitch(
                            semanticLabel: 'Enable $title',
                            value: row.enabled,
                            onChanged: !_state.canToggle
                                ? null
                                : (value) => _session.toggle(
                                    _kind,
                                    name,
                                    value,
                                    confirm: _confirmEnable,
                                  ),
                          ),
                        ],
                      ),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.description),
                        if (!_skills)
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Setup and providers for $title',
                              onPressed: _state.busy
                                  ? null
                                  : () => _session.reviewSetup(
                                      name,
                                      widget.onToolSetup,
                                    ),
                              icon: const Icon(Icons.tune, size: 18),
                            ),
                          ),
                        if (!_skills && row.hasTools) ...[
                          const SizedBox(height: 8),
                          viewportSelection(SelectableText(tools.join(', '))),
                        ],
                      ],
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
