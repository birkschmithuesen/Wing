import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'support/profile_paging_fixture.dart';

class MembershipFixture extends ProfilePagingFixture {
  bool omitLast = false;
  String project = 'p99';

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async {
        if (method == 'projects.update') {
          return {
            'project': {
              'id': params['id'],
              'name': params['name'],
              'primary_path': '/project/99',
            },
          };
        }
        return base.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> projects(String profile) =>
      [
            for (var i = 0; i < 100; i++)
              {
                'id': 'p$i',
                'label': 'Project $i',
                'path': '/project/$i',
                'lastActive': now,
                'sessionIds': i.toString() == project.substring(1)
                    ? ['chat-${count - 1}']
                    : <String>[],
              },
            {
              'id': 'home',
              'label': 'Home',
              'isNoProject': true,
              'lastActive': now,
              'sessionIds': [for (var i = 0; i < count - 1; i++) 'chat-$i'],
            },
          ]
          .map(
            (row) => {
              ...row,
              if (omitLast && row['id'] == project) 'sessionIds': <String>[],
            },
          )
          .toList();
}

void main() {
  late MembershipFixture fixture;
  late ProfileWorkspaceController owner;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = MembershipFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'membership-owner',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await owner.initialize();
  });
  tearDown(() {
    owner.dispose();
    appPreferences.dispose();
  });

  Future<ProfileChat> open(String id) async {
    final chat = (await owner.openSession(
      ProfileSessionKey(owner.current!.scope, id),
    ))!;
    for (var i = 0; i < 20 && chat.projectLoading; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(chat.projectLoading, isFalse);
    return chat;
  }

  int treeReads() => fixture.calls
      .where(
        (call) =>
            call.$2 == 'projects.tree' && call.$3.containsKey('session_limit'),
      )
      .length;

  test(
    '100 projects share one tree for assigned and proven Home chats',
    () async {
      final assigned = await open('chat-124');
      expect(assigned.projectId, 'p99');
      owner.showList();
      final unassigned = await open('chat-0');
      expect(unassigned.projectId, isNull);
      expect(unassigned.projectLookupFailed, isFalse);
      for (var i = 0; i < 10; i++) {
        owner.showList();
        await open('chat-0');
      }
      expect(treeReads(), 1);
      expect(
        fixture.calls.where((call) => call.$2 == 'projects.project_sessions'),
        isEmpty,
      );
    },
  );

  test(
    'large histories request adequate coverage and absent keys remain unknown',
    () async {
      fixture.count = 6100;
      fixture.omitLast = true;
      final chat = await open('chat-6099');
      expect(chat.projectLookupFailed, isTrue);
      expect(owner.chatProjectLabel(chat), 'Project unavailable');
      expect(
        fixture.calls
            .lastWhere((call) => call.$2 == 'projects.tree')
            .$3['session_limit'],
        6100,
      );
      owner.showList();
      await open('chat-6099');
      expect(treeReads(), 1);
    },
  );

  test('refresh and profile changes discard prior membership', () async {
    final chat = await open('chat-124');
    expect(chat.projectId, 'p99');
    fixture.project = 'p4';
    await owner.switchProfile('personal');
    final reopened = await open('chat-124');
    expect(reopened.projectId, 'p4');
    expect(treeReads(), 2);
    await owner.switchProfile('work');
    await open('chat-124');
    expect(treeReads(), 3);
  });

  test('project mutation and reconnect discard cached membership', () async {
    final chat = await open('chat-124');
    expect(chat.projectId, 'p99');
    fixture.project = 'p4';
    await owner.updateProject(
      owner.current!.scope,
      'p99',
      name: 'Renamed',
      canDispatch: () => true,
    );
    await open('chat-124');
    expect(chat.projectId, 'p4');
    expect(treeReads(), 2);
    fixture.project = 'p5';
    await owner.reconnect(owner.current!.scope);
    await open('chat-124');
    expect(chat.projectId, 'p5');
    expect(treeReads(), 3);
  });
}
