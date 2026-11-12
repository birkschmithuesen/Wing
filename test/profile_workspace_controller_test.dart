import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/live_voice_session.dart';
import 'support/live_voice_fixture.dart';
import 'package:wing/core/models/gateway_approval.dart';
import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:image/image.dart' as image;
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/models/profile_selection.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _captureAttachments = bool.fromEnvironment('CAPTURE_ATTACHMENTS');
const _attachmentFrame = ValueKey('attachment-review-frame');

class _AttachmentTestBinding extends AutomatedTestWidgetsFlutterBinding {
  Future<void>? imageDecodeDelay;
  int delayedDecodeCount = 0;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    final delay = imageDecodeDelay;
    if (delay != null) {
      delayedDecodeCount++;
      await delay;
    }
    return super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
  }
}

Future<void> _waitForAttachmentImages(WidgetTester tester) async {
  final context = tester.element(find.byKey(_attachmentFrame));
  var loaded = false;
  final pending = Future.wait([
    for (final widget in tester.widgetList<Image>(find.byType(Image)))
      precacheImage(widget.image, context),
  ]).then((_) => loaded = true);
  for (var attempt = 0; attempt < 200 && !loaded; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    loaded,
    isTrue,
    reason: 'Attachment images must finish before interaction or capture',
  );
  await pending;
  await tester.pumpAndSettle();
}

Future<void> _waitForSubmission(WidgetTester tester, Host host) async {
  for (
    var attempt = 0;
    attempt < 300 && !host.calls.any((call) => call.$2 == 'prompt.submit');
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(host.calls.where((call) => call.$2 == 'prompt.submit'), hasLength(1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _captureAttachmentFrame(WidgetTester tester, String name) async {
  if (!_captureAttachments) return;
  await _waitForAttachmentImages(tester);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_attachmentFrame),
  );
  await tester.runAsync(() async {
    final bitmap = await boundary.toImage();
    try {
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/attachments-review')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      bitmap.dispose();
    }
  });
}

class DelayedAttachmentDraftService extends AttachmentDraftService {
  final Completer<void> preparationStarted = Completer<void>();
  final Completer<void> finishPreparation = Completer<void>();

  DelayedAttachmentDraftService({required super.cacheDirectoryProvider});

  @override
  Future<AttachmentDraft> prepareGenericFile({
    required String sourcePath,
    required String displayName,
    String mediaType = 'application/octet-stream',
    required Iterable<AttachmentDraft> existingDrafts,
  }) async {
    preparationStarted.complete();
    await finishPreparation.future;
    return super.prepareGenericFile(
      sourcePath: sourcePath,
      displayName: displayName,
      mediaType: mediaType,
      existingDrafts: existingDrafts,
    );
  }
}

final class PhotoFileFixture extends PlatformFile {
  PhotoFileFixture(this.uri, {this.name = 'photo.jpg'});
  @override
  final Uri uri;
  @override
  final String name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PhotoPickerFixture extends FilePickerPlatform {
  PhotoPickerFixture(this.files, {this.type = FileType.image});
  final List<PlatformFile> files;
  final FileType type;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(type, this.type);
    return files;
  }
}

class _SocketHttpOverrides extends HttpOverrides {}

class Host {
  final canonicalRevisions = <String, int>{};
  final canonicalAdmissions = <String, Map<String, dynamic>>{};
  final canonicalPayloads = <String, Map<String, dynamic>>{};
  ScopedOwnedPost? ownedPatch;
  final gateways = <String, ProfileGateway>{};
  final calls = <(String, String, Map<String, dynamic>)>[];
  final reads = <(String, Map<String, String>)>[];
  final delays = <String, Completer<void>>{};
  final failures = <String>{};
  final closed = <String>[];
  List<String> profiles = ['a', 'b'];
  bool running = true;
  final runtimeForResume = <String, String>{};
  bool promptSubmitFails = false;
  int promptSubmitFailures = 0;
  bool fileAttachFails = false;
  Object? sessionTitle;
  List<Map<String, dynamic>>? indexedSessions;
  Completer<void>? fileAttachStarted;
  Completer<void>? fileAttachDelay;
  Map<String, dynamic> imageAttachResult = {
    'attached': true,
    'path': '/profile/images/upload.png',
  };
  bool approvalFails = false;
  bool approvalAlreadyResolved = false;
  List<Map<String, dynamic>> notificationActiveSessions = [];
  Map<String, dynamic>? notificationReplay;
  List<Map<String, dynamic>>? pendingApprovals;
  final nativePrompts = <(String, String), Map<String, dynamic>>{};
  final _nativeObservers = <ProfileGateway>{};
  final nativeGenerations = <(String, String), int>{};
  List<Map<String, dynamic>> approvalOpenRequests = [];
  Completer<void>? pendingApprovalDelay;
  Completer<void>? approvalDelay;
  Future<void> Function()? onApprovalResponse;
  Completer<void>? promptSubmitStarted;
  Completer<void>? promptSubmitDelay;
  Completer<void>? promptReplaceStarted;
  Completer<void>? promptReplaceDelay;
  Completer<void>? connectDelay;
  Completer<void>? activeListDelay;
  int connectFailures = 0;
  Object? connectError;
  Object? rosterFailure;
  Object? resumeError;
  int connectCalls = 0;
  int disconnectCalls = 0;
  final connectsByProfile = <String, int>{};
  final disconnectsByProfile = <String, int>{};
  int resumeFailures = 0;
  Completer<void>? resumeStarted;
  Completer<void>? resumeDelay;
  bool expireUnsubmittedResume = false;
  int sessionCreates = 0;
  String? createdCwdOverride;
  bool omitCreatedCwd = false;
  Completer<void>? replacementCreateStarted;
  Completer<void>? replacementCreateDelay;
  Completer<void>? expiredResumeStarted;
  Completer<void>? expiredResumeDelay;
  bool expiredResumeWasDelayed = false;
  Map<String, dynamic>? inflight;
  Map<String, dynamic>? todoState;
  List<Map<String, dynamic>>? historyMessages;
  Completer<void>? heldHistoryStarted;
  Completer<void>? heldHistoryDelay;
  Object? heldHistoryFailure;
  Object? liveVoiceStatusFailure;
  Object? liveVoiceSessionFailure;
  bool liveVoiceApiAvailable = true;
  String? voiceCachedPrompt;
  String? voiceSavedPrompt = 'Native saved prompt';
  Completer<void>? heldVoiceContext;
  Completer<void>? heldVoiceStatus;
  Completer<void>? heldVoiceSession;
  final voiceEndpoints = <String>[];
  Completer<void>? heldTimingLog;
  Completer<void>? projectDelay;
  final projectPaths = <String, String?>{};
  bool wrongProjectOwner = false;
  Object? discoveryFailure;
  Completer<void>? discoveryDelay;
  Completer<void>? discoveryStarted;
  Completer<void>? defaultDiscoveryDelay;
  Completer<void>? defaultDiscoveryStarted;
  Object? defaultDiscoveryFailure;
  Map<String, dynamic> clarifyResult = {'status': 'ok'};
  Future<void> Function()? onClarifyResponse;
  Map<String, dynamic> steerResult = {'status': 'queued'};
  Future<ProfileDiscovery> discover() async {
    if (discoveryStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await discoveryDelay?.future;
    if (discoveryFailure case final failure?) throw failure;
    return ProfileDiscovery(
      profiles: profiles.map((p) => HermesProfile(name: p)).toList(),
      currentName: 'a',
      activeName: 'a',
    );
  }

  ProfileGateway gateway(WorkspaceScope scope) {
    final name = scope.profileName;
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      serverResponse: (requestId, result) async {
        calls.add((
          name,
          'server.response',
          {'id': requestId, 'result': result},
        ));
        await onClarifyResponse?.call();
      },
      ownedPatch: ownedPatch,
      ownedPost: (endpoint, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(
            StateError('Creation retired'),
          );
        }
        if (endpoint == 'plugins/wing/voice/v2/session?profile=$name') {
          onDispatched();
          voiceEndpoints.add(endpoint);
          calls.add((name, 'voice.negotiate', Map.of(body)));
          await heldVoiceSession?.future;
          if (liveVoiceSessionFailure case final failure?) throw failure;
          return {
            'contractVersion': 2,
            'answer': 'SDP',
            'mode': body['mode'],
            'protocol': body['mode'] == 'api' ? 'openai-live' : 'codex-live-v3',
            'handoff': 'client',
          };
        }
        expect(endpoint, 'files/mkdir?profile=$name');
        onDispatched();
        return {
          'ok': true,
          'path': body['path'],
          'entry': {'path': body['path'], 'is_directory': true},
        };
      },
      scope: scope,
      discover: () async {
        if (name == 'default' && defaultDiscoveryDelay != null) {
          defaultDiscoveryStarted?.complete();
          await defaultDiscoveryDelay!.future;
          if (defaultDiscoveryFailure case final failure?) throw failure;
        }
        return discover();
      },
      connect: () async {
        if (gateway.onEvent != null) {
          gateways[name] = gateway;
          if (_nativeObservers.add(gateway)) {
            final receive = gateway.onEvent!;
            gateway.onEvent = (event) {
              if ({
                'approval.request',
                'clarify.request',
              }.contains(event.type)) {
                nativeGenerations[(name, event.sessionId!)] =
                    event.data['execution_generation'] as int;
                nativePrompts[(name, event.data['prompt_id'] as String)] =
                    Map.of(event.data);
              } else if ({
                'approval.settled',
                'clarify.settled',
              }.contains(event.type)) {
                final key = (name, event.data['prompt_id'] as String);
                if (nativePrompts[key]?['execution_generation'] ==
                    event.data['execution_generation']) {
                  nativePrompts.remove(key);
                }
              }
              receive(event);
            };
          }
          connectCalls++;
          connectsByProfile.update(
            name,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        await connectDelay?.future;
        if (connectError != null) throw connectError!;
        if (connectFailures > 0) {
          connectFailures--;
          throw TimeoutException('Network is waking up');
        }
      },
      close: () {
        if (gateway.onEvent != null) closed.add(name);
      },
      disconnect: () {
        disconnectCalls++;
        disconnectsByProfile.update(
          name,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      },
      get: (path, query) async {
        if (path == 'plugins/wing/voice/v2/status') {
          reads.add((path, query));
          await heldVoiceStatus?.future;
          if (liveVoiceStatusFailure case final failure?) throw failure;
          return {
            'contractVersion': 2,
            'available': query['mode'] == 'api' ? liveVoiceApiAvailable : true,
            'authOwner': 'hermes-profile',
            'modes': ['subscription', 'api'],
            'voices': query['mode'] == 'api'
                ? ['marin', 'cedar']
                : ['cove', 'breeze'],
          };
        }

        reads.add((path, query));
        if (RegExp(r'^sessions/[^/]+/mutation-snapshot$').hasMatch(path)) {
          return {
            'session_id': Uri.decodeComponent(path.split('/')[1]),
            'exists': true,
            'runtime_revision': 0,
            'runtime_generation': 0,
          };
        }
        if (path == 'model/options') return {'providers': <Object>[]};
        if (path == 'model/info') return <String, dynamic>{};
        if (path == 'logs') {
          if (heldTimingLog case final held?) await held.future;
          return {'file': 'gui', 'lines': <String>[]};
        }
        await delays[name]?.future;
        if (failures.contains(name)) throw Exception('offline');
        if (path == 'sessions') {
          return {
            'offset': int.parse(query['offset']!),
            'limit': int.parse(query['limit']!),
            'total': indexedSessions?.length ?? 1,
            'sessions':
                indexedSessions ??
                [
                  {'id': 'same', 'title': '$name chat', 'profile': name},
                ],
          };
        }
        if (RegExp(r'^sessions/[^/]+$').hasMatch(path)) {
          return {
            'id': Uri.decodeComponent(path.split('/')[1]),
            'profile': name,
            'system_prompt': voiceSavedPrompt == null
                ? null
                : '$voiceSavedPrompt for $name',
          };
        }
        if (path.startsWith('sessions/') &&
            path.endsWith('/messages') &&
            heldHistoryDelay != null) {
          final delay = heldHistoryDelay!;
          final failure = heldHistoryFailure;
          heldHistoryDelay = null;
          heldHistoryStarted!.complete();
          await delay.future;
          if (failure != null) throw failure;
        }
        if (!path.startsWith('sessions/') || !path.endsWith('/messages')) {
          throw StateError('Unhandled fixture GET: $path');
        }
        return {
          'session_id': path.split('/')[1],
          'pagination': {
            'limit': int.parse(query['limit']!),
            'offset': 0,
            'order': 'latest',
            'returned': historyMessages?.length ?? 1,
          },
          'messages':
              historyMessages ??
              [
                {'id': 1, 'role': 'assistant', 'content': '$name completed'},
              ],
        };
      },
      ownedDelete: (endpoint, query, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(
            StateError('Fixture owner retired'),
          );
        }
        onDispatched();
        calls.add((
          name,
          'DELETE $endpoint',
          Map<String, dynamic>.unmodifiable(query),
        ));
        return {'ok': true};
      },
      rpc: (method, params) async {
        calls.add((name, method, params));
        if (method == 'process.list') return {'processes': <Object>[]};
        if (method == 'config.set') return {'value': params['value']};
        if (method == 'subagent.roster') {
          if (rosterFailure != null) throw rosterFailure!;
          return {'sessions': <Object>[]};
        }
        if (method == 'session.active_list') {
          await activeListDelay?.future;
          return {'sessions': notificationActiveSessions};
        }
        if (method == 'session.events.since') {
          return {
            'replay_epoch': params['replay_epoch'],
            'latest_seq': params['last_sequence'],
            'events': <Map<String, dynamic>>[],
            'open_requests': approvalOpenRequests,
            ...?notificationReplay,
          };
        }
        if (method == 'file.attach') {
          if (fileAttachStarted case final started? when !started.isCompleted) {
            started.complete();
          }
          await fileAttachDelay?.future;
          if (fileAttachFails) throw StateError('Synthetic upload failure');
          return {'attached': true, 'ref_text': 'attached:${params['name']}'};
        }
        if (method == 'image.attach_bytes') return imageAttachResult;
        if (method == 'prompt.submit') {
          if (params['submission_id'] is! String) {
            throw const FormatException('Missing canonical submission ID');
          }
          final input =
              '$name:${params['session_id']}:${params['submission_id']}';
          final receipt = canonicalAdmissions.putIfAbsent(
            input,
            () => canonicalReceipt(
              params,
              admissionId: 'admission-${canonicalAdmissions.length + 1}',
              sequence: canonicalAdmissions.length + 1,
            ),
          );
          canonicalPayloads.putIfAbsent(
            input,
            () => Map<String, dynamic>.from(params),
          );
          if (promptSubmitStarted case final started?
              when !started.isCompleted) {
            started.complete();
          }
          await promptSubmitDelay?.future;
          if (promptSubmitFails) {
            throw TimeoutException('Prompt acknowledgement was lost');
          }
          return receipt;
        }
        if (method == 'prompt.receipt') {
          return canonicalAdmissions.values.firstWhere(
            (row) => row['admission_id'] == params['admission_id'],
          );
        }
        if (method == 'prompt.cancel' ||
            method == 'prompt.resolve_unknown' ||
            method == 'prompt.steer_queued') {
          final row = canonicalAdmissions.values.firstWhere(
            (row) => row['admission_id'] == params['admission_id'],
          );
          row['status'] = method == 'prompt.steer_queued'
              ? 'started'
              : 'terminal';
          row['outcome'] = method == 'prompt.steer_queued' ? null : 'cancelled';
          if (method == 'prompt.steer_queued') row['steering'] = true;
          return row;
        }
        if (method == 'prompt.replace_queued') {
          final row = canonicalAdmissions.values.firstWhere(
            (row) => row['admission_id'] == params['admission_id'],
          );
          if (row['status'] != 'queued') {
            throw JsonRpcError(
              method,
              'already claimed',
              reason: 'admission_started',
            );
          }
          row['status'] = 'terminal';
          row['outcome'] = 'cancelled';
          final replacement = canonicalReceipt(
            {...params, 'queued': true},
            admissionId: 'admission-${canonicalAdmissions.length + 1}',
            sequence: canonicalAdmissions.length + 1,
          );
          canonicalAdmissions['$name:${params['session_id']}:${params['submission_id']}'] =
              replacement;
          promptReplaceStarted?.complete();
          await promptReplaceDelay?.future;
          return replacement;
        }
        if (method == 'session.mutate') {
          canonicalRevisions['$name:${params['session_id']}'] =
              (params['expected_revision'] as int) + 1;
          return {
            'session_id': params['session_id'],
            'operation': params['operation'],
            if (params['operation'] == 'rename')
              'title': (params['payload'] as Map)['title'],
            'revision': (params['expected_revision'] as int) + 1,
            'execution_generation': params['expected_generation'],
            'status': 'applied',
          };
        }
        if (method == 'prompt.submit' && promptSubmitFailures > 0) {
          promptSubmitFailures--;
          throw JsonRpcError(
            method,
            'Connection closed',
            reason: 'connection_closed',
          );
        }
        if (method == 'approval.pending') {
          final pending =
              (pendingApprovals ??
                      [
                        for (final entry in nativePrompts.entries)
                          if (entry.key.$1 == name &&
                              entry.value['kind'] == 'approval')
                            {
                              ...entry.value,
                              'request_id': entry.value['prompt_id'],
                            },
                      ])
                  .map(
                    (row) => Map<String, dynamic>.of(row)
                      ..remove('execution_generation')
                      ..remove('prompt_id')
                      ..remove('kind'),
                  )
                  .toList();
          await pendingApprovalDelay?.future;
          return {'approvals': pending};
        }
        if (method == 'approval.respond') {
          if (params.keys.toSet().difference({
                'session_id',
                'profile',
                'prompt_id',
                'execution_generation',
                'choice',
              }).isNotEmpty ||
              params['prompt_id'] is! String ||
              params['execution_generation'] is! int ||
              params['choice'] is! String) {
            throw JsonRpcError(
              method,
              'Invalid canonical approval response',
              reason: 'invalid_params',
            );
          }
          await approvalDelay?.future;
          if (approvalFails) throw TimeoutException('Approval failed');
          if ((nativeGenerations[(name, params['session_id'] as String)] ??
                  0) ==
              params['execution_generation']) {
            pendingApprovals?.removeWhere(
              (r) => r['request_id'] == params['prompt_id'],
            );
          }
          final promptKey = (name, params['prompt_id'] as String);
          if (nativePrompts[promptKey]?['execution_generation'] ==
              params['execution_generation']) {
            nativePrompts.remove(promptKey);
          }
          await onApprovalResponse?.call();
          return {
            'status': approvalAlreadyResolved ? 'already_resolved' : 'resolved',
            'prompt_id': params['prompt_id'],
          };
        }
        if (method == 'session.steer') {
          if (params['execution_generation'] is! int) {
            throw JsonRpcError(
              method,
              'Missing generation',
              reason: 'invalid_params',
            );
          }
          return steerResult;
        }
        if (method == 'session.resume' && resumeError != null) {
          throw resumeError!;
        }
        if (method == 'session.resume' && resumeFailures > 0) {
          resumeFailures--;
          throw TimeoutException('Session resume temporarily unavailable');
        }
        if (method == 'session.resume' &&
            expireUnsubmittedResume &&
            params['session_id'] == 'same') {
          if (!expiredResumeWasDelayed && expiredResumeDelay != null) {
            expiredResumeWasDelayed = true;
            expiredResumeStarted?.complete();
            await expiredResumeDelay!.future;
          }
          throw JsonRpcError(
            'session.resume',
            'Session does not exist',
            code: 4001,
            reason: 'not_found',
          );
        }
        if (method == 'clarify.lock' || method == 'request.answer') {
          // Hermes contracts/prompt_voice.py uses Params, not SessionParams:
          // these replies are owned by the server request ID. Unknown fields
          // are rejected by contracts/registry.py before the handler runs.
          final allowed = method == 'clarify.lock'
              ? {'request_id', 'question_id', 'answer', 'profile'}
              : {'id', 'result', 'profile'};
          final unknown = params.keys.where((key) => !allowed.contains(key));
          if (unknown.isNotEmpty) {
            throw JsonRpcError(
              method,
              'invalid params: ${unknown.first}: Extra inputs are not permitted',
              code: 4000,
            );
          }
          await onClarifyResponse?.call();
          return clarifyResult;
        }
        if (method == 'projects.tree') {
          return {
            'projects': [
              {
                'id': 'same',
                'label': '$name project',
                'sessionIds': <String>[],
                'path': projectPaths.containsKey(name)
                    ? projectPaths[name]
                    : '/$name',
                'lastActive': 1,
              },
            ],
          };
        }
        if (method == 'projects.project_sessions') {
          await projectDelay?.future;
          return {
            'project': {
              'id': params['project_id'],
              'repos': [
                {
                  'groups': [
                    {
                      'sessions': [
                        {
                          'id': 'project-chat',
                          'title': 'Project chat',
                          'profile': wrongProjectOwner ? 'other' : name,
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          };
        }
        if (method == 'session.info') {
          await heldVoiceContext?.future;
          return {
            'system_prompt': voiceCachedPrompt,
            'cwd': '/$name/workspace',
          };
        }
        if (method == 'session.create' || method == 'session.resume') {
          if (method == 'session.create') sessionCreates++;
          final replacement = sessionCreates > 1;
          if (method == 'session.create' && replacement) {
            replacementCreateStarted?.complete();
            await replacementCreateDelay?.future;
          }
          final response = <String, dynamic>{
            ...canonicalSnapshotFields,
            'pending': canonicalAdmissions.values
                .where(
                  (row) =>
                      (row['ref'] as Map)['profile_id'] == '/fixture/$name' &&
                      row['status'] != 'terminal',
                )
                .toList(),
            'session_id':
                method == 'session.resume' && runtimeForResume.containsKey(name)
                ? runtimeForResume[name]
                : replacement
                ? '$name-replacement-runtime'
                : '$name-runtime',
            'stored_session_id': replacement ? 'replacement' : 'same',
            'session_key': replacement ? 'replacement' : 'same',
            'messages': <Map<String, dynamic>>[],
            'running': method == 'session.resume' && running,
            'inflight': inflight,
            'open_requests': approvalOpenRequests,
            'prompts': [
              for (final entry in nativePrompts.entries)
                if (entry.key.$1 == name &&
                    (pendingApprovals == null ||
                        entry.value['kind'] != 'approval'))
                  entry.value,
              for (final row
                  in pendingApprovals ?? const <Map<String, dynamic>>[])
                {
                  ...row,
                  'kind': 'approval',
                  'prompt_id': row['request_id'],
                  'execution_generation': 0,
                },
            ],
            'todo_state': todoState,
            'info': {
              'profile_name': name,
              if (sessionTitle != null) 'title': sessionTitle,
              if (!omitCreatedCwd)
                'cwd':
                    createdCwdOverride ??
                    (params['cwd_explicit'] == true
                        ? params['cwd']
                        : '/$name/profile-default'),
            },
          };
          response['revision'] =
              canonicalRevisions['$name:${response['session_id']}'] ?? 0;
          response['pending'] = canonicalAdmissions.values
              .where(
                (row) =>
                    (row['ref'] as Map)['session_id'] ==
                        response['session_id'] &&
                    row['status'] != 'terminal',
              )
              .toList();
          if (method == 'session.resume' && resumeDelay != null) {
            final delay = resumeDelay!;
            resumeDelay = null;
            resumeStarted?.complete();
            await delay.future;
          }
          return response;
        }
        if (method == 'projects.create') {
          return {
            'project': {
              'id': 'new',
              'name': params['name'],
              'primary_path': params['primary_path'],
            },
          };
        }
        return {};
      },
    );
    return gateway;
  }

  void event(
    String profile,
    String type, [
    Map<String, dynamic> data = const {},
  ]) {
    data = stockChatReply(gateways[profile]!, type, data);
    if (type == 'approval' && data['server_request_id'] == null) {
      final generation = nativeGenerations[(profile, '$profile-runtime')] ?? 0;
      type = 'approval.request';
      data = {
        ...data,
        'kind': 'approval',
        'prompt_id': data['request_id'],
        'execution_generation': generation,
        'choices': GatewayApprovalRequest.fromEventData(
          data,
        ).choices.map((choice) => choice.wireValue).toList(),
      }..remove('request_id');
    }
    if ({'approval.request', 'clarify.request'}.contains(type)) {
      nativePrompts[(profile, data['prompt_id'] as String)] = Map.of(data);
    } else if ({'approval.settled', 'clarify.settled'}.contains(type)) {
      final key = (profile, data['prompt_id'] as String);
      if (nativePrompts[key]?['execution_generation'] ==
          data['execution_generation']) {
        nativePrompts.remove(key);
      }
    }
    gateways[profile]!.onEvent!(
      StreamEvent(type: type, data: data, sessionId: '$profile-runtime'),
    );
    if (type == 'turn.end' || type == 'message.complete') {
      final rows = canonicalAdmissions.values
          .where(
            (row) => (row['ref'] as Map)['session_id'] == '$profile-runtime',
          )
          .toList();
      for (final row in rows.where((row) => row['status'] == 'started')) {
        row['status'] = 'terminal';
      }
      final next = rows.where((row) => row['status'] == 'queued').firstOrNull;
      if (next != null) next['status'] = 'started';
      gateways[profile]!.onEvent!(
        StreamEvent(
          type: 'session.info',
          sessionId: '$profile-runtime',
          data: {
            'pending': rows
                .where((row) => row['status'] != 'terminal')
                .toList(),
          },
        ),
      );
    }
  }
}

void main() {
  final binding = _AttachmentTestBinding();
  setUpAll(() async {
    if (!_captureAttachments) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(File(entry.value).readAsBytesSync()),
          ),
        );
      await loader.load();
    }
  });
  late Host host;
  late ProfileWorkspaceController controller;
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  late List<ProfileSessionKey> notifications;
  late Directory attachmentCache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = Host();
    attachmentCache = Directory.systemTemp.createTempSync(
      'wing-controller-attachments-',
    );
    notifications = [];
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
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
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      attachmentService: AttachmentDraftService(
        cacheDirectoryProvider: () async => attachmentCache,
      ),
      onAttention: (notification) async => notifications.add(notification.key),
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
    attachmentCache.deleteSync(recursive: true);
  });

  test(
    'live voice reports a missing plugin without blaming ChatGPT sign-in',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.liveVoiceStatusFailure = const DashboardHttpException(
        404,
        'plugins/wing/voice/v2/status',
      );
      final transport = VoiceTransportFixture();
      final session = LiveVoiceSession(
        createTransport: () => transport,
        background: VoiceBackgroundFixture(),
      );
      await session.start(controller.liveVoiceConversation(chat));
      await settleVoice();
      expect(
        session.error,
        'The Wing plugin is not installed or enabled on this Hermes profile. Install and enable it for live voice.',
      );
      expect(host.calls.where((c) => c.$2 == 'voice.negotiate'), isEmpty);
      expect(transport.closed, isTrue);
      session.dispose();
    },
  );

  test(
    'live voice captures billing and chat scope without consuming draft',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Keep my typed draft');
      await appPreferences.setLiveVoiceMode(LiveVoiceMode.api);
      await appPreferences.setLiveApiVoice('cedar');
      final voice = controller.liveVoiceConversation(chat);
      await appPreferences.setLiveApiVoice('marin');
      expect(voice.mode, LiveVoiceMode.api);
      await appPreferences.setLiveVoiceMode(LiveVoiceMode.subscription);
      final result = await voice.negotiate('offer');
      expect(result['protocol'], 'openai-live');
      expect(result['mode'], 'api');
      final negotiation = host.calls.singleWhere(
        (call) => call.$2 == 'voice.negotiate',
      );
      expect(negotiation.$1, chat.key.workspace.profileName);
      expect(negotiation.$3['offer'], 'offer');
      expect(negotiation.$3['voice'], 'cedar');
      expect(host.voiceEndpoints, [
        'plugins/wing/voice/v2/session?profile=${chat.key.workspace.profileName}',
      ]);
      expect(
        host.calls.singleWhere((c) => c.$2 == 'voice.negotiate').$3['mode'],
        'api',
      );
      await voice.delegate(
        'request',
        'Spoken request',
        delegationId: 'spoken-request',
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.composer.observation.text, 'Keep my typed draft');
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
      final submitted = host.calls.singleWhere((c) => c.$2 == 'prompt.submit');
      expect(submitted.$3['session_id'], chat.runtime.runtimeId);
      expect(submitted.$3['text'], 'Spoken request');
      voice.release();
      expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
      expect(voice.available, isFalse);
      await expectLater(
        voice.delegate('request', 'Too late', delegationId: 'too-late'),
        throwsStateError,
      );
    },
  );

  test(
    'live voice rejects a voice missing from plugin support before startup',
    () async {
      await appPreferences.setLiveSubscriptionVoice('ember');
      final chat = await controller.createChat(canDispatch: () => true);
      final voice = controller.liveVoiceConversation(chat);
      addTearDown(voice.release);
      await expectLater(
        voice.negotiate('offer'),
        throwsA(
          isA<LiveVoiceStartException>().having(
            (error) => error.message,
            'message',
            contains('does not support this voice'),
          ),
        ),
      );
      expect(host.voiceEndpoints, isEmpty);
    },
  );

  test('live voice subscription uses only the Wing plugin contract', () async {
    await appPreferences.setLiveSubscriptionVoice('breeze');
    final chat = await controller.createChat(canDispatch: () => true);
    final voice = controller.liveVoiceConversation(chat);
    final result = await voice.negotiate('offer');
    expect(result['mode'], 'subscription');
    expect(host.voiceEndpoints, [
      'plugins/wing/voice/v2/session?profile=${chat.key.workspace.profileName}',
    ]);
    expect(host.calls.singleWhere((c) => c.$2 == 'voice.negotiate').$3, {
      'offer': 'offer',
      'voice': 'breeze',
      'mode': 'subscription',
      'system_prompt':
          'Native saved prompt for ${chat.key.workspace.profileName}',
      'cwd': '/${chat.key.workspace.profileName}/workspace',
      'history': voice.context,
    });
    final reads = host.reads.where((r) => r.$1.contains('voice/')).toList();
    expect(reads.single.$1, 'plugins/wing/voice/v2/status');
    expect(reads.single.$2['profile'], chat.key.workspace.profileName);
    voice.release();
  });

  test(
    'live voice subscription delegates provider text through canonical chat',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Keep this draft');
      final transport = VoiceTransportFixture();
      final session = LiveVoiceSession(
        createTransport: () => transport,
        background: VoiceBackgroundFixture(),
      );
      await session.start(controller.liveVoiceConversation(chat));
      const text =
          'Ask Hermes to use its terminal tool to calculate 137 times 29';
      transport.event({
        'type': 'output_transcript.added',
        'item': {'text': 'I will ask Hermes.'},
      });
      transport.delegate('native-delegation', text);
      transport.delegate('native-delegation', text);
      await settleVoice();
      await settleVoice();
      final submissions = host.calls
          .where((c) => c.$2 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(1));
      expect(submissions.single.$3['session_id'], chat.runtime.runtimeId);
      expect(submissions.single.$3['text'], text);
      expect(submissions.single.$3['surface'], 'voice-live');
      expect(
        submissions.single.$3['voice_context'],
        contains('I will ask Hermes.'),
      );
      expect(submissions.single.$3.containsKey('voice_turn'), isFalse);
      expect(chat.composer.observation.text, 'Keep this draft');
      await session.end();
      session.dispose();
      expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
    },
  );

  test(
    'live voice matches each completion to its admission, including completion before ACK',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final voice = controller.liveVoiceConversation(chat);
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      await voice.delegate(
        'request',
        'Calculate it',
        delegationId: 'spoken-work',
      );
      await host.promptSubmitStarted!.future;
      final receipt = host.canonicalAdmissions.values.single;
      void complete(String admission, String text) {
        host.gateways[chat.key.workspace.profileName]!.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            envelope: {'admission_id': admission},
            data: {'text': text},
          ),
        );
      }

      complete(receipt['admission_id'] as String, 'The result is 3973');
      expect(voice.completedReplies, isEmpty);
      host.promptSubmitDelay!.complete();
      await settleVoice();
      await settleVoice();
      expect(voice.completedReplies, {'spoken-work': 'The result is 3973'});
      host.promptSubmitDelay = null;
      host.promptSubmitStarted = null;
      await voice.delegate(
        'request',
        'Another task',
        delegationId: 'second-work',
      );
      await settleVoice();
      await settleVoice();
      final second = host.canonicalAdmissions.values.last;
      complete(second['admission_id'] as String, 'Second result');
      expect(voice.completedReplies, {
        'spoken-work': 'The result is 3973',
        'second-work': 'Second result',
      });
      complete('unrelated-typed-work', 'Do not read this aloud');
      expect(voice.completedReplies, {
        'spoken-work': 'The result is 3973',
        'second-work': 'Second result',
      });
      voice.release();
    },
  );

  test('live voice edited unsent request retains result routing', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await chat.composer.pause();
    final voice = controller.liveVoiceConversation(chat);
    addTearDown(voice.release);
    await voice.delegate(
      'request',
      'Calculate it',
      delegationId: 'edited-voice',
    );
    await settleVoice();
    final queued = chat.composer.observation.queue.single;
    await controller.beginQueuedPromptEdit(chat, queued.id);
    controller.updateQueuedPromptEdit(chat, 'Calculate 173 times 41');
    await controller.saveQueuedPromptEdit(chat);
    await controller.resumeQueue(chat);
    await settleVoice();
    final receipt = host.canonicalAdmissions.values.single;
    host.gateways[chat.key.workspace.profileName]!.onEvent!(
      StreamEvent(
        type: 'message.complete',
        sessionId: chat.runtime.runtimeId,
        envelope: {'admission_id': receipt['admission_id']},
        data: {'text': '7093'},
      ),
    );
    await settleVoice();
    expect(voice.completedReplies, {'edited-voice': '7093'});
    expect(
      host.calls.where((c) => c.$2 == 'prompt.submit').single.$3['text'],
      'Calculate 173 times 41',
    );
  });

  for (final early in [false, true]) {
    test(
      'live voice server queue replacement retains handoff early=$early',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        emitChatEvent(controller, chat, 'message.start');
        final voice = controller.liveVoiceConversation(chat);
        addTearDown(voice.release);
        await voice.delegate(
          'request',
          'Calculate it',
          voiceContext: 'Original spoken context',
          delegationId: 'replaced-voice',
        );
        await settleVoice();
        await settleVoice();
        final original = host.canonicalAdmissions.values.single;
        expect(original['status'], 'queued');
        final queued = chat.composer.observation.queue.single;
        await controller.beginQueuedPromptEdit(chat, queued.id);
        controller.updateQueuedPromptEdit(chat, 'Calculate 173 times 41');
        host.promptReplaceStarted = Completer<void>();
        if (early) host.promptReplaceDelay = Completer<void>();
        final edited = controller.saveQueuedPromptEdit(chat);
        await host.promptReplaceStarted!.future;
        if (!early) await edited;
        final replacement = host.canonicalAdmissions.values.last;
        expect(original['outcome'], 'cancelled');
        expect(replacement['admission_id'], isNot(original['admission_id']));
        host.gateways[chat.key.workspace.profileName]!.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            envelope: {'admission_id': replacement['admission_id']},
            data: {
              'text': '7093',
              'persisted_turn': {
                'submission_id': replacement['input_id'],
                'row_ids': [201, 202],
                'complete': true,
                'final_assistant_row_id': 202,
              },
            },
          ),
        );
        if (early) {
          host.promptReplaceDelay!.complete();
          await edited;
        }
        await settleVoice();
        expect(voice.completedReplies, {'replaced-voice': '7093'});
        final sent = host.calls
            .singleWhere((c) => c.$2 == 'prompt.replace_queued')
            .$3;
        expect(sent['surface'], 'voice-live');
        expect(sent['voice_context'], 'Original spoken context');
        expect(
          chat.reading.isVoiceTaskReply({'id': 202, 'role': 'assistant'}),
          isTrue,
        );
      },
    );
  }

  for (final beforeAck in [false, true]) {
    for (final hangup in [false, true]) {
      test(
        'live voice forwards streamed result with null completion text beforeAck=$beforeAck hangup=$hangup',
        () async {
          final chat = await controller.createChat(canDispatch: () => true);
          final transport = VoiceTransportFixture();
          final session = LiveVoiceSession(
            createTransport: () => transport,
            background: VoiceBackgroundFixture(),
          );
          await session.start(controller.liveVoiceConversation(chat));
          addTearDown(() async {
            await session.end();
            session.dispose();
          });
          host.promptSubmitStarted = Completer<void>();
          if (beforeAck) host.promptSubmitDelay = Completer<void>();
          transport.delegate('spoken-result', 'Calculate it');
          await host.promptSubmitStarted!.future;
          if (!beforeAck) {
            await settleVoice();
            await settleVoice();
          }
          final receipt = host.canonicalAdmissions.values.single;
          final admission = receipt['admission_id'] as String;
          void emit(String type, Map<String, dynamic> data) =>
              host.gateways[chat.key.workspace.profileName]!.onEvent!(
                StreamEvent(
                  type: type,
                  sessionId: chat.runtime.runtimeId,
                  envelope: {'admission_id': admission},
                  data: data,
                ),
              );
          if (hangup) await session.end();
          emit('message.start', {'turn_id': 'native-turn'});
          emit('message.delta', {
            'turn_id': 'native-turn',
            'segment': 0,
            'offset': 0,
            'text': 'The result is 3973.',
          });
          expect(chat.reading.streaming, 'The result is 3973.');
          // Captured stock event shape: body is carried by stream, receipt by completion.
          emit('message.complete', {
            'text': null,
            'content': null,
            'admission_id': admission,
            'outcome': 'completed',
            'status': 'complete',
            'persisted_turn': {
              'complete': true,
              'row_ids': [101, 102],
              'user_row_id': 101,
              'user_row_ids': [101],
              'final_assistant_row_id': 102,
              'submission_id': receipt['input_id'],
            },
          });
          if (beforeAck) host.promptSubmitDelay!.complete();
          await settleVoice();
          await settleVoice();
          await settleVoice();
          final replies = transport.sent
              .where(
                (event) =>
                    event['type'] == 'delegation.context.append' &&
                    event['delegation_item_id'] == 'spoken-result' &&
                    jsonEncode(event).contains('The result is 3973.'),
              )
              .toList();
          expect(
            replies,
            hasLength(hangup ? 0 : 1),
            reason: 'The actual Hermes result must reach GPT-Live once',
          );
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            hasLength(1),
          );
          expect(
            chat.reading.isVoiceTaskReply({
              'id': 102,
              'role': 'assistant',
              'content': 'The result is 3973.',
            }),
            isTrue,
          );
          expect(
            chat.reading.isVoiceTaskReply({
              'id': 103,
              'role': 'assistant',
              'content': 'The result is 3973.',
            }),
            isFalse,
            reason: 'Identical typed answers must not be folded',
          );
          expect(
            chat.reading.isVoiceTaskReply({
              'id': 101,
              'role': 'user',
              'content': 'Calculate it',
            }),
            isFalse,
          );
          expect(
            chat.reading.isVoiceTaskReply({
              '_reply_admission': admission,
              'role': 'assistant',
              'content': 'Interim task reply',
            }),
            isTrue,
            reason: 'Streaming and saved replies share task provenance',
          );
          await session.end();
          expect(
            chat.reading.isVoiceTaskReply({'id': 102, 'role': 'assistant'}),
            isTrue,
            reason: 'Hangup must retain task details',
          );
        },
      );
    }
  }

  test(
    'live voice preserves the native cached prompt over an older saved prompt',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.voiceCachedPrompt = 'Native active SOUL and memory';
      final voice = controller.liveVoiceConversation(chat);
      await voice.negotiate('offer');
      final body = host.calls.singleWhere((c) => c.$2 == 'voice.negotiate').$3;
      expect(body['system_prompt'], 'Native active SOUL and memory');
      expect(body['cwd'], '/${chat.key.workspace.profileName}/workspace');
      voice.release();
    },
  );

  test(
    'live voice explicitly requests native profile inspection for a new chat',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.voiceSavedPrompt = null;
      final voice = controller.liveVoiceConversation(chat);
      await voice.negotiate('offer');
      expect(
        host.calls
            .singleWhere((c) => c.$2 == 'voice.negotiate')
            .$3['system_prompt'],
        isNull,
      );
      voice.release();
    },
  );

  test(
    'live voice retirement during native context read prevents negotiation',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final held = host.heldVoiceContext = Completer<void>();
      final voice = controller.liveVoiceConversation(chat);
      final pending = expectLater(voice.negotiate('offer'), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      voice.release();
      held.complete();
      await pending;
      expect(host.voiceEndpoints, isEmpty);
    },
  );

  test('live voice API unavailable stops before negotiating', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await appPreferences.setLiveVoiceMode(LiveVoiceMode.api);
    host.liveVoiceApiAvailable = false;
    final voice = controller.liveVoiceConversation(chat);
    await expectLater(
      voice.negotiate('offer'),
      throwsA(
        isA<LiveVoiceStartException>().having(
          (e) => e.message,
          'message',
          contains('Configure OpenAI API credentials'),
        ),
      ),
    );
    expect(host.voiceEndpoints, isEmpty);
    voice.release();
  });

  test('live voice provider failure never changes billing mode', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.liveVoiceSessionFailure = const DashboardHttpException(
      429,
      'plugins/wing/voice/v2/session',
    );
    final voice = controller.liveVoiceConversation(chat);
    await expectLater(
      voice.negotiate('offer'),
      throwsA(
        isA<LiveVoiceStartException>().having(
          (e) => e.message,
          'message',
          contains('subscription’s voice allowance'),
        ),
      ),
    );
    expect(host.voiceEndpoints, hasLength(1));
    expect(host.reads.where((r) => r.$1.startsWith('audio/')), isEmpty);
    voice.release();
  });

  for (final duringSession in [false, true]) {
    test(
      'live voice release fences held ${duringSession ? 'session' : 'status'} response',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        final held = Completer<void>();
        if (duringSession) {
          host.heldVoiceSession = held;
        } else {
          host.heldVoiceStatus = held;
        }
        final voice = controller.liveVoiceConversation(chat);
        final pending = expectLater(voice.negotiate('offer'), throwsStateError);
        await Future<void>.delayed(Duration.zero);
        voice.release();
        held.complete();
        await pending;
        expect(host.voiceEndpoints, hasLength(duringSession ? 1 : 0));
        expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
      },
    );
  }

  test('live voice bounds long chat context including its heading', () async {
    host.historyMessages = [
      {'id': 1, 'role': 'assistant', 'content': '${'x' * 30000}Latest result'},
    ];
    final chat = (await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'same'),
    ))!;
    final voice = controller.liveVoiceConversation(chat);
    expect(voice.context.length, lessThanOrEqualTo(24000));
    expect(voice.context, startsWith('Current chat:'));
    expect(voice.context, endsWith('Latest result'));
    voice.release();
  });

  test(
    'live voice release revokes negotiation and never cancels work',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final voice = controller.liveVoiceConversation(chat);
      voice.release();
      await expectLater(voice.negotiate('late offer'), throwsStateError);
      expect(host.calls.where((c) => c.$2 == 'voice.negotiate'), isEmpty);
      expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
    },
  );

  test(
    'sent image reads share login across independently disposed owners',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var logins = 0;
      var downloads = 0;
      var expectedSession = 'same';
      final subscription = server.listen((request) async {
        if (request.uri.path == '/auth/password-login') {
          logins++;
          await utf8.decoder.bind(request).join();
          if (logins > 10) {
            request.response.statusCode = HttpStatus.tooManyRequests;
          } else {
            request.response.headers.add(
              'set-cookie',
              'hermes_session_at=fixture; Path=/',
            );
            request.response.write('{}');
          }
        } else {
          expect(
            request.uri.path,
            anyOf('/api/fs/download', '/api/fs/read-text'),
          );
          expect(request.headers.value('cookie'), 'hermes_session_at=fixture');
          expect(request.uri.queryParameters['profile'], 'a');
          expect(request.uri.queryParameters['session_id'], expectedSession);
          downloads++;
          if (request.uri.path.endsWith('read-text')) {
            expect(request.uri.queryParameters['path'], 'relative.md');
            request.response.write(
              jsonEncode({
                'path': '/child/relative.md',
                'text': 'Child content',
              }),
            );
          } else {
            request.response.add([1, 2, 3]);
          }
        }
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'image-login-fixture',
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'image-host',
            label: 'Images',
            host: '127.0.0.1',
            port: 1,
            dashboardPortOverride: server.port,
            dashboardUsername: 'fixture',
            dashboardPassword: 'fixture',
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      await controller.initialize();
      final chat = (await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'same'),
      ))!;
      Future<void> imageRead(int index) async {
        final files = controller.traceResources(chat.key);
        try {
          expect(await files.loadImage('/images/$index.png'), [1, 2, 3]);
        } finally {
          files.dispose();
        }
      }

      await Future.wait([for (var i = 0; i < 3; i++) imageRead(i)]);
      expect(logins, 1, reason: 'The three chat previews must share one login');
      await controller.switchProfile('b');
      for (var i = 3; i < 40; i++) {
        await imageRead(i);
      }
      expect(downloads, 40);
      for (final child in ['child-session', 'nested-session']) {
        expectedSession = child;
        final trace = controller.traceResources(
          ProfileSessionKey(chat.key.workspace, child),
        );
        try {
          expect(await trace.loadImage('image.png'), [1, 2, 3]);
          expect(
            (await trace.files.readText('relative.md')).text,
            'Child content',
          );
        } finally {
          trace.dispose();
        }
      }
      expect(downloads, 44);
      expect(
        logins,
        1,
        reason: 'Disposing a file reader must retain connection authentication',
      );
    }, _SocketHttpOverrides()),
  );

  test(
    'discovery retains unchanged facts and publishes real membership changes',
    () async {
      final first = controller.discovery!;
      await controller.switchProfile('a');
      expect(controller.discovery, same(first));
      host.profiles = ['a', 'b', 'c'];
      await controller.switchProfile('a');
      expect(controller.discovery, isNot(same(first)));
      expect(controller.discovery!.profiles.map((profile) => profile.name), [
        'a',
        'b',
        'c',
      ]);
      expect(first.profiles.map((profile) => profile.name), ['a', 'b']);
      expect(
        () => controller.discovery!.profiles.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'canonical rows detach producer data and publish stable deep readonly facts',
    () async {
      final nested = <String, dynamic>{
        'paths': <String>['/original'],
      };
      final row = <String, dynamic>{
        'id': 'same',
        'title': 'Original',
        'profile': 'a',
        'metadata': nested,
      };
      host.indexedSessions = [row];
      await controller.refresh();
      final resource = controller.current!;
      final discovery = controller.discovery!;
      expect(identical(discovery, controller.discovery), isTrue);
      expect(() => discovery.profiles.clear(), throwsUnsupportedError);
      final published = resource.sessions.single;
      expect(identical(published, resource.sessions.single), isTrue);
      expect(() => resource.sessions.clear(), throwsUnsupportedError);
      expect(() => published['title'] = 'Outside', throwsUnsupportedError);
      final metadata = published['metadata'] as Map;
      expect(() => metadata['paths'] = [], throwsUnsupportedError);
      expect(() => (metadata['paths'] as List).clear(), throwsUnsupportedError);
      nested['paths'] = ['/changed'];
      row['title'] = 'Producer changed';
      expect(published['title'], 'Original');
      expect(metadata['paths'], ['/original']);
      final chat = (await controller.openSession(
        ProfileSessionKey(resource.scope, 'same'),
      ))!;
      expect(() => resource.chats.clear(), throwsUnsupportedError);
      expect(
        () => resource.deletedSessions.add('same'),
        throwsUnsupportedError,
      );
      expect(
        () => (chat as dynamic).title = 'Outside',
        throwsNoSuchMethodError,
      );
      expect(
        () => (resource as dynamic).selectedSession = null,
        throwsNoSuchMethodError,
      );
      expect(
        () => (controller as dynamic).current = null,
        throwsNoSuchMethodError,
      );
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'readonly-child',
        'goal': 'Work',
      });
      final subagents = chat.subagents;
      expect(() => subagents.clear(), throwsUnsupportedError);
      expect(
        () => subagents.single.recentActivity.add('Outside'),
        throwsUnsupportedError,
      );
    },
  );

  for (final hasCachedRow in [false, true]) {
    test(
      'server title overrides cached or absent row: cached=$hasCachedRow',
      () async {
        final resource = controller.current!;
        host.indexedSessions = hasCachedRow
            ? [
                {
                  'id': 'same',
                  'title': 'Outdated cached title',
                  'profile': 'a',
                },
              ]
            : [];
        await controller.refresh();
        host.sessionTitle = 'Current server title';
        await controller.openSession(ProfileSessionKey(resource.scope, 'same'));
        expect(controller.current!.chat!.title, 'Current server title');
      },
    );
  }

  test(
    'session title events update only their runtime and durable owner',
    () async {
      final first = await controller.createChat(canDispatch: () => true);
      await controller.navigateProfile('b');
      final second = await controller.createChat(canDispatch: () => true);
      host.event('a', 'session.title', {
        'session_id': 'same',
        'title': 'Explicit rename',
      });
      expect(first.title, 'Explicit rename');
      expect(second.title, 'New chat');
      host.event('a', 'session.title', {
        'session_id': 'another',
        'title': 'Wrong owner',
      });
      host.event('a', 'session.title', {'session_id': 'same', 'title': '  '});
      host.event('a', 'session.info', {
        'stored_session_id': 'another',
        'title': 'Wrong info owner',
      });
      expect(first.title, 'Explicit rename');
      host.event('a', 'session.info', {
        'stored_session_id': 'same',
        'title': 'Current info title',
      });
      expect(first.title, 'Current info title');
    },
  );

  test('unknown session title info keeps an existing title', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'session.title', {
      'session_id': chat.key.sessionId,
      'title': 'Known title',
    });
    for (final title in [null, '', '  ', 123]) {
      host.event('a', 'session.info', {'title': title});
      expect(chat.title, 'Known title');
    }
  });

  test(
    'reconnect notification uses recovered answer instead of generic status',
    () async {
      final received = <ProfileNotification>[];
      final connection = controller.connection;
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => received.add(notice),
      );
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('work');
      await controller.send(chat);
      host.historyMessages = [
        {
          'id': 42,
          'role': 'assistant',
          'content': 'The report is ready for review.',
        },
      ];
      host.running = false;
      await controller.reconnect(chat.key.workspace);
      await Future<void>.delayed(Duration.zero);
      expect(received.last.content.preview, 'The report is ready for review.');
      expect(received.last.focus?.kind, 'answer');
    },
  );

  test(
    'notification loads pending approval for an already online empty chat',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.pendingApprovals = [
        {
          'request_id': 'not-yet-observed',
          'command': 'echo ready',
          'choices': ['once', 'deny'],
        },
      ];
      controller.showList();
      expect(chat.runtime.approval, isNull);
      final loaded = await controller.loadNotificationApproval(chat.key);
      expect(loaded, same(chat));
      expect(loaded?.runtime.approval?.requestId, 'not-yet-observed');
      expect(controller.notificationChat, isNull);
      expect(
        host.calls.where((call) => call.$2 == 'approval.respond'),
        isEmpty,
      );
    },
  );

  test(
    'cold approval review loads requests without selecting the chat',
    () async {
      host.running = false;
      host.pendingApprovals = [
        {
          'request_id': 'cold-review',
          'command': 'print(1)',
          'choices': ['once', 'deny'],
        },
      ];
      final key = ProfileSessionKey(controller.current!.scope, 'same');
      controller.showList();
      final chat = await controller.loadNotificationApproval(key);
      await Future<void>.delayed(Duration.zero);
      expect(chat?.runtime.approval?.requestId, 'cold-review');
      expect(controller.notificationChat, isNull);
      expect(controller.visible, isFalse);
      expect(
        host.calls.where((call) => call.$2 == 'approval.respond'),
        isEmpty,
      );
    },
  );

  for (final outcome in [
    'recovered',
    'failed',
    'replaced',
    'changed command',
    'joined',
    'timed out',
  ]) {
    testWidgets('notification approval recovery: $outcome', (tester) async {
      host.running = false;
      final chat = await controller.createChat(canDispatch: () => true);
      final request = <String, dynamic>{
        'request_id': 'notification-original',
        'command': 'print("test")',
        'choices': ['once', 'deny'],
      };
      host.pendingApprovals = [request];
      host.event('a', 'approval', request);
      host.gateways['a']!.onConnectionChanged!(false);
      if (outcome == 'failed') host.connectFailures = 20;
      if (outcome == 'replaced') {
        host.pendingApprovals = [
          {...request, 'request_id': 'replacement'},
        ];
      }
      if (outcome == 'changed command') {
        host.pendingApprovals = [
          {...request, 'command': 'print("changed")'},
        ];
      }
      if (outcome == 'joined' || outcome == 'timed out') {
        host.connectDelay = Completer<void>();
      }
      Future<void>? recovering;
      if (outcome == 'joined') {
        recovering = controller.reconnect(chat.key.workspace);
        await tester.pump(const Duration(milliseconds: 20));
      }
      Object? failure;
      var finished = false;
      final action = controller
          .approveNotification(
            chat,
            'once',
            requestId: 'notification-original',
            command: request['command'] as String,
          )
          .catchError((Object error) {
            failure = error;
          })
          .whenComplete(() {
            finished = true;
          });
      await tester.pump(const Duration(milliseconds: 20));
      if (outcome == 'joined') {
        expect(finished, isFalse);
        host.connectDelay!.complete();
      }
      if (outcome == 'timed out') {
        await tester.pump(const Duration(seconds: 16));
        expect(finished, isTrue);
        // Completing recovery later must not submit the timed-out intent.
        host.connectDelay!.complete();
      }
      for (var turn = 0; turn < 200 && !finished; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        finished,
        isTrue,
        reason: 'The bounded notification recovery must settle',
      );
      await action;
      if (recovering != null) await recovering;
      final decisions = host.calls
          .where((c) => c.$2 == 'approval.respond')
          .toList();
      if (outcome == 'recovered' || outcome == 'joined') {
        expect(failure, isNull);
        expect(decisions, hasLength(1));
        expect(decisions.single.$3['prompt_id'], 'notification-original');
      } else {
        expect(failure, isNotNull);
        expect(decisions, isEmpty);
        if (outcome == 'failed' || outcome == 'timed out') {
          expect(chat.runtime.decisionErrorRequestId, 'notification-original');
          expect(chat.runtime.decisionError, isNotNull);
        }
        host.connectFailures = 0;
        var reconnected = false;
        final retry = controller.reconnect(chat.key.workspace).whenComplete(() {
          reconnected = true;
        });
        for (var turn = 0; turn < 200 && !reconnected; turn++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          reconnected,
          isTrue,
          reason: 'Recovery after a refused decision must settle',
        );
        await retry;
        expect(host.calls.where((c) => c.$2 == 'approval.respond'), isEmpty);
      }
    });
  }

  test('restores draft text after controller restart', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'unfinished thought');
    final key = chat.key;
    final connection = controller.connection;
    controller.dispose();

    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    await controller.openSession(key);

    expect(
      controller.current!.chat!.composer.observation.text,
      'unfinished thought',
    );
  });

  test('recovers a cold saved draft into a fresh local chat', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final source = ProfileSessionKey(controller.current!.scope, 'cold-draft');
    await store.write(
      profileName: 'a',
      sessionId: source.sessionId,
      text: 'Cold camera draft check',
      attachments: const [],
      queuedPrompts: [QueuedPromptDraft(text: 'send later')],
    );
    expect((await controller.savedDraft(source))!.text, contains('Cold'));
    final destination = await controller.createChat(canDispatch: () => true);

    await controller.recoverDraft(source, destination);

    expect(destination.composer.observation.text, 'Cold camera draft check');
    expect(destination.composer.observation.submissionUncertain, isFalse);
    expect(destination.composer.observation.queue.single.text, 'send later');
    expect(destination.composer.observation.paused, isTrue);
    expect(await controller.savedDraft(source), isNull);
    final durable = await store.read(
      profileName: 'a',
      sessionId: destination.key.sessionId,
    );
    expect(durable!.text, 'Cold camera draft check');
    expect(durable.queuePaused, isTrue);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    expect(
      host.calls.where(
        (call) =>
            call.$2 == 'session.resume' &&
            call.$3['session_id'] == source.sessionId,
      ),
      isEmpty,
    );
  });

  test('does not recover from a draft owned by a live chat', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final source = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(source, 'still being edited');
    final destination = await controller.createChat(canDispatch: () => true);

    await expectLater(
      controller.recoverDraft(source.key, destination),
      throwsStateError,
    );

    expect(destination.composer.observation.text, isEmpty);
    expect(
      (await store.read(
        profileName: 'a',
        sessionId: source.key.sessionId,
      ))!.text,
      'still being edited',
    );
  });

  test(
    'lost prompt acknowledgement preserves its uncertain outbox head',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'original-settings',
      );
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'send once');
      host.promptSubmitFails = true;

      await controller.send(chat);

      expect(chat.composer.observation.text, isEmpty);
      expect(chat.composer.observation.queue.single.text, 'send once');
      expect(
        chat.composer.observation.queue.single.submissionUncertain,
        isTrue,
      );
      expect(chat.composer.observation.paused, isTrue);
      final saved = (await store.read(profileName: 'a', sessionId: 'same'))!;
      expect(saved.text, isEmpty);
      expect(saved.queuedPrompts.single.text, 'send once');
      expect(saved.queuedPrompts.single.submissionUncertain, isTrue);

      await controller.reconnect(chat.key.workspace);

      expect(chat.composer.observation.text, isEmpty);
      expect(chat.composer.observation.queue.single.text, 'send once');
      expect(
        chat.composer.observation.queue.single.submissionUncertain,
        isTrue,
      );
      await expectLater(controller.resumeQueue(chat), throwsStateError);
      expect(chat.runtime.error, contains('not confirmed'));
      final attempts = host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .toList();
      expect(attempts, hasLength(2));
      expect(attempts[1].$3, attempts[0].$3);
      expect(host.canonicalAdmissions, hasLength(1));
    },
  );

  test('accepted prompt clears the durable draft', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'send once');

    await controller.send(chat);

    expect(chat.composer.observation.text, isEmpty);
    expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
  });

  test(
    'expired unsubmitted runtime keeps its draft and project on replacement',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'original-settings',
      );
      final project = controller.current!.projects.single;
      final chat = await controller.createChat(
        inProject: project,
        canDispatch: () => true,
      );
      final oldKey = chat.key;
      final attachment = AttachmentDraft(
        id: 'camera',
        cachedPath: 'camera.png',
        name: 'camera.png',
        byteLength: 20,
        mediaType: 'image/png',
        kind: AttachmentDraftKind.image,
        sourceImageFormat: AttachmentImageFormat.png,
        sanitized: true,
      );
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [attachment],
      );
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendQueued: [QueuedPromptDraft(text: 'later')],
      );
      await controller.setIntelligence(
        chat,
        const ChatIntelligenceSelection(
          choice: ModelChoice(
            provider: 'chosen-provider',
            model: 'chosen-model',
          ),
          reasoningEffort: 'low',
          fastMode: ChatFastMode.normal,
        ),
        confirmModelChange: (_) async => true,
      );
      emitChatEvent(controller, chat, 'session.info', {'yolo': true});
      await controller.updateDraft(chat, 'keep this draft');
      host.expireUnsubmittedResume = true;
      host.connectError = StateError('Synthetic permanent connection failure');
      await controller.reconnect(chat.key.workspace);
      expect(controller.current!.reconnectError, isNotNull);
      host.connectError = null;

      await controller.navigateProfile('a');
      // Model selection setup uses genuine RPCs on the original runtime.
      // Only calls admitted by this replacement action target its new runtime.
      final replacementCallStart = host.calls.length;
      await controller.openSession(oldKey, recoverExpiredDraft: true);

      expect(chat.key.sessionId, 'replacement');
      expect(chat.runtime.runtimeId, 'a-replacement-runtime');
      expect(chat.composer.observation.text, 'keep this draft');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        attachment.id,
      ]);
      expect(chat.composer.observation.queue.single.text, 'later');
      expect(chat.projectId, project['id']);
      expect(chat.intelligenceRuntime, 'a-replacement-runtime');
      expect(chat.yolo, isTrue);
      expect(controller.current!.chat, same(chat));
      expect(controller.current!.reconnectError, isNull);
      expect(
        host.calls.lastWhere((call) => call.$2 == 'session.create').$3['cwd'],
        project['primary_path'],
      );
      expect(
        host.calls
            .lastWhere((call) => call.$2 == 'session.create')
            .$3['cwd_explicit'],
        isTrue,
      );
      expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
      final migrated = await store.read(
        profileName: 'a',
        sessionId: 'replacement',
      );
      expect(migrated?.text, 'keep this draft');
      expect(migrated?.attachments.single.id, 'camera');
      expect(migrated?.queuedPrompts.single.text, 'later');
      expect(
        host.calls
            .skip(replacementCallStart)
            .where((call) => call.$2 == 'config.set')
            .map((call) => call.$3['session_id']),
        everyElement('a-replacement-runtime'),
      );
      expect(
        host.calls
            .skip(replacementCallStart)
            .where((call) => call.$2 == 'config.set')
            .map((call) => call.$3['key']),
        containsAll(['fast', 'yolo']),
      );
    },
  );

  // Stock contract inspected at f42f579cf8bac4918ac9599bece71618afadd846:
  // session_workdir._completion_cwd and methods_session._create_session.
  test(
    'profile chat inherits its directory without explicit provenance',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final params = host.calls
          .lastWhere((call) => call.$2 == 'session.create')
          .$3;
      expect(params['cwd_explicit'], isFalse);
      expect(params.containsKey('cwd'), isFalse);
      expect(chat.projectId, isNull);
    },
  );

  test(
    'inherited cwd keeps provenance even when it names a project path',
    () async {
      final response = await controller.current!.gateway.createSession(
        cwd: '/a',
        cwdExplicit: false,
        canDispatch: () => true,
      );
      final params = host.calls
          .lastWhere((call) => call.$2 == 'session.create')
          .$3;
      expect(params['cwd'], '/a');
      expect(params['cwd_explicit'], isFalse);
      expect(response['info']['cwd'], '/a/profile-default');
    },
  );

  test('project chat chooses its directory over the profile default', () async {
    final project = controller.current!.projects.single;
    final chat = await controller.createChat(
      inProject: project,
      canDispatch: () => true,
    );
    final params = host.calls
        .lastWhere((call) => call.$2 == 'session.create')
        .$3;
    expect(params['cwd'], '/a');
    expect(params['cwd_explicit'], isTrue);
    expect(chat.projectId, project['id']);
  });

  test('project directory permits stock lexical normalization', () async {
    host.projectPaths['a'] = '/a/./';
    await controller.navigateProfile('a');
    final project = controller.current!.projects.single;
    host.createdCwdOverride = '/a';
    final chat = await controller.createChat(
      inProject: project,
      canDispatch: () => true,
    );
    expect(chat.projectId, project['id']);
  });

  for (final missingAcknowledgement in [false, true]) {
    test(
      'project chat refuses ${missingAcknowledgement ? 'missing' : 'different'} acknowledged directory',
      () async {
        final project = controller.current!.projects.single;
        host.createdCwdOverride = '/a/profile-default';
        host.omitCreatedCwd = missingAcknowledgement;
        await expectLater(
          controller.createChat(inProject: project, canDispatch: () => true),
          throwsStateError,
        );
        expect(controller.current!.chats, isEmpty);
        expect(controller.current!.selectedSession, isNull);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  test('project without a directory refuses creation before RPC', () async {
    host.projectPaths['a'] = null;
    await controller.navigateProfile('a');
    final project = controller.current!.projects.single;
    await expectLater(
      controller.createChat(inProject: project, canDispatch: () => true),
      throwsStateError,
    );
    expect(host.sessionCreates, 0);
    expect(controller.current!.chats, isEmpty);
  });

  for (final unavailablePath in [false, true]) {
    test(
      'expired project draft stays put when destination ${unavailablePath ? 'is unavailable' : 'disagrees'}',
      () async {
        final project = controller.current!.projects.single;
        final chat = await controller.createChat(
          inProject: project,
          canDispatch: () => true,
        );
        final oldKey = chat.key;
        await controller.updateDraft(chat, 'Keep this project draft');
        host.expireUnsubmittedResume = true;
        if (!unavailablePath) {
          host.createdCwdOverride = '/a/profile-default';
        } else {
          host.projectPaths['a'] = null;
        }
        // Reload stock project metadata through the actual captured owner.
        await controller.navigateProfile('a');
        await expectLater(
          controller.openSession(oldKey, recoverExpiredDraft: true),
          throwsStateError,
        );
        expect(chat.key, oldKey);
        expect(chat.runtime.runtimeId, 'a-runtime');
        expect(chat.projectId, project['id']);
        expect(chat.composer.observation.text, 'Keep this project draft');
        expect(controller.current!.chats.keys, ['same']);
        final store = ComposerDraftStore(
          preferences,
          connectionIdentity: 'original-settings',
        );
        expect(
          (await store.read(profileName: 'a', sessionId: 'same'))?.text,
          'Keep this project draft',
        );
        expect(
          await store.read(profileName: 'a', sessionId: 'replacement'),
          isNull,
        );
        expect(host.sessionCreates, unavailablePath ? 1 : 2);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  test(
    'unknown resume failure does not replace an unsubmitted runtime',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final oldKey = chat.key;
      await controller.updateDraft(chat, 'keep this draft');
      host.resumeFailures = 1;

      await controller.navigateProfile('a');
      await expectLater(
        controller.openSession(oldKey),
        throwsA(isA<TimeoutException>()),
      );

      expect(chat.key, oldKey);
      expect(chat.composer.observation.text, 'keep this draft');
      expect(host.sessionCreates, 1);
    },
  );

  test('ordinary open does not replace a definitively expired draft', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    final oldKey = chat.key;
    await controller.updateDraft(chat, 'keep this draft');
    host.expireUnsubmittedResume = true;

    await controller.navigateProfile('a');
    await expectLater(
      controller.openSession(oldKey),
      throwsA(isA<JsonRpcError>()),
    );

    expect(chat.key, oldKey);
    expect(chat.composer.observation.text, 'keep this draft');
    expect(host.sessionCreates, 1);
  });

  test('reconnect replaces the selected definitively expired draft', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'keep this draft');
    host.expireUnsubmittedResume = true;

    await controller.reconnect(chat.key.workspace);

    expect(chat.key.sessionId, 'replacement');
    expect(chat.composer.observation.text, 'keep this draft');
    expect(controller.current!.chat, same(chat));
    expect(controller.current!.reconnectError, isNull);
  });

  test(
    'replacement blocks composer writes until the durable key moves',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'original-settings',
      );
      final chat = await controller.createChat(canDispatch: () => true);
      final oldKey = chat.key;
      await controller.updateDraft(chat, 'keep this draft');
      host
        ..expireUnsubmittedResume = true
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();
      await controller.navigateProfile('a');

      final opening = controller.openSession(oldKey, recoverExpiredDraft: true);
      await host.replacementCreateStarted!.future;
      final typing = controller.updateDraft(chat, 'racing edit');
      await controller.send(chat);
      await expectLater(
        controller.queuePrompt(chat, 'racing queue'),
        throwsStateError,
      );
      host.replacementCreateDelay!.complete();
      await opening;
      await typing;

      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
      expect(
        (await store.read(profileName: 'a', sessionId: 'replacement'))?.text,
        'racing edit',
      );
    },
  );

  test(
    'camera target follows a draft already replaced by background reconnect',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host.expireUnsubmittedResume = true;

      await controller.reconnect(capturedKey.workspace);
      expect(chat.key, isNot(capturedKey));
      await controller.navigateProfile('a');
      await expectLater(
        controller.openSession(capturedKey),
        throwsA(isA<JsonRpcError>()),
      );
      final opened = await controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );

      expect(opened, same(chat));
      expect(chat.composer.observation.text, 'camera draft');
      expect(
        chat.reading.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        isEmpty,
      );
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'mounted camera intake keeps the draft without a session resume',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      controller.setRouteMounted(Object(), true);
      final start = host.calls.length;

      final destination = await controller.prepareSharedDraftTarget(chat.key);

      expect(destination?.chat, same(chat));
      expect(destination?.retainWorkspace, isTrue);
      expect(host.calls.skip(start), isEmpty);
    },
  );

  test('mounted camera intake joins background draft replacement', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    final capturedKey = chat.key;
    await controller.updateDraft(chat, 'camera draft');
    controller.setRouteMounted(Object(), true);
    host
      ..expireUnsubmittedResume = true
      ..replacementCreateStarted = Completer<void>()
      ..replacementCreateDelay = Completer<void>();
    final reconnecting = controller.reconnect(capturedKey.workspace);
    await host.replacementCreateStarted!.future;
    final destination = controller.prepareSharedDraftTarget(capturedKey);

    host.replacementCreateDelay!.complete();
    await reconnecting;

    final prepared = await destination;
    expect(prepared?.chat, same(chat));
    expect(prepared?.retainWorkspace, isTrue);
    expect(chat.key.sessionId, 'replacement');
    expect(chat.composer.observation.text, 'camera draft');
    expect(
      host.calls.where((call) => call.$2 == 'session.resume'),
      hasLength(1),
    );
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    final later = await controller.prepareSharedDraftTarget(capturedKey);
    expect(later?.chat, same(chat));
    expect(later?.retainWorkspace, isTrue);
    expect(
      host.calls.where((call) => call.$2 == 'session.resume'),
      hasLength(1),
    );
  });

  test(
    'explicit recovery waits for an in-flight replacement of its captured key',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host
        ..expireUnsubmittedResume = true
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();

      final reconnecting = controller.reconnect(capturedKey.workspace);
      await host.replacementCreateStarted!.future;
      final opening = controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );
      final openingResult = opening.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );

      host.replacementCreateDelay!.complete();
      await reconnecting;
      expect(await openingResult, same(chat));

      expect(chat.key.sessionId, 'replacement');
      expect(chat.composer.observation.text, 'camera draft');
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'explicit recovery joins replacement started during its resume request',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host
        ..expireUnsubmittedResume = true
        ..expiredResumeStarted = Completer<void>()
        ..expiredResumeDelay = Completer<void>()
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();

      final opening = controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );
      await host.expiredResumeStarted!.future;
      final reconnecting = controller.reconnect(capturedKey.workspace);
      await host.replacementCreateStarted!.future;
      final openingExpectation = expectLater(opening, completion(same(chat)));

      host.expiredResumeDelay!.complete();
      host.replacementCreateDelay!.complete();
      await reconnecting;
      await openingExpectation;

      expect(chat.key.sessionId, 'replacement');
      expect(chat.composer.observation.text, 'camera draft');
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test('definitive resume failure does not replace a submitted chat', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    final oldKey = chat.key;
    await controller.updateDraft(chat, 'accepted prompt');
    await controller.send(chat);
    host.expireUnsubmittedResume = true;

    await controller.navigateProfile('a');
    await expectLater(
      controller.openSession(oldKey),
      throwsA(isA<JsonRpcError>()),
    );

    expect(chat.key, oldKey);
    expect(host.sessionCreates, 1);
  });

  test(
    'reconnect does not clear text edited after a lost acknowledgement',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'first version');
      host.promptSubmitFails = true;
      await controller.send(chat);
      await controller.updateDraft(chat, 'edited while checking');
      host.promptSubmitFails = false;

      await controller.reconnect(chat.key.workspace);

      expect(chat.composer.observation.text, 'edited while checking');
    },
  );

  test('concurrent prompt submissions send once', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'one prompt');
    host.promptSubmitStarted = Completer<void>();
    host.promptSubmitDelay = Completer<void>();

    final first = controller.send(chat);
    final second = controller.send(chat);
    await host.promptSubmitStarted!.future;
    expect(
      host.calls.where((call) => call.$2 == 'prompt.submit'),
      hasLength(1),
    );
    host.promptSubmitDelay!.complete();
    await Future.wait([first, second]);
  });

  test('send consumes the composer before asynchronous preparation', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'outgoing prompt');
    host.discoveryStarted = Completer<void>();
    host.discoveryDelay = Completer<void>();
    final sending = controller.send(chat);
    try {
      expect(chat.composer.observation.text, isEmpty);
      await host.discoveryStarted!.future;
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      final savedDraft =
          (await ComposerDraftStore(
            preferences,
            connectionIdentity: 'original-settings',
          ).read(
            profileName: chat.key.workspace.profileName,
            sessionId: chat.key.sessionId,
          ))!;
      expect(savedDraft.queuedPrompts.single.text, 'outgoing prompt');
      await controller.updateDraft(chat, 'immediate follow-up');
    } finally {
      host.discoveryDelay!.complete();
      await sending;
    }
    expect(chat.composer.observation.text, 'immediate follow-up');
    expect(
      host.calls.singleWhere((call) => call.$2 == 'prompt.submit').$3['text'],
      'outgoing prompt',
    );
    expect(chat.reading.messages.last['content'], 'outgoing prompt');
  });

  for (final freshDraft in ['', 'immediate follow-up']) {
    test(
      'preparation failure keeps unsent outbox with ${freshDraft.isEmpty ? 'empty' : 'fresh'} composer',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'outgoing prompt');
        host.discoveryStarted = Completer<void>();
        host.discoveryDelay = Completer<void>();
        host.discoveryFailure = StateError('Profile unavailable');
        final sending = controller.send(chat);
        try {
          expect(chat.composer.observation.text, isEmpty);
          await host.discoveryStarted!.future;
          if (freshDraft.isNotEmpty) {
            await controller.updateDraft(chat, freshDraft);
          }
        } finally {
          host.discoveryDelay!.complete();
          await sending;
        }
        expect(chat.composer.observation.text, freshDraft);
        expect(chat.composer.observation.submissionUncertain, isFalse);
        expect(chat.composer.observation.queue.single.text, 'outgoing prompt');
        expect(
          chat.composer.observation.queue.single.submissionUncertain,
          isFalse,
        );
        expect(chat.composer.observation.paused, isTrue);
        expect(chat.runtime.execution, ChatExecution.failed);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        final savedDraft =
            (await ComposerDraftStore(
              preferences,
              connectionIdentity: 'original-settings',
            ).read(
              profileName: chat.key.workspace.profileName,
              sessionId: chat.key.sessionId,
            ))!;
        expect(savedDraft.text, freshDraft);
        expect(savedDraft.queuedPrompts.single.text, 'outgoing prompt');
        expect(savedDraft.queuedPrompts.single.submissionUncertain, isFalse);
        expect(savedDraft.queuePaused, isTrue);
      },
    );
  }

  test(
    'accepted prompt does not clear follow-up text typed while waiting',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'first prompt');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();

      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.reading.messages.last['content'], 'first prompt');
      expect(chat.composer.observation.text, isEmpty);
      await controller.updateDraft(chat, 'follow-up draft');
      host.promptSubmitDelay!.complete();
      await sending;

      expect(chat.composer.observation.text, 'follow-up draft');
    },
  );

  test(
    'acknowledgement keeps a new draft identical to the sent prompt',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'same text');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();

      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.composer.observation.text, isEmpty);
      await controller.updateDraft(chat, 'same text');
      host.promptSubmitDelay!.complete();
      await sending;

      expect(chat.composer.observation.text, 'same text');
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  test(
    'lost acknowledgement keeps untouched sent content in the outbox',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'recover this prompt');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      host.promptSubmitFails = true;

      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.composer.observation.text, isEmpty);
      host.promptSubmitDelay!.complete();
      await sending;

      expect(chat.composer.observation.text, isEmpty);
      expect(chat.composer.observation.submissionUncertain, isFalse);
      expect(
        chat.composer.observation.queue.single.text,
        'recover this prompt',
      );
      expect(
        chat.composer.observation.queue.single.submissionUncertain,
        isTrue,
      );
      expect(chat.composer.observation.paused, isTrue);
      final saved = (await controller.savedDraft(chat.key))!;
      expect(saved.text, isEmpty);
      expect(saved.queuedPrompts.single.text, 'recover this prompt');
      expect(saved.queuedPrompts.single.submissionUncertain, isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  test('lost acknowledgement preserves a fresh follow-up draft', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'first prompt');
    host.promptSubmitStarted = Completer<void>();
    host.promptSubmitDelay = Completer<void>();
    host.promptSubmitFails = true;

    final sending = controller.send(chat);
    await host.promptSubmitStarted!.future;
    expect(chat.composer.observation.text, isEmpty);
    await controller.updateDraft(chat, 'follow-up draft');
    host.promptSubmitDelay!.complete();
    await sending;

    expect(chat.composer.observation.text, 'follow-up draft');
    expect(
      host.calls.where((call) => call.$2 == 'prompt.submit'),
      hasLength(1),
    );
  });

  test('adds and removes the next attachment while a response runs', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-running-attachment-',
    );
    try {
      final attachmentService = DelayedAttachmentDraftService(
        cacheDirectoryProvider: () async =>
            Directory('${sandbox.path}${Platform.pathSeparator}cache'),
      );
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
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
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        attachmentService: attachmentService,
      );
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'first prompt');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.runtime.execution, ChatExecution.running);

      final source = File(
        '${sandbox.path}${Platform.pathSeparator}follow-up.txt',
      );
      await source.writeAsString('follow-up file');
      host.promptSubmitDelay!.complete();
      await sending;
      host
        ..promptSubmitStarted = null
        ..promptSubmitDelay = null;
      expect(chat.runtime.execution, ChatExecution.running);
      await controller.updateDraft(chat, 'queued follow-up');
      await controller.queuePrompt(chat, 'queued follow-up');
      expect(chat.composer.observation.queue, hasLength(1));
      bool? lastCanAdd;
      void observeAttachmentControls() {
        lastCanAdd = controller.canAddAttachment(chat);
      }

      controller.addListener(observeAttachmentControls);
      final adding = controller.addAttachments(chat, [
        (path: source.path, name: 'follow-up.txt'),
      ]);
      await attachmentService.preparationStarted.future;
      final settled = Completer<void>();
      void observeSettlement() {
        if (chat.runtime.execution == ChatExecution.completed &&
            !settled.isCompleted) {
          settled.complete();
        }
      }

      controller.addListener(observeSettlement);
      host.event('a', 'message.complete');
      await settled.future;
      controller.removeListener(observeSettlement);
      attachmentService.finishPreparation.complete();
      await adding;

      final added = (await readComposerFixture(
        chat: chat,
        preferences: controller.preferences,
      ))!.attachments.single;
      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.paused, isFalse);
      final submissions = host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(2));
      expect(submissions.last.$3['text'], 'queued follow-up');
      expect(lastCanAdd, isTrue);
      controller.removeListener(observeAttachmentControls);
      expect(controller.canRemoveAttachment(chat, added.id), isTrue);
      expect(await File(added.cachedPath).exists(), isTrue);
      await controller.removeAttachment(chat, added.id);
      expect(chat.composer.observation.attachments, isEmpty);
      expect(await File(added.cachedPath).exists(), isFalse);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('cannot remove an attachment captured by prompt submission', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-submitting-attachment-',
    );
    try {
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
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
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        attachmentService: AttachmentDraftService(
          cacheDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}cache'),
        ),
      );
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      final source = File(
        '${sandbox.path}${Platform.pathSeparator}original.txt',
      );
      await source.writeAsString('original file');
      await controller.addAttachments(chat, [
        (path: source.path, name: 'original.txt'),
      ]);
      final captured = (await readComposerFixture(
        chat: chat,
        preferences: controller.preferences,
      ))!.attachments.single;
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;

      expect(controller.canAddAttachment(chat), isTrue);
      expect(controller.canRemoveAttachment(chat, captured.id), isFalse);
      await controller.removeAttachment(chat, captured.id);
      expect(chat.composer.observation.attachments, isEmpty);
      expect(
        chat.composer.observation.queue.single.attachments.map(
          (file) => file.id,
        ),
        contains(captured.id),
      );
      expect(await File(captured.cachedPath).exists(), isTrue);
      final nextSource = File('${sandbox.path}/next.txt');
      await nextSource.writeAsString('Next composer file');
      await controller.addAttachments(chat, [
        (path: nextSource.path, name: 'next.txt'),
      ]);
      final next = (await readComposerFixture(
        chat: chat,
        preferences: controller.preferences,
      ))!.attachments.single;
      expect(controller.canRemoveAttachment(chat, next.id), isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );

      host.promptSubmitDelay!.complete();
      await sending;
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        next.id,
      ]);
      expect(chat.composer.observation.queue, isEmpty);
      expect(await File(captured.cachedPath).exists(), isFalse);
      expect(await File(next.cachedPath).exists(), isTrue);
      expect(controller.canAddAttachment(chat), isTrue);
      await controller.removeAttachment(chat, next.id);
      expect(await File(next.cachedPath).exists(), isFalse);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('adds a locally picked file while a saved chat reconnects', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-reconnecting-attachment-',
    );
    try {
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
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
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        attachmentService: AttachmentDraftService(
          cacheDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}cache'),
        ),
      );
      await controller.initialize();
      final key = ProfileSessionKey(controller.current!.scope, 'same');
      await controller.openSession(key);
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Keep this next message');
      final existing = File(
        '${sandbox.path}${Platform.pathSeparator}existing.txt',
      );
      await existing.writeAsString('existing file');
      await controller.addAttachments(chat, [
        (path: existing.path, name: 'existing.txt'),
      ]);
      final callsBeforePickerReturn = host.calls.length;
      controller
          .browserResource(chat.key.workspace.profileName)
          .gateway
          .onConnectionChanged!(false);
      final picked = File('${sandbox.path}${Platform.pathSeparator}picked.txt');
      await picked.writeAsString('picked after background reconnect');

      await controller.addAttachments(chat, [
        (path: picked.path, name: 'picked.txt'),
      ]);

      expect(chat.composer.observation.text, 'Keep this next message');
      expect(chat.composer.observation.attachments.map((draft) => draft.name), [
        'existing.txt',
        'picked.txt',
      ]);
      expect(host.calls, hasLength(callsBeforePickerReturn));
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('a stale question panel cannot answer a newer request', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'clarify', {
      'request_id': 'old',
      'question': 'Old question',
    });
    final old = chat.runtime.questions!;
    emitChatEvent(controller, chat, 'clarify', {
      'request_id': 'new',
      'question': 'New question',
    });
    await expectLater(
      controller.clarify(chat, 'old answer', expectedRequest: old),
      throwsStateError,
    );
    expect(
      host.calls.where(
        (call) => {'clarify.lock', 'request.answer'}.contains(call.$2),
      ),
      isEmpty,
    );
    expect(chat.runtime.questions!.questions.first.requestId, 'new');
  });

  test(
    'failed profile navigation preserves the previous project load',
    () async {
      final data = controller.current!;
      host.projectDelay = Completer<void>();
      final pending = controller.selectProject(data.projects.first);
      host.failures.add('b');
      await controller.navigateProfile('b');
      expect(controller.current, same(data));
      expect(data.projectSessionsLoading, isTrue);
      host.projectDelay!.complete();
      await pending;
      expect(data.projectSessions.single['id'], 'project-chat');
      expect(data.projectSessionsError, isNull);
    },
  );

  test('profile traffic and canonical timing replay stay scoped', () async {
    await controller.createProject(
      'Test',
      '/a',
      color: '#112233',
      icon: 'folder',
      canDispatch: () => true,
    );
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('hello');
    await controller.send(chat);
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'once',
      'choices': ['once', 'deny'],
    });
    await controller.approve(
      chat,
      'once',
      requestId: chat.runtime.approval!.requestId,
    );
    await controller.stop(chat);
    final scopedCalls = host.calls.where((c) => c.$2 != 'subagent.roster');
    expect(scopedCalls.every((c) => c.$3['profile'] == c.$1), isTrue);
    // Host presence discovery names each target explicitly on one existing
    // socket. All session/profile commands above retain their captured scope.
    final rosters = host.calls.where((c) => c.$2 == 'subagent.roster');
    expect(rosters.map((c) => c.$3['profile']).toSet(), {'a', 'b'});
    expect(rosters.every((c) => c.$1 == 'a'), isTrue);
    final profileReads = host.reads.where((r) => r.$1 != 'logs');
    expect(profileReads, isNotEmpty);
    expect(profileReads.every((r) => r.$2['profile'] == 'a'), isTrue);
    expect(host.reads.where((r) => r.$1 == 'logs'), isEmpty);
    final replay = host.calls.where(
      (call) => call.$2 == 'session.events.since',
    );
    expect(replay, isNotEmpty);
    for (final (_, _, params) in replay) {
      expect(params['replay_epoch'], 'fixture-epoch');
      expect(params['last_sequence'], 0);
      expect(params.containsKey('last_seen'), isFalse);
    }
    expect(
      host.calls.map((c) => c.$2),
      containsAll([
        'projects.create',
        'session.create',
        'prompt.submit',
        'approval.respond',
        'session.interrupt',
      ]),
    );
  });

  test(
    'steer preserves ownership and reports accepted or rejected status',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('hello');
      await controller.send(chat);
      expect(await controller.steer(chat, 'focus on the error'), isTrue);
      expect(host.calls.last.$2, 'session.steer');
      expect(host.calls.last.$3, {
        'session_id': 'a-runtime',
        'text': 'focus on the error',
        'execution_generation': 0,
        'profile': 'a',
      });

      host.steerResult = {'status': 'rejected'};
      expect(await controller.steer(chat, 'keep this draft'), isFalse);
      expect(chat.runtime.runtimeId, 'a-runtime');
    },
  );

  test(
    'steering seals earlier assistant text before the steering marker',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Investigate');
      await controller.send(chat);
      host.event('a', 'tool.start', {
        'tool_id': 'active-tool',
        'name': 'terminal',
      });
      host.event('a', 'message.delta', {'text': 'Before steering'});
      expect(await controller.steer(chat, 'Focus on the failing test'), isTrue);
      host.event('a', 'message.delta', {'text': 'After steering'});
      final content = chat.reading.messages
          .map((row) => row['content'])
          .toList();
      expect(content.skip(content.length - 3), [
        'Investigate',
        'Before steering',
        'Focus on the failing test',
      ]);
      expect(chat.reading.streaming, 'After steering');
      expect(chat.runtime.toolActivities.map((tool) => tool.toolId), [
        'active-tool',
      ]);
      expect(chat.runtime.toolActivities.single.isTerminal, isFalse);
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test('steer rejects slash text and a chat without a running turn', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    expect(await controller.steer(chat, '/status'), isFalse);
    expect(await controller.steer(chat, 'later'), isFalse);
    expect(host.calls.where((call) => call.$2 == 'session.steer'), isEmpty);
  });

  test('approval accepts each server-supported scope', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('hello');
    await controller.send(chat);

    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'session',
      'choices': ['session', 'deny'],
    });
    await controller.approve(
      chat,
      'session',
      requestId: chat.runtime.approval!.requestId,
    );
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'always',
      'choices': ['always', 'deny'],
    });
    await controller.approve(
      chat,
      'always',
      requestId: chat.runtime.approval!.requestId,
    );

    expect(
      host.calls
          .where((call) => call.$2 == 'approval.respond')
          .map((call) => call.$3['choice']),
      ['session', 'always'],
    );
  });

  test('approval sends request ID and keeps a replacement request', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'old-request',
      'choices': ['once', 'deny'],
      'command': 'old command',
    });
    host.approvalDelay = Completer<void>();
    final response = controller.approve(
      chat,
      'once',
      requestId: chat.runtime.approval!.requestId,
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.approvalResponding, isTrue);
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'new-request',
      'choices': ['session', 'deny'],
      'command': 'new command',
    });
    host.approvalDelay!.complete();
    await response;
    expect(chat.runtime.approval?.requestId, 'new-request');
    expect(chat.runtime.approvalResponding, isFalse);
    expect(
      host.calls.lastWhere((c) => c.$2 == 'approval.respond').$3['prompt_id'],
      'old-request',
    );
  });

  test('failed approval retains the request for retry', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'failed-request',
      'choices': ['always', 'deny'],
    });
    host.approvalFails = true;
    await expectLater(
      controller.approve(
        chat,
        'always',
        requestId: chat.runtime.approval!.requestId,
      ),
      throwsException,
    );
    expect(chat.runtime.approval?.requestId, 'failed-request');
    expect(chat.runtime.approvalResponding, isFalse);
  });

  test('approval rejects a scope the server did not offer', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'once-only',
      'choices': ['once', 'deny'],
    });
    await expectLater(
      controller.approve(
        chat,
        'always',
        requestId: chat.runtime.approval!.requestId,
      ),
      throwsArgumentError,
    );
    expect(host.calls.where((call) => call.$2 == 'approval.respond'), isEmpty);
  });

  test(
    'completion refresh keeps the entered project bound to refreshed rows',
    () async {
      await controller.selectProject(controller.current!.projects.single);
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('Project work');
      await controller.send(chat);
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.execution, ChatExecution.completed);
      expect(
        controller.current!.selectedProject,
        same(controller.current!.projects.single),
      );
      await controller.selectProject(controller.current!.selectedProject);
      expect(controller.current!.projectSessionsError, isNull);
    },
  );

  test(
    'unsolicited message starts settle as separate turns without clearing composer state',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final attachment = AttachmentDraft(
        id: 'kept-attachment',
        cachedPath: '/tmp/kept.txt',
        name: 'kept.txt',
        byteLength: 4,
        mediaType: 'text/plain',
        kind: AttachmentDraftKind.genericFile,
      );
      chat.reading.installSavedHistory([
        {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
      ]);
      emitChatEvent(controller, chat, 'session.info', {
        'model': 'known-model',
        'provider': 'known-provider',
        'reasoning_effort': 'high',
      });
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: 'Keep this draft',
        appendAttachments: [attachment],
        appendQueued: [QueuedPromptDraft(text: 'Keep this queued prompt')],
        paused: true,
      );

      host.event('a', 'message.start', {'turn_id': 'unsolicited-first'});
      expect(chat.runtime.execution, ChatExecution.running);
      expect(chat.composer.observation.text, 'Keep this draft');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        attachment.id,
      ]);
      expect(
        chat.composer.observation.queue.single.text,
        'Keep this queued prompt',
      );
      expect(chat.model, 'known-model');
      expect(chat.provider, 'known-provider');
      expect(chat.reasoningEffort, 'high');
      expect(chat.reading.messages.single['content'], 'Keep this turn');

      host.event('a', 'message.delta', {'text': 'First'});
      host.event('a', 'message.start', {'turn_id': 'unsolicited-first'});
      expect(chat.reading.streaming, 'First');
      host.event('a', 'message.delta', {'text': ' loop reply'});
      host.historyMessages = [
        {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
        {'id': 2, 'role': 'assistant', 'content': 'First loop reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.execution, ChatExecution.completed);
      expect(chat.reading.streaming, isEmpty);

      host.event('a', 'message.start', {'turn_id': 'unsolicited-second'});
      expect(chat.runtime.execution, ChatExecution.running);
      host.event('a', 'message.delta', {'text': 'Second loop reply'});
      host.historyMessages = [
        {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
        {'id': 2, 'role': 'assistant', 'content': 'First loop reply'},
        {'id': 3, 'role': 'assistant', 'content': 'Second loop reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);

      expect(chat.runtime.execution, ChatExecution.completed);
      expect(chat.reading.streaming, isEmpty);
      expect(chat.reading.historyError, isNull);
      expect(
        chat.reading.messages
            .where((message) => message['role'] == 'assistant')
            .map((message) => message['content']),
        ['First loop reply', 'Second loop reply'],
      );
      expect(chat.composer.observation.text, 'Keep this draft');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        attachment.id,
      ]);
      expect(
        chat.composer.observation.queue.single.text,
        'Keep this queued prompt',
      );
      expect(chat.composer.observation.paused, isTrue);
    },
  );

  for (final configuration in [
    (photos: true, brightness: Brightness.light, width: 390.0, scale: 1.0),
    (photos: true, brightness: Brightness.dark, width: 390.0, scale: 1.0),
    (photos: true, brightness: Brightness.light, width: 320.0, scale: 2.0),
    (photos: true, brightness: Brightness.dark, width: 320.0, scale: 2.0),
    (photos: false, brightness: Brightness.light, width: 390.0, scale: 1.0),
  ]) {
    final photos = configuration.photos;
    final reviewName =
        '${configuration.brightness.name}-${configuration.width.toInt()}-${configuration.scale.toInt()}';
    testWidgets(
      '${photos ? 'Photos' : 'Files'} selects and sends multiple attachments $reviewName',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(configuration.width, 850);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final sandbox = Directory.systemTemp.createTempSync(
          'wing-multi-picker-',
        );
        final suffix = photos ? 'png' : 'txt';
        final sample = image.Image(width: 600, height: 900);
        image.fill(sample, color: image.ColorRgb8(227, 239, 241));
        image.fillRect(
          sample,
          x1: 50,
          y1: 60,
          x2: 550,
          y2: 320,
          color: image.ColorRgb8(39, 127, 137),
        );
        image.fillRect(
          sample,
          x1: 50,
          y1: 360,
          x2: 550,
          y2: 610,
          color: image.ColorRgb8(243, 188, 96),
        );
        image.fillRect(
          sample,
          x1: 50,
          y1: 650,
          x2: 550,
          y2: 840,
          color: image.ColorRgb8(83, 118, 161),
        );
        final selected = [
          for (var index = 1; index <= 2; index++)
            File('${sandbox.path}/item-$index.$suffix')..writeAsBytesSync(
              photos ? image.encodePng(sample) : [65, 66, 67],
            ),
        ];
        final originalPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = PhotoPickerFixture([
          for (final file in selected)
            PhotoFileFixture(file.uri, name: file.uri.pathSegments.last),
        ], type: photos ? FileType.image : FileType.any);
        addTearDown(() {
          FilePickerPlatform.instance = originalPicker;
          sandbox.deleteSync(recursive: true);
        });
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'Read both');
        await tester.pumpWidget(
          RepaintBoundary(
            key: _attachmentFrame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(configuration.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(configuration.scale)),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(photos ? 'Photos' : 'Files'));
        await tester.pump();
        for (var attempt = 0; attempt < 400; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (!chat.composer.observation.preparing) break;
        }
        expect(chat.composer.observation.preparing, isFalse);
        expect(chat.composer.observation.attachments.map((file) => file.name), [
          'item-1.$suffix',
          'item-2.$suffix',
        ]);
        expect(chat.composer.observation.text, 'Read both');
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        final saved = await tester.runAsync(
          () => readComposerFixture(
            chat: chat,
            preferences: controller.preferences,
          ),
        );
        expect(saved!.attachments, hasLength(2));
        if (photos) {
          await _captureAttachmentFrame(tester, 'composer-$reviewName');
          final decodedBeforePreview = binding.delayedDecodeCount;
          final decoding = Completer<void>();
          binding.imageDecodeDelay = decoding.future;
          addTearDown(() {
            binding.imageDecodeDelay = null;
            if (!decoding.isCompleted) decoding.complete();
          });
          await tester.tap(find.byTooltip('Preview item-1.png'));
          for (var attempt = 0; attempt < 200; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
            if (find.byType(ChatImagePreview).evaluate().isNotEmpty) break;
          }
          expect(find.byType(ChatImagePreview), findsOneWidget);
          expect(decoding.isCompleted, isFalse);
          decoding.complete();
          await _waitForAttachmentImages(tester);
          expect(binding.delayedDecodeCount, greaterThan(decodedBeforePreview));
          expect(find.byType(ChatImagePreview), findsOneWidget);
          final preview = tester.widget<ChatImagePreview>(
            find.byType(ChatImagePreview),
          );
          final decoded = image.decodeImage(preview.bytes!)!;
          expect((decoded.width, decoded.height), (600, 900));
          expect(find.byType(InteractiveViewer), findsOneWidget);
          expect(
            tester.getSize(find.byType(ChatImagePreview)).width,
            configuration.width,
          );
          await _captureAttachmentFrame(tester, 'preview-$reviewName');
          final viewer = find.byType(InteractiveViewer);
          final viewerSize = tester.getSize(viewer);
          expect(viewerSize.width, greaterThan(80));
          expect(viewerSize.height, greaterThan(0));
          final center = tester.getCenter(viewer);
          final left = await tester.createGesture(pointer: 1);
          final right = await tester.createGesture(pointer: 2);
          await left.down(center - const Offset(40, 0));
          await right.down(center + const Offset(40, 0));
          await tester.pump();
          await left.moveTo(center - const Offset(90, 0));
          await right.moveTo(center + const Offset(90, 0));
          await tester.pump();
          expect(
            tester
                .widget<Transform>(
                  find.descendant(of: viewer, matching: find.byType(Transform)),
                )
                .transform
                .getMaxScaleOnAxis(),
            greaterThan(1),
          );
          await left.up();
          await right.up();
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(chat.composer.observation.attachments, hasLength(2));
          expect(chat.composer.observation.text, 'Read both');
        }
        await tester.tap(find.byTooltip('Send'));
        await _waitForSubmission(tester, host);
        expect(
          host.calls.where(
            (call) =>
                call.$2 == (photos ? 'image.attach_bytes' : 'file.attach'),
          ),
          hasLength(2),
        );
        expect(
          host.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
        expect(chat.composer.observation.attachments, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('photo rejection shows its reason instead of a workspace error', (
    tester,
  ) async {
    final sandbox = Directory.systemTemp.createTempSync('wing-photo-error-');
    final source = File('${sandbox.path}/photo.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final originalPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = PhotoPickerFixture([
      PhotoFileFixture(source.uri),
    ]);
    addTearDown(() {
      FilePickerPlatform.instance = originalPicker;
      sandbox.deleteSync(recursive: true);
    });
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Keep my text');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Attach file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photos'));
    await tester.pump();
    // Drain real worker I/O and fake widget microtasks with a bounded wait.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (!chat.composer.observation.preparing) break;
    }
    expect(chat.composer.observation.preparing, isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn’t open this workspace'), findsNothing);
    expect(
      find.text('Unsupported image format. Choose a JPEG, PNG, or WebP image.'),
      findsOneWidget,
    );
    expect(chat.composer.observation.text, 'Keep my text');
    expect(chat.composer.observation.attachments, isEmpty);
    expect(
      host.calls.where((call) => call.$2 == 'image.attach_bytes'),
      isEmpty,
    );
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('send is available while completed history is still loading', (
    tester,
  ) async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Next question');
    host.event('a', 'message.start');
    final history = host.delays['a'] = Completer<void>();
    host.event('a', 'message.complete', {'text': 'First answer'});
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    try {
      final send = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(ComposerActionButton),
          matching: find.byType(IconButton),
        ),
      );
      expect(send.onPressed, isNotNull);
      await tester.tap(find.byTooltip('Send'));
      await _waitForSubmission(tester, host);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.runtime.execution, ChatExecution.running);
    } finally {
      history.complete();
      await tester.pump();
    }
    // The older history response must not remove the new prompt or finish it.
    expect(chat.runtime.execution, ChatExecution.running);
    expect(chat.reading.messages.last['content'], 'Next question');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('an older idle snapshot cannot finish a new submission', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.running = false;
    host.notificationActiveSessions = [
      {
        'id': chat.runtime.runtimeId,
        'session_key': chat.key.sessionId,
        'status': 'idle',
      },
    ];
    host.activeListDelay = Completer<void>();
    host.event('a', 'sessions.changed');
    await Future<void>.delayed(Duration.zero);
    await controller.updateDraft(chat, 'New turn');
    await controller.send(chat);
    host.activeListDelay!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.execution, ChatExecution.running);
    expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
  });

  test(
    'completion before acknowledgement cannot submit the next draft twice',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'First question');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      host.event('a', 'message.complete', {'text': 'First answer'});
      await controller.updateDraft(chat, 'Next question');
      try {
        await controller.send(chat);
        expect(
          host.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
        expect(chat.composer.observation.text, isEmpty);
        expect(chat.composer.observation.queue.map((prompt) => prompt.text), [
          'First question',
          'Next question',
        ]);
        expect(
          chat.composer.observation.queue.map(
            (prompt) => prompt.submissionUncertain,
          ),
          [true, false],
        );
        final saved = (await controller.savedDraft(chat.key))!;
        expect(saved.text, isEmpty);
        expect(saved.queuedPrompts.map((prompt) => prompt.text), [
          'First question',
          'Next question',
        ]);
        // Another tap on the empty composer adds nothing.
        await controller.send(chat);
        expect(chat.composer.observation.queue, hasLength(2));
      } finally {
        host.promptSubmitStarted = null;
        host.promptSubmitDelay!.complete();
        await sending;
      }
      await Future<void>.delayed(Duration.zero);
      expect(chat.composer.observation.queue, isEmpty);
      expect(
        host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .map((call) => call.$3['text']),
        ['First question', 'Next question'],
      );
    },
  );

  test(
    'queued follow-up waits for acknowledgement after early completion',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'First question');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      await controller.updateDraft(chat, 'Queued question');
      await controller.send(chat);
      host.event('a', 'message.complete', {'text': 'First answer'});
      await Future<void>.delayed(Duration.zero);
      try {
        expect(chat.composer.observation.paused, isFalse);
        expect(chat.composer.observation.queue.map((prompt) => prompt.text), [
          'First question',
          'Queued question',
        ]);
        expect(
          chat.composer.observation.queue.map(
            (prompt) => prompt.submissionUncertain,
          ),
          [true, false],
        );
        expect(
          host.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
      } finally {
        host.promptSubmitStarted = null;
        host.promptSubmitDelay!.complete();
        await sending;
      }
      await Future<void>.delayed(Duration.zero);
      expect(chat.composer.observation.paused, isFalse);
      expect(chat.composer.observation.queue, isEmpty);
      expect(
        host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .map((call) => call.$3['text']),
        ['First question', 'Queued question'],
      );
    },
  );

  test(
    'unsolicited message start survives an older completed history refresh',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      host.delays['a'] = Completer<void>();
      host.historyMessages = [
        {'id': 1, 'role': 'assistant', 'content': 'First reply'},
      ];

      host.event('a', 'message.start');
      host.event('a', 'message.delta', {'text': 'First reply'});
      host.event('a', 'message.complete');
      expect(chat.runtime.execution, ChatExecution.completed);

      host.event('a', 'message.start');
      host.event('a', 'reasoning.delta', {'text': 'Second reasoning'});
      host.event('a', 'message.delta', {'text': 'Second reply'});
      expect(chat.runtime.execution, ChatExecution.running);
      expect(chat.reading.streaming, 'Second reply');
      expect(
        chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
        'Second reasoning',
      );

      host.delays['a']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.execution, ChatExecution.running);
      expect(chat.reading.streaming, 'Second reply');
      expect(
        chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
        'Second reasoning',
      );

      host.historyMessages = [
        {'id': 1, 'role': 'assistant', 'content': 'First reply'},
        {'id': 2, 'role': 'assistant', 'content': 'Second reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.execution, ChatExecution.completed);
      expect(chat.reading.streaming, isEmpty);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.map((message) => message['content']), [
        'First reply',
        'Second reply',
      ]);
    },
  );

  test('A continues while B is visible; duplicate IDs stay separate', () async {
    final a = await controller.createChat(canDispatch: () => true);
    a.composer.editText('A work');
    await controller.send(a);
    controller.setRouteVisibility(controller, true);
    await controller.switchProfile('b');
    final b = await controller.createChat(canDispatch: () => true);
    b.composer.editText('B draft');
    host.event('a', 'message.delta', {'text': 'A result'});
    expect(a.reading.streaming, 'A result');
    expect(b.reading.streaming, isEmpty);
    expect(a.key, isNot(b.key));
    expect(host.closed, isEmpty);
    expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
    host.event('a', 'message.complete');
    await Future<void>.delayed(Duration.zero);
    expect(a.runtime.execution, ChatExecution.completed);
    expect(controller.current!.chat, same(b));
    expect(b.composer.observation.text, 'B draft');
    expect(notifications, [a.key]);
    await controller.openSession(a.key);
    expect(controller.current!.scope.profileName, 'a');
    expect(
      controller.current!.chat!.reading.messages.single['content'],
      'a completed',
    );
  });

  test('forwards the server push identity with live attention', () async {
    final eventIds = <String?>[];
    final connection = controller.connection;
    controller.dispose();
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (notification) async => eventIds.add(notification.eventId),
    );
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('work');
    await controller.send(chat);
    host.event('a', 'message.complete', {'mobile_push_event_id': 'delivery-1'});
    await Future<void>.delayed(Duration.zero);
    expect(eventIds, ['delivery-1']);
  });

  test('rapid A B A ignores a late B load and persists A', () async {
    host.delays['b'] = Completer<void>();
    final b = controller.switchProfile('b');
    await Future<void>.delayed(Duration.zero);
    expect(await controller.switchProfile('a'), isTrue);
    host.delays['b']!.complete();
    expect(await b, isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(
      ProfileSelectionCodec.canonicalName(
        preferences.get(ProfileSelectionCodec.storageKey('original-settings')),
      ),
      'a',
    );
  });

  test(
    'project entry uses authoritative scoped membership and owns drafts',
    () async {
      final project = controller.current!.projects.single;
      await controller.selectProject(project);
      expect(controller.current!.visibleSessions.single['id'], 'project-chat');
      expect(host.calls.last.$3, {
        'project_id': 'same',
        'session_limit': 5000,
        'profile': 'a',
      });
      final draft = await controller.createChat(canDispatch: () => true);
      expect(draft.projectId, project['id']);
      expect(
        host.calls.lastWhere((call) => call.$2 == 'session.create').$3['cwd'],
        '/a',
      );
      await controller.selectProject(null);
      expect(controller.current!.visibleSessions.single['id'], 'same');
    },
  );

  test('late project load cannot undo leaving the project', () async {
    host.projectDelay = Completer<void>();
    final loading = controller.selectProject(
      controller.current!.projects.single,
    );
    await Future<void>.delayed(Duration.zero);
    await controller.selectProject(null);
    host.projectDelay!.complete();
    await loading;
    expect(controller.current!.selectedProject, isNull);
    expect(controller.current!.projectSessions, isEmpty);
    expect(controller.current!.projectSessionsLoading, isFalse);
  });

  test('project response with another profile fails closed', () async {
    host.wrongProjectOwner = true;
    await controller.selectProject(controller.current!.projects.single);
    expect(controller.current!.visibleSessions, isEmpty);
    expect(controller.current!.projectSessionsError, contains('owner'));
  });

  test('stock error completion is not reported as success', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('test');
    await controller.send(chat);
    host.event('a', 'message.complete', {
      'status': 'error',
      'text': 'Provider unavailable',
      'error': 'Provider unavailable',
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.execution, ChatExecution.failed);
    expect(chat.runtime.error, contains('Provider unavailable'));
  });

  for (final terminal in ['completed', 'error', 'interrupted', 'turn.error']) {
    test(
      'empty $terminal retires the reply before a restamped delta',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        host.event('a', 'message.start', {'turn_id': 'empty-terminal'});
        host.event(
          'a',
          terminal == 'turn.error' ? terminal : 'message.complete',
          {'status': terminal, 'text': '', 'message': 'Stopped'},
        );
        await Future<void>.delayed(Duration.zero);
        host.event('a', 'message.delta', {
          'turn_id': 'empty-terminal',
          'segment': 0,
          'offset': 0,
          'text': 'late reply',
        });
        expect(chat.reading.streaming, isEmpty);
        expect(
          chat.reading.messages.any((row) => row['content'] == 'late reply'),
          isFalse,
        );
      },
    );
  }

  test('final text survives a failed history refresh', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('test');
    await controller.send(chat);
    host.failures.add('a');
    host.event('a', 'message.complete', {
      'status': 'completed',
      'text': 'The final response',
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.reading.messages.last['content'], 'The final response');
    expect(chat.runtime.execution, ChatExecution.completed);
    expect(chat.runtime.error, contains('History refresh failed'));
  });

  test('failed switch retains committed profile and data', () async {
    host.failures.add('b');
    expect(await controller.switchProfile('b'), isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(controller.error, contains('Couldn’t open this workspace'));
  });

  test('deleted profile blocks write, never retries unscoped', () async {
    await controller.switchProfile('b');
    host.profiles = ['a'];
    final before = host.calls.length;
    await expectLater(
      controller.createChat(canDispatch: () => true),
      throwsStateError,
    );
    expect(host.calls.length, before);
    expect(controller.current!.scope.profileName, 'b');
  });

  test(
    'notification target for missing profile does not open default',
    () async {
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'host',
            profileName: 'missing',
            connectionIdentity: 'original-settings',
          ),
          'same',
        ),
      );
      expect(controller.current!.scope.profileName, 'a');
      expect(controller.current!.chat, isNull);
      expect(controller.error, contains('no longer available'));
    },
  );

  test(
    'cross-profile project object is rejected even with identical ID',
    () async {
      final aProject = controller.current!.projects.single;
      await controller.switchProfile('b');
      expect(() => controller.selectProject(aProject), throwsArgumentError);
    },
  );

  test(
    'fresh reading survives a refused runtime attachment and retries',
    () async {
      host.running = false;
      host.resumeError = JsonRpcError(
        'session.resume',
        'runtime_coordination_required',
        code: 4001,
        reason: 'runtime_coordination_required',
      );
      final key = ProfileSessionKey(controller.current!.scope, 'same');
      ProfileChat? revealed;
      final chat = await controller.openSessionForReading(
        key,
        isCurrentRequest: () => true,
        onReadingAvailable: (chat) => revealed = chat,
      );
      expect(chat, same(revealed));
      expect(chat, isNotNull);
      expect(chat!.reading.messages, isNotEmpty);
      expect(chat.runtime.offline, isTrue);
      expect(chat.runtime.openingError, contains('Sending is unavailable'));
      expect(host.gateways['a']!.canonical.session('same'), isNull);
      await controller.updateDraft(chat, 'Keep this draft');
      expect((await controller.savedDraft(key))!.text, 'Keep this draft');
      await controller.send(chat);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      // A later network failure does not revoke the known attachment refusal.
      host.resumeError = TimeoutException('Unavailable');
      await controller.retryConversation(chat);
      expect(chat.attachmentBlocked, isTrue);
      await controller.send(chat);
      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.text, 'Keep this draft');
      host.resumeError = null;
      await controller.retryConversation(chat);
      expect(chat.attachmentBlocked, isFalse);
      expect(controller.current!.chat, same(chat));
      expect(chat.runtime.offline, isFalse);
      expect(chat.runtime.openingError, isNull);
      expect(chat.composer.observation.text, 'Keep this draft');
      expect(
        host.gateways['a']!.canonical.session(chat.runtime.runtimeId),
        isNotNull,
      );
    },
  );

  test(
    'fresh reading is available before runtime attachment completes',
    () async {
      host.running = false;
      final resume = host.resumeDelay = Completer<void>();
      final visible = Completer<ProfileChat>();
      final opening = controller.openSessionForReading(
        ProfileSessionKey(controller.current!.scope, 'same'),
        isCurrentRequest: () => true,
        onReadingAvailable: visible.complete,
      );
      final chat = await visible.future.timeout(const Duration(seconds: 2));
      expect(chat.reading.messages, isNotEmpty);
      expect(chat.runtime.offline, isTrue);
      expect(chat.refreshingConversation, isTrue);
      resume.complete();
      expect(await opening, same(chat));
      expect(chat.runtime.offline, isFalse);
      expect(chat.refreshingConversation, isFalse);
    },
  );

  test(
    'notification reads history despite refused runtime attachment',
    () async {
      host.resumeError = JsonRpcError(
        'session.resume',
        'runtime_coordination_required',
        code: 4001,
        reason: 'runtime_coordination_required',
      );
      await controller.openNotification(
        ProfileSessionKey(controller.current!.scope, 'same'),
      );
      final chat = controller.notificationChat!;
      expect(chat.reading.messages, isNotEmpty);
      expect(chat.runtime.offline, isTrue);
      expect(chat.runtime.openingError, contains('Sending is unavailable'));
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test('leaving fresh reading cannot manufacture runtime authority', () async {
    var current = true;
    ProfileChat? revealed;
    final opened = await controller.openSessionForReading(
      ProfileSessionKey(controller.current!.scope, 'same'),
      isCurrentRequest: () => current,
      onReadingAvailable: (chat) {
        revealed = chat;
        current = false;
      },
    );
    expect(opened, isNull);
    expect(revealed!.reading.messages, isNotEmpty);
    expect(revealed!.runtime.offline, isTrue);
    expect(revealed!.refreshingConversation, isFalse);
    expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
  });

  test('reconnect uses original durable owner without resubmitting', () async {
    final a = await controller.createChat(canDispatch: () => true);
    a.composer.editText('once');
    await controller.send(a);
    await controller.switchProfile('b');
    await controller.reconnect(a.key.workspace);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit').length, 1);
    final resume = host.calls.lastWhere((c) => c.$2 == 'session.resume');
    expect(resume.$3, {
      'session_id': 'same',
      'profile': 'a',
      'display_projection': true,
    });
    expect(a.runtime.execution, ChatExecution.running);
  });

  test(
    'reconnect restores stock inflight assistant text and failure',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('once');
      await controller.send(chat);
      host.inflight = {'assistant': 'Partial response', 'streaming': true};
      await controller.reconnect(chat.key.workspace);
      expect(chat.reading.streaming, 'Partial response');
      host.running = false;
      host.inflight = {
        'assistant': 'Partial response',
        'status': 'error',
        'error': 'Provider stopped',
      };
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.execution, ChatExecution.failed);
      expect(chat.runtime.error, 'Provider stopped');
      expect(host.calls.where((c) => c.$2 == 'prompt.submit').length, 1);
    },
  );

  test(
    'partial response survives resume until server history is available',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      chat.reading.updateStreaming('An answer in progress');
      host.running = false;
      host.failures.add('a');
      await controller.reconnect(chat.key.workspace);
      expect(chat.reading.streaming, 'An answer in progress');
      host.failures.clear();
      await controller.reconnect(chat.key.workspace);
      expect(chat.reading.streaming, isEmpty);
      expect(chat.reading.messages.single['content'], 'a completed');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets('startup timeout then DNS failure recovers without user action', (
    tester,
  ) async {
    controller.dispose();
    controller = ProfileWorkspaceController(
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
      connectionIdentity: 'original-settings',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    host.discoveryFailure = TimeoutException(
      'Future not completed',
      const Duration(seconds: 20),
    );
    await controller.initialize();
    expect(controller.error, isNull);
    host.discoveryFailure = const SocketException('Failed host lookup');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.error, isNull);
    host.discoveryFailure = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(controller.current?.scope.profileName, 'a');
    expect(controller.error, isNull);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets(
    'startup recovery continues at a capped delay until the server returns',
    (tester) async {
      final access = controller.access;
      controller.dispose();
      controller = ProfileWorkspaceController(
        access: access,
        connectionIdentity: 'original-settings',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      host.discoveryFailure = const SocketException('Network asleep');
      await controller.initialize();
      expect(
        controller.connectionStatus.phase,
        isNot(ServerConnectionPhase.disconnected),
      );
      for (final seconds in [1, 2, 4, 8, 16, 30, 30]) {
        await tester.pump(Duration(seconds: seconds));
        expect(
          controller.connectionStatus.phase,
          ServerConnectionPhase.reconnecting,
        );
      }
      host.discoveryFailure = null;
      await tester.pump(const Duration(seconds: 30));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(controller.initialized, isTrue);
      expect(
        controller.connectionStatus.phase,
        isNot(ServerConnectionPhase.disconnected),
      );
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets('refresh keeps loaded chats visible while the network stalls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a chat'), findsOneWidget);
    late Future<void> refresh;
    await tester.runAsync(() async {
      host.delays['a'] = Completer<void>();
      refresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('a chat'), findsOneWidget);
    await tester.runAsync(() async {
      host.delays['a']!.complete();
      await refresh;
    });
    await tester.pump();
  });

  testWidgets('idle chat recovers after a transient reconnect failure', (
    tester,
  ) async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.running = false;
    host.connectFailures = 1;
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.error, isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(1));
    expect(controller.error, isNull);
    expect(chat.runtime.execution, ChatExecution.idle);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  for (final missingFact in ['access', 'live observation']) {
    test('automatic queue drain requires confirmed $missingFact', () async {
      // History can finish while optional timing reads remain in flight. Hold
      // their HTTP success so it cannot supply fresh access evidence after we
      // deliberately remove one of the queue's required connection facts.
      final timingLog = Completer<void>();
      host.heldTimingLog = timingLog;
      addTearDown(() {
        if (!timingLog.isCompleted) timingLog.complete();
      });
      final chat = await controller.createChat(canDispatch: () => true);
      final profile = chat.key.workspace.profileName;
      expect(
        controller.connectionStatus.access,
        ConnectionAvailability.available,
      );
      expect(controller.connectionStatus.liveAvailable(profile), isTrue);
      if (missingFact == 'access') {
        controller.connectionStatus.access = ConnectionAvailability.unchecked;
      } else {
        controller.connectionStatus.forgetLive(profile);
      }

      await controller.queuePrompt(chat, 'Keep until connected');

      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(
        chat.composer.observation.queue.single.text,
        'Keep until connected',
      );
      expect(
        chat.composer.observation.queue.single.submissionUncertain,
        isFalse,
      );
      expect(chat.composer.observation.paused, isFalse);
      expect(
        (await controller.savedDraft(chat.key))!.queuedPrompts.single.text,
        'Keep until connected',
      );

      timingLog.complete();
      controller.connectionStatus.accessAvailable();
      controller.connectionStatus.liveChanged(profile, true);
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.single.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Keep until connected');
      await controller.saveQueuedPromptEdit(chat);

      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.composer.observation.queue, isEmpty);
    });
  }

  test(
    'missing session reconnect durably pauses retained queued work',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      await chat.composer.pause();
      await controller.queuePrompt(chat, 'Keep missing session work');
      expect(chat.composer.observation.paused, isTrue);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      host.expireUnsubmittedResume = true;

      await controller.reconnect(chat.key.workspace);

      expect(
        host.calls.where((call) => call.$2 == 'session.resume'),
        hasLength(1),
      );
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(chat.runtime.execution, ChatExecution.failed);
      expect(chat.composer.observation.paused, isTrue);
      expect(
        chat.composer.observation.queue.single.text,
        'Keep missing session work',
      );
      final saved = (await controller.savedDraft(chat.key))!;
      expect(saved.queuePaused, isTrue);
      expect(saved.queuedPrompts.single.text, 'Keep missing session work');
    },
  );

  testWidgets(
    'successful automatic recovery clears controller reconnect error',
    (tester) async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('once');
      await tester.runAsync(() => controller.send(chat));
      host.connectFailures = 1;
      host.gateways['a']!.onConnectionChanged!(false);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(chat.runtime.execution, ChatExecution.running);
      expect(controller.error, isNull);
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
    },
  );

  testWidgets('idle chat retries a transient session resume failure', (
    tester,
  ) async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.running = false;
    host.resumeFailures = 1;
    await controller.reconnect(chat.key.workspace);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(2));
    expect(controller.error, isNull);
    expect(controller.current!.reconnectScheduled, isFalse);
  });

  testWidgets('app focus restarts recovery during capped backoff', (
    tester,
  ) async {
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Keep this draft');
    host.running = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    // Settle the startup Recents read before exercising recovery backoff.
    await tester.pumpAndSettle();
    host.connectFailures = 5;
    final before = host.connectsByProfile['a']!;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
      expect(controller.error, isNull);
      expect(find.byType(MaterialBanner), findsNothing);
    }
    expect(host.connectsByProfile['a']! - before, 5);
    expect(controller.connectionStatus.liveAvailable('a'), isFalse);
    expect(chat.composer.observation.text, 'Keep this draft');
    await controller.send(chat);
    expect(chat.composer.observation.text, isEmpty);
    expect(chat.composer.observation.queue.single.text, 'Keep this draft');
    expect(chat.composer.observation.queue.single.submissionUncertain, isFalse);
    final saved = (await controller.savedDraft(chat.key))!;
    expect(saved.text, isEmpty);
    expect(saved.queuedPrompts.single.text, 'Keep this draft');
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    // Returning to Wing bypasses the pending 30-second retry.
    await tester.pump(const Duration(seconds: 29));
    expect(host.connectsByProfile['a']! - before, 5);
    host.rosterFailure = JsonRpcError(
      'subagent.roster',
      'Connection unavailable',
      reason: 'connection_closed',
    );
    for (var poll = 0; poll < 3; poll++) {
      await controller.reconcileNotificationRequests({});
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(host.connectsByProfile['a']! - before, 5);
      expect(controller.connectionStatus.liveAvailable('a'), isFalse);
    }
    host.rosterFailure = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 20 &&
          (chat.composer.observation.sending ||
              chat.composer.observation.queue.isNotEmpty);
      attempt++
    ) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(controller.recovering, isFalse);
    expect(chat.composer.observation.sending, isFalse);
    expect(chat.composer.observation.queue, isEmpty);
    expect(find.text('Live updates interrupted'), findsNothing);
    expect(chat.composer.observation.text, isEmpty);
    expect(chat.runtime.execution, ChatExecution.running);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
    host.event('a', 'message.complete', {'text': 'Accepted queued question'});
    await tester.pumpAndSettle();
    expect(host.connectsByProfile['a']! - before, 6);
    expect(find.byType(MaterialBanner), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('retry clears a failed unopened profile while chat works', () async {
    final owner = controller.current!;
    host.connectError = const SocketException('Connection interrupted');
    expect(await controller.switchProfile('b'), isFalse);
    host.connectError = null;
    expect(controller.current, same(owner));
    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Reconnecting');

    await controller.resumeConnection();

    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Connected');
  });

  testWidgets('failed unopened profile reconnects while current chat works', (
    tester,
  ) async {
    host.connectFailures = 1;
    expect(await controller.switchProfile('b'), isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(await controller.current!.gateway.call('tools.list'), isEmpty);
    expect(controller.connectionStatus.liveAvailable('b'), isFalse);

    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(controller.connectionStatus.description, 'Connected');
    expect(controller.current!.scope.profileName, 'a');
    expect(controller.error, isNull);
  });

  test(
    'restored chat socket clears warning during slow notification checks',
    () async {
      host.activeListDelay = Completer<void>();
      final recovery = controller.reconnect(controller.current!.scope);
      await Future<void>.delayed(Duration.zero);

      expect(await controller.current!.gateway.call('tools.list'), isEmpty);
      expect(controller.connectionStatus.liveAvailable('a'), isTrue);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );

      host.activeListDelay!.complete();
      await recovery;
    },
  );

  test('retry recovers an interrupted activity-only profile', () async {
    final owner = controller.current!;
    final background = controller.browserResource('b');
    await background.gateway.connect();
    expect(background.loaded, isFalse);
    expect(background.chats, isEmpty);
    host.resumeFailures = 1;
    await expectLater(
      background.gateway.resume('same'),
      throwsA(isA<TimeoutException>()),
    );
    expect(controller.connectionStatus.liveAvailable('b'), isFalse);
    expect(background.reconnectScheduled, isTrue);

    await controller.resumeConnection();

    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Connected');
    expect(controller.current, same(owner));
    expect(background.loaded, isFalse);
    expect(background.reconnectScheduled, isFalse);
  });

  test(
    'network loss includes a live profile whose list was never loaded',
    () async {
      final background = controller.browserResource('b');
      await background.gateway.connect();
      expect(background.loaded, isFalse);
      final before = Map.of(host.disconnectsByProfile);

      controller.networkUnavailable();

      for (final profile in ['a', 'b']) {
        expect(host.disconnectsByProfile[profile], (before[profile] ?? 0) + 1);
      }
      expect(controller.connectionStatus.liveAvailable('a'), isFalse);
      expect(controller.connectionStatus.liveAvailable('b'), isFalse);
      // Only an explicit networkRestored() lifts the device-level outage
      // flag (see ServerConnectionStatus.networkLost); a plain resume
      // attempt proving the socket works is not itself proof of the OS's
      // own network state.
      controller.networkRestored();
      await controller.resumeConnection();
      expect(controller.connectionStatus.description, 'Connected');
    },
  );

  test(
    'retry leaves browser-only profiles without sockets unchecked',
    () async {
      final background = controller.browserResource('b');
      final before = Map.of(host.connectsByProfile);

      await controller.resumeConnection();

      expect(host.connectsByProfile['a'], before['a']! + 1);
      expect(host.connectsByProfile['b'], before['b']);
      expect(background.loaded, isFalse);
      expect(controller.connectionStatus.liveAvailable('b'), isFalse);
      expect(controller.connectionStatus.description, 'Connected');
    },
  );

  testWidgets('network change bypasses chat-list recovery backoff', (
    tester,
  ) async {
    host.connectFailures = 5;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(controller.connectionStatus.liveAvailable('a'), isFalse);
    final calls = host.connectCalls;
    await tester.pump(const Duration(seconds: 29));
    expect(host.connectCalls, calls);
    await tester.runAsync(
      () => controller.resumeConnection(networkChanged: true),
    );
    await tester.pump();
    expect(controller.connectionStatus.description, 'Connected');
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('recovery caps its delay and an explicit retry bypasses it', (
    tester,
  ) async {
    host.connectFailures = 20;
    host.gateways['a']!.onConnectionChanged!(false);
    expect(
      controller.connectionStatus.phase,
      isNot(ServerConnectionPhase.disconnected),
    );
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.reconnecting,
      );
    }
    final calls = host.connectCalls;
    for (var attempt = 1; attempt <= 3; attempt++) {
      await tester.pump(const Duration(seconds: 29));
      expect(host.connectCalls, calls + attempt - 1);
      await tester.pump(const Duration(seconds: 1));
      expect(host.connectCalls, calls + attempt);
    }
    expect(controller.current!.reconnectScheduled, isTrue);
    expect(controller.recovering, isTrue);
    expect(controller.current!.reconnectAttempt, 9);
    host.connectFailures = 0;
    await tester.runAsync(controller.resumeConnection);
    await tester.pump();
    expect(controller.connectionStatus.description, 'Connected');
    expect(controller.current!.reconnectScheduled, isFalse);
    expect(
      controller.connectionStatus.phase,
      isNot(ServerConnectionPhase.disconnected),
    );
  });

  testWidgets(
    'session recovery continues when the transport is already healthy',
    (tester) async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Keep this draft');
      host.running = false;
      host.resumeFailures = 5;
      host.gateways['a']!.onConnectionChanged!(false);
      for (final seconds in [1, 2, 4, 8, 16]) {
        await tester.pump(Duration(seconds: seconds));
      }
      // An independent activity read can restore the transport without restoring
      // this conversation. That must not clear its failed recovery indicator.
      await tester.runAsync(() => controller.current!.gateway.connect());
      expect(controller.connectionStatus.liveAvailable('a'), isTrue);
      expect(controller.recovering, isTrue);
      expect(controller.current!.reconnectScheduled, isTrue);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.reconnecting,
      );
      expect(controller.connectionStatus.recoveryProblem, isNull);
      await tester.pump(const Duration(seconds: 30));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(controller.recovering, isFalse);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );
      expect(chat.composer.observation.text, 'Keep this draft');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets('disposing a workspace cancels prolonged recovery', (
    tester,
  ) async {
    final offlineHost = Host();
    final retiring = ProfileWorkspaceController(
      access: controller.access,
      connectionIdentity: 'retiring',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: offlineHost.gateway,
    );
    await retiring.initialize();
    offlineHost.connectError = const SocketException('Offline');
    offlineHost.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    final calls = offlineHost.connectCalls;
    retiring.dispose();
    await tester.pump(const Duration(minutes: 2));
    expect(offlineHost.connectCalls, calls);
  });

  testWidgets('sign-in rejection stops automatic live recovery', (
    tester,
  ) async {
    host.connectError = const DashboardHttpException(401, '/api/ws');
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.pump(const Duration(seconds: 1));
    final calls = host.connectCalls;
    await tester.pump(const Duration(minutes: 2));
    expect(host.connectCalls, calls);
    expect(controller.current!.reconnectScheduled, isFalse);
    expect(controller.current!.reconnectError, contains('Sign-in'));
    expect(controller.recovering, isFalse);
  });

  testWidgets('manual reconnect cancels a pending automatic retry', (
    tester,
  ) async {
    await controller.createChat(canDispatch: () => true);
    host.running = false;
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.runAsync(
      () => controller.reconnect(controller.current!.scope),
    );
    final before = host.connectCalls;
    await tester.pump(const Duration(minutes: 1));
    expect(host.connectCalls, before);
    expect(controller.current!.reconnectScheduled, isFalse);
  });

  test(
    'refresh resumes the selected chat and keeps unrelated errors',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.running = false;
      await controller.refresh();
      expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(1));
      expect(chat.runtime.execution, ChatExecution.idle);

      host.failures.add('b');
      await controller.switchProfile('b');
      final unrelatedError = controller.error;
      expect(unrelatedError, isNotNull);
      host.failures.remove('b');
      await controller.reconnect(chat.key.workspace);
      expect(controller.error, unrelatedError);
    },
  );

  testWidgets('background recovery stays with its profile', (tester) async {
    final a = controller.current!;
    await controller.switchProfile('b');
    host.connectFailures = 6;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(a.recovering, isTrue);
    expect(a.reconnectError, isNull);
    expect(controller.recovering, isFalse);
    expect(controller.error, isNull);
    host.connectFailures = 0;
    await tester.runAsync(() => controller.reconnect(a.scope));
    expect(a.recovering, isFalse);
    expect(controller.current!.scope.profileName, 'b');
  });

  test('background approval stays with its owning profile', () async {
    final a = await controller.createChat(canDispatch: () => true);
    a.composer.editText('test');
    await controller.send(a);
    await controller.switchProfile('b');
    host.event('a', 'approval', {'request_id': 'dummy', 'command': 'dummy'});
    expect(a.runtime.needsInput, isTrue);
    expect(notifications, [a.key]);
    await controller.approve(
      a,
      'deny',
      requestId: a.runtime.approval!.requestId,
    );
    expect(host.calls.lastWhere((c) => c.$2 == 'approval.respond').$3, {
      'session_id': 'a-runtime',
      'prompt_id': 'dummy',
      'execution_generation': 0,
      'choice': 'deny',
      'profile': 'a',
    });
  });

  test(
    'persistent targets include connection profile and durable ID only',
    () async {
      final a = await controller.createChat(canDispatch: () => true);
      a.composer.editText('secret draft');
      await controller.send(a);
      final key = preferences.getKeys().singleWhere(
        (k) => k.startsWith('profile_pending'),
      );
      final value = preferences.getStringList(key)!.single;
      expect(value, contains('"profile":"a"'));
      expect(value, contains('"session":"same"'));
      expect(value, isNot(contains('secret draft')));
    },
  );

  test('unavailable pending owner survives unrelated journal writes', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    chat.composer.editText('A turn');
    await controller.send(chat);
    final connection = controller.connection;
    controller.dispose();
    host.profiles = ['b'];
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    expect(controller.initialized, isFalse);
    expect(controller.error, contains('saved profile is unavailable'));
    expect(await controller.switchProfile('b'), isTrue);
    final b = await controller.createChat(canDispatch: () => true);
    b.composer.editText('B turn');
    await controller.send(b);
    final journalKey = preferences.getKeys().singleWhere(
      (k) => k.startsWith('profile_pending'),
    );
    final saved = preferences.getStringList(journalKey)!;
    expect(saved.any((value) => value.contains('"profile":"a"')), isTrue);
    expect(saved.any((value) => value.contains('"profile":"b"')), isTrue);
  });

  test(
    'an older failed discovery cannot overwrite a newer initialized selection',
    () async {
      final connection = controller.connection;
      controller.dispose();
      host.defaultDiscoveryDelay = Completer<void>();
      host.defaultDiscoveryStarted = Completer<void>();
      host.defaultDiscoveryFailure = StateError('Older discovery failed');
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      final older = controller.initialize();
      await host.defaultDiscoveryStarted!.future;
      expect(await controller.switchProfile('b'), isTrue);
      expect(controller.current!.scope.profileName, 'b');
      expect(controller.initialized, isTrue);
      await preferences.reload();
      expect(
        ProfileSelectionCodec.canonicalName(
          preferences.get(
            ProfileSelectionCodec.storageKey('original-settings'),
          ),
        ),
        'b',
      );
      expect(controller.error, isNull);
      expect(controller.recovering, isFalse);
      final observations = <(String?, bool)>[];
      controller.addListener(() {
        observations.add((controller.error, controller.recovering));
      });
      host.defaultDiscoveryDelay!.complete();
      await older;
      expect(controller.current!.scope.profileName, 'b');
      expect(controller.initialized, isTrue);
      expect(
        preferences.get(ProfileSelectionCodec.storageKey('original-settings')),
        'b',
      );
      expect(controller.error, isNull);
      expect(controller.recovering, isFalse);
      expect(observations, everyElement((null, false)));
    },
  );

  test(
    'unavailable selected profile retains pending owners during notification recovery before repair',
    () async {
      final first = await controller.createChat(canDispatch: () => true);
      first.composer.editText('A turn');
      await controller.send(first);
      final journalKey = preferences.getKeys().singleWhere(
        (key) => key.startsWith('profile_pending'),
      );
      final before = preferences.getStringList(journalKey)!;
      expect(before.any((value) => value.contains('"profile":"a"')), isTrue);
      final connection = controller.connection;
      controller.dispose();
      host.profiles = ['b'];
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      await controller.initialize();
      expect(controller.initialized, isFalse);
      expect(controller.error, contains('saved profile is unavailable'));
      expect(preferences.getStringList(journalKey), before);
      host.calls.clear();
      final target = ProfileSessionKey(
        WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: 'original-settings',
          profileName: 'b',
        ),
        'same',
      );
      final observed = await controller.loadNotificationApproval(target);
      expect(observed, isNotNull);
      expect(observed!.key, target);
      expect(observed.runtime.blocksTurnAdmission, isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'session.resume').single.$1,
        'b',
      );
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      final after = preferences.getStringList(journalKey)!;
      expect(after.any((value) => value.contains('"profile":"b"')), isTrue);
      expect(
        after.any((value) => value.contains('"profile":"a"')),
        isTrue,
        reason:
            'an unresolved earlier owner survives an unrelated admitted read',
      );
    },
  );

  test(
    'notification recovery before initialization retains other pending owners',
    () async {
      final first = await controller.createChat(canDispatch: () => true);
      first.composer.editText('A turn');
      await controller.send(first);
      final journalKey = preferences.getKeys().singleWhere(
        (key) => key.startsWith('profile_pending'),
      );
      final before = preferences.getStringList(journalKey)!;
      expect(before.any((value) => value.contains('"profile":"a"')), isTrue);
      final connection = controller.connection;
      controller.dispose();
      host.profiles = ['b'];
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      expect(controller.initialized, isFalse);
      expect(controller.discovery, isNull);
      host.calls.clear();
      final target = ProfileSessionKey(
        WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: 'original-settings',
          profileName: 'b',
        ),
        'same',
      );
      final observed = await controller.loadNotificationApproval(target);
      expect(observed, isNotNull);
      expect(observed!.key, target);
      expect(observed.runtime.blocksTurnAdmission, isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'session.resume').single.$1,
        'b',
      );
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      final after = preferences.getStringList(journalKey)!;
      expect(after.any((value) => value.contains('"profile":"b"')), isTrue);
      expect(after.any((value) => value.contains('"profile":"a"')), isTrue);
      expect(controller.initialized, isFalse);
      expect(controller.discovery, isNull);
    },
  );

  for (final invalid in <Object>[
    7,
    <String>['not-json'],
    <String>['{"session":"same"}'],
  ]) {
    test(
      'notification recovery refuses to overwrite unreadable pending owners: $invalid',
      () async {
        final connection = controller.connection;
        controller.dispose();
        const journalKey = 'profile_pending_v2_original-settings';
        if (invalid is int) {
          await preferences.setInt(journalKey, invalid);
        } else {
          await preferences.setStringList(journalKey, invalid as List<String>);
        }
        controller = ProfileWorkspaceController(
          connectionIdentity: 'original-settings',
          access: ConnectionAccess(
            connection: connection,
            dashboardOAuth: null,
          ),
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: host.gateway,
        );
        host.calls.clear();
        final target = ProfileSessionKey(
          WorkspaceScope(
            connectionId: connection.id,
            connectionIdentity: 'original-settings',
            profileName: 'b',
          ),
          'same',
        );
        await expectLater(
          controller.loadNotificationApproval(target),
          throwsFormatException,
        );
        expect(
          host.calls.where((call) => call.$2 == 'session.resume').single.$1,
          'b',
        );
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        expect(preferences.get(journalKey), invalid);
        expect(controller.error, contains('Saved pending chat owners'));
        expect(controller.initialized, isFalse);
      },
    );
  }

  test('settled pending owners are not seeded again by later writes', () async {
    final first = await controller.createChat(canDispatch: () => true);
    first.composer.editText('A turn');
    await controller.send(first);
    const journalKey = 'profile_pending_v2_original-settings';
    expect(
      preferences
          .getStringList(journalKey)!
          .any((value) => value.contains('"profile":"a"')),
      isTrue,
    );
    final connection = controller.connection;
    controller.dispose();
    host.running = false;
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    expect(controller.initialized, isTrue);
    expect(preferences.getStringList(journalKey), isEmpty);
    expect(await controller.switchProfile('b'), isTrue);
    final second = await controller.createChat(canDispatch: () => true);
    second.composer.editText('B turn');
    await controller.send(second);
    final saved = preferences.getStringList(journalKey)!;
    expect(saved.any((value) => value.contains('"profile":"b"')), isTrue);
    expect(saved.any((value) => value.contains('"profile":"a"')), isFalse);
  });

  test(
    'stock batched clarification routes the unanswered question ID',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'clarify', {
        'request_id': 'request',
        'questions': [
          {'qid': 'q0', 'question': 'First question'},
          {'qid': 'q1', 'question': 'What is the recovery marker?'},
        ],
        'answers': {'q0': 'already answered'},
      });
      expect(
        chat.runtime.pendingQuestion!.question,
        'What is the recovery marker?',
      );
      await controller.clarify(chat, 'PROCESS_RECOVERY_QA');
      expect(host.calls.last.$3['question_id'], 'q1');
      expect(host.calls.last.$3['request_id'], 'request');
    },
  );

  test(
    'batch answers keep remaining questions attached to their owner',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'clarify', {
        'request_id': 'batch',
        'questions': [
          {'qid': 'q0', 'question': 'First'},
          {'qid': 'q1', 'question': 'Second'},
        ],
      });
      await controller.switchProfile('b');
      host.clarifyResult = {
        'status': 'ok',
        'remaining': ['q1'],
      };
      await controller.clarify(chat, 'one');
      expect(chat.runtime.pendingQuestion!.question, 'Second');
      expect(chat.runtime.needsInput, isTrue);
      expect(host.calls.last.$1, 'a');
      expect(host.calls.last.$3['question_id'], 'q0');
      host.clarifyResult = {'status': 'ok', 'remaining': []};
      await controller.clarify(chat, 'two');
      expect(host.calls.last.$3['question_id'], 'q1');
      expect(chat.runtime.questions, isNull);
      expect(chat.runtime.execution, ChatExecution.running);
      expect(controller.current!.scope.profileName, 'b');
    },
  );

  test(
    'composer clarification captures its exact draft and profile request',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.event('a', 'message.start');
      host.event('a', 'clarify', {
        'request_id': 'single',
        'question': 'Which marker?',
      });
      await controller.updateDraft(chat, 'Blue');
      host.onClarifyResponse = () async {
        expect(chat.answeringQuestion, isTrue);
        await controller.updateDraft(chat, 'Keep this newer draft');
      };
      expect(controller.canAnswerWithComposer(chat), isTrue);
      await controller.answerWithComposer(chat);
      final answer = host.calls.lastWhere(
        (call) => call.$2 == 'request.answer',
      );
      expect(answer.$1, 'a');
      expect(answer.$3, {
        'id': 'single',
        'result': {'answer': 'Blue'},
        'profile': 'a',
      });
      expect(chat.composer.observation.text, 'Keep this newer draft');
      expect(chat.answeringQuestion, isFalse);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'composer clarification rejects slash commands without consuming them',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.event('a', 'clarify', {
        'request_id': 'single',
        'question': 'Which?',
      });
      await controller.updateDraft(chat, '/status');
      expect(controller.canAnswerWithComposer(chat), isFalse);
      await controller.answerWithComposer(chat);
      expect(chat.composer.observation.text, '/status');
      expect(host.calls.where((call) => call.$2 == 'request.answer'), isEmpty);
    },
  );

  test(
    'task plan gauge preserves sparse context updates and clears complete omissions',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.event('a', 'session.info', {
        'usage': {
          'calls': 1,
          'plan_gauge': {
            'id': 'task',
            'label': 'Session',
            'used_bp': 4250,
            'resets_at_ms': 1900000000000,
          },
        },
      });
      expect(chat.planGauge?.usedBasisPoints, 4250);
      host.event('a', 'session.info', {
        'usage': {'context_used': 10},
      });
      expect(chat.planGauge?.id, 'task');
      host.event('a', 'session.info', {
        'usage': {'calls': 2},
      });
      expect(chat.planGauge, isNull);
    },
  );

  test(
    'single clarification sends its request ID without a batch ID',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'clarify', {
        'request_id': 'single',
        'question': 'Which marker?',
      });
      expect(chat.runtime.pendingQuestion!.question, 'Which marker?');
      await controller.clarify(chat, 'marker');
      expect(host.calls.last.$2, 'request.answer');
      expect(host.calls.last.$3['id'], 'single');
      expect(host.calls.last.$3['result'], {'answer': 'marker'});
      expect(host.calls.last.$3.containsKey('question_id'), isFalse);
      expect(chat.runtime.questions, isNull);
    },
  );

  test('ended response cannot close a newer clarification', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'clarify', {'request_id': 'old', 'question': 'Old?'});
    host.onClarifyResponse = () async {
      host.event('a', 'clarify', {'request_id': 'new', 'question': 'New?'});
    };
    host.clarifyResult = {'status': 'expired'};
    final resumesBefore = host.calls
        .where((c) => c.$2 == 'session.resume')
        .length;
    await controller.clarify(chat, 'late answer');
    expect(chat.runtime.pendingQuestion?.requestId, 'new');
    expect(
      host.calls.where((c) => c.$2 == 'session.resume'),
      hasLength(resumesBefore),
    );
  });

  test(
    'ended batch closes even when desktop advances its pending question',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      final questions = [
        {'qid': 'q0', 'question': 'First?'},
        {'qid': 'q1', 'question': 'Second?'},
      ];
      host.event('a', 'clarify', {
        'request_id': 'batch',
        'questions': questions,
      });
      host.onClarifyResponse = () async {
        host.event('a', 'session.info', {
          'open_requests': [
            {
              'id': 'batch',
              'method': 'clarify',
              'params': {
                'session_id': chat.runtime.runtimeId,
                'questions': questions,
                'answers': {'q0': 'desktop'},
              },
            },
          ],
        });
      };
      host.clarifyResult = {'status': 'expired'};
      await controller.clarify(chat, 'late answer');
      expect(chat.runtime.pendingQuestion, isNull);
    },
  );

  test(
    'expired input refreshes its owner without retrying the answer',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'clarify', {
        'request_id': 'expired',
        'question': 'Marker?',
      });
      final pending = chat.reading.questionHistory!.questions.single;
      expect(pending.requestId, 'expired');
      expect(pending.kind, HermesQuestionKind.clarification);
      expect(pending.status, HermesQuestionStatus.pending);
      final resumesBefore = host.calls
          .where((c) => c.$2 == 'session.resume')
          .length;
      host.running = false;
      host.clarifyResult = {'status': 'expired'};
      await controller.clarify(chat, 'marker');
      expect(chat.runtime.questions, isNull);
      expect(chat.runtime.execution, ChatExecution.completed);
      final expired = chat.reading.questionHistory!.questions.single;
      expect(expired.requestId, pending.requestId);
      expect(expired.timestamp, pending.timestamp);
      expect(expired.description, pending.description);
      // Stock "expired" also means answered on another surface, so only a
      // request.cancel timeout receipt can establish actual expiry.
      expect(expired.status, HermesQuestionStatus.closed);
      expect(chat.runtime.error, isNull);
      final resumes = host.calls
          .where((c) => c.$2 == 'session.resume')
          .toList();
      expect(resumes.length, resumesBefore + 1);
      expect(resumes.last.$1, chat.key.workspace.profileName);
      expect(resumes.last.$3['session_id'], chat.key.sessionId);
      expect(host.calls.where((c) => c.$2 == 'request.answer'), hasLength(1));
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test('server cancellation removes only the matching clarification', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    host.event('a', 'clarify', {
      'request_id': 'current-request',
      'questions': [
        {'qid': 'q0', 'question': 'Which room?'},
      ],
    });
    host.event('a', 'request.cancel', {
      'id': 'old-request',
      'method': 'clarify',
      'reason': 'timeout',
    });
    expect(chat.runtime.pendingQuestion!.question, 'Which room?');
    host.event('a', 'request.cancel', {
      'id': 'current-request',
      'method': 'clarify',
      'reason': 'timeout',
    });
    expect(chat.runtime.pendingQuestion, isNull);
    expect(chat.runtime.execution, ChatExecution.running);
    expect(
      host.calls.where(
        (call) => {
          'clarify.lock',
          'request.answer',
          'prompt.submit',
        }.contains(call.$2),
      ),
      isEmpty,
    );
  });
}
