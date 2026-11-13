import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed visibility save retains the actually confirmed chat filter',
    () async {
      SharedPreferences.resetStatic();
      final platform = _FalseVisibilityStore();
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final controller = ProfileWorkspaceController(
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
        connectionIdentity: 'verified-host',
        preferences: prefs,
        appPreferences: owner,
        gatewayFactory: (_) => throw StateError('No network is needed'),
      );
      addTearDown(() {
        controller.dispose();
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      Object? failure;
      try {
        await controller.setSessionVisibility(SessionVisibility.all);
      } catch (error) {
        failure = error;
      }
      expect(platform.writes, contains('all'));
      expect(
        (await platform.getAll())[_FalseVisibilityStore.key],
        'chats',
        reason: 'the platform did not acknowledge the new choice',
      );
      expect(
        controller.sessionVisibility,
        SessionVisibility.chats,
        reason: 'a failed choice cannot change the confirmed browser filter',
      );
      expect(failure, isNotNull);
    },
  );
  test(
    'malformed stored visibility sends no guessed listing and explicit repair reloads it',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_visibility_v2_host': 'automated',
      });
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final requests = <Map<String, String>>[];
      final controller = ProfileWorkspaceController(
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
        connectionIdentity: 'verified-host',
        preferences: prefs,
        appPreferences: owner,
        gatewayFactory: (scope) => ProfileGateway(
          scope: scope,
          discover: () async => const ProfileDiscovery(
            profiles: [HermesProfile(name: 'default', isDefault: true)],
            currentName: 'default',
            activeName: 'default',
          ),
          connect: () async {},
          close: () {},
          rpc: (_, _) async => {},
          get: (path, params) async {
            if (path == 'sessions') {
              requests.add(Map.of(params));
              return {'sessions': [], 'offset': 0, 'limit': 50, 'total': 0};
            }
            return {'projects': [], 'sessions': []};
          },
        ),
      );
      addTearDown(() {
        controller.dispose();
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      await controller.initialize();
      expect(requests, isEmpty);
      expect(controller.sessionVisibility, isNull);
      expect(controller.visibilityControl.notice, isNotNull);
      expect(prefs.getString('session_visibility_v2_host'), 'automated');
      await controller.setSessionVisibility(SessionVisibility.chats);
      expect(prefs.getString('session_visibility_v2_host'), 'chats');
      expect(controller.sessionVisibility, SessionVisibility.chats);
      expect(requests, isNotEmpty);
      expect(
        requests.every(
          (request) =>
              request['exclude_sources'] ==
              'cron,tool,subagent,kanban,oneshot,bot_room',
        ),
        isTrue,
      );
    },
  );
}

class _FalseVisibilityStore extends InMemorySharedPreferencesStore {
  _FalseVisibilityStore() : super.withData({key: 'chats'});
  static const key = 'flutter.session_visibility_v2_host';
  final writes = <Object>[];
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == _FalseVisibilityStore.key) {
      writes.add(value);
      if (value == 'all') return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}
