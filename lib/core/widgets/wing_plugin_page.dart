import 'dart:async';
import 'package:flutter/material.dart';
import '../models/wing_plugin.dart';
import '../services/web_preview.dart';
import '../services/wing_plugin_session.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'studio_form_actions.dart';
import 'studio_loading.dart';
import 'wing_app_bar.dart';

/// A manager or profile inventory borrowing the settings card's captured owner.
class WingPluginPage extends StatefulWidget {
  const WingPluginPage({
    super.key,
    required this.session,
    required this.profiles,
    required this.openProfiles,
  });
  final WingPluginSession session;
  final bool profiles;
  final VoidCallback openProfiles;

  @override
  State<WingPluginPage> createState() => _WingPluginPageState();
}

class _WingPluginPageState extends State<WingPluginPage> {
  WingPluginSession get session => widget.session;
  bool get profiles => widget.profiles;
  bool _openingGitHub = false, _githubFailed = false;

  Future<void> _openGitHub() async {
    if (_openingGitHub) return;
    setState(() {
      _openingGitHub = true;
      _githubFailed = false;
    });
    final opened = await openWebPreview(
      Uri.parse(WingPluginRelease.repository),
    );
    if (!mounted) return;
    setState(() {
      _openingGitHub = false;
      _githubFailed = !opened;
    });
  }

  Widget _introduction(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'This optional plugin runs on your Hermes server to enable extra features in Wing. '
        'You can install or update it for individual profiles, or for all profiles at once.',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              'GitHub · tarkilhk/wing-hermes-plugin',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Semantics(
            link: true,
            child: StudioButtonPress(
              child: IconButton(
                tooltip: 'Open Wing plugin on GitHub',
                onPressed: _openingGitHub ? null : _openGitHub,
                icon: const Icon(Icons.open_in_new),
              ),
            ),
          ),
        ],
      ),
      if (_githubFailed)
        const StudioError('Could not open GitHub. Please try again.'),
      const SizedBox(height: 24),
    ],
  );

  void _apply(BuildContext context) {
    if (profiles) Navigator.of(context).pop();
    unawaited(session.requestApply());
  }

  Widget _version(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  Widget _review(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: WingRadius.control,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Replace the pinned version?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              session.reviewProfileLabel != null
                  ? 'Replace the pinned Wing version in ${session.reviewProfileLabel} with ${session.reviewRelease!.version.value} from the official GitHub release.'
                  : 'Move pinned copies to Wing ${session.reviewRelease!.version.value} from the official GitHub release, then install or update Wing in the other profiles.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Hermes requires a forced reinstall for pinned copies. This accepts caution-level scan warnings; dangerous code stays blocked.',
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _details(BuildContext context) {
    final overview = session.overview;
    final review = session.reviewRelease;
    return [
      if (review == null) _introduction(context),
      Row(
        children: [
          const Icon(Icons.dns_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(session.server.connectionLabel)),
        ],
      ),
      const SizedBox(height: 24),
      if (review != null) _review(context),
      if (review == null) ...[
        if (overview.needsAttention)
          StudioError(
            overview.title,
            detail: overview.detail,
            icon: Icons.extension_outlined,
          )
        else ...[
          Text(overview.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(overview.detail),
        ],
      ],
      if (overview.installedVersions case final versions?)
        _version(context, 'Installed version', versions),
      _version(
        context,
        'Latest GitHub release',
        session.release?.version.value ?? 'Unavailable',
      ),
      if (session.error case final error?)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: StudioError(error),
        ),
      if (session.releaseError case final error?)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: StudioError(error),
        ),
      const Divider(height: 40),
      StudioButtonPress(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.people_outline),
          title: const Text('Profiles'),
          subtitle: Text(
            session.profiles.isEmpty
                ? 'Inventory unavailable'
                : overview.summary == 'Not installed'
                ? '0 of ${session.profiles.length} installed'
                : overview.summary,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.openProfiles,
        ),
      ),
    ];
  }

  List<Widget> _profileRows(BuildContext context) => [
    if (session.reviewRelease != null && session.reviewProfileName != null)
      _review(context),
    if (session.error case final error?) StudioError(error),
    Text(
      'Wing plugin · ${session.server.connectionLabel}',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    if (session.profiles.isEmpty)
      const Padding(
        padding: EdgeInsets.only(top: 24),
        child: Text('Profile inventory is not available yet.'),
      ),
    for (final row in session.profiles) ...[
      const SizedBox(height: 20),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.person_outline, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                if (row.plugin?.pinnedSha?.isNotEmpty == true)
                  Text(
                    'Pinned version',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (row.error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: StudioError(error),
                  ),
                if (row.result case final result?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(result),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Install or update Wing in ${row.profile.label}',
              onPressed:
                  session.reviewRelease == null &&
                      session.canApplyTo(row.profile.name)
                  ? () => unawaited(
                      session.requestApply(profileName: row.profile.name),
                    )
                  : null,
              icon: const Icon(Icons.system_update_alt),
            ),
          ),
        ],
      ),
      const Divider(height: 24),
    ],
  ];

  Widget _footer(BuildContext context) {
    final review =
        session.reviewRelease != null &&
        (!profiles || session.reviewProfileName != null);
    final reviewLabel = session.reviewProfileLabel;
    final scopeLabel =
        (review ? reviewLabel : null) ?? session.operationProfileLabel;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${scopeLabel ?? (session.profiles.isEmpty ? 'All profiles' : 'All ${session.profiles.length} profiles')}\n${session.server.connectionLabel}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 12),
            if (review)
              StudioFormActions(
                onCancel: session.busy ? null : session.cancelReview,
                onConfirm: session.canConfirmReview
                    ? () => unawaited(session.confirmPinnedUpdate())
                    : null,
                confirmLabel: reviewLabel == null
                    ? 'Replace pinned Wing and update all profiles'
                    : 'Replace pinned Wing in $reviewLabel',
              )
            else ...[
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Refresh Wing plugin versions',
                  onPressed: session.busy
                      ? null
                      : () => unawaited(session.refresh()),
                  icon: const Icon(Icons.refresh),
                ),
              ),
              if (session.canApply || session.updating) ...[
                const SizedBox(width: 8),
                StudioButtonPress(
                  child: IconButton.filled(
                    tooltip: 'Install or update Wing in all profiles',
                    onPressed: session.canApply ? () => _apply(context) : null,
                    icon: const Icon(Icons.system_update_alt),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Scaffold(
      appBar: WingAppBar(
        context: context,
        title: Text(profiles ? 'Profiles' : 'Wing plugin'),
      ),
      body: StudioPageLoading(
        active: session.busy || _openingGitHub,
        label: session.busy ? session.progressLabel : 'Opening GitHub',
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey(session.reviewRelease),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: profiles
                      ? _profileRows(context)
                      : _details(context),
                ),
              ),
            ),
            const Divider(height: 1),
            _footer(context),
          ],
        ),
      ),
    ),
  );
}
