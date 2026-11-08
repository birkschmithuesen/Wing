import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'support/profile_history_fixture.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/email_draft.dart';
import 'package:wing/core/services/email_composer.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/email_draft_card.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'helpers/pump_markdown_widget.dart';
import 'support/form_family_capture.dart';

class _RealHttp extends HttpOverrides {}

const reference = EmailDraftReference('d_0123456789abcdef0123456789abcdef', 1);
const card =
    '```wing-email-draft\n{"id":"d_0123456789abcdef0123456789abcdef","version":1}\n```';
EmailDraft draft({
  String body =
      'Hello Alex,\n\nCould you review the project notes before our meeting?\n\nThank you.',
}) => EmailDraft.fromJson(reference, {
  'id': reference.id,
  'version': 1,
  'fields': {
    'to': ['alex@example.com'],
    'cc': ['team+review@example.com'],
    'bcc': ['archive@example.com'],
    'subject': 'Project update',
    'body': body,
  },
});

Future<void> show(
  WidgetTester tester,
  Future<EmailDraft> Function(EmailDraftReference) read, {
  String data = card,
  bool streaming = false,
  Object owner = 'alice',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => tester.pumpMarkdownWidget(
  MaterialApp(
    theme: wingTheme(brightness),
    home: RepaintBoundary(
      key: formFamilyCapture,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Project email'),
          actions: const [StudioLoadingSlot()],
        ),
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: EmailDraftScope(
            owner: owner,
            read: read,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: MarkdownMessageContent(data: data, streaming: streaming),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(loadFormFamilyFonts);
  test(
    'workspace transport retains original profile across navigation and recovers from 404',
    () => HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Uri>[];
      final received = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        requests.add(request.uri);
        if (requests.length == 1) {
          received.complete();
          await release.future;
          request.response.statusCode = 404;
          request.response.write('{"detail":"Draft version not found"}');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'id': reference.id,
              'version': 1,
              'fields': {
                'to': ['hotel@example.com'],
                'cc': [],
                'bcc': [],
                'subject': 'Original profile',
                'body': 'Exact body',
              },
            }),
          );
        }
        await request.response.close();
      });
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'draft-server',
            apiKey: 'fixture',
            label: 'Fixture',
            host: server.address.address,
            port: server.port,
            dashboardPortOverride: server.port,
            dashboardProxied: true,
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'draft-origin',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: ProfileHistoryFixture().gateway,
      );
      addTearDown(() async {
        controller.dispose();
        appPreferences.dispose();
        await server.close(force: true);
      });
      await controller.initialize();
      final chat = (await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'chat-0'),
      ))!;
      final reading = controller.readEmailDraft(chat, reference);
      final failure = expectLater(
        reading,
        throwsA(isA<DashboardHttpException>()),
      );
      await received.future.timeout(const Duration(seconds: 5));
      await controller.switchProfile('work');
      release.complete();
      await failure;
      final recovered = await controller.readEmailDraft(chat, reference);
      expect(recovered.subject, 'Original profile');
      expect(requests, hasLength(2));
      expect(
        requests.every((uri) => uri.queryParameters['profile'] == 'personal'),
        isTrue,
      );
      expect(
        requests.last.path,
        '/api/plugins/wing/drafts/v1/${reference.id}/versions/1',
      );
    }, _RealHttp()),
  );
  test('reference is strict and response must identify the exact version', () {
    expect(
      EmailDraftReference.parse('{"id":"../outside","version":1}'),
      isNull,
    );
    expect(
      EmailDraftReference.parse(jsonEncode({'id': reference.id, 'version': 0})),
      isNull,
    );
    expect(
      () => EmailDraft.fromJson(reference, {'id': reference.id, 'version': 2}),
      throwsFormatException,
    );
  });
  test('complete long Unicode body and fields survive mailto encoding', () {
    final body = 'Hello 日本 & + ? #\n${'Full body. ' * 1300}';
    final uri = Uri.parse(draft(body: body).mailto);
    expect(Uri.decodeComponent(uri.path), 'alex@example.com');
    expect(uri.queryParameters, {
      'cc': 'team+review@example.com',
      'bcc': 'archive@example.com',
      'subject': 'Project update',
      'body': body,
    });
    expect(uri.toString(), contains('%20'));
    expect(uri.toString(), startsWith('mailto:alex@example.com?'));
  });
  testWidgets(
    'production markdown loads exact reference and opens complete fields',
    (tester) async {
      final reads = <EmailDraftReference>[];
      final load = Completer<EmailDraft>();
      final open = Completer<bool>();
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        (call) {
          calls.add(call);
          return open.future;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          EmailComposer.channel,
          null,
        ),
      );
      await show(tester, (ref) {
        reads.add(ref);
        return load.future;
      });
      expect(reads, [reference]);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await captureFormFamily(tester, 'email-draft-loading');
      load.complete(draft());
      await tester.pumpAndSettle();
      expect(find.text('Project update'), findsOneWidget);
      await tester.tap(find.byTooltip('Open in email app'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(find.text('Project update'), findsOneWidget);
      await tester.tap(find.byTooltip('Open in email app'));
      expect(calls, hasLength(1));
      expect(calls.single.method, 'compose');
      expect(calls.single.arguments, draft().mailto);
      await captureFormFamily(tester, 'email-draft-opening');
      open.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.textContaining('sent'), findsNothing);
    },
  );
  testWidgets(
    'failed read retries and missing email app keeps draft for retry',
    (tester) async {
      var reads = 0, opens = 0;
      final retry = Completer<EmailDraft>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        (_) async => ++opens > 1,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          EmailComposer.channel,
          null,
        ),
      );
      await show(tester, (_) {
        reads++;
        return reads == 1 ? Future.error(Exception('offline')) : retry.future;
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry loading draft'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      retry.complete(draft());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open in email app'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Install or enable'), findsOneWidget);
      await tester.tap(find.byTooltip('Open in email app'));
      await tester.pumpAndSettle();
      expect(opens, 2);
      expect(find.textContaining('Install or enable'), findsNothing);
    },
  );
  testWidgets('departure and profile replacement ignore late results', (
    tester,
  ) async {
    final old = Completer<EmailDraft>();
    await show(tester, (_) => old.future);
    await show(tester, (_) async => draft(body: 'Bob draft'), owner: 'bob');
    await tester.pumpAndSettle();
    old.complete(draft(body: 'Alice draft'));
    await tester.pumpAndSettle();
    expect(find.text('Bob draft'), findsOneWidget);
    expect(find.text('Alice draft'), findsNothing);
    final open = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      EmailComposer.channel,
      (_) => open.future,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        null,
      ),
    );
    await tester.tap(find.byTooltip('Open in email app'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    open.completeError(PlatformException(code: 'no-app'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('streaming and malformed references do not fetch drafts', (
    tester,
  ) async {
    var reads = 0;
    Future<EmailDraft> read(EmailDraftReference _) async {
      reads++;
      return draft();
    }

    await show(tester, read, streaming: true);
    expect(reads, 0);
    await show(tester, read);
    await tester.pumpAndSettle();
    expect(reads, 1);
    await show(
      tester,
      read,
      data: '```wing-email-draft\n{"id":"bad","version":1}\n```',
    );
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byTooltip('Open in email app'), findsNothing);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('phone draft ${brightness.name} text $scale', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(
          tester,
          (_) async => draft(),
          brightness: brightness,
          scale: scale,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Open in email app'), findsOneWidget);
        await captureFormFamily(
          tester,
          'email-draft-${brightness.name}-$scale',
        );
      });
    }
  }
}
