import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../controllers/profile_voice_controller.dart';
import '../../widgets/read_recovery.dart';
import 'admin_widgets.dart';

class AdminVoicePage extends StatefulWidget {
  const AdminVoicePage({
    super.key,
    required this.createSession,
    required this.onRecognition,
    required this.onSynthesis,
    required this.onDefaults,
  });
  final ProfileVoiceController Function() createSession;
  final Future<void> Function(BuildContext) onRecognition,
      onSynthesis,
      onDefaults;
  @override
  State<AdminVoicePage> createState() => _AdminVoicePageState();
}

class _AdminVoicePageState extends State<AdminVoicePage> {
  late final _session = widget.createSession();
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
  Widget build(BuildContext context) => AdminPage(
    title: 'Voice',
    scope: _session.scopeLabel,
    child: ReadRecovery(
      shouldRetry: () => _session.canRecoverRead,
      retry: _session.loadDefaults,
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final state = _session.state;
          return StudioLoadingRegion(
            available: state.settings != null,
            busy: state.loading,
            label: 'Loading voice settings',
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (state.error != null)
                  AdminNotice.error(state.error!, retry: _session.loadDefaults),
                if (state.settings != null) ...[
                  AdminGroup(
                    children: [
                      AdminRow(
                        title: 'Speech recognition provider',
                        subtitle: 'Configured backend providers and keys',
                        icon: Icons.mic_none,
                        onTap: () => widget.onRecognition(context),
                      ),
                      AdminRow(
                        title: 'Speech synthesis provider',
                        subtitle: 'Configured backend providers and keys',
                        icon: Icons.volume_up_outlined,
                        onTap: () => widget.onSynthesis(context),
                      ),
                      AdminRow(
                        title: 'Speech defaults',
                        subtitle: 'Language, model and automatic speech',
                        icon: Icons.tune,
                        onTap: () => widget.onDefaults(context),
                      ),
                    ],
                  ),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: state.busy ? null : _session.loadDefaults,
                      child: const Text('Refresh configured providers'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ),
  );
}
