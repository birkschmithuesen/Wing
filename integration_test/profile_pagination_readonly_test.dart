import 'package:wing/core/services/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';

/// Uses a saved Android connection and its secure credentials. No server writes,
/// model turns, seeded conversations, or transcript reads. Logs counts only.
/// Pagination is bounded to 40 pages per profile to limit production load.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const label = String.fromEnvironment('PAGING_CONNECTION_LABEL');
  const expectedHost = String.fromEnvironment('PAGING_EXPECTED_HOST');
  testWidgets(
    'read-only real gateway paging and profile isolation',
    (tester) async {
      expect(label, isNotEmpty);
      expect(expectedHost, isNotEmpty);
      final preferences = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(preferences);
      final connections = await manager.loadConnectionsWithSecrets();
      final connection = connections.singleWhere(
        (c) => c.label == label && c.host == expectedHost,
      );
      // Reuse credentials only. Restoring the installed app's pending work can
      // mutate the server, even when this test only calls browsing methods.
      SharedPreferences.setMockInitialValues({});
      final isolatedPreferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(isolatedPreferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        appPreferences: appPreferences,
        access: manager.accessFor(connection),
        connectionIdentity: await ProfileConnectionIdentity().resolve(
          connection,
        ),
        preferences: isolatedPreferences,
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
              if (endpoint != 'sessions' && endpoint != 'sessions/search') {
                throw StateError(
                  'Read-only paging blocked an unexpected route',
                );
              }
              return live.read(endpoint, query);
            },
            rpc: (method, params) {
              if (method != 'projects.tree') {
                throw StateError(
                  'Read-only paging blocked a non-allowlisted RPC',
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
      await tester.pumpWidget(
        MaterialApp(home: ProfileWorkspaceScreen(controller: controller)),
      );
      var largeProfiles = 0;
      final names = controller.discovery!.profiles.map((p) => p.name).toList();
      expect(names, isNotEmpty, reason: 'Paging requires at least one profile');
      for (var index = 0; index < names.length; index++) {
        await controller.navigateProfile(names[index]);
        expect(controller.error, isNull);
        final data = controller.current!;
        expect(data.scope.profileName, names[index]);
        expect(
          data.sessions.every((row) => row['profile'] == names[index]),
          isTrue,
        );
        final pins = data.sessions
            .where((r) => r['pinned'] == true)
            .map((r) => r['id'])
            .toSet();
        var pages = 1;
        while (data.nextSessionOffset != null && pages < 40) {
          await controller.loadMoreSessions();
          expect(data.sessionsPageError, isNull);
          expect(
            data.sessions.every((r) => r['profile'] == names[index]),
            isTrue,
          );
          expect(
            data.sessions.map((r) => r['id']).toSet().length,
            data.sessions.length,
          );
          expect(
            data.sessions.map((r) => r['id']).toSet().containsAll(pins),
            isTrue,
          );
          pages++;
        }
        if (data.sessions.length > 100) largeProfiles++;
        debugPrint(
          '[paging-readonly] profile ${index + 1}: pages=$pages unique=${data.sessions.length} pins=${pins.length} more=${data.nextSessionOffset != null}',
        );
        // Render actual loaded rows, then inspect one authoritative project.
        await tester.pumpAndSettle();
        if (data.projects.isNotEmpty) {
          final largest = data.projects.reduce(
            (a, b) =>
                ((a['sessionCount'] as num?) ?? 0) >=
                    ((b['sessionCount'] as num?) ?? 0)
                ? a
                : b,
          );
          await controller.selectProject(largest);
          expect(data.projectSessionsError, isNull);
          expect(
            data.projectSessions.every((r) => r['profile'] == names[index]),
            isTrue,
          );
          await tester.pumpAndSettle();
          if (data.projectSessions.length > 100) {
            final last = data.projectSessions.last;
            final row = find.byKey(
              ValueKey('chat-${names[index]}-${last['id']}'),
            );
            await tester.scrollUntilVisible(
              row,
              500,
              scrollable: find.byType(Scrollable).last,
              maxScrolls: 100,
            );
            expect(
              row.hitTestable(),
              findsOneWidget,
              reason:
                  'A project member beyond the first page must be reachable',
            );
          }
          debugPrint(
            '[paging-readonly] project ${index + 1}: members=${data.projectSessions.length}',
          );
          await controller.selectProject(null);
        }
      }
      // Check navigation retention. This is not a held-read race test: the
      // previous loop may already have exhausted pagination on the live host.
      await controller.navigateProfile(names.first);
      final initial = controller.current!;
      await controller.navigateProfile(names.last);
      expect(controller.current!.scope.profileName, names.last);
      await controller.navigateProfile(names.first);
      expect(controller.current, same(initial));
      expect(initial.sessionsLoadingMore, isFalse);
      expect(
        initial.sessions.every((r) => r['profile'] == names.first),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        largeProfiles,
        greaterThan(0),
        reason: 'No >100-chat profile was available to verify real volume.',
      );
      debugPrint(
        '[paging-readonly] PASS: profiles=${names.length} profiles_over_100=$largeProfiles; no server mutations or model calls.',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
