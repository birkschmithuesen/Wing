import 'package:flutter/material.dart';
import '../../services/administration_repository.dart';
import '../../services/server_connection_status.dart';
import 'admin_voice_routes.dart';
import '../../services/android_voice.dart';
import '../../widgets/server_connection_label.dart';

/// Single integration point for App settings. Capture the owner before routing;
/// an administration navigation redesign only needs to change this entry point.
Future<void> openProfileVoiceSettings(
  BuildContext context, {
  required ProfileAdministration profile,
  required ServerConnectionStatus connectionStatus,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ServerConnectionScope(
        status: connectionStatus,
        child: profileSpeechSynthesisPage(
          profile,
          device: AndroidVoice.instance,
        ),
      ),
    ),
  );
}
