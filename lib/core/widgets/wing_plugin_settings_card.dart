import 'dart:async';
import 'package:flutter/material.dart';
import '../services/wing_plugin_session.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'studio_form_actions.dart';
import 'studio_loading.dart';

/// Presentation only; the captured session owns inventory and command admission.
class WingPluginSettingsCard extends StatefulWidget {
  const WingPluginSettingsCard({super.key, required this.createSession});
  final WingPluginSession Function() createSession;
  @override
  State<WingPluginSettingsCard> createState() => _WingPluginSettingsCardState();
}

class _WingPluginSettingsCardState extends State<WingPluginSettingsCard> {
  late final WingPluginSession _session = widget.createSession();
  @override
  void initState() {
    super.initState();
    unawaited(_session.refresh(explicit: false));
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (!_session.canApply) return;
    final release = _session.release!;
    if (_session.hasPinnedUpdates) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: const Text('Replace pinned Wing version?'),
          content: Text(
            'Install Wing ${release.version.value} from its official GitHub release in all profiles on ${_session.server.connectionLabel}.\n\n'
            'Pinned copies will move to this release. Hermes requires a forced reinstall, which also accepts caution-level scan warnings. Dangerous code remains blocked.',
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Replace pinned Wing and update all profiles',
              confirmIcon: Icons.system_update_alt,
            ),
          ],
        ),
      );
      if (!mounted || approved != true) return;
      await _session.applyToAll(approvedPinnedRelease: release);
    } else {
      await _session.applyToAll();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => StudioPageLoading(
      active: _session.explicitBusy,
      label: _session.updating
          ? 'Updating Wing plugin in ${_session.activeProfile ?? 'all profiles'}'
          : 'Checking Wing plugin versions',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _session.server.connectionLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _session.release == null
                    ? 'Latest GitHub release —'
                    : 'Latest GitHub release ${_session.release!.version.value}',
              ),
              const SizedBox(height: 8),
              const Text(
                'Install or update Wing in all profiles on this server.',
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Refresh Wing plugin versions',
                      onPressed: _session.busy
                          ? null
                          : () => unawaited(_session.refresh()),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Install or update Wing in all profiles',
                      onPressed: _session.canApply
                          ? () => unawaited(_apply())
                          : null,
                      icon: const Icon(Icons.system_update_alt),
                    ),
                  ),
                ],
              ),
              if (_session.error case final error?) StudioError(error),
              if (_session.releaseError case final error?) StudioError(error),
              for (final row in _session.profiles) ...[
                const Divider(height: 24),
                Text(
                  row.profile.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (row.profile.label != row.profile.name)
                  Text(
                    row.profile.name,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 4),
                Text(row.installedLabel),
                if (row.error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: StudioError(error),
                  ),
                if (row.result case final result?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(result),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
