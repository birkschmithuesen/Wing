import '../../widgets/conversation_page.dart';
import '../../widgets/conversation_reading_scope.dart';
import '../../widgets/profile_subagent_panel.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import '../../widgets/conversation_activity.dart';
import '../../widgets/profile_live_work_dock.dart';
import '../../models/bots.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/bot_group_history_session.dart';
import '../profile_transcript.dart';
import '../../models/transcript_timeline.dart';
import '../../widgets/profile_message.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/wing_app_bar.dart';

class BotGroupHistoryScreen extends StatefulWidget {
  const BotGroupHistoryScreen({
    super.key,
    required this.createSession,
    required this.appearanceForMember,
    this.initialMemberId,
  });
  final BotRecord? Function(String profile) appearanceForMember;
  final String? initialMemberId;
  final BotGroupHistorySession Function() createSession;

  @override
  State<BotGroupHistoryScreen> createState() => _BotGroupHistoryScreenState();
}

class _BotGroupHistoryScreenState extends State<BotGroupHistoryScreen>
    with WidgetsBindingObserver {
  final _dock = GlobalKey<ProfileLiveWorkDockState>();
  late final _session = widget.createSession();
  String? _reportedError;
  Object? _paintedReading, _hydratingReading;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _errorNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
    _session.setVisible(true);
    final first = widget.initialMemberId == null
        ? _session.group.members.firstOrNull
        : _session.group.members
              .where((member) => member.id == widget.initialMemberId)
              .firstOrNull;
    if (first != null) unawaited(_session.select(first));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.setVisible(state == AppLifecycleState.resumed);

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final reader = _session.reader;
    if (reader.historyAvailable && !identical(_paintedReading, reader)) {
      _paintedReading = reader;
      // First paint the saved conversation and closed Activity. Live replay is
      // independent enrichment and may complete while older pages still load.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_session.reader, reader)) {
          unawaited(_hydrateActivity(reader));
        }
      });
    }
    final error = reader.historyError;
    if (error == null) {
      _errorNotice?.close();
      _errorNotice = null;
    }
    if (error != null &&
        error != _reportedError &&
        _session.reader.messages.isNotEmpty) {
      final notice = ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: StudioError(error)));
      _errorNotice = notice;
      unawaited(
        notice.closed.then((_) {
          if (identical(_errorNotice, notice)) _errorNotice = null;
        }),
      );
    }
    _reportedError = error;
  }

  Future<void> _hydrateActivity(Object reader) async {
    setState(() => _hydratingReading = reader);
    try {
      await _session.refreshLive();
    } finally {
      if (mounted && identical(_hydratingReading, reader)) {
        setState(() => _hydratingReading = null);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _errorNotice?.close();
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConversationReadingScope(
    key: ValueKey(_session.group.key),
    builder: _buildConversation,
  );

  Widget _buildConversation(BuildContext context) {
    final reading = ConversationReadingScope.maybeOf(context)!;
    final reader = _session.reader;
    final runtime = _session.runtime;
    final projection = ChatTranscriptProjection(
      savedRows: reader.messages,
      requestActivities: reader.requestActivities,
      streamingMessage: _session.streamingMessage,
      runtime: runtime,
      presentationId: reader.messagePresentationId,
      liveAnswering: _session.liveAnswering,
    );
    final timeline = projection.timeline;
    final activity = ConversationActivity(
      runtime: runtime,
      entries: projection.activity,
      beforeMessagePresentationId:
          projection.retainedActivityBeforePresentationId,
      todos: _session.todos,
      inspection: _session,
      agentsBuilder: () =>
          ProfileSubagentPanel(session: _session, embedded: true),
      live: _session.liveAnswering,
      taskCount: _session.todos.length,
      agentCount: _session.subagents.length,
    );
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _dock.currentState?.isOpen != true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _dock.currentState?.dismiss();
          setState(() {});
        }
      },
      child: ConversationPage(
        header: WingAppBar(
          context: context,
          title: const WingConversationTitle(title: 'Working history'),
          inlineContext:
              reading.active || ConversationReadingScope.compact(context),
          leading: StudioButtonPress(
            child: BackButton(
              onPressed: reading.active
                  ? reading.exit
                  : () => Navigator.of(context).maybePop(),
            ),
          ),
          contextRow: reading.active
              ? null
              : Text(
                  _session.group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          actions: [
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Refresh working history',
                onPressed: reader.historyLoading ? null : _session.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        body: StudioPageLoading(
          active:
              !reader.historyPaging &&
              (reader.historyLoading || identical(_hydratingReading, reader)),
          label: _session.historyAvailable
              ? 'Refreshing working history'
              : 'Loading working history',
          child: ConversationLayout(
            needsInput: false,
            contextHeader: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      for (final member in _session.group.members)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: StudioButtonPress(
                            child: ChoiceChip(
                              showCheckmark: false,
                              label: Text(member.name),
                              selected: _session.member?.id == member.id,
                              onSelected: (_) {
                                if (_session.member?.id == member.id) return;
                                unawaited(_session.select(member));
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Read only · This bot’s internal conversation',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            transcript: BotConversationScope(
              bot: _session.member == null
                  ? null
                  : widget.appearanceForMember(_session.member!.profile),
              name: _session.member?.name,
              child: ProfileTranscript(
                key: ValueKey(('worker-history', _session.member?.id)),
                presentation: TranscriptPresentation.capture(
                  identity: (
                    'worker-history',
                    _session.group.key,
                    _session.member?.id,
                  ),
                  reader: reader,
                  timeline: timeline,
                  needsInput: runtime.needsInput,
                  turnAdmissionBlocked: _session.liveAnswering,
                ),
                onRefreshHistory: _session.refresh,
                onLoadOlder: _session.loadOlder,
                activity: activity,
                emptyContent: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No working history is available for ${_session.member?.name ?? 'this bot'}.',
                    textAlign: TextAlign.center,
                  ),
                ),
                tail: const [],
                messageBuilder: (entry) =>
                    ProfileMessage(message: entry.message),
              ),
            ),
            footerBuilder: (context, constraints) => ConversationFooter(
              constraints: constraints,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_session.liveError case final error?)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: StudioError(error),
                    ),
                  activity.status(saving: false),
                  activity.dock(
                    key: _dock,
                    onOpenChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
