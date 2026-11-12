import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../controllers/profile_voice_controller.dart';
import '../../services/administration_repository.dart';
import '../../services/android_voice.dart';
import '../../services/profile_voice_repository.dart';
import '../../services/profile_tool_setup_session.dart';
import 'admin_voice_page.dart';
import 'admin_speech_synthesis_page.dart';
import 'admin_provider_credentials.dart';
import 'admin_operations_page.dart';
import 'admin_tool_setup_page.dart';
import 'admin_settings_page.dart';
import 'admin_widgets.dart';

/// Actual route composition. Every picker replacement gets the selected profile;
/// typed Voice views never receive a raw transport or an earlier profile's fields.
AdminSpeechSynthesisPage profileSpeechSynthesisPage(
  ProfileAdministration profile, {
  required VoiceDevice device,
}) => AdminSpeechSynthesisPage(
  createSession: () =>
      ProfileVoiceController(ProfileVoiceRepository(profile), device: device),
  onCredential: (context, field) async {
    await adminPushProfile(
      context,
      profile,
      (context, selected) =>
          AdminSecretPage(profile: selected, name: field.key),
    );
  },
  onResult: (context, operation) async {
    await adminPush(
      context,
      (_) => AdminActionPage(
        operation: operation,
        title: 'Speech setup',
        scope: profile.label,
      ),
    );
  },
);

AdminVoicePage profileVoicePage(
  ProfileAdministration profile, {
  required VoiceDevice device,
}) => AdminVoicePage(
  createSession: () =>
      ProfileVoiceController(ProfileVoiceRepository(profile), device: device),
  onRecognition: (context) async {
    await adminPushProfile(
      context,
      profile,
      (context, selected) => AdminToolSetupPage(
        createSession: () => ProfileToolSetupSession(selected, tool: 'stt'),
        onCredential: (context, field) async {
          await adminPushProfile(
            context,
            selected,
            (context, target) =>
                AdminSecretPage(profile: target, name: field.key),
          );
        },
      ),
    );
  },
  onSynthesis: (context) async {
    await adminPushProfile(
      context,
      profile,
      (context, selected) =>
          profileSpeechSynthesisPage(selected, device: device),
    );
  },
  onDefaults: (context) async {
    await adminPushProfile(
      context,
      profile,
      (context, selected) =>
          _ProfileSpeechDefaults(profile: selected, device: device),
    );
  },
);

/// Provides this route's current field catalog to the existing settings editor.
/// The editor remains the sole settings-draft/write owner.
class _ProfileSpeechDefaults extends StatefulWidget {
  const _ProfileSpeechDefaults({required this.profile, required this.device});
  final ProfileAdministration profile;
  final VoiceDevice device;
  @override
  State<_ProfileSpeechDefaults> createState() => _ProfileSpeechDefaultsState();
}

class _ProfileSpeechDefaultsState extends State<_ProfileSpeechDefaults> {
  late final _session = ProfileVoiceController(
    ProfileVoiceRepository(widget.profile),
    device: widget.device,
  );
  @override
  void initState() {
    super.initState();
    _session.loadDefaults();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.state;
      if (!state.fresh && state.settings == null) {
        return AdminPage(
          title: 'Speech defaults',
          scope: _session.scopeLabel,
          child: state.loading
              ? StudioPageLoading.waiting(label: 'Loading voice settings')
              : AdminNotice.error(
                  state.error ?? 'Speech settings are unavailable.',
                  retry: _session.loadDefaults,
                ),
        );
      }
      return AdminSettingsPage(
        profile: widget.profile,
        title: 'Speech defaults',
        fields: state.defaults,
      );
    },
  );
}
