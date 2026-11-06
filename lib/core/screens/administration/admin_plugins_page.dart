import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../models/profile_plugins.dart';
import '../../services/profile_plugins_session.dart';
import '../../widgets/compact_switch.dart';
import '../../widgets/read_recovery.dart';
import 'admin_widgets.dart';

class AdminPluginsPage extends StatefulWidget {
  const AdminPluginsPage({super.key, required this.createSession});
  final ProfilePluginsSession Function() createSession;
  @override
  State<AdminPluginsPage> createState() => _AdminPluginsPageState();
}

class _AdminPluginsPageState extends State<AdminPluginsPage> {
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

  Future<void> _choose(ProfilePlugin row, bool enabled) async {
    await _session.toggle(row, enabled);
    if (!mounted) {
      return;
    }
    final state = _session.state;
    if (state.error != null) {
      adminMessage(context, state.error!, isError: true);
    } else if (state.acknowledgement?.restartRequired == true) {
      adminMessage(
        context,
        'Plugin change saved. Restart Hermes to apply it to running handlers.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Agent plugins',
    scope: _session.scopeLabel,
    child: ReadRecovery(
      shouldRetry: () => _session.canRecover,
      retry: _session.refresh,
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final state = _session.state;
          return StudioPageLoading(
            active: state.busy,
            label: switch (state.phase) {
              ProfilePluginsPhase.updating => 'Updating installed plugins',
              ProfilePluginsPhase.saving => 'Saving plugin setting',
              _ => 'Refreshing plugins',
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (state.error != null) AdminNotice.error(state.error!),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Update installed plugins',
                        onPressed: state.canUpdate
                            ? _session.updateInstalled
                            : null,
                        icon: const Icon(Icons.system_update_alt),
                      ),
                    ),
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Refresh plugins',
                        onPressed: state.canRefresh ? _session.refresh : null,
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ],
                ),
                if (state.maintenance == null)
                  const AdminNotice(
                    'Held installs stay unchanged. Updates needing review are skipped.',
                  ),
                if (state.maintenance case final result?)
                  _MaintenanceResults(result: result),
                if (state.verified && state.rows.isEmpty)
                  const AdminNotice('No agent plugins reported.'),
                AdminGroup(
                  children: [
                    for (final row in state.rows)
                      CompactSwitchListTile(
                        title: Text(row.name),
                        subtitle: Text(
                          [
                            '${row.source} · ${row.status.label}',
                            if (row.version.isNotEmpty)
                              'Version ${row.version}',
                            if (row.updateAvailable == true)
                              'Update available${(row.catalogVersion ?? row.updateTarget) == null ? '' : ': ${row.catalogVersion ?? row.updateTarget}'}',
                            if (row.pinnedSha case final pin?
                                when pin.isNotEmpty)
                              'Pinned to $pin',
                            row.description,
                          ].join('\n'),
                        ),
                        value: row.enabled,
                        onChanged: state.canToggle
                            ? (value) => _choose(row, value)
                            : null,
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _MaintenanceResults extends StatelessWidget {
  const _MaintenanceResults({required this.result});
  final PluginMaintenanceResult result;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        liveRegion: true,
        child: AdminNotice(
          '${result.updated} updated · ${result.alreadyCurrent} already current',
        ),
      ),
      AdminGroup(
        children: [
          for (final row in result.results)
            ListTile(
              title: Text(row.name),
              subtitle: Text(
                [
                  row.status.label,
                  if (row.detail.isNotEmpty) row.detail,
                ].join('\n'),
              ),
            ),
          for (final row in result.skipped)
            ListTile(
              title: Text(row.name),
              subtitle: Text('Skipped · ${row.reason}'),
            ),
        ],
      ),
      if (result.needsReview)
        const AdminNotice(
          'Review these updates with hermes plugins update <name> on the server.',
        ),
      if (result.updated > 0)
        const AdminNotice(
          'Updated plugins were reloaded. New Python tools apply to new sessions.',
        ),
    ],
  );
}
