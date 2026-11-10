import '../services/administration_repository.dart';
import '../services/wing_plugin_session.dart';
import '../widgets/wing_plugin_settings_card.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/notification_channel_diagnostics.dart';
import 'package:flutter/material.dart';
import '../widgets/compact_switch.dart';
import 'package:flutter/foundation.dart';
import '../services/voice_preferences_session.dart';

import '../config/support_wing.dart';
import '../theme/profile_workspace_theme.dart';
import '../theme/wing_theme.dart';
import '../services/background_monitoring_service.dart';
import '../services/app_preferences.dart';
import '../models/app_preferences.dart';
import '../theme/app_preferences_rendering.dart';
import '../widgets/studio_error.dart';
import '../widgets/support_wing_section.dart';
import '../widgets/text_size_settings_card.dart';
import '../widgets/installed_app_version_card.dart';
import '../widgets/composer_action_settings.dart';
import '../widgets/voice_preferences_card.dart';
import 'privacy_policy_screen.dart';

/// Existing device preferences, shared by connected and disconnected navigation.
class AppSettingsContent extends StatefulWidget {
  const AppSettingsContent({
    super.key,
    required this.preferences,
    required this.pluginServer,
    required this.createVoiceSession,
    required this.onChanged,
    this.enableNotifications,
    this.backgroundMonitoringState,
    this.retryBackgroundMonitoring,
    this.openMonitoringBatterySettings,
  });

  final AppPreferences preferences;
  final AdministrationRepository? pluginServer;
  final VoicePreferencesSession Function() createVoiceSession;
  final VoidCallback onChanged;
  final Future<void> Function()? enableNotifications;
  final ValueListenable<BackgroundMonitoringState>? backgroundMonitoringState;
  final Future<void> Function()? retryBackgroundMonitoring;
  final Future<void> Function()? openMonitoringBatterySettings;

  @override
  State<AppSettingsContent> createState() => _AppSettingsContentState();
}

class _AppSettingsContentState extends State<AppSettingsContent> {
  bool _requesting = false;
  bool _retryingMonitoring = false;

  Future<void> _retryMonitoring() async {
    if (_retryingMonitoring) return;
    setState(() => _retryingMonitoring = true);
    try {
      await widget.retryBackgroundMonitoring!();
    } catch (_) {
      // A failed retry leaves the existing monitoring notice visible.
    } finally {
      if (mounted) setState(() => _retryingMonitoring = false);
    }
  }

  Widget _monitoringError(BuildContext context) {
    const notice = StudioError(
      'Background notifications paused.',
      framed: false,
    );
    final retry = widget.retryBackgroundMonitoring == null
        ? null
        : StudioButtonPress(
            child: IconButton(
              tooltip: 'Retry background monitoring',
              onPressed: _retryingMonitoring ? null : _retryMonitoring,
              icon: _retryingMonitoring
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        semanticsLabel: 'Retrying background monitoring',
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh),
            ),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: StudioErrorFrame(
        child: Padding(
          padding: const EdgeInsets.all(WingSpacing.md),
          child: MediaQuery.textScalerOf(context).scale(14) > 21
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    notice,
                    if (retry != null)
                      Align(alignment: Alignment.centerRight, child: retry),
                  ],
                )
              : Row(
                  children: [
                    const Expanded(child: notice),
                    ?retry,
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _notifications() async {
    setState(() => _requesting = true);
    try {
      await widget.enableNotifications!();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test alert sent. Check your notifications.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        showStudioError(
          context,
          error is StateError
              ? error.message.toString()
              : 'Could not send the test notification.',
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<AppPreferencesState>(
        valueListenable: widget.preferences.state,
        builder: (context, state, _) => _buildSettings(context, state),
      );

  Widget _buildSettings(BuildContext context, AppPreferencesState state) {
    final accent = state.values.accent?.appearance ?? WorkspaceAccent.teal;
    final mode = state.theme.selected;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.reloadControl.visible)
                  Card(
                    child: StudioLoadingRegion(
                      available: !state.reloadControl.busy,
                      busy: state.reloadControl.busy,
                      label: 'Reloading settings',
                      child: Column(
                        children: [
                          StudioButtonPress(
                            child: ListTile(
                              leading: const Icon(Icons.refresh),
                              title: const Text('Reload settings'),
                              subtitle: state.reloadControl.error == null
                                  ? null
                                  : StudioError(state.reloadControl.error!),
                              onTap: state.reloadControl.invoke,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                _SettingsSection(
                  title: 'Appearance',
                  child: Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: StudioLoadingRegion(
                            available: !state.theme.busy && !state.accent.busy,
                            busy: state.theme.busy || state.accent.busy,
                            label: state.theme.busy
                                ? 'Saving theme'
                                : 'Saving accent',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _AppearancePreview(
                                  mode: mode?.name ?? 'unconfigured',
                                  accent: accent,
                                ),
                                if (state.needsAppearanceRepair)
                                  const StudioError(
                                    'Saved appearance settings need repair. Choose the affected settings below.',
                                  ),
                                const SizedBox(height: 16),
                                Text(
                                  'Theme',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final option in [
                                      (
                                        AppThemePreference.system,
                                        'System',
                                        Icons.brightness_auto_outlined,
                                      ),
                                      (
                                        AppThemePreference.light,
                                        'Light',
                                        Icons.light_mode_outlined,
                                      ),
                                      (
                                        AppThemePreference.dark,
                                        'Dark',
                                        Icons.dark_mode_outlined,
                                      ),
                                    ])
                                      StudioButtonPress(
                                        child: ChoiceChip(
                                          showCheckmark: false,
                                          key: ValueKey(
                                            'theme-${option.$1.name}',
                                          ),
                                          avatar: Icon(option.$3, size: 18),
                                          label: Text(option.$2),
                                          selected: mode == option.$1,
                                          onSelected: state.theme.choose == null
                                              ? null
                                              : (_) => state.theme.choose!(
                                                  option.$1,
                                                ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (state.theme.notice != null)
                                  StudioError(state.theme.notice!),
                                if (state.theme.error != null)
                                  StudioError(state.theme.error!),

                                const SizedBox(height: 20),
                                Text(
                                  'Accent color',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final choice
                                        in AppAccentPreference.values)
                                      StudioButtonPress(
                                        child: ChoiceChip(
                                          showCheckmark: false,
                                          key: ValueKey(
                                            'accent-${choice.name}',
                                          ),
                                          label: Text(choice.appearance.label),
                                          selected:
                                              state.accent.selected == choice,
                                          avatar: CircleAvatar(
                                            radius: 8,
                                            backgroundColor:
                                                Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? choice.appearance.dark
                                                : choice.appearance.light,
                                          ),
                                          onSelected:
                                              state.accent.choose == null
                                              ? null
                                              : (_) => state.accent.choose!(
                                                  choice,
                                                ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (state.accent.notice != null)
                                  StudioError(state.accent.notice!),
                                if (state.accent.error != null)
                                  StudioError(state.accent.error!),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        TextSizeSettingsCard(preferences: widget.preferences),
                      ],
                    ),
                  ),
                ),
                _SettingsSection(
                  title: 'Chat',
                  child: ComposerActionSettings(
                    preferences: widget.preferences,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _webLinkSettings(context, state.webLinkDestination),
                ),
                if (widget.enableNotifications != null)
                  _SettingsSection(
                    title: 'Notifications',
                    child: Card(
                      child: Column(
                        children: [
                          _PreferenceSwitch(
                            title: 'Completed work',
                            control: state.completedNotifications,
                          ),
                          _PreferenceSwitch(
                            title: 'Needs attention',
                            subtitle: 'Questions, approvals and failed turns.',
                            control: state.attentionNotifications,
                          ),
                          _PreferenceSwitch(
                            title: 'Show message previews',
                            subtitle:
                                'Include reply and question text in alerts.',
                            control: state.notificationPreviews,
                          ),
                          if (widget.backgroundMonitoringState != null) ...[
                            ValueListenableBuilder<BackgroundMonitoringState>(
                              valueListenable:
                                  widget.backgroundMonitoringState!,
                              builder: (_, state, _) {
                                if (_retryingMonitoring ||
                                    state == BackgroundMonitoringState.failed) {
                                  return _monitoringError(context);
                                }
                                if (state !=
                                    BackgroundMonitoringState
                                        .batteryRestricted) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Notifications may be delayed.',
                                      ),
                                      if (widget
                                              .openMonitoringBatterySettings !=
                                          null)
                                        Builder(
                                          builder: (anchor) => StudioButtonPress(
                                            child: TextButton(
                                              onPressed: () async {
                                                const key =
                                                    'open-battery-settings';
                                                dismissTransientError(
                                                  anchor,
                                                  errorKey: key,
                                                );
                                                try {
                                                  await widget
                                                      .openMonitoringBatterySettings!();
                                                } catch (_) {
                                                  if (anchor.mounted) {
                                                    showTransientError(
                                                      anchor,
                                                      'Could not open battery settings.',
                                                      errorKey: key,
                                                      icon: Icons
                                                          .battery_alert_outlined,
                                                    );
                                                  }
                                                }
                                              },
                                              child: const Text(
                                                'Allow background activity',
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                          const Divider(height: 1),
                          StudioButtonPress(
                            child: ListTile(
                              leading: const Icon(Icons.notifications_outlined),
                              title: widget.backgroundMonitoringState == null
                                  ? const Text('Test notification')
                                  : ValueListenableBuilder<
                                      BackgroundMonitoringState
                                    >(
                                      valueListenable:
                                          widget.backgroundMonitoringState!,
                                      builder: (_, state, _) => Text(
                                        state ==
                                                BackgroundMonitoringState
                                                    .permissionRequired
                                            ? 'Enable notifications'
                                            : 'Test notification',
                                      ),
                                    ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _requesting ? null : _notifications,
                            ),
                          ),
                          const NotificationChannelDiagnostics(),
                        ],
                      ),
                    ),
                  ),

                _SettingsSection(
                  title: 'Voice',
                  child: Card(
                    child: StudioButtonPress(
                      child: ListTile(
                        key: const ValueKey('voice-settings'),
                        leading: const Icon(Icons.mic_none),
                        title: const Text('Voice input and output'),
                        subtitle: const Text(
                          'Processing, Android voices and read-aloud.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => VoicePreferencesPage(
                              createSession: widget.createVoiceSession,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _SettingsSection(
                  title: 'Hermes',
                  child: WingPluginSettingsCard(
                    key: ObjectKey(widget.pluginServer),
                    createSession: widget.pluginServer == null
                        ? null
                        : () => WingPluginSession(widget.pluginServer!),
                  ),
                ),
                _SettingsSection(
                  title: 'About',
                  child: Card(
                    child: Column(
                      children: [
                        const InstalledAppVersionCard(),
                        const Divider(height: 1),
                        StudioButtonPress(
                          child: ListTile(
                            key: const ValueKey('privacy-policy'),
                            leading: const Icon(Icons.privacy_tip_outlined),
                            title: const Text('Privacy policy'),
                            subtitle: const Text(
                              'How your data is stored and used.',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => const PrivacyPolicyScreen(),
                              ),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        SupportWingSection(
                          githubUri: wingGitHubSponsorsUri,
                          koFiUri: wingKoFiUri,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _webLinkSettings(
  BuildContext context,
  AppPreferenceControl<WebLinkDestination> control,
) {
  final theme = Theme.of(context);
  final (value, accessibleValue) = switch (control.selected) {
    WebLinkDestination.wing => ('Wing', 'Open in Wing'),
    WebLinkDestination.externalBrowser => (
      'Browser',
      'Open in external browser',
    ),
    null => ('Choose', 'Choose a link destination'),
  };
  return Card(
    child: StudioLoadingRegion(
      available: !control.busy,
      busy: control.busy,
      label: 'Saving link preference',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Theme(
            data: theme.copyWith(
              highlightColor: theme.colorScheme.primaryContainer,
            ),
            child: StudioButtonPress(
              child: PopupMenuButton<WebLinkDestination>(
                key: const ValueKey('link-destination'),
                tooltip: 'Default link destination',
                initialValue: control.selected,
                enabled: control.choose != null,
                onSelected: control.choose,
                position: PopupMenuPosition.under,
                borderRadius: WingRadius.card,
                popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
                    ? AnimationStyle.noAnimation
                    : null,
                itemBuilder: (_) => const [
                  StudioPopupMenuItem(
                    value: WebLinkDestination.wing,
                    child: Text('Open in Wing'),
                  ),
                  StudioPopupMenuItem(
                    value: WebLinkDestination.externalBrowser,
                    child: Text('Open in external browser'),
                  ),
                ],
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) => FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Open links in',
                                      maxLines: 1,
                                      style: theme.textTheme.bodyLarge,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      value,
                                      semanticsLabel: accessibleValue,
                                      maxLines: 1,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final message in [control.notice, control.error])
            if (message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: StudioError(message),
              ),
        ],
      ),
    ),
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        child,
      ],
    ),
  );
}

/// A real themed reading sample, updated only after the preference is saved.
class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({required this.mode, required this.accent});

  final String mode;
  final WorkspaceAccent accent;

  @override
  Widget build(BuildContext context) {
    final brightness = switch (mode) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => MediaQuery.platformBrightnessOf(context),
    };
    return Theme(
      data: profileWorkspaceTheme(
        ThemeData(brightness: brightness),
        accent: accent,
      ),
      child: Builder(
        builder: (context) {
          final tokens = WingTokens.of(context);
          return Container(
            key: const ValueKey('appearance-preview'),
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: WingRadius.card,
              border: Border.all(color: tokens.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chat preview',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: tokens.muted),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: WingRadius.card,
                    ),
                    child: Text(
                      'Let’s make a plan.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'One step at a time.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PreferenceSwitch extends StatelessWidget {
  const _PreferenceSwitch({
    required this.title,
    required this.control,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final AppPreferenceControl<bool> control;

  @override
  Widget build(BuildContext context) => StudioLoadingRegion(
    available: !control.busy,
    busy: control.busy,
    label: 'Saving app settings',
    child: Column(
      children: [
        if (control.selected case final bool selected)
          CompactSwitchListTile(
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle!),
            value: selected,
            onChanged: control.choose,
          )
        else
          ListTile(
            title: Text(title),
            subtitle: Wrap(
              spacing: 8,
              children: [
                for (final option in [(true, 'On'), (false, 'Off')])
                  StudioButtonPress(
                    child: ChoiceChip(
                      showCheckmark: false,
                      selected: false,
                      label: Text(option.$2),
                      onSelected: control.choose == null
                          ? null
                          : (_) => control.choose!(option.$1),
                    ),
                  ),
              ],
            ),
          ),
        if (control.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StudioError(control.notice!),
          ),
        if (control.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StudioError(control.error!),
          ),
      ],
    ),
  );
}
