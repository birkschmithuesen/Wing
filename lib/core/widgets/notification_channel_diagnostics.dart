import 'studio_error.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import '../services/native_notification_sink.dart';

/// Android channel blocks are independent of the application's permission.
class NotificationChannelDiagnostics extends StatefulWidget {
  const NotificationChannelDiagnostics({super.key});
  @override
  State<NotificationChannelDiagnostics> createState() =>
      _NotificationChannelDiagnosticsState();
}

class _NotificationChannelDiagnosticsState
    extends State<NotificationChannelDiagnostics>
    with WidgetsBindingObserver {
  List<NativeNotificationChannel> _blocked = const [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final rows = await NativeNotificationSink.blockedChannels();
      if (!mounted) return;
      setState(() {
        _blocked = rows;
      });
    } catch (_) {
      /* Unavailable outside Android. */
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final channel in _blocked)
        Builder(
          builder: (anchor) => StudioButtonPress(
            child: ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text('${channel.name} blocked'),
              subtitle: const Text(
                'Enable this category in Android notification settings.',
              ),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                final key = ('notification-channel', channel);
                dismissTransientError(anchor, errorKey: key);
                try {
                  await NativeNotificationSink.openChannelSettings(channel);
                } catch (_) {
                  if (anchor.mounted) {
                    showTransientError(
                      anchor,
                      'Could not open Android notification settings.',
                      errorKey: key,
                      icon: Icons.notifications_off_outlined,
                    );
                  }
                }
              },
            ),
          ),
        ),
    ],
  );
}
