import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import '../test/support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';

/// Production read-only acceptance. No session.resume, prompts, or mutations.
/// Display metadata and message bodies are never printed to logs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const label = String.fromEnvironment('PAGING_CONNECTION_LABEL');
  const host = String.fromEnvironment('PAGING_EXPECTED_HOST');
  testWidgets(
    'production history beyond 500 and whole-profile search',
    (tester) async {
      expect(label, isNotEmpty);
      expect(host, isNotEmpty);
      final preferences = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(preferences);
      final connection = (await manager.loadConnectionsWithSecrets())
          .singleWhere((c) => c.label == label && c.host == host);
      // Use the saved secret only for transport. Never restore pending runtimes
      // or overwrite the owner's selected profile/preferences in a read test.
      SharedPreferences.setMockInitialValues({});
      final fixturePreferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(fixturePreferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        appPreferences: appPreferences,
        access: manager.accessFor(connection),
        connectionIdentity: await ProfileConnectionIdentity().resolve(
          connection,
        ),
        preferences: fixturePreferences,
        gatewayFactory: (scope) {
          final live = ProfileGateway.forConnection(
            manager.accessFor(connection),
            scope,
          );
          return ProfileGateway(
            scope: scope,
            discover: live.discover,
            connect: live.connect,
            close: live.close,
            get: (endpoint, query) {
              if (endpoint != 'sessions' &&
                  endpoint != 'sessions/search' &&
                  !RegExp(r'^sessions/[^/]+/messages$').hasMatch(endpoint)) {
                throw StateError('Read-only test blocked an unexpected route');
              }
              return live.read(endpoint, query);
            },
            rpc: (method, params) {
              if (method != 'projects.tree') {
                throw StateError(
                  'Read-only test blocked a non-allowlisted RPC',
                );
              }
              return live.call(method, params);
            },
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.error, isNull);
      final browser = ChatBrowserData(controller);
      addTearDown(browser.dispose);
      final names = controller.discovery!.profiles.map((p) => p.name).toList();
      var longHistories = 0;
      var remoteMatches = 0;
      for (var index = 0; index < names.length; index++) {
        await controller.navigateProfile(names[index]);
        expect(controller.error, isNull);
        final data = controller.current!;
        final firstIds = data.sessions.map((s) => s['id']).toSet();
        var pages = 1;
        while (data.nextSessionOffset != null && pages < 40) {
          await controller.loadMoreSessions();
          expect(data.sessionsPageError, isNull);
          pages++;
        }
        if (data.sessions.isEmpty) continue;
        final outside = data.sessions
            .where((s) => !firstIds.contains(s['id']))
            .firstOrNull;
        if (outside != null) {
          final id = outside['id'] as String;
          await browser.search(id);
          expect(browser.state.searchError, isNull);
          expect(
            browser.state.profiles[names[index]]!.searchMatches,
            contains(id),
          );
          final target = ProfileSessionKey(data.scope, id);
          expect(
            browser.entries.any((entry) => entry.sessionKey == target),
            isTrue,
          );
          remoteMatches++;
        }
        await browser.search('hermes');
        expect(browser.state.searchError, isNull);
        final contentMatches =
            browser.state.profiles[names[index]]!.searchMatches;
        expect(contentMatches.length, lessThanOrEqualTo(100));
        debugPrint(
          '[history-search-readonly] profile ${index + 1}: content_matches=${contentMatches.length} outside_first_page=${outside != null}',
        );
        final candidates = data.sessions.toList()
          ..sort(
            (a, b) => ((b['message_count'] as num?) ?? 0).compareTo(
              (a['message_count'] as num?) ?? 0,
            ),
          );
        final id = candidates.first['id'] as String;
        final runtime = ChatRuntime(runtimeId: '');
        final chat = composeChat(
          controller: controller,
          preferences: controller.preferences,
          key: ProfileSessionKey(data.scope, id),
          runtime: runtime,
          title: 'Read-only history verification',
        );
        var readingAlive = true;
        final readingChanges = ChangeNotifier();
        bool canPublishReading() =>
            readingAlive && identical(controller.current, data);
        void readingChanged() {
          if (canPublishReading()) readingChanges.notifyListeners();
        }

        Future<void> refreshReading() => chat.reading.refresh(
          sessionId: id,
          runtimeId: '',
          canPublish: canPublishReading,
          onChanged: readingChanged,
        );
        Future<void> loadOlderReading() => chat.reading.loadOlder(
          canPublish: canPublishReading,
          onChanged: readingChanged,
        );
        try {
          await refreshReading();
          expect(chat.reading.historyError, isNull);
          final tail = chat.reading.messages.map((m) => m['id']).toSet();
          var historyPages = 1;
          while (chat.reading.nextHistoryOffset != null &&
              chat.reading.messages.length <= 550 &&
              historyPages < 15) {
            await loadOlderReading();
            expect(chat.reading.historyError, isNull);
            historyPages++;
          }
          expect(
            chat.reading.messages.map((m) => m['id']).toSet().length,
            chat.reading.messages.length,
          );
          expect(
            chat.reading.messages.map((m) => m['id']).toSet().containsAll(tail),
            isTrue,
          );
          if (chat.reading.messages.length > 500) longHistories++;
          debugPrint(
            '[history-search-readonly] profile ${index + 1}: history_pages=$historyPages messages=${chat.reading.messages.length} older_available=${chat.reading.nextHistoryOffset != null}',
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: readingChanges,
                  builder: (_, _) => ProfileTranscript(
                    key: ValueKey(chat.key),
                    presentation: TranscriptPresentation.capture(
                      identity: chat.key,
                      reader: chat.reading,
                      timeline: TranscriptTimeline.project(
                        [
                          ...chat.reading.messages,
                          ?chat.reading.streamingMessage,
                        ],
                        presentationId: chat.reading.messagePresentationId,
                        liveMessageIndex: chat.reading.streamingMessage == null
                            ? null
                            : chat.reading.messages.length,
                      ),
                      needsInput: chat.runtime.needsInput,
                      turnAdmissionBlocked: chat.runtime.blocksTurnAdmission,
                    ),
                    openingContent: chat.runtime.opening
                        ? ProfileTranscriptOpening(
                            status: controller.connectionStatus,
                            error: chat.runtime.openingError,
                            onRetry: controller.resumeConnection,
                          )
                        : null,
                    notificationReading: chat.reading,
                    onAnswerRead: (target) =>
                        controller.notificationAnswerRead(chat, target),
                    onRefreshHistory: refreshReading,
                    onLoadOlder: () => loadOlderReading(),
                    messageBuilder: (m) => ProfileMessage(message: m.message),
                    tail: const [],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.drag(
            find.byKey(const ValueKey('profile-transcript')),
            const Offset(0, 400),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (chat.reading.messages.length > 500) {
            // The live contract is reachable navigation over a long history.
            // Precise anchor preservation belongs to controlled paging tests.
            final jump = find.byKey(const ValueKey('jump-to-latest'));
            expect(jump.hitTestable(), findsOneWidget);
            final count = chat.reading.messages.length;
            await tester.tap(jump);
            await tester.pumpAndSettle();
            expect(jump, findsNothing);
            expect(chat.reading.readingPosition.resume, isNull);
            expect(chat.reading.messages.length, count);
          }
          // Refresh keeps the older prefix when the server's newest page overlaps.
          final oldest = chat.reading.messages.firstOrNull?['id'];
          await refreshReading();
          expect(chat.reading.historyError, isNull);
          expect(chat.reading.messages.firstOrNull?['id'] == oldest, isTrue);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          readingAlive = false;
          chat.reading.dispose();
          chat.composer.dispose();
          runtime.dispose();
          readingChanges.dispose();
        }
      }
      expect(remoteMatches, greaterThan(0));
      expect(
        longHistories,
        greaterThan(0),
        reason: 'No real history over 500 rows was available.',
      );
      debugPrint(
        '[history-search-readonly] PASS: profiles=${names.length} histories_over_500=$longHistories remote_searches=$remoteMatches; no resume, mutations, or model calls.',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
