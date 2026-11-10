import '../test/support/composer_fixture.dart';
import '../test/helpers/journey_controls.dart' show tapJourneyControl;
import '../test/support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/profile_queued_messages.dart';

import '../test/support/profile_actions_fixture.dart';

/// Runs production widgets/controller on Android with no external transport.
/// Install only in the separate Dev package on a disposable emulator.
class _QueueFixture extends ProfileActionsFixture {
  final gateways = <String, ProfileGateway>{};
  final steers = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? steerReply;
  bool rejectSteer = false;
  final admissions = <String, Map<String, dynamic>>{};
  final replacements = <Map<String, dynamic>>[];
  final cancellations = <Map<String, dynamic>>[];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'user', 'content': 'Review the Android conversation UI.'},
    {
      'id': 2,
      'role': 'assistant',
      'content': 'I am checking the composer and queued messages.',
    },
  ];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        await base.connect();
        // Startup catalog readers close after their read; queue events belong
        // to the retained conversation gateway that has a stream consumer.
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
      },
      get: base.read,
      rpc: (method, params) async {
        if (method == 'prompt.submit') {
          calls.add((scope.profileName, method, Map.of(params)));
          return admissions.putIfAbsent(
            params['submission_id'] as String,
            () => canonicalReceipt(
              params,
              admissionId: 'queue-${admissions.length + 1}',
              sequence: admissions.length + 1,
            ),
          );
        }
        if (method == 'session.resume') {
          return {
            ...canonicalSnapshotFields,
            'session_id': params['session_id'],
            'status': 'working',
            'messages': [],
            'info': {'profile_name': scope.profileName},
            'pending': admissions.values
                .where((row) => row['status'] != 'terminal')
                .toList(),
          };
        }
        if (method == 'prompt.replace_queued') {
          replacements.add(Map.of(params));
          final row = admissions.values.singleWhere(
            (row) => row['admission_id'] == params['admission_id'],
          );
          if (row['status'] != 'queued') {
            throw JsonRpcError(
              method,
              'Already started',
              reason: 'admission_started',
            );
          }
          row['status'] = 'terminal';
          row['outcome'] = 'cancelled';
          return admissions[params['submission_id']
              as String] = canonicalReceipt(
            {...params, 'queued': true},
            admissionId: 'queue-${admissions.length + 1}',
            sequence: admissions.length + 1,
          );
        }
        if (method == 'prompt.cancel' || method == 'prompt.steer_queued') {
          final row = admissions.values.singleWhere(
            (row) => row['admission_id'] == params['admission_id'],
          );
          if (method == 'prompt.steer_queued') {
            steers.add(Map.of(params));
            if (rejectSteer) {
              throw JsonRpcError(
                method,
                'Cannot steer this admission',
                reason: 'admission_not_queued',
              );
            }
            await steerReply?.future;
            row['status'] = 'started';
          } else {
            cancellations.add(Map.of(params));
            row['status'] = 'terminal';
            row['outcome'] = 'cancelled';
          }
          return row;
        }
        if (method == 'file.attach') {
          return {'attached': true, 'ref_text': 'attached:${params['name']}'};
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }

  void finish(ProfileChat chat) {
    final gateway = gateways[chat.key.workspace.profileName]!;
    final first = admissions.values
        .where((row) => row['status'] == 'queued')
        .first;
    first['status'] = 'started';
    gateway.onEvent!(
      StreamEvent(
        type: 'turn.end',
        sessionId: chat.runtime.runtimeId,
        data: {'status': 'completed'},
      ),
    );
    gateway.onEvent!(
      StreamEvent(
        type: 'session.info',
        sessionId: chat.runtime.runtimeId,
        data: {
          'pending': admissions.values
              .where((row) => row['status'] != 'terminal')
              .toList(),
          'running': true,
        },
      ),
    );
  }

  List<Map<String, dynamic>> get submissions => calls
      .where((call) => call.$2 == 'prompt.submit')
      .map((call) => call.$3)
      .toList();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  late _QueueFixture fixture;
  late ProfileWorkspaceController controller;
  late ProfileChat chat;
  var convertedSurface = false;
  final composer = find.byKey(const Key('profile-message-composer'));

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapReady(WidgetTester tester, Finder control) async {
    // Route dismissal and the keyboard can move the action after a first frame.
    await tapJourneyControl(tester, control);
  }

  Future<void> capture(
    WidgetTester tester,
    String name, {
    bool keyboard = false,
  }) async {
    if (const bool.fromEnvironment('QUEUE_NATIVE_CAPTURE')) {
      // The host captures Android's full window, including the real IME.
      // Flutter surface screenshots below intentionally contain only the app.
      final directory = Directory.systemTemp.path;
      final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
      await File('$directory/wing-queue-stage.json').writeAsString(
        jsonEncode({'name': name, 'token': token, 'keyboard': keyboard}),
      );
      final ack = File('$directory/wing-queue-ack');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (await ack.exists() && await ack.readAsString() == token) return;
      }
      throw StateError('Native Android capture did not complete $name');
    }
    if (!convertedSurface) {
      await binding.convertFlutterSurfaceToImage();
      convertedSurface = true;
      await frames(tester);
    }
    final bytes = await binding.takeScreenshot(name);
    final directory = await getExternalStorageDirectory();
    final frame = File('${directory!.path}/$name.png');
    await frame.writeAsBytes(bytes);
    debugPrint('Native frame: ${frame.path}');
  }

  Future<AttachmentDraft> file(String name) async {
    final directory = await getTemporaryDirectory();
    final cached = File('${directory.path}/$name');
    await cached.writeAsString('Isolated queued-message device test');
    addTearDown(() async {
      if (await cached.exists()) await cached.delete();
    });
    return AttachmentDraft(
      id: name,
      cachedPath: cached.path,
      name: name,
      byteLength: await cached.length(),
      mediaType: 'text/plain',
      kind: AttachmentDraftKind.genericFile,
    );
  }

  Future<void> launch(
    WidgetTester tester, {
    double scale = 1,
    bool light = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(light ? Brightness.light : Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> edit(WidgetTester tester, String original) async {
    final row = find.text(original);
    await tester.ensureVisible(row);
    await frames(tester);
    expect(row.hitTestable(), findsOneWidget);
    await tester.longPress(row);
    await frames(tester);
    expect(chat.composer.observation.displayedText, original);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Save queued message'), findsOneWidget);
    expect(find.byTooltip('Steer queued message'), findsOneWidget);
  }

  late AppPreferences appPreferences;
  setUp(() async {
    convertedSurface = false;
    SharedPreferences.setMockInitialValues({});
    fixture = _QueueFixture();
    final fixturePreferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(fixturePreferences);
    controller = ProfileWorkspaceController(
      appPreferences: appPreferences,
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'queue-device',
          label: 'Queue device QA',
          host: 'unused',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'isolated-queued-message-device-test',
      preferences: fixturePreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'session.title', {
      'session_id': chat.key.sessionId,
      'title': 'Queued message device check',
    });
    emitChatEvent(controller, chat, 'message.start');
    await controller.queuePrompt(chat, 'Review the layout');
    await controller.queuePrompt(chat, 'Then check the tests');
    await controller.updateDraft(
      chat,
      'My unfinished draft\nKeep this second line.',
    );
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  testWidgets(
    'long press opens the native keyboard; Queue restores text and files',
    (tester) async {
      final bufferedFile = await file('draft-notes.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [bufferedFile],
      );
      await launch(tester);
      expect(find.byTooltip('Message actions'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ComposerActionButton)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await frames(tester);
      expect(
        find.byKey(const ValueKey('composer-choice-queue')),
        findsOneWidget,
      );
      await gesture.cancel();
      await frames(tester);
      expect(
        find.byKey(const ValueKey('composer-action-selector')),
        findsNothing,
      );
      await edit(tester, 'Review the layout');
      // No synthetic viewInsets: this is the real Android IME after focus.
      final keyboardDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (View.of(tester.element(composer)).viewInsets.bottom == 0 &&
          DateTime.now().isBefore(keyboardDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        View.of(tester.element(composer)).viewInsets.bottom,
        greaterThan(0),
      );
      expect(find.byTooltip('Delete queued message'), findsOneWidget);
      await capture(tester, 'queue-01-edit-keyboard', keyboard: true);
      await tester.enterText(
        composer,
        'Review spacing first\nThen check contrast.',
      );
      await frames(tester);
      await tester.tap(find.byTooltip('Save queued message'));
      await frames(tester);
      expect(chat.composer.observation.queue.map((prompt) => prompt.text), [
        'Then check the tests',
        'Review spacing first\nThen check contrast.',
      ]);
      expect(
        chat.composer.observation.displayedText,
        'My unfinished draft\nKeep this second line.',
      );
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        bufferedFile.id,
      ]);
      expect(await File(bufferedFile.cachedPath).exists(), isTrue);
      expect(fixture.submissions, hasLength(2));
      expect(fixture.replacements.single['admission_id'], 'queue-1');
      await capture(tester, 'queue-02-restored-draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Cancel restores the draft and discards only the queue edit', (
    tester,
  ) async {
    await launch(tester);
    await edit(tester, 'Review the layout');
    await tester.enterText(composer, 'Discard this modification');
    await frames(tester);
    await tester.tap(find.byTooltip('Cancel queued message editing'));
    await frames(tester);
    expect(chat.composer.observation.queue.first.text, 'Review the layout');
    expect(
      chat.composer.observation.displayedText,
      'My unfinished draft\nKeep this second line.',
    );
    expect(find.byTooltip('Delete queued message'), findsNothing);
    expect(fixture.steers, isEmpty);
    expect(fixture.submissions, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('red cross asks before deleting just the selected instruction', (
    tester,
  ) async {
    await launch(tester);
    await edit(tester, 'Review the layout');
    await tapReady(tester, find.byTooltip('Delete queued message'));
    await frames(tester);
    await capture(tester, 'queue-03-delete-confirmation');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Cancel'),
      ),
    );
    await frames(tester);
    expect(chat.composer.observation.queue, hasLength(2));
    expect(chat.composer.observation.displayedText, 'Review the layout');
    await tapReady(tester, find.byTooltip('Delete queued message'));
    await frames(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Delete queued message'),
      ),
    );
    await frames(tester);
    expect(chat.composer.observation.queue.single.text, 'Then check the tests');
    expect(
      chat.composer.observation.displayedText,
      'My unfinished draft\nKeep this second line.',
    );
    expect(fixture.cancellations.single['admission_id'], 'queue-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Steer waits for acknowledgement, sends once and restores the draft',
    (tester) async {
      fixture.steerReply = Completer<Map<String, dynamic>>();
      final bufferedFile = await file('steer-buffer.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [bufferedFile],
      );
      await launch(tester);
      await edit(tester, 'Review the layout');
      await tester.enterText(composer, 'Focus on spacing now');
      await frames(tester);
      expect(
        chat.composer.queueActions(chat.composer.observation.editing!).canSteer,
        false,
      );
      await tester.enterText(composer, 'Review the layout');
      await frames(tester);
      await tester.tap(find.byTooltip('Steer queued message'));
      await frames(tester);
      expect(chat.composer.observation.saving, isTrue);
      expect(find.byTooltip('Saving message'), findsOneWidget);
      await capture(tester, 'queue-04-steer-pending');
      await tester.tap(find.byTooltip('Steer queued message'));
      await frames(tester);
      expect(fixture.steers, hasLength(1));
      expect(fixture.submissions, hasLength(2));
      expect(chat.composer.observation.displayedText, 'Review the layout');
      expect(tester.widget<TextField>(composer).enabled, isFalse);
      expect(fixture.steers, hasLength(1));
      expect(fixture.steers.single['admission_id'], 'queue-1');
      expect(fixture.steers.single.containsKey('text'), false);
      expect(fixture.steers.single['session_id'], chat.runtime.runtimeId);
      expect(chat.composer.observation.queue.first.serverOwned, true);
      fixture.steerReply!.complete({'status': 'queued'});
      await frames(tester);
      expect(
        chat.composer.observation.queue.single.text,
        'Then check the tests',
      );
      expect(
        chat.composer.observation.displayedText,
        'My unfinished draft\nKeep this second line.',
      );
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        bufferedFile.id,
      ]);
      expect(fixture.submissions, hasLength(2));
      expect(find.text('steered'), findsOneWidget);
      await capture(tester, 'queue-04-steered');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rejected and failed canonical steering preserve the admitted instruction',
    (tester) async {
      fixture.rejectSteer = true;
      await launch(tester);
      await edit(tester, 'Review the layout');
      await tester.tap(find.byTooltip('Steer queued message'));
      await frames(tester);
      expect(chat.composer.observation.queue, hasLength(2));
      expect(chat.composer.observation.displayedText, 'Review the layout');
      expect(find.text('steered'), findsNothing);
      fixture.rejectSteer = false;
      fixture.steerReply = Completer<Map<String, dynamic>>();
      await tester.tap(find.byTooltip('Steer queued message'));
      await frames(tester);
      fixture.steerReply!.completeError(
        StateError('Device test connection lost'),
      );
      await frames(tester);
      expect(chat.composer.observation.queue.first.text, 'Review the layout');
      expect(chat.composer.observation.queue.first.serverOwned, true);
      expect(
        chat.composer.observation.text,
        'My unfinished draft\nKeep this second line.',
      );
      expect(fixture.steers.map((row) => row['admission_id']).toSet(), {
        'queue-1',
      });
      expect(fixture.submissions, hasLength(2));
      await capture(tester, 'queue-05-failed-steer');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('server claim retires an outdated edit without resubmission', (
    tester,
  ) async {
    await launch(tester);
    await edit(tester, 'Review the layout');
    await tester.enterText(composer, 'Too late to replace this admission');
    await frames(tester);
    fixture.finish(chat);
    await frames(tester);
    expect(chat.composer.observation.editing, isNull);
    expect(
      chat.composer.observation.displayedText,
      'My unfinished draft\nKeep this second line.',
    );
    expect(chat.composer.observation.queue.single.text, 'Then check the tests');
    expect(fixture.replacements, isEmpty);
    expect(fixture.submissions, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unaccepted attachment draft survives editing at large text with the keyboard',
    (tester) async {
      await chat.composer.pause();
      final queuedFile = await file('queued-review.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [queuedFile],
        paused: true,
      );
      await controller.updateDraft(chat, 'Review this file');
      await controller.queuePrompt(chat, chat.composer.observation.text);
      await controller.updateDraft(chat, 'Buffered draft');
      final queued = chat.composer.observation.queue.last;
      expect(queued.serverOwned, isFalse);
      expect(queued.text, 'Review this file');
      expect(queued.attachments.map((file) => file.id), [queuedFile.id]);
      expect(chat.composer.observation.paused, isTrue);
      expect(fixture.submissions, hasLength(2));
      await launch(tester, scale: 2, light: true);
      final row = find.text('Review this file · queued-review.txt');
      // At 2× the third row can be outside the lazy queue viewport. Scroll
      // that list to build it before asking for its actual element/geometry.
      await tester.scrollUntilVisible(
        row,
        80,
        scrollable: find.descendant(
          of: find.byType(ProfileQueuedMessages),
          matching: find.byType(Scrollable),
        ),
      );
      await frames(tester);
      expect(row.hitTestable(), findsOneWidget);
      await tester.longPress(row);
      await frames(tester);
      await tester.enterText(composer, 'Check the attached notes');
      await frames(tester);
      final keyboardDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (View.of(tester.element(composer)).viewInsets.bottom == 0 &&
          DateTime.now().isBefore(keyboardDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        View.of(tester.element(composer)).viewInsets.bottom,
        greaterThan(0),
      );
      await tester.ensureVisible(find.byTooltip('Save queued message'));
      await frames(tester);
      expect(
        find.byTooltip('Save queued message').hitTestable(),
        findsOneWidget,
      );
      await capture(tester, 'queue-06-large-text-attachment', keyboard: true);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byTooltip(
                  'Hermes only supports steering text-only messages.',
                ),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Save queued message'));
      await frames(tester);
      expect(
        chat.composer.observation.queue.last.text,
        'Check the attached notes',
      );
      expect(
        chat.composer.observation.queue.last.attachments.map((file) => file.id),
        [queuedFile.id],
      );
      expect(await File(queuedFile.cachedPath).exists(), isTrue);
      expect(chat.composer.observation.displayedText, 'Buffered draft');
      expect(tester.takeException(), isNull);
    },
  );
}
