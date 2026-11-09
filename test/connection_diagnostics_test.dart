import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:image/image.dart' as image;
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/attachment_image_worker.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_diagnostics.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_connection_failure.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import 'support/bots_fixture.dart';

BotsRepository _imageRepository(ScopedRpc rpc) => BotsRepository.forServer(
  AdministrationRepository(
    connectionId: 'host',
    connectionIdentity: 'instance-1',
    connectionLabel: 'Home server',
    request: (_, _, _, _) async => throw StateError('Unexpected HTTP read'),
    settingsWrite: (_, _, _, _) async =>
        throw StateError('Unexpected settings'),
    ownedMutation: (_, _, _, _, _, _) async =>
        throw StateError('Unexpected write'),
    gateway: (profile) => ProfileGateway(
      scope: WorkspaceScope(connectionId: 'host', profileName: profile),
      get: (_, _) async => throw StateError('Unexpected profile read'),
      rpc: rpc,
      discover: () async => const ProfileDiscovery(
        profiles: [],
        currentName: null,
        activeName: null,
      ),
    ),
  ),
  groupObservations: GroupObservations(
    WorkspaceScope(
      connectionId: 'host',
      connectionIdentity: 'instance-1',
      profileName: 'default',
    ),
  ),
);

void main() {
  late DebugPrintCallback previousPrint;
  late List<String> lines;
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  List<Map<String, dynamic>> events() => lines
      .where((line) => line.startsWith('[WingConnection] '))
      .map(
        (line) =>
            jsonDecode(line.substring('[WingConnection] '.length))
                as Map<String, dynamic>,
      )
      .toList();
  setUp(() async {
    previousPrint = debugPrint;
    lines = [];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = Host();
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'diagnostic-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    lines.clear();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
    debugPrint = previousPrint;
  });

  test(
    'group and avatar generation pass the strict stock image schema',
    () async {
      final bytes = image.encodePng(image.Image(width: 16, height: 16));
      final calls = <Map<String, dynamic>>[];
      final repository = _imageRepository((method, params) async {
        expect(method, 'image.generate');
        calls.add(params);
        const allowed = {'prompt', 'aspect_ratio', 'max_bytes', 'probe'};
        if (params.keys.any((key) => !allowed.contains(key))) {
          throw JsonRpcError(
            method,
            'invalid params: profile: Extra inputs are not permitted',
            code: 4000,
          );
        }
        return {
          'available': true,
          'success': true,
          'image_data': base64Encode(bytes),
        };
      });
      expect(
        await repository.generateGroupPicture('Team emblem', () => true, () {}),
        bytes,
      );
      final bot = (await BotsFixture().repository.bots()).first;
      expect(
        await repository.generateAvatar(bot, 'Bot emblem', () => true, () {}),
        bytes,
      );
      expect(calls, [
        {
          'prompt': 'Team emblem',
          'aspect_ratio': 'square',
          'max_bytes': 8000000,
        },
        {
          'prompt': 'Bot emblem',
          'aspect_ratio': 'square',
          'max_bytes': 2000000,
        },
      ]);
    },
  );

  test(
    'production group generation admits larger originals and bounds the icon',
    () async {
      final original = image.encodePng(
        image.Image(width: 1024, height: 768, numChannels: 3),
        level: 0,
      );
      expect(original.length, greaterThan(2000000));
      final repository = _imageRepository((method, params) async {
        expect(method, 'image.generate');
        expect(params.containsKey('profile'), false);
        return {
          'available': true,
          'success': true,
          'image': '/generated/room.png',
          if (original.length <= (params['max_bytes'] as int))
            'image_data': 'data:image/png;base64,${base64Encode(original)}',
        };
      });
      final bytes = await repository.generateGroupPicture(
        'Room emblem',
        () => true,
        () {},
      );
      expect(bytes, original);
      final thumbnail = encodeRoomThumbnail((
        bytes,
        BotsRepository.groupPictureMaxBytes,
      ));
      expect(thumbnail.length, lessThanOrEqualTo(45000));
      final decoded = image.decodeImage(thumbnail)!;
      expect((decoded.width, decoded.height), (256, 256));
    },
  );

  test(
    'generated group originals above 8 MB are rejected before decoding',
    () async {
      final repository = _imageRepository(
        (_, _) async => {
          'available': true,
          'success': true,
          'image_data': base64Encode(Uint8List(8000001)),
        },
      );
      await expectLater(
        repository.generateGroupPicture('Room emblem', () => true, () {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        events().singleWhere(
          (event) => event['event'] == 'bots.image_generation_failed',
        )['stage'],
        'decode',
      );
      expect(
        () => encodeRoomThumbnail((Uint8List(8000001), 45000)),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'bot metadata commands retain profile scope and retired images are not sent',
    () async {
      final calls = <Map<String, dynamic>>[];
      final gateway = ProfileGateway(
        scope: WorkspaceScope(connectionId: 'host', profileName: 'atlas'),
        get: (_, _) async => {},
        rpc: (_, params) async {
          calls.add(params);
          return {};
        },
        discover: () async => const ProfileDiscovery(
          profiles: [],
          currentName: null,
          activeName: null,
        ),
      );
      await gateway.botCommand(
        'profiles.configure',
        {'name': 'atlas'},
        canDispatch: () => true,
        onDispatched: () {},
      );
      expect(calls.single, {'name': 'atlas', 'profile': 'atlas'});
      await expectLater(
        gateway.botCommand(
          'image.generate',
          {'prompt': 'Unsent'},
          canDispatch: () => false,
          onDispatched: () => fail('Retired command dispatched'),
        ),
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      expect(calls, hasLength(1));
    },
  );

  test(
    'RPC failure logs explain schema and timing without exposing payloads',
    () async {
      const secret = 'SECRET_NEVER_LOG';
      final repository = _imageRepository(
        (method, _) async => throw JsonRpcError(
          method,
          secret,
          code: 4000,
          data: {'token': secret},
        ),
      );
      await expectLater(
        repository.generateGroupPicture(secret, () => true, () {}),
        throwsA(isA<JsonRpcError>()),
      );
      final rpc = events().singleWhere(
        (event) => event['event'] == 'gateway.rpc_failed',
      );
      expect(rpc['rpc_failure'], 'invalid_params');
      expect(rpc['parameter_count'], 3);
      expect(rpc['profile_parameter'], false);
      expect(rpc['elapsed_ms'], isA<int>());
      final preparation = events().singleWhere(
        (event) => event['event'] == 'bots.image_generation_failed',
      );
      expect(preparation['stage'], 'request');
      expect(preparation['operation'], 'group_picture');
      expect(preparation['rpc_code'], 4000);
      expect(lines.join(), isNot(contains(secret)));
    },
  );

  test(
    'image logs distinguish provider, transfer and decoding failures',
    () async {
      const secret = 'SECRET_NEVER_LOG';
      for (final scenario in [
        (
          {'available': false, 'success': false, 'error': secret},
          'provider',
          'provider_unavailable',
        ),
        (
          {'available': true, 'success': false, 'error': secret},
          'provider',
          'generation_failed',
        ),
        (
          {
            'available': true,
            'success': true,
            'image': 'https://host/?token=$secret',
          },
          'transfer',
          'image_data_missing',
        ),
        (
          {'available': true, 'success': true, 'image_data': secret},
          'decode',
          'invalid_image_data',
        ),
      ]) {
        lines.clear();
        final repository = _imageRepository((_, _) async => scenario.$1);
        await expectLater(
          repository.generateGroupPicture(secret, () => true, () {}),
          throwsA(anyOf(isA<Exception>(), isA<Error>())),
        );
        final event = events().singleWhere(
          (event) => event['event'] == 'bots.image_generation_failed',
        );
        expect(event['stage'], scenario.$2);
        expect(event['failure'], scenario.$3);
        expect(event['elapsed_ms'], isA<int>());
        expect(lines.join(), isNot(contains(secret)));
      }
    },
  );

  testWidgets(
    'recovery logs retain failure, capped retry and successful resume',
    (tester) async {
      host.connectFailures = 5;
      host.gateways['a']!.onConnectionChanged!(false);
      for (final seconds in [1, 2, 4, 8, 16]) {
        await tester.pump(Duration(seconds: seconds));
      }
      final failures = events().where(
        (event) => event['event'] == 'workspace.recovery_failed',
      );
      expect(failures, hasLength(5));
      expect(failures.first, containsPair('retryable', true));
      expect(failures.first['causes'], [
        {'type': 'TimeoutException'},
      ]);
      expect(events().last['event'], 'workspace.recovery_scheduled');
      expect(events().last['delay_ms'], 30000);
      expect(controller.error, isNull);
      await tester.pump(const Duration(seconds: 30));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(events().last['event'], 'workspace.recovered');
      expect(controller.connectionStatus.liveAvailable('a'), isTrue);
      debugPrint = tester.binding.debugPrintOverride;
    },
  );

  test('technical errors omit prose, payloads, URLs and secrets', () {
    const secret = 'SECRET_NEVER_LOG';
    final failures = <Object>[
      FormatException(secret, '{"password":"$secret"}', 3),
      StateError(secret),
      SocketException(
        'https://user:$secret@host/?ticket=$secret',
        osError: OSError(secret, 111),
      ),
      WebSocketChannelException.from(
        SocketException(secret, osError: OSError(secret, 101)),
      ),
      JsonRpcError(
        'session.resume',
        secret,
        code: -32603,
        reason: secret,
        data: {'token': secret},
      ),
      DashboardRequestNotSentException(
        const DashboardHttpException(401, 'sessions/$secret?token=$secret'),
      ),
    ];
    for (final failure in failures) {
      logConnectionDiagnostic(
        'test.failure',
        error: failure,
        details: workspaceFailureDiagnostic(failure),
        stackTrace: StackTrace.current,
      );
    }
    expect(lines.join(), isNot(contains(secret)));
    final logged = events();
    expect(logged[0]['causes'], [
      {'type': 'FormatException', 'offset': 3},
    ]);
    expect(logged[2]['causes'], [
      {'type': 'SocketException', 'os_error_code': 111},
    ]);
    expect(logged[3]['causes'], [
      {'type': 'WebSocketChannelException'},
      {'type': 'SocketException', 'os_error_code': 101},
    ]);
    expect(logged[4]['rpc_code'], -32603);
    expect(logged[4]['rpc_method'], 'session.resume');
    expect(logged[5]['request_sent'], isFalse);
    expect(logged[5]['http_status'], 401);
    expect(
      workspaceFailureMessage(failures[4]),
      'Couldn’t open this workspace. Check the connection settings and try again.',
    );
    expect(
      connectionDiagnosticEndpoint(
        'https://user:$secret@host/api/sessions/$secret?token=$secret',
      ),
      'sessions/…',
    );
  });

  test(
    'a responsive server can close only the socket and logs retain its close code',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final socketReady = Completer<WebSocket>();
        server.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            socketReady.complete(await WebSocketTransformer.upgrade(request));
          } else {
            request.response.write('healthy');
            await request.response.close();
          }
        });
        final client = WsClient(
          'http://127.0.0.1:${server.port}',
          token: 'SECRET_NEVER_LOG',
        );
        final closed = Completer<void>();
        client.onConnectionChanged = (connected) {
          if (!connected && !closed.isCompleted) closed.complete();
        };
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        await client.connect();
        final socket = await socketReady.future;
        unawaited(socket.close(1001, 'SECRET_NEVER_LOG'));
        await closed.future.timeout(const Duration(seconds: 2));
        final requestClient = HttpClient();
        try {
          final response = await (await requestClient.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/health'),
          )).close();
          expect(await utf8.decoder.bind(response).join(), 'healthy');
        } finally {
          requestClient.close(force: true);
        }
        final closeEvent = events().singleWhere(
          (event) => event['event'] == 'ws.remote_closed',
        );
        expect(closeEvent['close_code'], 1001);
        expect(lines.join(), isNot(contains('SECRET_NEVER_LOG')));
      }, _RealHttpOverrides());
    },
  );

  test(
    'failed HTTP reads log status without response or authentication content',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/') {
            request.response.write(
              'window.__HERMES_SESSION_TOKEN__="SECRET_NEVER_LOG";',
            );
          } else {
            request.response.statusCode = 400;
            request.response.write('{"detail":"SECRET_NEVER_LOG"}');
          }
          await request.response.close();
        });
        final client = DashboardClient(host: '127.0.0.1', port: server.port);
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        await expectLater(
          client.apiGet(
            'profiles',
            queryParameters: {'token': 'SECRET_NEVER_LOG'},
          ),
          throwsA(isA<DashboardHttpException>()),
        );
        final failure = events().singleWhere(
          (event) => event['event'] == 'http.read_failed',
        );
        expect(failure['http_status'], 400);
        expect(failure['stage'], 'response');
        expect(failure['endpoint'], 'profiles');
        expect(lines.join(), isNot(contains('SECRET_NEVER_LOG')));
      }, _RealHttpOverrides());
    },
  );

  test(
    'failed HTTP writes log status without response or authentication content',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/') {
            request.response.write(
              'window.__HERMES_SESSION_TOKEN__="SECRET_NEVER_LOG";',
            );
          } else {
            await request.drain<void>();
            request.response.statusCode = 403;
            request.response.write('{"detail":"SECRET_NEVER_LOG"}');
          }
          await request.response.close();
        });
        final client = DashboardClient(host: '127.0.0.1', port: server.port);
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        await expectLater(
          client.apiWriteOwned(
            'PATCH',
            'sessions/SECRET_NEVER_LOG',
            body: {'unread': false, 'password': 'SECRET_NEVER_LOG'},
            canDispatch: () => true,
            onDispatched: () {},
          ),
          throwsException,
        );
        final failure = events().singleWhere(
          (event) => event['event'] == 'http.write_failed',
        );
        expect(failure['http_status'], 403);
        expect(failure['method'], 'PATCH');
        expect(failure['endpoint'], 'sessions/…');
        expect(lines.join(), isNot(contains('SECRET_NEVER_LOG')));
      }, _RealHttpOverrides());
    },
  );

  test('release stack offsets survive without copying arbitrary trace text', () {
    logConnectionDiagnostic(
      'test.release',
      error: StateError('SECRET_NEVER_LOG'),
      stackTrace: StackTrace.fromString(
        'isolate_dso_base: 0000007000000000\n'
        '#00 abs 0000007000000123 virt 0000000000000123 _kDartIsolateSnapshotInstructions+0x123\n'
        'SECRET_NEVER_LOG\n'
        '#1 Injected (https://host/?ticket=SECRET_NEVER_LOG)',
      ),
    );
    final event = events().single;
    expect(event['stack_bases'], ['isolate_dso_base: 0000007000000000']);
    expect(event['stack'], ['#00 abs 0000007000000123 virt 0000000000000123']);
    expect(lines.join(), isNot(contains('SECRET_NEVER_LOG')));
  });

  test('logging failure cannot break recovery', () async {
    debugPrint = (message, {wrapWidth}) =>
        throw StateError('logging unavailable');
    await controller.resumeConnection();
    expect(controller.connectionStatus.liveAvailable('a'), isTrue);
    debugPrint = previousPrint;
  });
}

class _RealHttpOverrides extends HttpOverrides {}
