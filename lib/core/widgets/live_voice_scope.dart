import 'dart:async';

import 'package:flutter/material.dart';

import '../models/profile_session_key.dart';
import '../models/app_preferences.dart';
import '../services/live_voice_session.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';

class LiveVoiceScope extends InheritedNotifier<LiveVoiceSession> {
  const LiveVoiceScope({
    super.key,
    required LiveVoiceSession session,
    required this.openChat,
    required super.child,
  }) : super(notifier: session);
  final Future<void> Function(ProfileSessionKey) openChat;
  static LiveVoiceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveVoiceScope>();
  LiveVoiceSession get session => notifier!;
}

/// The app builder is above Navigator's overlay. Supply a full-window overlay
/// here so call-control tooltips remain anchored and can extend above the dock.
class LiveVoiceLayout extends StatelessWidget {
  const LiveVoiceLayout({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final voice = LiveVoiceScope.maybeOf(context)?.session;
    final hasDock = voice?.active == true || voice?.error != null;
    final keyboard = hasDock ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    return Overlay.wrap(
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: hasDock,
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: Column(
            children: [
              Expanded(child: child),
              LiveVoiceDock(keyboardVisible: keyboard > 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stays reachable while browsing and uses the same app-owned call everywhere.
class LiveVoiceDock extends StatefulWidget {
  const LiveVoiceDock({super.key, this.keyboardVisible = false});
  final bool keyboardVisible;
  @override
  State<LiveVoiceDock> createState() => _LiveVoiceDockState();
}

class _LiveVoiceDockState extends State<LiveVoiceDock> {
  bool _captions = false;
  bool _opening = false;
  @override
  Widget build(BuildContext context) {
    final scope = LiveVoiceScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final voice = scope.session;
    if (!voice.active && voice.error == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    Widget action(String label, IconData icon, VoidCallback? onPressed) =>
        StudioButtonPress(
          child: IconButton(
            tooltip: label,
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        );
    final mode = voice.conversation?.mode == LiveVoiceMode.api
        ? 'API'
        : 'Subscription';
    final status = switch (voice.phase) {
      LiveVoicePhase.connecting => 'Connecting voice…',
      LiveVoicePhase.ending => 'Ending voice…',
      _ => voice.muted ? '$mode · microphone muted' : '$mode · listening',
    };
    return Material(
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WingSpacing.md,
            vertical: WingSpacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (voice.active) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            voice.conversation!.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (voice.busy || voice.audioChanging || _opening)
                      const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: 'Updating voice',
                        ),
                      ),
                    action(
                      'Open voice chat',
                      Icons.chat_bubble_outline,
                      _opening
                          ? null
                          : () async {
                              final key = voice.conversation!.key;
                              setState(() => _opening = true);
                              try {
                                await scope.openChat(key);
                              } finally {
                                if (mounted) setState(() => _opening = false);
                              }
                            },
                    ),
                    action(
                      'End voice',
                      Icons.call_end,
                      voice.phase == LiveVoicePhase.ending
                          ? null
                          : () => unawaited(voice.end()),
                    ),
                  ],
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    action(
                      voice.muted ? 'Unmute voice' : 'Mute voice',
                      voice.muted ? Icons.mic_off : Icons.mic,
                      voice.busy || voice.audioChanging
                          ? null
                          : () => unawaited(voice.toggleMute()),
                    ),
                    action(
                      voice.speaker ? 'Use earpiece' : 'Use speaker',
                      voice.speaker ? Icons.volume_up : Icons.hearing,
                      voice.busy || voice.audioChanging
                          ? null
                          : () => unawaited(voice.toggleSpeaker()),
                    ),
                    if (!widget.keyboardVisible)
                      action(
                        _captions
                            ? 'Hide voice captions'
                            : 'Show voice captions',
                        Icons.closed_caption_outlined,
                        () => setState(() => _captions = !_captions),
                      ),
                  ],
                ),
                if (_captions &&
                    !widget.keyboardVisible &&
                    voice.caption.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 128),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(voice.caption),
                    ),
                  ),
              ],
              if (voice.error != null)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 128),
                        child: SingleChildScrollView(
                          child: StudioError(voice.error!),
                        ),
                      ),
                    ),
                    action(
                      'Dismiss voice error',
                      Icons.close,
                      voice.dismissError,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
