import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_output.dart';
import '../models/chat_runtime.dart';
import '../models/transcript_timeline.dart';
import '../theme/wing_theme.dart';
import 'profile_execution_activity.dart';
import 'profile_activity_tabs.dart';
import 'profile_tool_activity.dart';
import 'profile_message.dart';
import 'activity_time.dart';
import 'anchored_expansion_tile.dart';
import 'recent_conversations/conversation_gestures.dart';
import 'studio_loading.dart';

/// Compact current-turn disclosure. Source order and identities remain owned by
/// the runtime/history; only the grouped presentation is reversed here.
class ProfileLiveExecution extends StatefulWidget {
  const ProfileLiveExecution({
    super.key,
    required this.entries,
    this.savedActivity,
    this.startedAt,
    this.endedAt,
    this.running = true,
    this.indicator,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  });

  final List<ChatActivityEntry> entries;
  final TranscriptTimelineSection? savedActivity;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final bool running;
  final Widget? indicator;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  @override
  State<ProfileLiveExecution> createState() => _ProfileLiveExecutionState();
}

class _ProfileLiveExecutionState extends State<ProfileLiveExecution>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _rowKeys = <Object, GlobalKey>{};
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _outerAnchor = GlobalKey();
  List<Object> _order = const [];
  bool _expanded = false;
  bool _visited = false;
  bool _readingDetails = false;
  Object? _anchorRevision;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ProfileLiveExecution oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running && !widget.running) {
      _expanded = false;
    } else {
      _preserveReading();
    }
  }

  void _preserveReading() {
    if (!_expanded ||
        !_scroll.hasClients ||
        (_scroll.offset <= 0 && !_readingDetails)) {
      return;
    }
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    for (final identity in _order) {
      final box = _rowKeys[identity]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final position = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (position + box.size.height <= 0) continue;
      final revision = _anchorRevision = Object();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_expanded ||
            _anchorRevision != revision ||
            !_scroll.hasClients) {
          return;
        }
        final next = _rowKeys[identity]?.currentContext?.findRenderObject();
        final nextViewport = _viewport.currentContext?.findRenderObject();
        if (next is! RenderBox ||
            nextViewport is! RenderBox ||
            !next.hasSize ||
            !nextViewport.hasSize) {
          return;
        }
        final delta =
            next.localToGlobal(Offset.zero, ancestor: nextViewport).dy -
            position;
        if (delta.abs() < .5) return;
        _scroll.jumpTo(
          (_scroll.offset + delta).clamp(
            _scroll.position.minScrollExtent,
            _scroll.position.maxScrollExtent,
          ),
        );
      });
      break;
    }
  }

  void _toggle() {
    ExpansionAnchorNotification(
      _outerAnchor.currentContext!,
      allowBottomGap: !_expanded,
    ).dispatch(context);
    setState(() {
      _expanded = !_expanded;
      if (!_expanded) _readingDetails = false;
      _visited = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rows = <(Object, Widget)>[];
    var savedGroups = <TranscriptTimelineGroup>[];
    var liveTools = <ChatActivityEntry>[];
    Object boundary = 'initial';
    DateTime? startedAt = widget.startedAt;
    String? latestReasoning;
    var totalTools = 0;

    void flush({DateTime? endedAt, bool running = false}) {
      if (savedGroups.isEmpty && liveTools.isEmpty) return;
      final saved = List<TranscriptTimelineGroup>.unmodifiable(savedGroups);
      final live = List<ChatActivityEntry>.unmodifiable(liveTools);
      final count = saved
          .where((group) => group.isTool)
          .fold(
            live.whereType<ChatToolEntry>().length,
            (count, group) => count + group.messages.length,
          );
      totalTools += count;
      rows.add((
        ('run', boundary),
        ProfileActivitySection(
          label: count == 0
              ? 'Activity'
              : 'Activity · $count ${count == 1 ? 'tool' : 'tools'}',
          subtitle:
              startedAt != null &&
                  (endedAt != null ? !endedAt.isBefore(startedAt) : running)
              ? ActivityTime.interval(start: startedAt, end: endedAt)
              : null,
          detailsBuilder: (_) => ProfileActivityTimeline(
            groups: saved,
            noticeBuilder: (entry) => ProfileMessage(message: entry.message),
            newestFirst: true,
            currentActivity: [
              if (live.isNotEmpty)
                ProfileExecutionActivity(
                  entries: live.reversed.toList(growable: false),
                  loadImage: widget.loadImage,
                  onOpenResource: widget.onOpenResource,
                  onShareResource: widget.onShareResource,
                ),
            ],
            loadImage: widget.loadImage,
            onOpenResource: widget.onOpenResource,
            onShareResource: widget.onShareResource,
          ),
        ),
      ));
      savedGroups = [];
      liveTools = [];
    }

    for (final group
        in widget.savedActivity?.groups ?? <TranscriptTimelineGroup>[]) {
      if (group.isReasoning) {
        final entry = group.messages.first;
        if (entry.reasoning.trim().isEmpty) continue;
        flush(endedAt: entry.timestamp);
        startedAt = entry.timestamp;
        boundary = ('saved-reasoning', entry.presentationId);
        latestReasoning = entry.reasoning;
        rows.add((
          boundary,
          ProfileReasoningDisclosure(
            text: entry.reasoning,
            heading: reasoningHeading(entry.reasoning),
          ),
        ));
      } else if (!group.isAgentNotice) {
        savedGroups.add(group);
      }
    }
    for (final entry in widget.entries) {
      switch (entry) {
        case ChatToolEntry() || ChatRequestEntry():
          liveTools.add(entry);
        case ChatReasoningEntry():
          if (entry.text.trim().isEmpty) continue;
          flush(endedAt: entry.postedAt);
          startedAt = entry.postedAt;
          boundary = ('reasoning', entry.identity);
          latestReasoning = entry.text;
          rows.add((
            boundary,
            ProfileReasoningDisclosure(
              text: entry.text,
              heading: reasoningHeading(entry.text),
              running: entry.running,
              source: entry.source,
              availableText: entry.availableText,
            ),
          ));
      }
    }
    flush(endedAt: widget.endedAt, running: widget.running);
    _order = rows.reversed.map((row) => row.$1).toList(growable: false);
    _rowKeys.removeWhere((identity, _) => !_order.contains(identity));
    if (rows.isEmpty) return const SizedBox.shrink();
    final tokens = WingTokens.of(context);
    final heading = _expanded || !widget.running
        ? 'Activity'
        : latestReasoning == null
        ? 'Working'
        : reasoningHeading(latestReasoning);
    return ConversationGestureBoundary(
      blocked: true,
      child: ExpansionSizeObserver(
        key: _outerAnchor,
        child: Column(
          key: const ValueKey('live-activity'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: _expanded,
              child: StudioButtonPress(
                child: InkWell(
                  key: const ValueKey('live-activity-toggle'),
                  onTap: _toggle,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        widget.indicator ?? const StudioWingMark(size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                heading,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.typography.body.copyWith(
                                  fontSize: 14,
                                ),
                              ),
                              if (totalTools > 0) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '$totalTools ${totalTools == 1 ? 'tool' : 'tools'}',
                                  style: tokens.typography.label.copyWith(
                                    fontSize: 12,
                                    color: tokens.muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.chevron_right,
                          size: 16,
                          color: tokens.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_visited)
              Offstage(
                offstage: !_expanded,
                child: TickerMode(
                  enabled: _expanded,
                  child: ProfileActivityGuide(
                    inset: 8,
                    child: NotificationListener<ExpansionAnchorNotification>(
                      // The transcript anchors changes to the enclosing row
                      // while this viewport bounds the expanded content.
                      onNotification: (_) {
                        _readingDetails = true;
                        return false;
                      },
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(
                            360,
                            MediaQuery.sizeOf(context).height * .45,
                          ),
                        ),
                        child: SingleChildScrollView(
                          key: _viewport,
                          controller: _scroll,
                          primary: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final row in rows.reversed)
                                Padding(
                                  key: _rowKeys.putIfAbsent(
                                    row.$1,
                                    GlobalKey.new,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: row.$2,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
