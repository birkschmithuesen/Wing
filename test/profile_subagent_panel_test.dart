import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/services/transcript_resource_session.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/widgets/subagent_timeline.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/composer_fixture.dart' show emitChatEvent;
import 'helpers/pump_markdown_widget.dart';

class _SubagentFixture extends ProfileActionsFixture {
  List<Map<String, dynamic>>? childMessages;
  List<Map<String, dynamic>>? nestedMessages;
  final childEvents = <Map<String, dynamic>>[];
  int listCalls = 0;
  int tailCalls = 0;
  int tailFailures = 0;
  Completer<void>? tailGate;
  Completer<void>? steerGate;
  bool acceptSteer = false;
  bool failSteer = false;
  bool findInterrupt = false;
  bool failInterrupt = false;
  bool emptyList = false;
  bool tailAvailable = true;
  double? startedAt;
  List<Map<String, dynamic>>? rows;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (path, query) async {
        if (path == 'sessions/child-session/messages' ||
            path == 'sessions/nested-session/messages') {
          final nested = path.contains('nested-session');
          final messages = nested ? nestedMessages : childMessages;
          return {
            'session_id': nested ? 'nested-session' : 'child-session',
            'messages':
                messages?.reversed.toList() ??
                [
                  {
                    'id': 101,
                    'role': 'assistant',
                    'content': 'Child saved evidence',
                  },
                ],
            'pagination': {
              'offset': int.parse(query['offset']!),
              'limit': int.parse(query['limit']!),
              'returned': messages?.length ?? 1,
              'order': 'latest',
            },
          };
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        requests.add((method, params));
        final id = params['session_id'];
        final isChild = id == 'child-session' || id == 'nested-session';
        final events = id == 'nested-session'
            ? <Map<String, dynamic>>[]
            : childEvents;
        if (method == 'session.resume' && isChild) {
          expect(params['display_projection'], isTrue);
          expect(params.containsKey('lazy'), isFalse);
          expect(params.containsKey('omit_messages'), isFalse);
          return {
            'session_id': id,
            'stored_session_id': id,
            'replay_epoch': 'child-epoch',
            'last_sequence': events.length,
            'running': true,
          };
        }
        if (method == 'session.events.since' && isChild) {
          expect(params['replay_epoch'], 'child-epoch');
          return {
            'replay_epoch': 'child-epoch',
            'events': [
              for (final event in events)
                if ((event['seq'] as int) > (params['last_sequence'] as int))
                  event,
            ],
            'latest_seq': events.fold<int>(
              0,
              (latest, event) =>
                  (event['seq'] as int) > latest ? event['seq'] as int : latest,
            ),
            'truncated': false,
            'snapshot_required': false,
          };
        }
        switch (method) {
          case 'subagent.list':
            listCalls += 1;
            return {
              'subagents':
                  rows ??
                  [
                    if (!emptyList)
                      {
                        'subagent_id': 'child-1',
                        'goal': 'Inspect the release',
                        'status': 'running',
                        'model': 'test-model',
                        'last_tool': 'read_file',
                        'accepting_steer': true,
                        'started_at': startedAt,
                        'tool_count': 3,
                      },
                  ],
              'delegations': const [],
            };
          case 'subagent.tail':
            tailCalls += 1;
            await tailGate?.future;
            if (tailCalls <= tailFailures) {
              throw StateError('tail unavailable');
            }
            return {
              'subagent_id': 'child-1',
              'available': tailAvailable,
              'text': tailAvailable ? 'latest child output' : '',
              'truncated': false,
              'snapshot_required': false,
            };
          case 'subagent.steer':
            if (failSteer) throw StateError('Steering transport failed');
            if (steerGate case final gate?) await gate.future;
            return {
              'status': acceptSteer ? 'queued' : 'rejected',
              'subagent_id': 'child-1',
            };
          case 'subagent.interrupt':
            if (failInterrupt) throw StateError('Interrupt transport failed');
            return {'found': findInterrupt, 'subagent_id': 'child-1'};
          default:
            return base.call(method, params);
        }
      },
    );
  }
}

class _TracePicker extends FilePickerPlatform {
  final files = <(String, Uint8List)>[];
  final pending = Completer<Uri?>();
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    files.add((fileName, bytes));
    return pending.future;
  }
}

void main() {
  const review = bool.fromEnvironment('CAPTURE_SUBAGENT_FIXES');
  const frame = ValueKey('subagent-fixes-render');
  setUpAll(() async {
    if (!review) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'monospace': 'build/studio-mono.ttf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (!review) return;
    await tester.settleMarkdown();
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(frame))
          .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('build/design-previews/subagent-fixes/site')
        ..createSync(recursive: true);
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String outcome,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: outcome);
      if (ready()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    } while (DateTime.now().isBefore(deadline));
    fail('Timed out waiting for $outcome');
  }

  late _SubagentFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ProfileSupervisionSession supervision;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _SubagentFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'subagent-panel',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'message.start', {});
    supervision = ProfileSupervisionSession(controller: controller, chat: chat);
  });

  tearDown(() {
    supervision.dispose();
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> showPanel(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1.8,
    bool motion = false,
    Size size = const Size(320, 640),
    TranscriptResourceSession Function(ProfileSessionKey)? resources,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: !motion,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                ProfileSubagentPanel(
                  session: supervision,
                  createResources: resources ?? controller.traceResources,
                  initiallyExpanded: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (!motion) await tester.pumpAndSettle();
  }

  Future<void> openDetails(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1.8,
    Size size = const Size(320, 640),
  }) async {
    await showPanel(tester, brightness: brightness, scale: scale, size: size);
    await tester.ensureVisible(find.text('Inspect the release'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inspect the release'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  TranscriptResourceSession resourcesFor(
    ProfileSessionKey key,
    Future<http.Response> Function(http.Request) respond,
  ) {
    final client = RemoteFilesClient(
      dashboard: DashboardClient(
        host: 'trace.test',
        port: 9119,
        proxied: true,
        httpClient: MockClient(respond),
      ),
    );
    final gateway = fixture.gateway(key.workspace);
    return TranscriptResourceSession(
      files: OwnedRemoteFiles(
        source: client,
        profileName: key.workspace.profileName,
        storedSessionId: key.sessionId,
        release: client.close,
      ),
      loadHistory: (offset) => gateway.history(key.sessionId, offset: offset),
      createSkillReader: gateway.skillReader,
    );
  }

  Future<void> openChild(WidgetTester tester) async {
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'child_session_id': 'child-session',
      'goal': 'Inspect the release',
    });
    await tester.pump();
    await tester.tap(find.text('Inspect the release'));
    await until(
      tester,
      () => find.byType(SubagentTimeline).evaluate().isNotEmpty,
      'child timeline',
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  List<Map<String, dynamic>> resourceRows(String name, String arguments) => [
    {'id': 1, 'role': 'user', 'content': 'Inspect source evidence'},
    {
      'id': 2,
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'id': 'source-1',
          'function': {'name': name, 'arguments': arguments},
        },
      ],
    },
    {
      'id': 3,
      'role': 'tool',
      'tool_call_id': 'source-1',
      'content': name == 'read_file'
          ? 'A short file excerpt'
          : 'Day details are readable.',
    },
  ];

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'child trace source image loads retries and opens ${brightness.name} $scale',
        (tester) async {
          const path =
              '/home/tarkil/.hermes/cache/scratch/rwc-ux/390-day29.png';
          fixture.childMessages = resourceRows(
            'vision_analyze',
            jsonEncode({
              'image_url': path,
              'question': 'Inspect mobile day details and controls',
            }),
          );
          final requests = <http.Request>[];
          var response = Completer<http.Response>();
          await showPanel(
            tester,
            brightness: brightness,
            scale: scale,
            size: scale == 1 ? const Size(390, 844) : const Size(320, 640),
            resources: (key) => resourcesFor(key, (request) {
              requests.add(request);
              return response.future;
            }),
          );
          await openChild(tester);
          await tester.openLiveActivity();
          await Scrollable.ensureVisible(
            tester.element(find.text('Analyzed image')),
            alignment: 0.5,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Analyzed image'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.bySemanticsLabel('Loading image'), findsWidgets);
          await capture(
            tester,
            'resource-image-pending-${brightness.name}-$scale',
          );
          expect(requests.single.url.path, '/api/fs/download');
          expect(requests.single.url.queryParameters, {
            'path': path,
            'profile': chat.key.workspace.profileName,
            'session_id': 'child-session',
          });
          response.complete(http.Response('{"detail":"File not found"}', 404));
          await until(
            tester,
            () => find
                .text('This image could not be previewed.')
                .evaluate()
                .isNotEmpty,
            'recoverable image failure',
          );
          response = Completer<http.Response>();
          await Scrollable.ensureVisible(
            tester.element(find.byTooltip('Retry image')),
            alignment: 0.5,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Retry image'));
          await tester.pump();
          expect(find.bySemanticsLabel('Loading image'), findsWidgets);
          response.complete(
            http.Response.bytes(
              img.encodePng(
                img.fill(
                  img.Image(width: 180, height: 100),
                  color: img.ColorRgb8(37, 103, 120),
                ),
              ),
              200,
            ),
          );
          await until(
            tester,
            () => find.byType(Image).evaluate().isNotEmpty,
            'image provider',
          );
          for (final element in find.byType(Image).evaluate()) {
            final image = element.widget as Image;
            await tester.runAsync(() => precacheImage(image.image, element));
          }
          await tester.pump();
          expect(find.text('This image could not be previewed.'), findsNothing);
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
          expect(requests, hasLength(2));
          expect(requests.last.url, requests.first.url);
          await Scrollable.ensureVisible(
            tester.element(find.byType(RawImage)),
            alignment: 0.5,
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(RawImage).hitTestable(), findsOneWidget);
          await capture(
            tester,
            'resource-image-ready-${brightness.name}-$scale',
          );
          await Scrollable.ensureVisible(
            tester.element(find.byTooltip('Preview image')),
            alignment: 0.5,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Preview image'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(ChatImagePreview), findsOneWidget);
          expect(
            tester
                .widget<ChatImagePreview>(find.byType(ChatImagePreview))
                .bytes,
            isNotEmpty,
          );
          Navigator.of(tester.element(find.byType(ChatImagePreview))).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Close subagent activity'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'child trace file preview binds full content and pending share to the child',
    (tester) async {
      fixture.childMessages = resourceRows('read_file', '{"path":"report.md"}');
      final requests = <http.Request>[];
      var response = Completer<http.Response>();
      await showPanel(
        tester,
        scale: 1,
        size: const Size(390, 844),
        resources: (key) => resourcesFor(key, (request) {
          requests.add(request);
          return response.future;
        }),
      );
      await openChild(tester);
      await tester.openLiveActivity();
      await Scrollable.ensureVisible(
        tester.element(find.text('Read file')),
        alignment: 0.5,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Read file'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Preview file'), findsOneWidget);
      expect(find.byTooltip('Share file'), findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(find.byTooltip('Preview file')),
        alignment: 0.5,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Preview file'));
      await tester.pump();
      expect(find.byType(ChatOutputsScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.bySemanticsLabel('Loading outputs'), findsWidgets);
      await tester.pumpAndSettle();
      await capture(tester, 'resource-file-pending');
      expect(requests.single.url.path, '/api/fs/read-text');
      expect(requests.single.url.queryParameters, {
        'path': 'report.md',
        'profile': chat.key.workspace.profileName,
        'session_id': 'child-session',
      });
      response.complete(
        http.Response(
          jsonEncode({
            'path': '/child/work/report.md',
            'text': '# Full child report\n\nDetails beyond the excerpt.',
            'language': 'markdown',
            'mimeType': 'text/markdown',
            'binary': false,
            'truncated': false,
          }),
          200,
        ),
      );
      await until(
        tester,
        () => find
            .byWidgetPredicate(
              (w) =>
                  w is MarkdownMessageContent &&
                  w.data.contains('Details beyond the excerpt.'),
            )
            .evaluate()
            .isNotEmpty,
        'full child file viewer',
      );
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      await capture(tester, 'resource-file-ready');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await until(
        tester,
        () => find.byTooltip('Share file').evaluate().isNotEmpty,
        'returned child file action',
      );
      response = Completer<http.Response>();
      await Scrollable.ensureVisible(
        tester.element(find.byTooltip('Share file')),
        alignment: 0.5,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Share file'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byTooltip('Share file'),
          matching: find.byIcon(Icons.hourglass_top),
        ),
        findsOneWidget,
      );
      expect(requests.last.url.path, '/api/fs/download');
      expect(requests.last.url.queryParameters['session_id'], 'child-session');
      await tester.tap(find.byTooltip('Close subagent activity'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      response.complete(http.Response.bytes([1, 2, 3], 200));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byType(SubagentTimeline), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('nested child message resources save under their own session', (
    tester,
  ) async {
    fixture.childEvents.add({
      'session_id': 'child-session',
      'seq': 1,
      'type': 'subagent.start',
      'payload': {
        'subagent_id': 'nested-agent',
        'child_session_id': 'nested-session',
        'goal': 'Inspect nested evidence',
      },
    });
    fixture.nestedMessages = [
      {'id': 1, 'role': 'assistant', 'content': '[Nested report](report.md)'},
    ];
    final originalPicker = FilePickerPlatform.instance;
    final picker = _TracePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    final keys = <ProfileSessionKey>[];
    final requests = <http.Request>[];
    final response = Completer<http.Response>();
    await showPanel(
      tester,
      scale: 1,
      size: const Size(390, 844),
      resources: (key) {
        keys.add(key);
        return resourcesFor(key, (request) {
          requests.add(request);
          return response.future;
        });
      },
    );
    await openChild(tester);
    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, false))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await Scrollable.ensureVisible(
      tester.element(find.text('Inspect nested evidence')),
      alignment: .5,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Inspect nested evidence'));
    await until(tester, () => keys.length == 2, 'nested resources');
    await tester.settleMarkdown();
    await until(
      tester,
      () => find.byTooltip('Download').evaluate().isNotEmpty,
      'nested deliverable',
    );
    expect(keys.map((key) => key.sessionId), [
      'child-session',
      'nested-session',
    ]);
    await Scrollable.ensureVisible(
      tester.element(find.byTooltip('Download')),
      alignment: .5,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Download'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byTooltip('Download'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(requests.single.url.queryParameters, {
      'path': 'report.md',
      'profile': chat.key.workspace.profileName,
      'session_id': 'nested-session',
    });
    response.complete(
      http.Response.bytes(
        utf8.encode('Nested original content'),
        200,
        headers: {'content-disposition': 'attachment; filename=report.md'},
      ),
    );
    await until(tester, () => picker.files.isNotEmpty, 'save picker');
    expect(picker.files.single.$1, 'report.md');
    expect(utf8.decode(picker.files.single.$2), 'Nested original content');
    expect(
      find.descendant(
        of: find.byTooltip('Download'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    picker.pending.complete(Uri.parse('content://documents/nested-report'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Close subagent activity').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, true))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close subagent activity').hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'normal chat opens child timeline without selecting or controlling it',
    (tester) async {
      await showPanel(tester, scale: 1);
      final selected = controller.current!.chat;
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'child_session_id': 'child-session',
        'goal': 'Inspect the release',
      });
      await tester.pump();
      await tester.tap(find.text('Inspect the release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(SubagentTimeline), findsOneWidget);
      final child = tester
          .widget<SubagentTimeline>(find.byType(SubagentTimeline))
          .session;
      expect(child.messages.single['content'], 'Child saved evidence');
      expect(child.historyError, isNull);
      expect(child.liveError, isNull);
      expect(controller.current!.chat, same(selected));
      await tester.tap(find.text('Task').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final steerField = find.byType(TextField);
      await tester.ensureVisible(steerField);
      await tester.showKeyboard(steerField);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(steerField);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Steer'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding();
      tester.testTextInput.hide();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.tailCalls, 0);
      expect(
        fixture.requests.where(
          (call) => call.$1 == 'prompt.submit' || call.$1 == 'session.close',
        ),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Close subagent activity'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SubagentTimeline), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('child completion retains one Activity for saved and live tools', (
    tester,
  ) async {
    fixture.childMessages = [
      {'id': 1, 'role': 'user', 'content': 'Inspect the release'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': '**Check saved evidence**',
        'tool_calls': [
          for (var i = 0; i < 11; i++)
            {
              'id': 'call-$i',
              'function': {'name': 'read_file', 'arguments': '{}'},
            },
        ],
      },
      for (var i = 0; i < 11; i++)
        {
          'id': i + 3,
          'role': 'tool',
          'tool_call_id': 'call-$i',
          'content': 'Evidence $i',
        },
    ];
    fixture.childEvents.addAll([
      {'session_id': 'child-session', 'seq': 1, 'type': 'message.start'},
      {
        'session_id': 'child-session',
        'seq': 2,
        'type': 'tool.start',
        'payload': {
          'tool_id': 'submirror:child-session:1',
          'name': 'read_file',
          'preview': 'current.txt',
        },
      },
    ]);
    await showPanel(tester, scale: 1);
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'child_session_id': 'child-session',
      'goal': 'Inspect the release',
    });
    await tester.pump();
    await tester.tap(find.text('Inspect the release'));
    await until(
      tester,
      () => find.text('12 tools').evaluate().isNotEmpty,
      'the child timeline with saved and live tools',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-activity-toggle')),
        matching: find.text('12 tools'),
      ),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .whereType<String>()
          .join(' | '),
    );
    expect(find.byType(ProfileLiveExecution), findsOneWidget);
    await tester.openLiveActivity();
    expect(find.byType(ProfileActivitySection), findsOneWidget);
    fixture.childEvents.add({
      'session_id': 'child-session',
      'seq': 3,
      'type': 'message.complete',
      'payload': {'text': 'Final reply awaiting persistence'},
    });
    await tester.tap(find.byTooltip('Refresh subagent activity'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-activity-toggle')),
        matching: find.text('12 tools'),
      ),
      findsOneWidget,
      reason:
          'Saved work and the retained final replay must stay in one reply Activity',
    );
    expect(find.byType(ProfileLiveExecution), findsOneWidget);
    await tester.openLiveActivity();
    expect(find.byType(ProfileActivitySection), findsOneWidget);
    await tester.tap(find.byTooltip('Close subagent activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('child timeline keeps its visible Running pulse', (tester) async {
    await showPanel(tester, scale: 1, motion: true);
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'child_session_id': 'child-session',
      'goal': 'Inspect the release',
    });
    await tester.pump();
    await tester.tap(find.text('Inspect the release'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(SubagentTimeline), findsOneWidget);
    final sheet = find.ancestor(
      of: find.byType(SubagentTimeline),
      matching: find.byType(StudioLoadingFrame),
    );
    expect(sheet, findsOneWidget);
    final pulse = find.descendant(
      of: sheet,
      matching: find.byWidgetPredicate(
        (widget) => widget is StudioLoading && widget.label == 'Running',
      ),
    );
    void expectVisibleWork() {
      expect(pulse, findsOneWidget);
      final bounds = tester.getRect(pulse);
      final viewport =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);
      expect(bounds.isEmpty, isFalse);
      expect(viewport.intersect(bounds), bounds);
      final paint = find.descendant(
        of: pulse,
        matching: find.byType(CustomPaint),
      );
      expect(paint, findsOneWidget);
      expect(tester.getSize(paint).isEmpty, isFalse);
    }

    final taskHeader = find.descendant(
      of: sheet,
      matching: find.ancestor(
        of: find.text('Task'),
        matching: find.byType(ListTile),
      ),
    );
    expect(taskHeader, findsOneWidget);
    expectVisibleWork();
    await tester.tap(taskHeader);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectVisibleWork();
    await tester.tap(taskHeader);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectVisibleWork();
    await tester.tap(find.byTooltip('Close subagent activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'timeline steering stays visible and reports pending/rejection ${brightness.name} $scale',
        (tester) async {
          fixture.childMessages = [
            {'id': 1, 'role': 'user', 'content': 'Check source evidence'},
            {
              'id': 2,
              'role': 'assistant',
              'content': '',
              'reasoning':
                  '**Fixing database issues**\n\nCheck the retained parent and child rows before changing the query.',
              'tool_calls': [
                {
                  'id': 'saved',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{"path":"evidence.py"}',
                  },
                },
              ],
            },
            {
              'id': 3,
              'role': 'tool',
              'tool_call_id': 'saved',
              'content': 'Saved source evidence',
            },
          ];
          await showPanel(
            tester,
            brightness: brightness,
            scale: scale,
            size: scale == 1 ? const Size(390, 844) : const Size(320, 640),
          );
          emitChatEvent(controller, chat, 'subagent.start', {
            'subagent_id': 'child-1',
            'child_session_id': 'child-session',
            'goal': 'Inspect the release',
          });
          await tester.pump();
          await tester.tap(find.text('Inspect the release'));
          final field = find.byType(TextField);
          final steer = find.byTooltip('Steer');
          await until(
            tester,
            () =>
                field.hitTestable().evaluate().isNotEmpty &&
                steer.hitTestable().evaluate().isNotEmpty,
            'the child steering editor and action',
          );
          expect(field.hitTestable(), findsOneWidget);
          expect(steer.hitTestable(), findsOneWidget);
          expect(find.byTooltip('Interrupt'), findsOneWidget);
          await tester.openLiveActivity(tools: false);
          final reasoning = find.text('Fixing database issues');
          await tester.ensureVisible(reasoning);
          await tester.pump(const Duration(milliseconds: 300));
          expect(reasoning, findsOneWidget);
          expect(
            find.ancestor(of: reasoning, matching: find.byType(ExpansionTile)),
            findsNothing,
          );
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is MarkdownMessageContent &&
                  w.data.startsWith('**Fixing database issues**'),
            ),
            findsNothing,
          );
          expect(
            tester
                .getRect(reasoning)
                .overlaps(tester.getRect(find.byType(SubagentTimeline))),
            isTrue,
            reason:
                'Reasoning ${tester.getRect(reasoning)}; viewport ${tester.getRect(find.byType(SubagentTimeline))}',
          );
          await capture(tester, 'reasoning-${brightness.name}-$scale');
          await tester.enterText(field, 'Check the retained child rows');
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(steer.hitTestable(), findsOneWidget);
          final gate = Completer<void>();
          fixture.steerGate = gate;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          await tester.tap(steer);
          await tester.pump();
          expect(
            find.descendant(
              of: steer,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(tester.widget<TextField>(field).enabled, isFalse);
          final dispatches = fixture.requests
              .where((c) => c.$1 == 'subagent.steer')
              .length;
          await tester.tap(steer);
          await tester.pump();
          expect(
            fixture.requests.where((c) => c.$1 == 'subagent.steer'),
            hasLength(dispatches),
          );
          final request = fixture.requests.lastWhere(
            (c) => c.$1 == 'subagent.steer',
          );
          expect(request.$2['session_id'], chat.runtime.runtimeId);
          expect(request.$2['subagent_id'], 'child-1');
          expect(request.$2['text'], 'Check the retained child rows');
          await capture(tester, 'steering-pending-${brightness.name}-$scale');
          gate.complete();
          await until(
            tester,
            () => find.text('Steer rejected').evaluate().isNotEmpty,
            'the rejected steering result',
          );
          expect(
            find.descendant(
              of: find.byType(StudioError),
              matching: find.text('Steer rejected'),
            ),
            findsOneWidget,
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Check the retained child rows',
          );
          expect(steer.hitTestable(), findsOneWidget);
          final rejected = find.text('Steer rejected');
          final feedbackViewport = find
              .ancestor(
                of: rejected,
                matching: find.byType(SingleChildScrollView),
              )
              .last;
          final viewportRect = tester.getRect(feedbackViewport);
          final messageRect = tester.getRect(rejected);
          if (messageRect.bottom > viewportRect.bottom) {
            // Larger fallback glyphs may wrap beyond the bounded viewport.
            await tester.drag(feedbackViewport, const Offset(0, -120));
            await tester.pumpAndSettle();
            expect(
              tester.getRect(rejected).bottom,
              lessThanOrEqualTo(viewportRect.bottom),
            );
          } else {
            expect(viewportRect.intersect(messageRect), messageRect);
          }
          await capture(tester, 'steering-rejected-${brightness.name}-$scale');
          fixture.steerGate = null;
          fixture.failSteer = true;
          await tester.tap(steer);
          await until(
            tester,
            () => find.text('Steering failed').evaluate().isNotEmpty,
            'the failed steering result',
          );
          expect(find.text('Steering failed'), findsOneWidget);
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Check the retained child rows',
          );
          fixture.failSteer = false;
          fixture.acceptSteer = true;
          await tester.tap(steer);
          await until(
            tester,
            () =>
                find.text('Steering queued.').evaluate().isNotEmpty &&
                tester.widget<TextField>(field).controller!.text.isEmpty,
            'accepted steering to clear the submitted draft',
          );
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          expect(find.text('Steering queued.'), findsOneWidget);
          await capture(tester, 'steering-queued-${brightness.name}-$scale');
          // A newer draft must survive acceptance of the captured submission.
          await tester.enterText(field, 'Original guidance');
          final acceptedGate = Completer<void>();
          fixture.steerGate = acceptedGate;
          addTearDown(() {
            if (!acceptedGate.isCompleted) acceptedGate.complete();
          });
          await tester.tap(steer);
          await tester.pump();
          tester.widget<TextField>(field).controller!.text = 'Newer guidance';
          acceptedGate.complete();
          await until(
            tester,
            () => tester.widget<TextField>(field).enabled != false,
            'the held steering submission to finish',
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Newer guidance',
          );

          tester.view.viewInsets = const FakeViewPadding();
          tester.testTextInput.hide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          fixture.failInterrupt = true;
          await tester.tap(find.byTooltip('Interrupt'));
          final interruptError = find.descendant(
            of: find.byType(StudioError),
            matching: find.text('Interrupt failed'),
          );
          await until(
            tester,
            () => interruptError.evaluate().isNotEmpty,
            'the failed interrupt result',
          );
          expect(find.byTooltip('Interrupt').hitTestable(), findsOneWidget);
          await capture(tester, 'interrupt-error-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Close subagent activity'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'agent timing is backend-derived and stops on completion or uncertainty',
    (tester) async {
      fixture.startedAt = DateTime.now().millisecondsSinceEpoch / 1000 - 40;
      await showPanel(tester);
      expect(find.text('Reading file'), findsOneWidget);
      expect(find.text('test-model · 3 tool calls'), findsOneWidget);
      var time = tester.widget<ActivityTime>(find.byType(ActivityTime));
      expect(time.backendStartedAt, fixture.startedAt);
      emitChatEvent(controller, chat, 'subagent.complete', {
        'subagent_id': 'child-1',
        'status': 'completed',
        'summary': 'Inspection finished',
        'duration_seconds': 42.5,
      });
      await tester.pump();
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Inspection finished'), findsOneWidget);
      time = tester.widget<ActivityTime>(find.byType(ActivityTime));
      expect(time.backendStartedAt, isNull);
      expect(time.durationSeconds, 42.5);
      expect(find.text('43 s'), findsOneWidget);
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'uncertain',
        'goal': 'Check another source',
        'started_at': fixture.startedAt,
      });
      fixture.emptyList = true;
      await supervision.refreshSubagents();
      await tester.pump();
      expect(find.text('Last seen running'), findsOneWidget);
      expect(
        tester
            .widgetList<ActivityTime>(find.byType(ActivityTime))
            .every((w) => w.backendStartedAt == null),
        isTrue,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'agent states and metadata remain readable ${brightness.name} $scale',
        (tester) async {
          const longGoal =
              'Inspect the release candidate and verify the Android transport settings. Keep every original instruction in the task body.';
          const heading =
              'Inspect the release candidate and verify the Android transport settings';
          fixture.rows = [
            {
              'subagent_id': 'child-1',
              'goal': longGoal,
              'status': 'running',
              'last_tool': 'read_file',
              'model': 'test-model',
              'accepting_steer': true,
            },
            {
              'subagent_id': 'queued',
              'goal': 'Compare suppliers',
              'status': 'queued',
              'started_at': 1000,
            },
          ];
          for (final status in ['completed', 'failed', 'interrupted']) {
            emitChatEvent(controller, chat, 'subagent.complete', {
              'subagent_id': status,
              'goal': 'Research $status',
              'status': status,
              'summary': 'Result for $status',
              'duration_seconds': 1.25,
            });
          }
          await showPanel(tester, brightness: brightness, scale: scale);
          final title = tester.widget<Text>(find.text(heading));
          expect(title.maxLines, 2);
          expect(title.overflow, TextOverflow.ellipsis);
          expect(find.text(longGoal), findsNothing);
          for (final label in [
            'Running',
            'Queued',
            'Completed',
            'Failed',
            'Interrupted',
          ]) {
            expect(find.text(label), findsOneWidget);
          }
          final queuedRow = find.byKey(
            ValueKey(('subagent', chat.key, 'queued')),
          );
          final queuedTime = tester.widget<ActivityTime>(
            find.descendant(of: queuedRow, matching: find.byType(ActivityTime)),
          );
          expect(queuedTime.backendStartedAt, isNull);
          expect(queuedTime.durationSeconds, isNull);
          await tester.ensureVisible(find.text(heading));
          await tester.pumpAndSettle();
          await tester.tap(find.text(heading));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text(longGoal), findsOneWidget);
          expect(find.byTooltip('Copy Task'), findsOneWidget);
          Navigator.of(tester.element(find.text(longGoal))).pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a terminal tool name is activity context, not a reported result',
    (tester) async {
      fixture.rows = [
        {
          'subagent_id': 'child-1',
          'goal': 'Inspect the release',
          'status': 'completed',
          'last_tool': 'read_file',
        },
      ];
      await openDetails(tester);
      await tester.pumpAndSettle();
      expect(find.text('Reported result'), findsNothing);
      expect(find.textContaining('Last activity:'), findsOneWidget);
      expect(find.byTooltip('Copy Current activity'), findsNothing);
      expect(find.byTooltip('Steer'), findsNothing);
      expect(find.byTooltip('Interrupt'), findsNothing);
      Navigator.of(tester.element(find.text('Task'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('backend metadata remains passive beside existing controls', (
    tester,
  ) async {
    await openDetails(tester);
    await tester.ensureVisible(find.byTooltip('Expand Raw details'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand Raw details'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy Raw details'), findsNothing);
    expect(find.byTooltip('Open Raw details'), findsNothing);
    expect(find.byTooltip('Wrap Raw details'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText &&
            widget.text.contains('Agent ID: child-1'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Copy Task'), findsOneWidget);
    expect(find.byTooltip('Copy Live output'), findsOneWidget);
    Navigator.of(tester.element(find.text('Raw details'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('refresh retains two live event children beside a failed child', (
    tester,
  ) async {
    fixture.emptyList = true;
    emitChatEvent(controller, chat, 'subagent.complete', {
      'subagent_id': 'failed',
      'goal': 'Timed out research',
      'status': 'timeout',
    });
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'one',
      'goal': 'Research one',
    });
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'two',
      'goal': 'Research two',
    });
    await showPanel(tester);
    expect(chat.subagents.map((item) => item.id), ['failed', 'one', 'two']);
    expect(find.text('Research one'), findsOneWidget);
    expect(find.text('Research two'), findsOneWidget);
    expect(find.text('1 finished'), findsNothing);
  });

  testWidgets(
    'detail shows received activity when the server has no transcript',
    (tester) async {
      fixture.tailAvailable = false;
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'goal': 'Inspect the release',
      });
      emitChatEvent(controller, chat, 'subagent.tool', {
        'subagent_id': 'child-1',
        'tool_name': 'read_file',
        'tool_preview': 'Checking android/app/build.gradle.kts',
      });
      await openDetails(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recent activity'),
        160,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.byTooltip('Copy Live output'), findsNothing);
      expect(find.byTooltip('Open Live output'), findsNothing);
      expect(find.byTooltip('Copy Current activity'), findsNothing);
      expect(find.byTooltip('Refresh live output'), findsOneWidget);
      expect(find.byTooltip('Copy Recent activity'), findsNothing);
      expect(
        find.textContaining('Checking android/app/build.gradle.kts').last,
        findsOneWidget,
      );
      Navigator.of(tester.element(find.text('Live output'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'an unavailable tail refresh preserves the output already received',
    (tester) async {
      await openDetails(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        160,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        findsOneWidget,
      );
      fixture.tailAvailable = false;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        findsOneWidget,
      );
      fixture.tailFailures = fixture.tailCalls + 1;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Could not refresh live output.'), findsNothing);
      expect(find.text('Showing the last received output.'), findsOneWidget);

      final refresh = find.byTooltip('Refresh live output');
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      fixture.tailGate = gate;
      fixture.tailFailures = fixture.tailCalls + 1;
      await tester.tap(refresh);
      await tester.pump();
      expect(
        find.descendant(
          of: refresh,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(StudioError),
          matching: find.text('Could not refresh live output.'),
        ),
        findsOneWidget,
      );
      expect(find.text('Showing the last received output.'), findsOneWidget);
      Navigator.of(tester.element(find.text('Live output'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('shows live tail and keeps rejected steering text', (
    tester,
  ) async {
    await openDetails(tester);

    expect(fixture.tailCalls, 1);
    await tester.scrollUntilVisible(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText && widget.text == 'latest child output',
      ),
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText && widget.text == 'latest child output',
      ),
      findsOneWidget,
    );
    expect(find.byType(SourceCodeText), findsWidgets);
    expect(find.byTooltip('Steer'), findsOneWidget);
    expect(find.byTooltip('Interrupt'), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(find.byType(TextField), 'Check the Android path');
    final steerButton = find.byTooltip('Steer');
    await tester.ensureVisible(steerButton);
    await tester.pumpAndSettle();
    await tester.tap(steerButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Steer rejected'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Check the Android path',
    );
    expect(chat.subagents.single.status.name, 'running');
    final steer = fixture.requests.lastWhere(
      (call) => call.$1 == 'subagent.steer',
    );
    expect(steer.$2['session_id'], chat.runtime.runtimeId);
    expect(steer.$2['subagent_id'], 'child-1');
    expect(steer.$2['text'], 'Check the Android path');

    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'populated event roster refreshes authoritative steering capability',
    (tester) async {
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'goal': 'Inspect the release',
        'status': 'running',
        'model': 'test-model',
      });
      expect(chat.subagents.single.acceptingSteer, isFalse);

      await showPanel(tester);

      expect(fixture.listCalls, 1);
      expect(chat.subagents.single.acceptingSteer, isTrue);
      await tester.ensureVisible(find.text('Inspect the release'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect the release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Steer'), findsOneWidget);

      Navigator.of(tester.element(find.byTooltip('Steer'))).pop();
      await tester.pumpAndSettle();
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'tail polling stops after three failures and Retry restarts it ${brightness.name} $scale',
        (tester) async {
          fixture.tailFailures = 3;
          await openDetails(
            tester,
            brightness: brightness,
            scale: scale,
            size: scale == 1 ? const Size(390, 844) : const Size(320, 640),
          );
          await tester.pump(const Duration(seconds: 2));
          await tester.pump(const Duration(seconds: 2));

          expect(fixture.tailCalls, 3);
          await tester.scrollUntilVisible(
            find.text('Could not refresh live output.'),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.descendant(
              of: find.byType(StudioError),
              matching: find.text('Could not refresh live output.'),
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(find.byType(StudioError));
          await tester.pump();
          await capture(tester, 'tail-error-${brightness.name}-$scale');
          expect(find.byTooltip('Retry'), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
          expect(fixture.tailCalls, 3);

          await tester.ensureVisible(find.byTooltip('Retry'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Retry'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.scrollUntilVisible(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SourceCodeText &&
                  widget.text == 'latest child output',
            ),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SourceCodeText &&
                  widget.text == 'latest child output',
            ),
            findsOneWidget,
          );

          Navigator.of(tester.element(find.text('Live output'))).pop();
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final status in ['running', 'completed']) {
    testWidgets(
      'settled conversation ${status == 'completed' ? 'retires completed' : 'keeps running'} subagents in the bottom dock',
      (tester) async {
        fixture.rows = [
          {
            'subagent_id': 'child-1',
            'goal': 'Inspect the release',
            'status': status,
          },
        ];
        await controller.refreshSubagents(chat);
        chat.reading.installSavedHistory([
          {'id': 1, 'role': 'user', 'content': 'Inspect the release'},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'The inspection is finished.',
          },
        ]);
        emitChatEvent(controller, chat, 'message.complete', {});
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(chat.runtime.executionActive, isFalse);
        expect(chat.reading.streamingMessage, isNull);
        if (status == 'completed') {
          expect(find.byType(ProfileLiveWorkDock), findsNothing);
          expect(find.byType(ProfileSubagentPanel), findsNothing);
          expect(tester.takeException(), isNull);
          return;
        }
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.byType(ProfileLiveExecution), findsNothing);
        expect(find.text('Activity'), findsNothing);
        expect(find.byType(ProfileSubagentPanel), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey(('live-work-tab', 0, false))),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey(('activity-tab', 'agents'))),
          findsNothing,
        );
        expect(find.byType(ProfileSubagentPanel), findsOneWidget);
        expect(find.text('Running'), findsOneWidget);
        final agent = find.byKey(ValueKey(('subagent', chat.key, 'child-1')));
        await tester.ensureVisible(agent);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: agent,
            matching: find.byIcon(Icons.chevron_right),
          ),
        );
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(find.text('Task'), findsOneWidget);
        expect(find.byTooltip('Copy Task'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        emitChatEvent(controller, chat, 'message.start', {});
        emitChatEvent(controller, chat, 'message.delta', {
          'text': 'The next answer is streaming.',
        });
        await tester.pump();
        await tester.settleMarkdown();
        await tester.pump(const Duration(milliseconds: 300));
        expect(chat.runtime.executionActive, isTrue);
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.byType(ProfileSubagentPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('live work Subagents opens this chat subagent roster', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    emitChatEvent(controller, chat, 'message.start', {});
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'goal': 'Inspect the release',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Inspect the release'), findsNothing);

    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, false))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Inspect the release').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Inspect the release'), findsOneWidget);
    expect(fixture.listCalls, 1);
  });
}
