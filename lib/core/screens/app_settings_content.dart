import '../widgets/notification_channel_diagnostics.dart';
import 'package:flutter/material.dart';
import '../widgets/compact_switch.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/support_wing.dart';
import '../theme/profile_workspace_theme.dart';
import '../theme/wing_theme.dart';
import '../services/turn_notification_service.dart';
import '../services/background_monitoring_service.dart';
import '../services/device_preference.dart';
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
    required this.onChanged,
    this.enableNotifications,
    this.backgroundMonitoringState,
    this.openMonitoringBatterySettings,
    this.openHermesVoiceSettings,
    this.hermesVoiceProfileLabel,
    this.notificationExtras = const [],
  });

  final SharedPreferences preferences;
  final VoidCallback onChanged;
  final Future<void> Function()? enableNotifications;
  final ValueListenable<BackgroundMonitoringState>? backgroundMonitoringState;
  final Future<void> Function()? openMonitoringBatterySettings;
  final VoidCallback? openHermesVoiceSettings;
  final String? hermesVoiceProfileLabel;
  final List<Widget> notificationExtras;

  @override
  State<AppSettingsContent> createState() => _AppSettingsContentState();
}

class _AppSettingsContentState extends State<AppSettingsContent> {
  bool _requesting = false;
  bool _saving = false;
  late final Map<String, Object?> _confirmed;

  @override
  void initState() {
    super.initState();
    _confirmed = {
      for (final key in [
        'theme_mode',
        WorkspaceAccent.preferenceKey,
        completionNotificationsKey,
        attentionNotificationsKey,
        notificationPreviewsKey,
      ])
        key: widget.preferences.get(key),
    };
  }

  Future<void> _save(String key, Object value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveDevicePreference(widget.preferences, key, value);
      if (!mounted) return;
      setState(() => _confirmed[key] = value);
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        showStudioError(context, 'Could not save the setting. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: StudioError(
              error is StateError
                  ? error.message.toString()
                  : 'Could not send the test notification.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = WorkspaceAccent.fromName(
      _confirmed[WorkspaceAccent.preferenceKey] as String?,
    );
    final mode = _confirmed['theme_mode'] as String? ?? 'system';
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
                _SettingsSection(
                  title: 'Appearance',
                  child: Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _AppearancePreview(mode: mode, accent: accent),
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
                                      'system',
                                      'System',
                                      Icons.brightness_auto_outlined,
                                    ),
                                    (
                                      'light',
                                      'Light',
                                      Icons.light_mode_outlined,
                                    ),
                                    ('dark', 'Dark', Icons.dark_mode_outlined),
                                  ])
                                    ChoiceChip(
                                      showCheckmark: false,
                                      key: ValueKey('theme-${option.$1}'),
                                      avatar: Icon(option.$3, size: 18),
                                      label: Text(option.$2),
                                      selected: mode == option.$1,
                                      onSelected: _saving
                                          ? null
                                          : (_) =>
                                                _save('theme_mode', option.$1),
                                    ),
                                ],
                              ),
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
                                  for (final choice in WorkspaceAccent.values)
                                    ChoiceChip(
                                      showCheckmark: false,
                                      key: ValueKey('accent-${choice.name}'),
                                      label: Text(choice.label),
                                      selected: accent == choice,
                                      avatar: CircleAvatar(
                                        radius: 8,
                                        backgroundColor:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? choice.dark
                                            : choice.light,
                                      ),
                                      onSelected: _saving
                                          ? null
                                          : (_) => _save(
                                              WorkspaceAccent.preferenceKey,
                                              choice.name,
                                            ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        TextSizeSettingsCard(
                          preferences: widget.preferences,
                          onChanged: (_) => widget.onChanged(),
                        ),
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
                if (widget.enableNotifications != null)
                  _SettingsSection(
                    title: 'Notifications',
                    child: Card(
                      child: Column(
                        children: [
                          CompactSwitchListTile(
                            title: const Text('Completed work'),
                            value:
                                _confirmed[completionNotificationsKey]
                                    as bool? ??
                                true,
                            onChanged: _saving
                                ? null
                                : (value) =>
                                      _save(completionNotificationsKey, value),
                          ),
                          CompactSwitchListTile(
                            title: const Text('Needs attention'),
                            subtitle: const Text(
                              'Questions, approvals and failed turns.',
                            ),
                            value:
                                _confirmed[attentionNotificationsKey]
                                    as bool? ??
                                true,
                            onChanged: _saving
                                ? null
                                : (value) =>
                                      _save(attentionNotificationsKey, value),
                          ),
                          CompactSwitchListTile(
                            title: const Text('Show message previews'),
                            subtitle: const Text(
                              'Include reply and question text in alerts.',
                            ),
                            value:
                                _confirmed[notificationPreviewsKey] as bool? ??
                                true,
                            onChanged: _saving
                                ? null
                                : (value) =>
                                      _save(notificationPreviewsKey, value),
                          ),
                          for (final extra in widget.notificationExtras) ...[
                            const Divider(height: 1),
                            extra,
                          ],
                          if (widget.backgroundMonitoringState != null) ...[
                            ValueListenableBuilder<BackgroundMonitoringState>(
                              valueListenable:
                                  widget.backgroundMonitoringState!,
                              builder: (_, state, _) {
                                if (state !=
                                        BackgroundMonitoringState
                                            .batteryRestricted &&
                                    state != BackgroundMonitoringState.failed) {
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
                                      Text(
                                        state ==
                                                BackgroundMonitoringState
                                                    .batteryRestricted
                                            ? 'Notifications may be delayed.'
                                            : 'Notifications paused.',
                                      ),
                                      if (state ==
                                              BackgroundMonitoringState
                                                  .batteryRestricted &&
                                          widget.openMonitoringBatterySettings !=
                                              null)
                                        TextButton(
                                          onPressed: () async {
                                            try {
                                              await widget
                                                  .openMonitoringBatterySettings!();
                                            } catch (_) {
                                              if (context.mounted) {
                                                showStudioError(
                                                  context,
                                                  'Could not open battery settings.',
                                                );
                                              }
                                            }
                                          },
                                          child: const Text(
                                            'Allow background activity',
                                          ),
                                        ),
                                      if (state ==
                                          BackgroundMonitoringState.failed)
                                        TextButton(
                                          onPressed: widget.onChanged,
                                          child: const Text('Retry'),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                          const Divider(height: 1),
                          ListTile(
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
                            trailing: _requesting
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.chevron_right),
                            onTap: _requesting ? null : _notifications,
                          ),
                          const NotificationChannelDiagnostics(),
                        ],
                      ),
                    ),
                  ),

                _SettingsSection(
                  title: 'Voice',
                  child: Card(
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
                            preferences: widget.preferences,
                            openHermesSettings: widget.openHermesVoiceSettings,
                            hermesProfileLabel: widget.hermesVoiceProfileLabel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _SettingsSection(
                  title: 'About',
                  child: Card(
                    child: Column(
                      children: [
                        const InstalledAppVersionCard(),
                        const Divider(height: 1),
                        ListTile(
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
