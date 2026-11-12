import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';

/// Local disposable rows only. Never point this test at production.
void main() {
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  const moveFolder = String.fromEnvironment('HERMES_TEST_PROJECT');
  test(
    'local stock session mutations retain profile ownership',
    () async {
      final dashboard = DashboardClient(host: '127.0.0.1', port: port);
      addTearDown(dashboard.close);
      final id = 'android-actions-qa-${DateTime.now().microsecondsSinceEpoch}';
      final gateways = <ProfileGateway>[];
      for (final profile in ['android-qa-a', 'android-qa-b']) {
        final gateway = ProfileGateway.forConnection(
          ConnectionAccess(
            connection: SavedConnection(
              id: 'local-actions',
              label: 'Local QA',
              host: '127.0.0.1',
              port: port,
              dashboardPortOverride: port,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          WorkspaceScope(connectionId: 'local-actions', profileName: profile),
        );
        gateways.add(gateway);
        addTearDown(gateway.close);
        expect((await gateway.discover()).named(profile), isNotNull);
        await gateway.connect();
        await dashboard.apiPost(
          'sessions/import',
          body: {
            'profile': profile,
            'sessions': [
              {
                'id': id,
                'title': 'Disposable Android action test',
                'source': 'desktop',
                'profile_name': profile,
                'started_at': DateTime.now().millisecondsSinceEpoch / 1000 - 60,
                'ended_at': DateTime.now().millisecondsSinceEpoch / 1000,
                'messages': [
                  {
                    'role': 'user',
                    'content': 'Authored test row. No model call.',
                  },
                ],
              },
            ],
          },
        );
        addTearDown(() => gateway.deleteSession(id, canDispatch: () => true));
      }
      final a = gateways.first;
      final b = gateways.last;
      await a.updateSession(id, {
        'title': 'Android QA renamed',
        'pinned': true,
        'unread': true,
      }, canDispatch: () => true);
      final first = (await a.sessions()).rows.firstWhere(
        (row) => row['id'] == id,
      );
      final second = (await b.sessions()).rows.firstWhere(
        (row) => row['id'] == id,
      );
      expect(first['title'], 'Android QA renamed');
      expect(first['pinned'], true);
      expect(first['unread'], true);
      expect(second['title'], 'Disposable Android action test');
      expect(second['pinned'], false);
      if (moveFolder.isNotEmpty) {
        final moved = await a.moveSession(
          id,
          moveFolder,
          canDispatch: () => true,
        );
        final movedRow = (await a.sessions()).rows.firstWhere(
          (row) => row['id'] == id,
        );
        final otherRow = (await b.sessions()).rows.firstWhere(
          (row) => row['id'] == id,
        );
        expect(movedRow['cwd'], moved['cwd']);
        expect(movedRow['git_repo_root'], moved['git_repo_root']);
        expect(otherRow['cwd'], second['cwd']);
      }
      await a.updateSession(id, {'archived': true}, canDispatch: () => true);
      expect(
        (await a.sessions(
          archivedOnly: true,
        )).rows.any((row) => row['id'] == id),
        true,
      );
      await a.updateSession(id, {
        'archived': false,
        'pinned': false,
        'unread': false,
      }, canDispatch: () => true);
      final restored = (await a.sessions()).rows.firstWhere(
        (row) => row['id'] == id,
      );
      expect(restored['archived'], false);
      expect(restored['unread'], false);
      await a.deleteSession(id, canDispatch: () => true);
      expect((await a.sessions()).rows.any((row) => row['id'] == id), false);
      expect((await b.sessions()).rows.any((row) => row['id'] == id), true);
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
