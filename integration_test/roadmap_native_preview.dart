/// Disposable emulator entry point for native camera, share and process checks.
/// Uses real Android plugins and preferences, with synthetic Hermes transport.
///
/// A nonempty `ROADMAP_NATIVE_NOTIFICATION_NONCE` posts one scoped notification
/// after opening the work fixture; relaunching with the same nonce only handles
/// the retained notification tap.
/// Build only as debug; never install this entry point in Wing.
library;

import 'package:wing/core/models/profile_session_key.dart';

import 'package:wing/core/services/app_preferences.dart';

import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/core/services/android_launch_intent_service.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/turn_notification_service.dart';
import 'package:wing/main.dart';

import 'support/roadmap_emulator_fixture.dart';

Future<void> main() async {
  if (!kDebugMode) throw StateError('Emulator preview requires a debug build.');
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(preferences);
  final connection = SavedConnection(
    id: 'roadmap-native-emulator',
    label: 'Emulator fixture',
    host: 'unused.invalid',
    port: 1,
    apiKey: '',
  );
  await manager.importConnections(
    [connection],
    replaceExisting: true,
    canCommit: () => true,
  );
  await preferences.setString('last_connection_id', connection.id);
  final fixture = RoadmapEmulatorFixture();
  const notificationNonce = String.fromEnvironment(
    'ROADMAP_NATIVE_NOTIFICATION_NONCE',
  );
  const notificationMarker = 'roadmap_native_notification_nonce_v1';
  final postNotification =
      notificationNonce.isNotEmpty &&
      preferences.getString(notificationMarker) != notificationNonce;
  final notificationSink = PluginTurnNotificationSink();
  if (postNotification) await notificationSink.initialize();
  final appPreferences = AppPreferences(preferences);
  final registry = ProfileWorkspaceRegistry(
    identities: ProfileConnectionIdentity(),
    create: (saved, identity) => ProfileWorkspaceController(
      access: ConnectionAccess(connection: saved, dashboardOAuth: null),
      connectionIdentity: identity,
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
      onAttention: postNotification
          ? (chat) async {
              final needsInput = chat.content.needsAttention;
              if (preferences.getString(notificationMarker) ==
                  notificationNonce) {
                return;
              }
              final payload = jsonEncode(chat.key.toJson());
              for (final phase in ['Warm', 'Cold']) {
                await notificationSink.show(
                  TurnNotification(
                    id: TurnNotificationService.notificationIdFor(
                      'roadmap-native:$notificationNonce:$phase',
                    ),
                    title: '$phase QA: ${chat.key.workspace.profileName}',
                    body:
                        '${needsInput ? 'Needs attention' : 'Chat finished'}: ${chat.title}',
                    payload: payload,
                    channel: TurnNotificationService.turnChannel,
                  ),
                );
              }
              await preferences.setString(
                notificationMarker,
                notificationNonce,
              );
            }
          : null,
    ),
  );
  ProfileChat? notificationTarget;
  ProfileSessionKey? visibleWorkTarget;
  if (postNotification) {
    final controller = await registry.forConnection(connection);
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'chat-0'),
    );
    notificationTarget = controller.current!.chat!;
    await controller.switchProfile('work');
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'chat-0'),
    );
    visibleWorkTarget = controller.current!.chat!.key;
  }
  final shareIntents = AndroidShareIntentService();
  final launchIntents = AndroidLaunchIntentService();
  await Future.wait([shareIntents.initialize(), launchIntents.initialize()]);
  final appKey = GlobalKey<WingAppState>();
  runApp(
    WingApp(
      appPreferences: appPreferences,
      key: appKey,
      connManager: manager,
      profileControllers: registry,
      shareIntents: shareIntents,
      launchIntents: launchIntents,
    ),
  );
  if (notificationTarget != null && visibleWorkTarget != null) {
    final target = notificationTarget;
    final workTarget = visibleWorkTarget;
    unawaited(
      WidgetsBinding.instance.endOfFrame.then((_) async {
        await appKey.currentState!.openProfileNotification(
          jsonEncode(workTarget.toJson()),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        fixture.requestApproval('personal', target.runtime.runtimeId);
      }),
    );
  }
}
