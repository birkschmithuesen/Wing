import 'dart:async';

import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/email_composer.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/web_preview.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/adaptive_markdown_table.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> message(
    WidgetTester tester,
    String content, {
    String role = 'assistant',
    bool streaming = false,
  }) async {
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ProfileMessage(
                message: TranscriptMessage.fromRow({
                  'id': 1,
                  'role': role,
                  'content': content,
                  'tool_name': 'terminal',
                }, streaming: streaming),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('only explicit web URLs can launch', () {
    expect(externalWebLink('https://example.com/path'), isNotNull);
    expect(externalWebLink('http://host:9119/docs'), isNotNull);
    for (final uri in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'intent://launch',
      'data:text/html,hello',
      '/host/file',
      '//example.com',
      'https://user:password@example.com',
      'https:missing-host',
    ]) {
      expect(externalWebLink(uri), isNull, reason: uri);
    }
  });

  testWidgets('formatted prose, lists and tables render on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const content =
        '# Result\n\n**Ready** and `inline`.\n\n- First\n- Second\n\n'
        '| Name | Status |\n| --- | --- |\n| A long project name | Ready |';
    await message(tester, content);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is MarkdownBody && widget.data == content,
      ),
      findsOneWidget,
    );
    expect(find.text('Result'), findsOneWidget);
    final table = find.byType(AdaptiveMarkdownTable);
    expect(table, findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    for (final text in ['Name', 'Status', 'A long project name', 'Ready']) {
      expect(
        find.descendant(
          of: table,
          matching: find.text(text, findRichText: true),
        ),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('code preserves whitespace and supports copy and wrapping', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const code = '  final value = 42;\n';
    await message(tester, 'Example\n\n```dart\n$code```\n\nDone.');
    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, code);
    expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
    await tester.tap(find.byTooltip('Scroll horizontally'));
    await tester.pump();
    expect(find.byTooltip('Wrap lines'), findsOneWidget);
    await tester.tap(find.byTooltip('Wrap lines'));
    await tester.pump();
    expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(copied, contains('```dart'));
  });

  testWidgets('user text stays literal', (tester) async {
    await message(tester, '**Literal** `draft`', role: 'user');
    expect(find.text('**Literal** `draft`'), findsOneWidget);
    expect(find.bySubtype<MarkdownBody>(), findsNothing);
  });

  testWidgets('streaming fences tolerate partial input', (tester) async {
    await message(tester, 'Working\n```dart\nfinal value =', streaming: true);
    expect(find.byTooltip('Copy message'), findsNothing);
    expect(tester.takeException(), isNull);
    await message(
      tester,
      'Working\n```dart\nfinal value = 42;\n```',
      streaming: true,
    );
    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('images render inline and unsafe links show a scoped error', (
    tester,
  ) async {
    await message(
      tester,
      '![Remote image](https://example.com/image.png)\n\n[Unsafe link](javascript:run)',
    );
    expect(
      find.descendant(
        of: find.byType(MarkdownMessageContent),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(MarkdownMessageContent),
        matching: find.byType(Image),
      ),
    );
    expect(image.semanticLabel, 'Open image: Remote image');
    await tester.tap(find.text('Unsafe link', findRichText: true));
    await tester.pump();
    expect(
      find.text(
        'Only web links, email links and linked Hermes files can be opened here.',
      ),
      findsOneWidget,
    );
  });

  for (final content in [
    '<alex@example.com>',
    '[Email hotel](mailto:alex@example.com?subject=Luggage%20storage&body=Hello%0AThank%20you&cc=other%2Btrip@example.com)',
  ]) {
    testWidgets('email link opens the compose chooser: $content', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          EmailComposer.channel,
          null,
        ),
      );
      await message(tester, content);
      await tester.tap(
        find.text(
          content.startsWith('<') ? 'alex@example.com' : 'Email hotel',
          findRichText: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.single.method, 'compose');
      expect(
        calls.single.arguments,
        content.startsWith('<')
            ? 'mailto:alex@example.com'
            : content.substring(content.indexOf('(') + 1, content.length - 1),
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final fails in [false, true]) {
    testWidgets('email handoff shows progress and settles (failure: $fails)', (
      tester,
    ) async {
      final reply = Completer<bool>();
      var calls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        (call) {
          calls++;
          return reply.future;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          EmailComposer.channel,
          null,
        ),
      );
      await tester.pumpMarkdownWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: const MarkdownMessageContent(
              data: '[Email](mailto:a@example.com)',
            ),
          ),
        ),
      );
      await tester.tap(find.text('Email', findRichText: true));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      await tester.tap(find.text('Email', findRichText: true));
      await tester.pump();
      expect(calls, 1);
      if (fails) {
        reply.completeError(PlatformException(code: 'unavailable'));
      } else {
        reply.complete(true);
      }
      await tester.pumpAndSettle();
      expect(find.byType(StudioLoading), findsNothing);
      expect(
        find.text(
          'Could not open an email app. Install or enable one and try again.',
        ),
        fails ? findsOneWidget : findsNothing,
      );
      expect(find.text('Email', findRichText: true), findsOneWidget);
    });
  }

  testWidgets('missing email app reports failure and permits another attempt', (
    tester,
  ) async {
    var calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      EmailComposer.channel,
      (call) async => ++calls > 1,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        null,
      ),
    );
    await message(tester, '[Email](mailto:a@example.com)');
    await tester.tap(find.text('Email', findRichText: true));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not open an email app. Install or enable one and try again.',
      ),
      findsOneWidget,
    );
    final emailLink = find.text('Email', findRichText: true);
    expect(emailLink.hitTestable(), findsOneWidget);
    await tester.tap(emailLink);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('departed message ignores a late failed email handoff', (
    tester,
  ) async {
    final reply = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      EmailComposer.channel,
      (_) => reply.future,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        EmailComposer.channel,
        null,
      ),
    );
    await message(tester, '[Email](mailto:a@example.com)');
    await tester.tap(find.text('Email', findRichText: true));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Other page'))),
    );
    reply.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'email composer rejects non-email schemes without platform dispatch',
    () async {
      for (final link in [
        'https://example.com',
        'intent://launch',
        'file:///tmp/a',
      ]) {
        expect(await EmailComposer.open(link), isFalse);
      }
    },
  );

  testWidgets('assistant file links keep their exact remote target', (
    tester,
  ) async {
    String? openedPath;
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(const {
              'role': 'assistant',
              'content': '[Open report](../exports/final-report.pdf)',
            }),
            onOpenRemoteFile: (output) async => openedPath = output.path,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pump();

    expect(openedPath, '../exports/final-report.pdf');
  });

  testWidgets('assistant file links explain an authentication failure', (
    tester,
  ) async {
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow(const {
              'role': 'assistant',
              'content': '[Missing report](/srv/removed/report.pdf)',
            }),
            onOpenRemoteFile: (_) async =>
                throw const DashboardHttpException(401, 'files/read'),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Hermes could not authenticate this session. Reconnect, then try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tool output starts collapsed and expands as plain text', (
    tester,
  ) async {
    await message(tester, '**raw output**\nexit code 0', role: 'tool');
    expect(find.text('Ran command'), findsOneWidget);
    expect(find.textContaining('exit code 0'), findsNothing);
    await tester.tap(find.text('Ran command'));
    await tester.pumpAndSettle();
    expect(find.text('**raw output**\nexit code 0'), findsOneWidget);
    expect(find.bySubtype<MarkdownBody>(), findsNothing);
  });

  group('conversation controls', () {
    late ProfileWorkspaceController controller;
    late AppPreferences appPreferences;
    late ProfileHistoryFixture host;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      host = ProfileHistoryFixture();
      final preferences = await SharedPreferences.getInstance();
      appPreferences = AppPreferences(preferences);
      controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'conversation-test',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      await controller.initialize();
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'chat-0'),
      );
    });
    tearDown(() {
      controller.dispose();
      appPreferences.dispose();
    });
    Future<void> show(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => []),
          ),
        ),
      );
      if (controller.current!.chat!.runtime.blocksTurnAdmission) {
        await tester.pump(const Duration(milliseconds: 300));
      } else {
        await tester.pumpAndSettle();
      }
    }

    testWidgets('large text with a keyboard keeps the composer usable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => []),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        'One\nTwo\nThree\nFour\nFive\nSix',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'composer keeps text above model controls with full tap targets',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await show(tester);
        expect(
          tester
              .getBottomLeft(find.byKey(const Key('profile-message-composer')))
              .dy,
          lessThanOrEqualTo(
            tester
                .getTopLeft(find.byKey(const Key('chat-intelligence-button')))
                .dy,
          ),
        );
        for (final tooltip in ['Attach file', 'Send']) {
          expect(
            tester.getSize(find.byTooltip(tooltip)).height,
            greaterThanOrEqualTo(48),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'empty send disabled, multiline draft survives profile navigation',
      (tester) async {
        await show(tester);
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('Send'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
        final field = find.byKey(const Key('profile-message-composer'));
        await tester.enterText(field, 'First line\nSecond line');
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('Send'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester.widget<TextField>(field).textInputAction,
          TextInputAction.newline,
        );
        await controller.navigateProfile('work');
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'chat-0'),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        await controller.navigateProfile('personal');
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'chat-0'),
        );
        await tester.settleTranscript();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          'First line\nSecond line',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets('working status allows drafting and holding to stop', (
      tester,
    ) async {
      final chat = controller.current!.chat!;
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'message.delta', {
        'text': 'A partial response',
      });
      await show(tester);
      expect(find.text('Writing response…'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsOneWidget);
      expect(find.byTooltip('Send'), findsNothing);
      expect(find.text('Draft your next message'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'For later');
      await tester.pump();
      expect(find.byTooltip('Steer'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Steer')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('composer-choice-stop'))),
      );
      await gesture.up();
      // Interrupt acknowledgement is not a terminal event. The truthful
      // working spinner keeps animating until the runtime confirms stopping.
      await tester.pump(const Duration(milliseconds: 300));
      final interrupt = host.calls.singleWhere(
        (call) => call.$2 == 'session.interrupt',
      );
      expect(interrupt.$3['profile'], 'personal');
      expect(chat.composer.observation.text, 'For later');
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('Latest returns to the tail without losing loaded pages', (
      tester,
    ) async {
      await show(tester);
      final list = find.byKey(const ValueKey('profile-transcript'));
      await tester.drag(list, const Offset(0, 550));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('jump-to-latest')), findsOneWidget);
      final count = controller.current!.chat!.reading.messages.length;
      await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
      await tester.pumpAndSettle();
      expect(controller.current!.chat!.reading.readingPosition.resume, isNull);
      expect(controller.current!.chat!.reading.messages.length, count);
      expect(find.byKey(const ValueKey('jump-to-latest')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
