import 'dart:async';

import 'package:flutter/material.dart';

import '../models/profile_session_key.dart';
import '../models/recent_conversation.dart';
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

/// Keeps call presentation above navigation, without taking over keyboard insets.
class LiveVoiceLayout extends StatefulWidget {
  const LiveVoiceLayout({super.key, required this.child});
  final Widget child;
  @override
  State<LiveVoiceLayout> createState() => _LiveVoiceLayoutState();
}

class _LiveVoiceLayoutState extends State<LiveVoiceLayout> {
  final _location = ValueNotifier<RecentConversationKey?>(null);

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = LiveVoiceScope.maybeOf(context)?.session;
    final hasCard = voice?.active == true || voice?.error != null;
    return _LiveVoiceLocationScope(
      location: _location,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Overlay.wrap(
          child: SafeArea(
            top: hasCard,
            bottom: false,
            child: Column(
              children: [
                ValueListenableBuilder<RecentConversationKey?>(
                  valueListenable: _location,
                  builder: (context, location, _) => LiveVoiceDock(
                    away:
                        voice?.conversation != null &&
                        location != null &&
                        location !=
                            RecentConversationKey.chat(
                              voice!.conversation!.key,
                            ),
                  ),
                ),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveVoiceLocationScope extends InheritedWidget {
  const _LiveVoiceLocationScope({required this.location, required super.child});
  final ValueNotifier<RecentConversationKey?> location;
  @override
  bool updateShouldNotify(_LiveVoiceLocationScope oldWidget) =>
      location != oldWidget.location;
}

/// Only actual conversation routes report visits. Lists, overlays and passive
/// previews leave the last visited chat intact; they do not imply a new chat.
class LiveVoiceChatLocation extends StatefulWidget {
  const LiveVoiceChatLocation({
    super.key,
    required this.conversation,
    required this.enabled,
    required this.child,
  });
  final RecentConversationKey conversation;
  final bool enabled;
  final Widget child;
  @override
  State<LiveVoiceChatLocation> createState() => _LiveVoiceChatLocationState();
}

class _LiveVoiceChatLocationState extends State<LiveVoiceChatLocation> {
  @override
  Widget build(BuildContext context) {
    final location = context
        .dependOnInheritedWidgetOfExactType<_LiveVoiceLocationScope>()
        ?.location;
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (location != null &&
        widget.enabled &&
        current &&
        location.value != widget.conversation) {
      final conversation = widget.conversation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.enabled &&
            widget.conversation == conversation &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          location.value = conversation;
        }
      });
    }
    return widget.child;
  }
}

/// One app-owned call, visually independent of the conversation below it.
class LiveVoiceDock extends StatefulWidget {
  const LiveVoiceDock({super.key, required this.away});
  final bool away;
  @override
  State<LiveVoiceDock> createState() => _LiveVoiceDockState();
}

class _LiveVoiceDockState extends State<LiveVoiceDock> {
  bool _captions = false;
  bool _opening = false;
  String? _openError;
  LiveVoiceConversation? _call;

  @override
  void didUpdateWidget(LiveVoiceDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.away) {
      _captions = false;
      _openError = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final call = LiveVoiceScope.maybeOf(context)?.session.conversation;
    if (!identical(call, _call)) {
      _call = call;
      _opening = false;
      _captions = false;
      _openError = null;
    }
  }

  Future<void> _returnToChat(LiveVoiceScope scope) async {
    final call = scope.session.conversation!;
    final key = call.key;
    bool current() => mounted && identical(scope.session.conversation, call);
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      await scope.openChat(key);
    } catch (_) {
      if (current()) {
        setState(
          () => _openError = 'Could not open the voice chat. Try again.',
        );
      }
    } finally {
      if (current()) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = LiveVoiceScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final voice = scope.session;
    if (!voice.active && voice.error == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget action(
      String label,
      Widget icon,
      VoidCallback? onPressed, {
      bool selected = false,
      bool? toggled,
      bool danger = false,
    }) => StudioButtonPress(
      child: IconButton(
        tooltip: label,
        isSelected: toggled,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(48),
          minimumSize: const Size.square(48),
          maximumSize: const Size.square(48),
          padding: const EdgeInsets.all(12),
          foregroundColor: danger
              ? colors.error
              : selected
              ? colors.primary
              : colors.onSurface,
          backgroundColor: danger
              ? colors.error.withValues(alpha: .12)
              : selected
              ? colors.primary.withValues(alpha: .10)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: icon,
      ),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        action(
          voice.muted ? 'Unmute voice' : 'Mute voice',
          Icon(voice.muted ? Icons.mic_off_outlined : Icons.mic_none),
          voice.busy || voice.audioChanging
              ? null
              : () => unawaited(voice.toggleMute()),
          selected: voice.muted,
          toggled: voice.muted,
        ),
        action(
          voice.speaker ? 'Use earpiece' : 'Use speaker',
          Icon(
            voice.speaker ? Icons.volume_up_outlined : Icons.hearing_outlined,
          ),
          voice.busy || voice.audioChanging
              ? null
              : () => unawaited(voice.toggleSpeaker()),
        ),
        action(
          'End voice',
          const Icon(Icons.call_end_outlined),
          voice.phase == LiveVoicePhase.ending
              ? null
              : () => unawaited(voice.end()),
          danger: true,
        ),
      ],
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: voice.conversation?.title ?? '',
          child: Text(
            voice.conversation?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 3),
        _LiveVoiceStatus(voice: voice, opening: _opening),
      ],
    );
    final captionStyle = theme.textTheme.bodySmall!.copyWith(height: 1.4);
    final captionHeight =
        MediaQuery.textScalerOf(context).scale(captionStyle.fontSize!) * 2.8;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Material(
        key: const ValueKey('live-voice-card'),
        color: Color.alphaBlend(
          colors.primary.withValues(alpha: .045),
          colors.surfaceContainer,
        ),
        elevation: 5,
        shadowColor: colors.shadow.withValues(alpha: .25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (voice.active) ...[
                LayoutBuilder(
                  builder: (context, constraints) {
                    final large =
                        MediaQuery.textScalerOf(context).scale(14) >= 21;
                    return large || constraints.maxWidth < 280
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              identity,
                              Align(
                                alignment: Alignment.centerRight,
                                child: controls,
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: identity),
                              const SizedBox(width: 8),
                              controls,
                            ],
                          );
                  },
                ),
                if (widget.away) ...[
                  const SizedBox(height: 5),
                  Divider(height: 1, color: colors.outlineVariant),
                  const SizedBox(height: 5),
                  SizedBox(
                    height: captionHeight.clamp(48.0, double.infinity),
                    child: Row(
                      children: [
                        Expanded(
                          child: _captions && voice.caption.isNotEmpty
                              ? SizedBox(
                                  key: const ValueKey('live-voice-captions'),
                                  height: captionHeight,
                                  child: Semantics(
                                    label: 'Voice captions',
                                    liveRegion: true,
                                    child: SingleChildScrollView(
                                      reverse: true,
                                      padding: const EdgeInsets.only(right: 6),
                                      child: Text(
                                        voice.caption,
                                        style: captionStyle,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        action(
                          _captions
                              ? 'Hide voice captions'
                              : 'Show voice captions',
                          const Icon(Icons.closed_caption_outlined),
                          () => setState(() => _captions = !_captions),
                          selected: _captions,
                          toggled: _captions,
                        ),
                        const SizedBox(width: 2),
                        action(
                          'Return to voice chat',
                          const _VoiceChatIcon(),
                          _opening
                              ? null
                              : () => unawaited(_returnToChat(scope)),
                          selected: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              if (voice.error ?? _openError case final error?)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .18,
                        ),
                        child: SingleChildScrollView(child: StudioError(error)),
                      ),
                    ),
                    action('Dismiss voice error', const Icon(Icons.close), () {
                      setState(() => _openError = null);
                      voice.dismissError();
                    }),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Only the small status row ticks; transcript and chat layout do not rebuild.
class _LiveVoiceStatus extends StatefulWidget {
  const _LiveVoiceStatus({required this.voice, required this.opening});
  final LiveVoiceSession voice;
  final bool opening;
  @override
  State<_LiveVoiceStatus> createState() => _LiveVoiceStatusState();
}

class _LiveVoiceStatusState extends State<_LiveVoiceStatus> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final since = voice.connectedAt;
    final seconds = since == null
        ? 0
        : DateTime.now().difference(since).inSeconds.clamp(0, 864000);
    final elapsed =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    final status = switch (voice.phase) {
      LiveVoicePhase.connecting => 'Connecting voice…',
      LiveVoicePhase.ending => 'Ending voice…',
      _ => '${voice.muted ? 'Muted' : 'Voice'} · $elapsed',
    };
    final pending = voice.busy || voice.audioChanging || widget.opening;
    final label = widget.opening
        ? 'Opening voice chat'
        : voice.audioChanging
        ? 'Updating voice audio'
        : status;
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          children: [
            if (pending)
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(
                voice.muted ? Icons.mic_off_outlined : Icons.graphic_eq,
                size: 14,
                color: color,
              ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceChatIcon extends StatelessWidget {
  const _VoiceChatIcon();
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(24),
    painter: _VoiceChatPainter(
      IconTheme.of(context).color ?? Theme.of(context).colorScheme.primary,
    ),
  );
}

class _VoiceChatPainter extends CustomPainter {
  const _VoiceChatPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final bubble = Path()
      ..moveTo(6, 3)
      ..lineTo(18, 3)
      ..quadraticBezierTo(21, 3, 21, 6)
      ..lineTo(21, 15)
      ..quadraticBezierTo(21, 18, 18, 18)
      ..lineTo(9, 18)
      ..lineTo(4, 21)
      ..lineTo(4, 6)
      ..quadraticBezierTo(4, 3, 6, 3)
      ..close();
    canvas.drawPath(bubble, pen);
    for (final (x, top, bottom) in [
      (8.0, 9.0, 12.0),
      (11.0, 7.0, 14.0),
      (14.0, 8.0, 13.0),
      (17.0, 9.0, 12.0),
    ]) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), pen);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VoiceChatPainter oldDelegate) =>
      color != oldDelegate.color;
}
