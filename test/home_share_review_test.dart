import 'support/canonical_gateway_fixture.dart';
import 'dart:async';
import 'package:wing/core/models/profile_session_key.dart';

import 'package:wing/core/services/shared_draft_session.dart';
import 'home_config_restore_test.dart' show homeEntryFactory;
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/attachment_image_worker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/widgets/composer_attachment_tile.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Credentials implements CredentialStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _CameraAttachments extends AttachmentDraftService {
  bool fail = false;
  int prepared = 0;
  Completer<void>? delay;

  @override
  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    void Function(AttachmentImageJob)? onImageJob,
  }) async {
    await delay?.future;
    if (fail) throw const AttachmentDraftException('Photo could not be saved.');
    return AttachmentDraft(
      id: 'captured-photo-${++prepared}',
      cachedPath: '/cache/captured-photo-$prepared.jpg',
      name: displayName,
      byteLength: 1,
      mediaType: 'image/jpeg',
      kind: AttachmentDraftKind.image,
      sourceImageFormat: AttachmentImageFormat.jpeg,
      sanitized: true,
    );
  }
}

Future<({ConnectionManager manager, AppPreferences appPreferences})>
_homeFixture() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(prefs);
  addTearDown(appPreferences.dispose);
  final manager = await ConnectionManager.create(
    prefs,
    credentialStore: _Credentials(),
  );
  return (manager: manager, appPreferences: appPreferences);
}

ProfileWorkspaceController _controller(
  SavedConnection connection,
  SharedPreferences prefs,
  AppPreferences appPreferences, {
  Set<String> missingSessions = const {},
  String resumeFailureReason = 'not_found',
  AttachmentDraftService? attachments,
  Future<void> Function()? beforeSessionRead,
  void Function(String)? onRpc,
}) {
  final controller = ProfileWorkspaceController(
    access: ConnectionAccess(connection: connection, dashboardOAuth: null),
    connectionIdentity: 'home-share-${connection.id}',
    preferences: prefs,
    appPreferences: appPreferences,
    attachmentService: attachments,
    gatewayFactory: (scope) => ProfileGateway(
      scope: scope,
      discover: () async => const ProfileDiscovery(
        profiles: [HermesProfile(name: 'default')],
        currentName: 'default',
        activeName: 'default',
      ),
      get: (path, query) async {
        if (path == 'logs') return {'file': 'gui', 'lines': <String>[]};
        if (path == 'model/info') {
          return {'provider': 'fixture', 'model': 'fixture/model'};
        }
        if (path == 'model/options') return {'providers': <Object>[]};
        if (path.endsWith('/messages')) {
          return {
            'session_id': Uri.decodeComponent(path.split('/')[1]),
            'messages': <Map<String, dynamic>>[],
            'pagination': {
              'offset': 0,
              'limit': 50,
              'returned': 0,
              'order': 'latest',
            },
          };
        }
        await beforeSessionRead?.call();
        return {
          'sessions': <Map<String, dynamic>>[],
          'offset': int.parse(query['offset']!),
          'limit': int.parse(query['limit']!),
          'total': 0,
        };
      },
      rpc: (method, params) async {
        onRpc?.call(method);
        if (method == 'session.resume' &&
            missingSessions.contains(params['session_id'])) {
          throw JsonRpcError(
            'session.resume',
            'Session does not exist',
            code: 4001,
            reason: resumeFailureReason,
          );
        }
        return method == 'session.create' || method == 'session.resume'
            ? {
                ...canonicalSnapshotFields,
                'session_id': 'runtime-${connection.id}',
                'stored_session_id': method == 'session.resume'
                    ? params['session_id']
                    : 'stored-${connection.id}',
                'session_key': method == 'session.resume'
                    ? params['session_id']
                    : 'stored-${connection.id}',
                'info': {'profile_name': 'default'},
              }
            : {'projects': <Map<String, dynamic>>[]};
      },
    ),
  );
  return controller;
}

Future<void> _pumpHome(
  WidgetTester tester,
  ConnectionManager manager,
  AndroidShareIntentService shareIntents, {
  required AppPreferences appPreferences,
  Set<String> missingSessions = const {},
  String resumeFailureReason = 'not_found',
  ProfileWorkspaceController? controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        createSharedDraftSession: (entry) => SharedDraftSession(
          connectionManager: manager,
          entrySession: entry,
          shareIntents: shareIntents,
        ),
        connManager: manager,
        appPreferences: appPreferences,
        shareIntents: shareIntents,
        createEntrySession: homeEntryFactory(
          tester,
          manager,
          appPreferences,
          create: (connection) =>
              controller ??
              _controller(
                connection,
                manager.prefs,
                appPreferences,
                missingSessions: missingSessions,
                resumeFailureReason: resumeFailureReason,
              ),
          launchIntents: null,
        ),
        createBackupSession: () => BackupSession(
          configuration: ConfigBackupService(
            connectionManager: manager,
            appPreferences: appPreferences,
          ),
          io: ConfigBackupIo(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidShareIntentService.channelName);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'acknowledgeShare') {
            expectSync((call.arguments as Map)['id'], isNotEmpty);
          }
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'share chooses its saved connection and acknowledges only after Add to draft',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = await _homeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
      await manager.saveConnection('Home', 'home.local', 8642, 'home-key');
      final shares = AndroidShareIntentService();
      addTearDown(shares.dispose);
      final payload = const AndroidSharePayload(
        id: 'share-work-1',
        text: 'Shared from another app',
      );

      await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
      shares.pendingShare.value = payload;
      await tester.pumpAndSettle();

      expect(
        find.text('Choose a Hermes instance for this shared draft'),
        findsOneWidget,
      );
      expect(shares.pendingShare.value, same(payload));
      final workChoice = find
          .ancestor(of: find.text('Work'), matching: find.byType(ListTile))
          .last;
      await tester.tap(workChoice);
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.text('Add shared content'), findsOneWidget);
      expect(find.text('Connection: Work'), findsOneWidget);
      expect(shares.pendingShare.value, same(payload));
      expect(find.byType(ProfileWorkspaceScreen), findsNothing);

      await tester.tap(find.byKey(const Key('share-add-to-draft')));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      expect(shares.pendingShare.value, isNull);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('profile-message-composer')),
            )
            .controller!
            .text,
        payload.text,
      );
    },
  );

  testWidgets(
    'cancel keeps Home review controls and Discard clears the share',
    (tester) async {
      final fixture = await _homeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
      final shares = AndroidShareIntentService();
      addTearDown(shares.dispose);
      final payload = const AndroidSharePayload(
        id: 'share-pending-1',
        text: 'Keep pending until reviewed',
      );

      await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
      shares.pendingShare.value = payload;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Add shared content'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Shared draft ready'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(shares.pendingShare.value, same(payload));

      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(shares.pendingShare.value, isNull);
      expect(find.text('Shared draft ready'), findsNothing);
    },
  );

  testWidgets('held native ACK cannot navigate to a different selected chat', (
    tester,
  ) async {
    final acknowledged = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'acknowledgeShare') {
            acknowledged.complete();
            await release.future;
          }
          return null;
        });
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    final connection = manager.getConnections().single;
    final controller = _controller(connection, manager.prefs, appPreferences);
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    const payload = AndroidSharePayload(
      id: 'held-ack-selection',
      text: 'Keep this draft at its captured destination',
    );
    await _pumpHome(
      tester,
      manager,
      shares,
      appPreferences: appPreferences,
      controller: controller,
    );
    shares.pendingShare.value = payload;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-add-to-draft')));
    await tester.pump();
    expect(acknowledged.isCompleted, isTrue);
    final staged = controller.current!.chat!;
    expect(staged.composer.observation.text, payload.text);
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'another-chat'),
    );
    release.complete();
    await tester.pumpAndSettle();
    expect(shares.pendingShare.value, isNull);
    expect(controller.current!.selectedSession, 'another-chat');
    expect(staged.composer.observation.text, payload.text);
    expect(find.byType(ProfileWorkspaceScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ACK failure keeps the staged draft and incoming share visible', (
    tester,
  ) async {
    const channel = MethodChannel(AndroidShareIntentService.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'acknowledgeShare') {
            throw PlatformException(code: 'ack-failed');
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    const payload = AndroidSharePayload(
      id: 'share-ack-failure',
      text: 'Do not lose this staged draft',
    );

    await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
    shares.pendingShare.value = payload;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-add-to-draft')));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    final composer = find.byKey(const Key('profile-message-composer'));
    expect(composer, findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, payload.text);
    expect(shares.pendingShare.value, same(payload));
    expect(find.textContaining('could not be cleared'), findsOneWidget);
  });

  testWidgets('failed discard preserves the Home review controls', (
    tester,
  ) async {
    const channel = MethodChannel(AndroidShareIntentService.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'acknowledgeShare') {
            throw PlatformException(code: 'discard-failed');
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    const payload = AndroidSharePayload(
      id: 'share-discard-failure',
      text: 'Keep this pending',
    );

    await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
    shares.pendingShare.value = payload;
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(shares.pendingShare.value, same(payload));
    expect(find.text('Shared draft ready'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(find.textContaining('could not be discarded'), findsOneWidget);
  });

  testWidgets('camera returns directly to its original connection and draft', (
    tester,
  ) async {
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    await manager.saveConnection('Home', 'home.local', 8642, 'home-key');
    final work = manager.getConnections().firstWhere(
      (connection) => connection.label == 'Work',
    );
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    final payload = AndroidSharePayload(
      id: 'camera-original',
      text: 'Captured content',
      target: {
        'connection': work.id,
        'connection_identity': 'home-share-${work.id}',
        'profile': 'default',
        'session': 'original-chat',
      },
    );
    await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
    shares.pendingShare.value = payload;
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a Hermes instance for this shared draft'),
      findsNothing,
    );
    expect(find.text('Add shared content'), findsNothing);
    final workspace = tester.widget<ProfileWorkspaceScreen>(
      find.byType(ProfileWorkspaceScreen),
    );
    expect(workspace.controller.current!.chat!.key.sessionId, 'original-chat');
    expect(
      workspace.controller.current!.chat!.composer.observation.text,
      payload.text,
    );
    expect(shares.pendingShare.value, isNull);
  });

  for (final outcome in [
    'saved',
    'cancelled',
    'preparation failed',
    'acknowledgement failed',
  ]) {
    testWidgets('photo taken inside a chat: $outcome', (tester) async {
      final fixture = await _homeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
      final connection = manager.getConnections().single;
      final expectedText = outcome == 'saved'
          ? 'Existing draft updated'
          : 'Existing draft';
      final attachments = _CameraAttachments()
        ..delay = outcome == 'cancelled' ? null : Completer<void>()
        ..fail = outcome == 'preparation failed';
      final controller = _controller(
        connection,
        manager.prefs,
        appPreferences,
        attachments: attachments,
      );
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Existing draft');
      await manager.prefs.setString('last_connection_id', connection.id);
      final drafts = ComposerDraftStore(
        manager.prefs,
        connectionIdentity: controller.connectionIdentity,
      );
      final shares = AndroidShareIntentService();
      addTearDown(shares.dispose);
      final payload = AndroidSharePayload(
        id: 'in-chat-photo',
        files: const [
          AndroidSharedFile(
            path: '/intake/camera.jpg',
            name: 'Camera photo.jpg',
            mediaType: 'image/jpeg',
            byteLength: 1,
          ),
        ],
        target: chat.key.toJson(),
      );
      var acknowledgements = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'capturePhoto') {
              expect((call.arguments as Map)['target'], chat.key.toJson());
              if (outcome != 'cancelled') shares.pendingShare.value = payload;
            }
            if (call.method == 'acknowledgeShare') {
              acknowledgements++;
              expect((call.arguments as Map)['id'], payload.id);
              final saved = drafts.summaries(profileName: 'default').single;
              expect(saved.sessionId, chat.key.sessionId);
              expect(saved.text, expectedText);
              expect(saved.attachmentCount, 1);
              if (outcome == 'acknowledgement failed') {
                throw PlatformException(code: 'ack-failed');
              }
            }
            return null;
          });

      await _pumpHome(
        tester,
        manager,
        shares,
        appPreferences: appPreferences,
        controller: controller,
      );
      await tester.pumpAndSettle();
      final originalScreen = tester.state(find.byType(ProfileWorkspaceScreen));
      final composerFinder = find.byKey(const Key('profile-message-composer'));
      final composer = tester.widget<TextField>(composerFinder);
      composer.controller!.selection = const TextSelection.collapsed(offset: 4);
      await tester.tap(find.byTooltip('Attach file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Camera'));
      if (outcome != 'cancelled') {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
          if (chat.composer.observation.preparing) break;
        }
        expect(chat.composer.observation.preparing, isTrue);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(ComposerPendingAttachmentTile), findsOneWidget);
        expect(find.byTooltip('Adding photo…'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('composer-image-thumbnail')),
          findsNothing,
        );
        expect(
          tester.state(find.byType(ProfileWorkspaceScreen)),
          same(originalScreen),
        );
        expect(
          tester.widget<TextField>(composerFinder).controller,
          same(composer.controller),
        );
        expect(tester.widget<TextField>(composerFinder).enabled, isTrue);
        if (outcome == 'saved') {
          await tester.enterText(composerFinder, expectedText);
          await tester.pump();
          composer.controller!.selection = const TextSelection.collapsed(
            offset: 4,
          );
        }
        attachments.delay!.complete();
      }
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPendingAttachmentTile), findsNothing);

      expect(find.text('Add shared content'), findsNothing);
      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      expect(
        tester.state(find.byType(ProfileWorkspaceScreen)),
        same(originalScreen),
      );
      expect(controller.current!.chat, same(chat));
      expect(
        tester.widget<TextField>(composerFinder).controller,
        same(composer.controller),
      );
      expect(
        composer.controller!.selection,
        const TextSelection.collapsed(offset: 4),
      );
      expect(chat.composer.observation.text, expectedText);
      expect(chat.reading.messages, isEmpty);
      final added = !attachments.fail && outcome != 'cancelled';
      expect(acknowledgements, added ? 1 : 0);
      expect(chat.composer.observation.attachments, hasLength(added ? 1 : 0));
      expect(
        shares.pendingShare.value,
        outcome == 'saved' || outcome == 'cancelled' ? isNull : same(payload),
      );
      if (added) {
        expect(
          find.byKey(const ValueKey('composer-image-thumbnail')),
          findsOneWidget,
        );
      }
      if (outcome == 'acknowledgement failed') {
        expect(find.textContaining('could not be cleared'), findsOneWidget);
      }
      if (attachments.fail) {
        expect(
          find.textContaining('still available to review'),
          findsOneWidget,
        );
      }
      if (outcome == 'saved') {
        final second = AndroidSharePayload(
          id: 'second-photo',
          files: payload.files,
          target: payload.target,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'capturePhoto') {
                shares.pendingShare.value = second;
              }
              if (call.method == 'acknowledgeShare') {
                acknowledgements++;
                final saved = drafts.summaries(profileName: 'default').single;
                expect(saved.text, expectedText);
                expect(saved.attachmentCount, 2);
              }
              return null;
            });
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Camera'));
        await tester.pumpAndSettle();
        expect(
          tester.state(find.byType(ProfileWorkspaceScreen)),
          same(originalScreen),
        );
        expect(chat.composer.observation.attachments.map((file) => file.id), [
          'captured-photo-1',
          'captured-photo-2',
        ]);
        expect(acknowledgements, 2);
        expect(shares.pendingShare.value, isNull);
      }
    });
  }

  testWidgets('camera intake retains the screen during resume recovery', (
    tester,
  ) async {
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    final connection = manager.getConnections().single;
    final listRelease = Completer<void>();
    final imageRelease = Completer<void>();
    addTearDown(() {
      if (!listRelease.isCompleted) listRelease.complete();
      if (!imageRelease.isCompleted) imageRelease.complete();
    });
    var capturing = false;
    var recovering = false;
    final methods = <String>[];
    final attachments = _CameraAttachments()..delay = imageRelease;
    final controller = _controller(
      connection,
      manager.prefs,
      appPreferences,
      attachments: attachments,
      beforeSessionRead: () async {
        if (capturing && !recovering) await listRelease.future;
      },
      onRpc: methods.add,
    );
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Keep my draft');
    await manager.prefs.setString('last_connection_id', connection.id);
    final errors = <String>{};
    var lostSelection = false;
    controller.addListener(() {
      if (controller.error case final error?) errors.add(error);
      if (capturing && !identical(controller.current?.chat, chat)) {
        lostSelection = true;
      }
    });
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    final payload = AndroidSharePayload(
      id: 'photo-during-recovery',
      files: const [
        AndroidSharedFile(
          path: '/intake/camera.jpg',
          name: 'Camera photo.jpg',
          mediaType: 'image/jpeg',
          byteLength: 1,
        ),
      ],
      target: chat.key.toJson(),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'capturePhoto') {
            capturing = true;
            shares.pendingShare.value = payload;
          }
          return null;
        });
    await _pumpHome(
      tester,
      manager,
      shares,
      appPreferences: appPreferences,
      controller: controller,
    );
    await tester.pumpAndSettle();
    final originalScreen = tester.state(find.byType(ProfileWorkspaceScreen));
    methods.clear();
    await tester.tap(find.byTooltip('Attach file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    recovering = true;
    await controller.resumeConnection();
    listRelease.complete();
    await tester.pump();
    imageRelease.complete();
    await tester.pumpAndSettle();

    expect(errors, isEmpty);
    expect(controller.error, isNull);
    expect(lostSelection, isFalse);
    expect(
      tester.state(find.byType(ProfileWorkspaceScreen)),
      same(originalScreen),
    );
    expect(methods.where((method) => method == 'session.resume'), hasLength(1));
    expect(methods.where((method) => method == 'prompt.submit'), isEmpty);
    expect(chat.composer.observation.text, 'Keep my draft');
    expect(chat.composer.observation.attachments, hasLength(1));
    expect(shares.pendingShare.value, isNull);
    expect(
      find.text('Chats changed while loading. Refresh to reload.'),
      findsNothing,
    );
  });

  testWidgets('cold camera recovery keeps the saved text in its new draft', (
    tester,
  ) async {
    final fixture = await _homeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
    final connection = manager.getConnections().single;
    final drafts = ComposerDraftStore(
      manager.prefs,
      connectionIdentity: 'home-share-${connection.id}',
    );
    await drafts.write(
      profileName: 'default',
      sessionId: 'expired-unsent',
      text: 'Cold camera draft check',
      attachments: [],
    );
    final shares = AndroidShareIntentService();
    addTearDown(shares.dispose);
    await _pumpHome(
      tester,
      manager,
      shares,
      appPreferences: appPreferences,
      missingSessions: {'expired-unsent'},
    );
    shares.pendingShare.value = AndroidSharePayload(
      id: 'cold-camera',
      text: 'Captured content',
      target: {
        'connection': connection.id,
        'connection_identity': 'home-share-${connection.id}',
        'profile': 'default',
        'session': 'expired-unsent',
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('New chat with recovered draft'), findsOneWidget);
    expect(find.text('Cold camera draft check'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-add-to-draft')));
    await tester.pumpAndSettle();
    final workspace = tester.widget<ProfileWorkspaceScreen>(
      find.byType(ProfileWorkspaceScreen),
    );
    expect(
      workspace.controller.current!.chat!.composer.observation.text,
      'Cold camera draft check\n\nCaptured content',
    );
    expect(
      (await drafts.read(
        profileName: 'default',
        sessionId: workspace.controller.current!.chat!.key.sessionId,
      ))!.text,
      'Cold camera draft check\n\nCaptured content',
    );
    expect(
      await drafts.read(profileName: 'default', sessionId: 'expired-unsent'),
      isNull,
    );
    expect(shares.pendingShare.value, isNull);
  });

  for (final reason in ['permission_denied', 'storage_unavailable']) {
    testWidgets(
      'camera refusal $reason does not recover or consume saved draft',
      (tester) async {
        final fixture = await _homeFixture();
        final manager = fixture.manager;
        final appPreferences = fixture.appPreferences;
        await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
        final connection = manager.getConnections().single;
        final drafts = ComposerDraftStore(
          manager.prefs,
          connectionIdentity: 'home-share-${connection.id}',
        );
        await drafts.write(
          profileName: 'default',
          sessionId: 'unavailable-chat',
          text: 'Keep the original saved draft',
          attachments: [],
        );
        final shares = AndroidShareIntentService();
        addTearDown(shares.dispose);
        await _pumpHome(
          tester,
          manager,
          shares,
          appPreferences: appPreferences,
          missingSessions: {'unavailable-chat'},
          resumeFailureReason: reason,
        );
        final incoming = AndroidSharePayload(
          id: 'camera-$reason',
          text: 'Captured content',
          target: {
            'connection': connection.id,
            'connection_identity': 'home-share-${connection.id}',
            'profile': 'default',
            'session': 'unavailable-chat',
          },
        );
        shares.pendingShare.value = incoming;
        await tester.pumpAndSettle();
        expect(find.text('New chat with recovered draft'), findsNothing);
        expect(find.text('Keep the original saved draft'), findsNothing);
        expect(find.text('New chat'), findsOneWidget);
        expect(
          find.textContaining('original chat could not be reopened'),
          findsOneWidget,
        );
        expect(shares.pendingShare.value, same(incoming));
        expect(
          (await drafts.read(
            profileName: 'default',
            sessionId: 'unavailable-chat',
          ))!.text,
          'Keep the original saved draft',
        );
      },
    );
  }

  testWidgets(
    'changed camera connection requires explicit destination review',
    (tester) async {
      final fixture = await _homeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('Work', 'work.local', 8642, 'work-key');
      final work = manager.getConnections().single;
      final shares = AndroidShareIntentService();
      addTearDown(shares.dispose);
      final payload = AndroidSharePayload(
        id: 'camera-changed',
        text: 'Keep captured content',
        target: {
          'connection': work.id,
          'connection_identity': 'previous-server-settings',
          'profile': 'default',
          'session': 'original-chat',
        },
      );
      await _pumpHome(tester, manager, shares, appPreferences: appPreferences);
      shares.pendingShare.value = payload;
      await tester.pumpAndSettle();
      expect(
        find.textContaining('original chat could not be reopened'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('share-destination-original-chat')),
        findsNothing,
      );
      expect(shares.pendingShare.value, same(payload));
      expect(find.byType(ProfileWorkspaceScreen), findsNothing);
    },
  );
}
