import 'package:wing/core/services/group_observations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/widgets/bot_avatar.dart';
import 'package:wing/core/widgets/mention_suggestions.dart';
import 'support/bots_fixture.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'composer_references_test.dart' show ReferenceHost;
import 'profile_workspace_controller_test.dart' show Host;

class _ReferenceWorkspaceHost extends Host {
  final references = ReferenceHost();
  String? terminal = 'local';

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: (path, query) => path == 'profiles' || path.startsWith('files')
          ? references.read(path, query)
          : base.read(path, query),
      rpc: (method, params) async {
        final result = await base.call(method, params);
        if (method == 'session.create' || method == 'session.resume') {
          return {
            ...result,
            'info': {
              ...result['info'] as Map,
              'cwd': '/work',
              if (terminal != null) 'terminal_backend': terminal,
            },
          };
        }
        if (method == 'session.context_breakdown') {
          return {
            'context_used': 0,
            'context_max': 32768,
            'context_percent': 0,
          };
        }
        if (method == 'session.history') {
          return {'messages': historyMessages ?? <Map<String, dynamic>>[]};
        }
        if (method == 'commands.catalog') {
          return {
            'pairs': [
              ['/bg', 'Background task'],
              ['/btw', 'Side question'],
            ],
          };
        }
        if (method == 'prompt.background' || method == 'prompt.btw') {
          return {'task_id': 'task-1', 'status': 'started'};
        }
        return result;
      },
    );
    return gateway;
  }
}

void main() {
  setUpAll(() async {
    final fonts = Platform.environment['CAPTURE_REFERENCE_FONTS'];
    if (fonts == null) return;
    for (final font in {
      'Roboto': '$fonts/Roboto-Regular.ttf',
      'MaterialIcons': '$fonts/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      final loader = FontLoader(font.key)
        ..addFont(File(font.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  late _ReferenceWorkspaceHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences preferences;
  late ProfileChat chat;
  late BotsSession bots;
  late BotsFixture botFixture;
  late BotsRepository botRepository;
  late DateTime botNow;
  const ref = ComposerReference(
    kind: ComposerReferenceKind.file,
    token: '@file:/work/note.md',
    target: '/work/note.md',
  );

  setUp(() async {
    botNow = DateTime.now();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    preferences = AppPreferences(prefs);
    host = _ReferenceWorkspaceHost()..running = false;
    controller = ProfileWorkspaceController(
      connectionIdentity: 'references',
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
      preferences: prefs,
      appPreferences: preferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    botFixture = BotsFixture();
    botFixture.profiles
      ..clear()
      ..addAll([
        BotsFixture.profile('hermes', 'Saved Hermes'),
        BotsFixture.profile('butler', 'Saved Butler'),
      ]);
    botFixture.profiles[0]['ui_meta']['hermes-bots']['title'] = 'Hermes';
    botFixture.profiles[1]['ui_meta']['hermes-bots']['title'] = 'Butler';
    botFixture.profiles[1]['ui_meta']['hermes-bots']['shape'] = 'hexagon';
    botFixture.profiles[1]['ui_meta']['hermes-bots']['color'] = '#8b5cf6';
    botRepository = BotsRepository(
      groupObservations: GroupObservations(
        WorkspaceScope(
          connectionId: chat.key.workspace.connectionId,
          connectionIdentity: chat.key.workspace.connectionIdentity,
          profileName: 'default',
        ),
      ),
      scope: WorkspaceScope(
        connectionId: chat.key.workspace.connectionId,
        connectionIdentity: chat.key.workspace.connectionIdentity,
        profileName: 'default',
      ),
      instance: 'Host',
      read: botFixture.read,
      command: botFixture.command,
      ownership: botFixture.ownership,

    );
    bots = BotsSession((_) async => [botRepository], now: () => botNow);
  });
  tearDown(() {
    bots.dispose();
    controller.dispose();
    preferences.dispose();
  });

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(ready(), isTrue);
  }

  Map<String, dynamic> lastCall(String method) =>
      host.calls.lastWhere((c) => c.$2 == method).$3;

  const photo =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';

  test(
    'ordinary reference identities retain saved-avatar hints without image demand',
    () async {
      botFixture.profiles.first['has_avatar'] = true;
      var rosters = 0, assets = 0;
      botFixture.readHook = (profile, method, params) async {
        if (method == 'profiles.list') rosters++;
        if (method == 'profiles.get_asset') {
          expect(profile, 'hermes');
          expect(params['name'], 'hermes');
          assets++;
          return {'found': true, 'data': photo};
        }
        return null;
      };
      final query = MentionQuery.at('@herm', 5)!;
      for (var i = 0; i < 2; i++) {
        final completion = await controller.completeMention(
          chat,
          query,
          bots: bots,
          canRead: () => true,
        );
        final candidate = completion.items.single;
        expect(candidate.label, 'Hermes');
        expect(candidate.reference.token, '@Hermes');
        expect(candidate.reference.target, 'hermes');
        expect(candidate.appearance!.title, 'Hermes');
        expect(candidate.appearance!.hasAvatar, true);
        expect(
          candidate.appearance!.scope.connectionIdentity,
          chat.key.workspace.connectionIdentity,
        );
      }
      expect(rosters, 1);
      expect(assets, 0, reason: 'Metadata completion does not admit images');
      expect(botFixture.commands, isEmpty);
    },
  );

  test(
    'retired reference queries reject metadata and fresh queries recover without image demand',
    () async {
      botFixture.profiles.first['has_avatar'] = true;
      final roster = Completer<Map<String, dynamic>?>();
      final started = Completer<void>();
      var allowed = true, assets = 0;
      botFixture.readHook = (_, method, _) async {
        if (method == 'profiles.list') {
          if (!started.isCompleted) started.complete();
          return roster.future;
        }
        if (method == 'profiles.get_asset') {
          assets++;
          return {'found': true, 'data': photo};
        }
        return null;
      };
      final query = MentionQuery.at('@herm', 5)!;
      final pending = controller.completeMention(
        chat,
        query,
        bots: bots,
        canRead: () => allowed,
      );
      final retired = expectLater(pending, throwsStateError);
      await started.future;
      allowed = false;
      roster.complete(null);
      await retired;
      expect(assets, 0);
      allowed = true;
      final fresh = await controller.completeMention(
        chat,
        query,
        bots: bots,
        canRead: () => allowed,
      );
      expect(fresh.items.single.appearance!.hasAvatar, true);
      expect(assets, 0, reason: 'Only mounted candidates borrow images');
    },
  );

  test(
    'appearance failure preserves discovery and explicit refresh recovers',
    () async {
      var unavailable = true;
      botFixture.readHook = (_, method, _) async {
        if (unavailable && method == 'profiles.list') {
          throw StateError('Unavailable appearance roster');
        }
        return null;
      };
      final query = MentionQuery.at('@', 1)!;
      final completion = await controller.completeMention(
        chat,
        query,
        bots: bots,
        canRead: () => true,
      );
      expect(
        completion.items
            .where((i) => i.reference.kind == ComposerReferenceKind.agent)
            .length,
        2,
      );
      expect(
        completion.items
            .where((i) => i.reference.kind == ComposerReferenceKind.file)
            .length,
        1,
      );
      expect(completion.items.every((i) => i.appearance == null), isTrue);
      unavailable = false;
      botNow = botNow.add(const Duration(seconds: 31));
      bots.invalidateAppearances();
      final recovered = await controller.completeMention(
        chat,
        query,
        bots: bots,
        canRead: () => true,
      );
      expect(
        recovered.items
            .where((i) => i.reference.kind == ComposerReferenceKind.agent)
            .every((i) => i.appearance != null),
        isTrue,
      );
      expect(
        recovered.items
            .where((i) => i.reference.kind == ComposerReferenceKind.file)
            .single
            .appearance,
        isNull,
      );
    },
  );

  test(
    'queued context is captured at server admission and unreadable context stays local',
    () async {
      host.event('a', 'message.start');
      await controller.updateDraft(chat, 'Read ${ref.token}', reference: ref);
      await controller.queuePrompt(chat, chat.composer.observation.text);
      final submitted = lastCall('prompt.submit');
      final prepared = PreparedComposerMessage.parse(submitted['text'])!;
      expect(prepared.context, contains('original'));
      expect(prepared.references.single.target, ref.target);
      expect(
        host.references.reads.where((r) => r.startsWith('files/read')),
        hasLength(1),
      );
      host.references.files[ref.target] = 'changed after admission';
      host.event('a', 'turn.end', {'status': 'completed'});
      expect(lastCall('prompt.submit'), submitted);
      host.references.files.clear();
      await controller.updateDraft(
        chat,
        'Read ${ref.token} again',
        reference: ref,
      );
      await controller.queuePrompt(chat, chat.composer.observation.text);
      await until(
        () =>
            chat.composer.observation.paused &&
            !chat.composer.observation.draining,
      );
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
      final failed = chat.composer.observation.queue.last;
      expect(failed.references.single.target, ref.target);
      expect(failed.text, 'Read ${ref.token} again');
    },
  );

  for (final command in {
    'bg': 'prompt.background',
    'btw': 'prompt.btw',
  }.entries) {
    test(
      '${command.key} prepares context while retaining authored task text',
      () async {
        await controller.updateDraft(
          chat,
          '/${command.key} Read ${ref.token}',
          reference: ref,
        );
        await controller.send(chat);
        final prepared = PreparedComposerMessage.parse(
          lastCall(command.value)['text'],
        )!;
        expect(prepared.message, 'Read ${ref.token}');
        expect(prepared.context, contains('original'));
        expect(
          chat.sideQuestionDeliveries.single.question,
          'Read ${ref.token}',
        );
        expect(chat.composer.observation.text, isEmpty);
      },
    );
  }

  test('steering uses the same scalar prepared transport', () async {
    host.event('a', 'message.start');
    await controller.updateDraft(chat, 'Read ${ref.token}', reference: ref);
    expect(
      await controller.steer(chat, chat.composer.observation.text),
      isTrue,
    );
    expect(
      PreparedComposerMessage.parse(
        lastCall('session.steer')['text'],
      )!.references.single.target,
      ref.target,
    );
    expect(chat.composer.observation.text, isEmpty);
  });

  test(
    'steering refuses a newer generation after reference preparation',
    () async {
      host.event('a', 'message.start');
      await controller.updateDraft(chat, 'Read ${ref.token}', reference: ref);
      host.references.readStarted = Completer<void>();
      host.references.hold = Completer<void>();
      final steering = controller.steer(chat, chat.composer.observation.text);
      final refused = expectLater(steering, throwsStateError);
      await host.references.readStarted!.future.timeout(
        const Duration(seconds: 3),
      );
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: const {},
          envelope: const {
            'seq': 1,
            'execution_generation': 1,
            'authority_epoch': 1,
            'replay_epoch': 'fixture-epoch',
          },
        ),
      );
      host.references.hold!.complete();
      await refused;
      expect(host.calls.where((call) => call.$2 == 'session.steer'), isEmpty);
      expect(chat.composer.observation.text, 'Read ${ref.token}');
      expect(chat.composer.observation.references.single.target, ref.target);
    },
  );

  test(
    'accepted prepared queue editing preserves authored text and its canonical reference',
    () async {
      host.event('a', 'message.start');
      const queued = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:note.md',
        target: '/work/note.md',
      );
      const draft = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:note.md',
        target: '/other/note.md',
      );
      host.references.files[draft.target] = 'Independent draft context';
      await controller.updateDraft(
        chat,
        'Read ${queued.token}',
        reference: queued,
      );
      await controller.queuePrompt(chat, chat.composer.observation.text);
      final row = chat.composer.observation.queue.single;
      expect(row.text, 'Read ${queued.token}');
      await controller.updateDraft(
        chat,
        'Later ${draft.token}',
        reference: draft,
      );
      await controller.beginQueuedPromptEdit(chat, row.id);
      expect(chat.composer.observation.editText, 'Read ${queued.token}');
      expect(chat.composer.observation.references.single.target, queued.target);
      controller.updateQueuedPromptEdit(chat, 'Review ${queued.token} again');
      await controller.saveQueuedPromptEdit(chat);
      final replacement = PreparedComposerMessage.parse(
        lastCall('prompt.replace_queued')['text'],
      )!;
      expect(replacement.message, 'Review ${queued.token} again');
      expect(replacement.references.single.target, queued.target);
      expect(replacement.context, contains('original'));
      expect(replacement.context, isNot(contains('Independent draft context')));
      expect(
        chat.composer.observation.queue.single.text,
        'Review ${queued.token} again',
      );
      expect(chat.composer.observation.text, 'Later ${draft.token}');
      expect(chat.composer.observation.references.single.target, draft.target);
    },
  );

  test(
    'queued steering prepares the selected references independently of the draft',
    () async {
      host.event('a', 'message.start');
      const queued = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:note.md',
        target: '/work/note.md',
      );
      const draft = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:note.md',
        target: '/other/note.md',
      );
      host.references.files[draft.target] = 'Separate draft context';
      await controller.updateDraft(
        chat,
        'Read ${queued.token}',
        reference: queued,
      );
      await controller.queuePrompt(chat, chat.composer.observation.text);
      final selected = chat.composer.observation.queue.single.id;
      await controller.updateDraft(
        chat,
        'Later ${draft.token}',
        reference: draft,
      );
      expect(await controller.steerQueuedPrompt(chat, selected), isTrue);
      final admitted = lastCall('prompt.submit');
      final prepared = PreparedComposerMessage.parse(admitted['text'])!;
      expect(prepared.references.single.target, queued.target);
      expect(
        lastCall('prompt.steer_queued')['admission_id'],
        host.canonicalAdmissions.values.single['admission_id'],
      );
      expect(
        chat.composer.observation.queue.single.text,
        'Read ${queued.token}',
      );
      expect(chat.composer.queueActions(selected).canSteer, isFalse);
      expect(chat.composer.observation.text, 'Later ${draft.token}');
      expect(chat.composer.observation.references.single.target, draft.target);
    },
  );

  test(
    'saved restore uses the captured canonical target before cutting history',
    () async {
      const selected = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:note.md',
        target: '/work/note.md',
      );
      final old = PreparedComposerMessage(
        message: 'Read @file:note.md',
        context: 'old snapshot',
        references: const [selected],
      );
      host.historyMessages = [
        {'id': 6, 'row_id': 6, 'role': 'user', 'content': old.wireText},
        {'id': 7, 'row_id': 7, 'role': 'assistant', 'content': 'Old answer'},
      ];
      await controller.refreshHistory(chat);
      host.event('a', 'session.info', {
        'cwd': '/different',
        'terminal_backend': 'local',
      });
      host.references.files[selected.target] = 'fresh restore content';
      final prompt = chat.reading.messages.first;
      expect(
        await controller.restoreSavedPrompt(chat, prompt),
        isTrue,
        reason: chat.runtime.error,
      );
      final dispatch = lastCall('prompt.submit');
      final prepared = PreparedComposerMessage.parse(dispatch['text'])!;
      expect(prepared.context, contains('fresh restore content'));
      expect(prepared.references.single.target, selected.target);
      final mutation = lastCall('session.mutate');
      expect(mutation['operation'], 'rewind');
      expect(mutation['payload'], {'target_message_id': 6});
      expect(dispatch.containsKey('truncate_before_row_id'), isFalse);
    },
  );

  for (final terminal in ['docker', null]) {
    test(
      '$terminal namespace uses host browsing; relative context pauses',
      () async {
        host.terminal = terminal;
        host.runtimeForResume['a'] = 'a-runtime';
        await controller.reconnect(chat.key.workspace);
        final query = MentionQuery.at('@', 1)!;
        final result = await controller.completeMention(
          chat,
          query,
          bots: bots,
          canRead: () => true,
        );
        expect(result.directory, '/work');
        expect(host.references.reads, contains('files:'));
        await controller.updateDraft(chat, 'Read @file:note.md');
        await controller.send(chat);
        expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
        expect(
          chat.composer.observation.queue.single.text,
          'Read @file:note.md',
        );
      },
    );
  }

  test('lazy cwd change retires a previous local namespace claim', () async {
    host.event('a', 'session.info', {'cwd': '/container'});
    await controller.completeMention(
      chat,
      MentionQuery.at('@', 1)!,
      bots: bots,
      canRead: () => true,
    );
    expect(host.references.reads, contains('files:'));
    expect(host.references.reads, isNot(contains('files:/container')));
    await controller.updateDraft(chat, 'Read @file:note.md');
    await controller.send(chat);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    expect(chat.composer.observation.queue.single.text, 'Read @file:note.md');
  });

  test(
    'ordinary picker searches the saved bot title with canonical identity',
    () async {
      botFixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Research Guide';
      botFixture.profiles[1]['has_avatar'] = true;
      var unrelatedAssets = 0;
      botFixture.readHook = (profile, method, params) async {
        if (method == 'profiles.get_asset' && profile == 'butler') {
          unrelatedAssets++;
        }
        return null;
      };
      const text = '@guide';
      final completion = await controller.completeMention(
        chat,
        MentionQuery.at(text, text.length)!,
        bots: bots,
        canRead: () => true,
      );
      final candidate = completion.items.singleWhere(
        (item) => item.reference.kind == ComposerReferenceKind.agent,
      );
      expect(candidate.label, 'Research Guide');
      expect(candidate.reference.token, '@`Research Guide`');
      expect(candidate.reference.target, 'hermes');
      expect(unrelatedAssets, 0);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('workspace references ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: const EdgeInsets.only(bottom: 280),
                ),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession(
                  (_) async => [botRepository],
                  now: () => botNow,
                ),
              ),
            ),
          ),
        );
        Future<void> captureFrame(String name) async {
          if (!Platform.environment.containsKey('CAPTURE_REFERENCES')) return;
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory('build/references-review')
                ..createSync(recursive: true);
              await File(
                '${directory.path}/$name-${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        final input = find.byKey(const Key('profile-message-composer'));
        const prefix = "Let's adapt the workflow, given that ";
        await tester.enterText(input, '$prefix@');
        final nativeInput = tester.widget<TextField>(input).controller!;
        nativeInput.value = nativeInput.value.copyWith(
          composing: TextRange(start: prefix.length, end: prefix.length + 1),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.text('Hermes'), findsOneWidget);
        final picker = find.byType(MentionSuggestions);
        final avatars = tester.widgetList<BotAvatar>(
          find.descendant(of: picker, matching: find.byType(BotAvatar)),
        );
        expect(avatars.map((a) => (a.name, a.shape, a.color)), [
          ('butler', 'hexagon', '#8b5cf6'),
          ('hermes', 'squircle', '#65c7bc'),
        ]);
        expect(
          find.descendant(
            of: picker,
            matching: find.byIcon(Icons.smart_toy_outlined),
          ),
          findsNothing,
        );
        await captureFrame('workspace-avatars');
        await tester.ensureVisible(find.text('Hermes'));
        expect(find.text('Hermes').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Hermes'));
        await tester.pumpAndSettle();
        expect(chat.composer.observation.references.single.target, 'hermes');
        expect(nativeInput.text, '$prefix@Hermes ');
        expect(nativeInput.value.composing, TextRange.empty);
        await tester.enterText(input, '@');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('Close references').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final file =
            '/work/${List.filled(4, 'long-directory').join('/')}/public_paths.py';
        host.references.files[file] = 'reference content';
        await tester.enterText(input, '@file:$file');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        final candidate = find.text('public_paths.py');
        expect(candidate.hitTestable(), findsOneWidget);
        await tester.tap(candidate);
        await tester.pumpAndSettle();
        expect(chat.composer.observation.references.single.target, file);
        expect(tester.takeException(), isNull);
        await captureFrame('workspace');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
