import 'package:wing/core/services/bots_session.dart';
import 'support/form_family_capture.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/models/transcript_position.dart';
import 'package:wing/core/services/conversation_reading_memory.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/browser_actions.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'support/chat_browser_interactions.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_chat_indicator.dart';
import 'package:wing/core/widgets/chat_status_dot.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  const capture = bool.fromEnvironment('CAPTURE_CHAT_RENAME');
  const captureKey = ValueKey('chat-rename-capture');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  late _RenameActionsFixture host;
  late ProfileWorkspaceController controller;
  late ChatBrowserData browser;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _RenameActionsFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'actions',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    browser = ChatBrowserData(controller);
  });
  tearDown(() {
    browser.dispose();
    controller.dispose();
    appPreferences.dispose();
  });
  ProfileSessionKey key([String id = 'newest']) =>
      ProfileSessionKey(controller.current!.scope, id);
  Future<void> keepBeforeNewDelete() async {
    final owner = key();
    final attempts = host.deleteAttempts.length;
    expect(controller.current!.quarantinedSessions, contains(owner.sessionId));
    expect(
      controller.current!.sessions.any((row) => row['id'] == owner.sessionId),
      isTrue,
    );
    await expectLater(
      controller.mutateSession(owner, delete: true, canDispatch: () => true),
      throwsStateError,
    );
    expect(host.deleteAttempts, hasLength(attempts));
    await controller.inspectDeletedDraftCleanup(owner);
    final recovery = controller.deletedDraftCleanupPresentation.value.entries
        .singleWhere((entry) => entry.key == owner);
    expect(recovery.actions.map((action) => action.label), [
      'Check chat',
      'Keep chat',
    ]);
    await controller.keepPreparedSession(owner);
    expect(
      controller.current!.quarantinedSessions,
      isNot(contains(owner.sessionId)),
    );
    expect(host.deleteAttempts, hasLength(attempts));
  }

  Future<void> showWorkspace(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool capture = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: capture
                ? true
                : MediaQuery.disableAnimationsOf(context),
          ),
          child: capture
              ? RepaintBoundary(key: formFamilyCapture, child: child!)
              : child!,
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester) async {
    await showWorkspace(tester);
    await filterChatsToProfile(tester, 'personal');
  }

  Future<void> menu(
    WidgetTester tester,
    String id, {
    bool overflow = false,
  }) async {
    final row = find.byKey(ValueKey('chat-personal-$id'));
    await tester.scrollUntilVisible(
      row,
      240,
      scrollable: find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is ListView && widget.scrollDirection == Axis.vertical,
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await Scrollable.ensureVisible(tester.element(row), alignment: 0.45);
    await tester.pumpAndSettle();
    if (overflow) {
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Chat actions')),
      );
    } else {
      await tester.longPress(row);
    }
    await tester.pumpAndSettle();
  }

  Future<void> waitForHistoryRead() async {
    for (var tick = 0; tick < 100; tick++) {
      if (host.reads.any((read) => read.$1.endsWith('/messages'))) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('Expected history read to start before navigation or mutation');
  }

  Future<void> loadNewestUnread() async {
    host.changes.putIfAbsent('personal', () => {})['newest'] = {'unread': true};
    await controller.refresh();
    host.updates.clear();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'rename form retains held/failing draft ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: wingTheme(brightness),
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
            ),
          );
          await tester.pumpAndSettle();
          await filterChatsToProfile(tester, 'personal');
          await menu(tester, 'newest');
          await tester.tap(find.text('Rename'));
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('chat-rename-title'));
          await tester.enterText(field, 'Keep this name');
          await captureFormFamily(
            tester,
            'rename-${brightness.name}-$scale-normal',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pumpAndSettle();
          await captureFormFamily(
            tester,
            'rename-${brightness.name}-$scale-keyboard',
          );
          final confirm = find.byKey(const ValueKey('chat-rename-save'));
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(584));
          expect(
            tester.getSize(confirm).shortestSide,
            greaterThanOrEqualTo(48),
          );
          host.mutationDelay = Completer<void>();
          host.failMutation = true;
          await tester.tap(confirm);
          await tester.pump();
          expect(find.text('Rename chat'), findsOneWidget);
          expect(find.bySemanticsLabel('Saving chat title'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 200));
          await captureFormFamily(
            tester,
            'rename-${brightness.name}-$scale-saving',
          );
          expect(host.updates, hasLength(1));
          expect(tester.widget<IconButton>(confirm).onPressed, isNull);
          await tester.tap(confirm);
          expect(host.updates, hasLength(1));
          await tester.binding.handlePopRoute();
          await tester.pump();
          expect(find.text('Rename chat'), findsOneWidget);
          host.mutationDelay!.complete();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Keep this name',
          );
          expect(find.bySemanticsLabel('Saving chat title'), findsNothing);
          expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
          await captureFormFamily(
            tester,
            'rename-${brightness.name}-$scale-failure',
          );
          host.failMutation = false;
          host.mutationDelay = null;
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(find.text('Rename chat'), findsNothing);
          expect(host.updates, hasLength(2));
          expect(host.updates.last.$3['title'], 'Keep this name');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  test(
    'AI title reads bounded dialogue and uses captured profile without saving',
    () async {
      host.titleHistory = [
        for (var i = 0; i < 30; i++)
          {
            'id': i,
            'role': i.isEven ? 'user' : 'assistant',
            'content': 'message $i ${'x' * 800}',
          },
        {'id': 31, 'role': 'tool', 'content': 'private tool output'},
        {'id': 32, 'role': 'system', 'content': 'private system instructions'},
        {
          'id': 33,
          'role': 'user',
          'content': 'hidden machinery',
          'display_kind': 'hidden',
        },
      ];
      final issued = browser.chatActionsFor(key());
      addTearDown(issued.dispose);
      expect(await issued.generateTitle(), host.suggestedTitle);
      final request = host.titleRequests.single;
      expect(request['profile'], 'personal');
      expect(request['task'], 'title_generation');
      expect(request.containsKey('session_id'), isFalse);
      expect(request['input'], isNot(contains('private')));
      expect(request['input'], isNot(contains('hidden machinery')));
      expect(request['input'], contains('message 29'));
      expect(
        (request['input'] as String).split('\n').length,
        lessThanOrEqualTo(24),
      );
      expect((request['input'] as String).length, lessThan(12500));
      expect(host.updates, isEmpty);
      expect(issued.state.generatingTitle, isFalse);
    },
  );

  test(
    'AI title retirement before generation prevents the model request',
    () async {
      host.titleHistory = [
        {'id': 1, 'role': 'user', 'content': 'Plan a garden'},
      ];
      final held = Completer<void>();
      host.historyDelays[('newest', 0)] = held;
      final issued = browser.chatActionsFor(key());
      final pending = issued.generateTitle();
      expect(issued.state.generatingTitle, isTrue);
      expect(await issued.generateTitle(), isNull);
      issued.dispose();
      held.complete();
      expect(await pending, isNull);
      expect(host.titleRequests, isEmpty);
      expect(host.updates, isEmpty);
    },
  );

  test('AI title profile retirement discards a held model response', () async {
    host.titleHistory = [
      {'id': 1, 'role': 'user', 'content': 'Plan a garden'},
    ];
    final issued = browser.chatActionsFor(key());
    addTearDown(issued.dispose);
    host.titleDelay = Completer<void>();
    final pending = issued.generateTitle();
    await Future<void>.delayed(Duration.zero);
    expect(host.titleRequests, hasLength(1));
    await controller.navigateProfile('work');
    expect(issued.state.generatingTitle, isFalse);
    host.titleDelay!.complete();
    expect(await pending, isNull);
    expect(host.updates, isEmpty);
  });

  test(
    'AI title rejects empty history and malformed model responses',
    () async {
      final issued = browser.chatActionsFor(key());
      addTearDown(issued.dispose);
      expect(await issued.generateTitle(), isNull);
      expect(issued.state.error, contains('Send a message'));
      expect(host.titleRequests, isEmpty);
      host.titleHistory = [
        {'id': 1, 'role': 'user', 'content': 'Plan a garden'},
      ];
      for (final invalid in [null, '', 'a\nb', 'x' * 101]) {
        host.suggestedTitle = invalid;
        expect(await issued.generateTitle(), isNull);
        expect(issued.state.error, contains('invalid title'));
        expect(issued.state.generatingTitle, isFalse);
      }
      host.suggestedTitle = 'A small garden plan';
      expect(await issued.generateTitle(), 'A small garden plan');
      expect(issued.state.error, isNull);
    },
  );

  test(
    'Rename refuses a concurrent mutation instead of acknowledging an unsent name',
    () async {
      final issued = browser.chatActionsFor(key());
      addTearDown(issued.dispose);
      host.mutationDelay = Completer<void>();
      host.mutationStarted = Completer<void>();
      final pin = controller.mutateSession(
        key(),
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      await host.mutationStarted!.future.timeout(const Duration(seconds: 5));
      host.mutationStarted = null;
      expect(
        await issued.perform(BrowserAction.rename, name: 'New name'),
        isFalse,
      );
      expect(issued.state.error, contains('already in progress'));
      expect(host.updates, hasLength(1));
      host.mutationDelay!.complete();
      await pin;
      host.mutationDelay = null;
      expect(
        await issued.perform(BrowserAction.rename, name: 'New name'),
        isTrue,
      );
      expect(host.updates.last.$3['title'], 'New name');
    },
  );

  testWidgets(
    'AI rename preserves newer typing and cancel retires the request',
    (tester) async {
      host.titleHistory = [
        {'id': 1, 'role': 'user', 'content': 'Plan a garden'},
      ];
      await show(tester);
      await menu(tester, 'newest');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-rename-title'));
      final history = Completer<void>();
      host.historyDelays[('newest', 0)] = history;
      host.titleDelay = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('chat-rename-ai')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(host.titleRequests, isEmpty);
      history.complete();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('chat-rename-save')))
            .onPressed,
        isNull,
      );
      await tester.enterText(field, 'My chosen name');
      host.titleDelay!.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'My chosen name',
      );
      expect(host.updates, isEmpty);
      host.titleDelay = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('chat-rename-ai')));
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      host.titleDelay!.complete();
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(host.updates, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Chat title editor feedback ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        host.titleHistory = [
          {'id': 1, 'role': 'user', 'content': 'Improve the chat list layout'},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'Use a compact grouped list.',
          },
        ];
        await controller.openSession(key());
        final chat = controller.current!.chat!;
        final reading = chat.reading;
        await controller.updateDraft(chat, 'Keep my draft');
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                  viewInsets: const EdgeInsets.only(bottom: 260),
                ),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final header = find.byTooltip('Rename chat');
        host.updates.clear();
        final headerRect = tester.getRect(header);
        await tester.tap(header);
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('chat-rename-title'));
        expect(field, findsOneWidget);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.widget<TextField>(field).controller!.text, chat.title);

        Future<void> snapshot(String state) async {
          expect(tester.takeException(), isNull);
          if (!capture) return;
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(captureKey),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final target = File(
              'build/design-previews/chat-rename/${brightness.name}-$scale-$state.png',
            );
            target.parent.createSync(recursive: true);
            target.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await snapshot('editor');
        final fieldRect = tester.getRect(field);
        final save = find.byKey(const ValueKey('chat-rename-save'));
        final saveRect = tester.getRect(save);
        expect(saveRect.bottom, lessThanOrEqualTo(844 - 260));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('chat-rename-ai')))
              .shortestSide,
          greaterThanOrEqualTo(48),
        );
        host.titleDelay = Completer<void>();
        await tester.tap(find.byKey(const ValueKey('chat-rename-ai')));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .value,
          scale == 2 ? isNotNull : isNull,
        );
        expect(tester.getRect(field), fieldRect);
        expect(tester.getRect(save), saveRect);
        expect(tester.widget<IconButton>(save).onPressed, isNull);
        await snapshot('generating');
        host.failTitle = true;
        host.titleDelay!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Title generation failed. Try again.'),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).controller!.text, chat.title);
        await snapshot('generation-error');
        host.failTitle = false;
        host.titleDelay = null;
        await tester.tap(find.byKey(const ValueKey('chat-rename-ai')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          host.suggestedTitle,
        );
        expect(host.updates, isEmpty);
        await snapshot('suggested');

        host.mutationDelay = Completer<void>();
        await tester.tap(save);
        await tester.pump();
        expect(field, findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == 'Cancel',
                ),
              )
              .onPressed,
          isNull,
        );
        await snapshot('saving');
        host.failMutation = true;
        host.mutationDelay!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Write rejected'), findsOneWidget);
        expect(
          tester.widget<TextField>(field).controller!.text,
          host.suggestedTitle,
        );
        await snapshot('save-error');
        host.failMutation = false;
        host.mutationDelay = null;
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(field, findsNothing);
        expect(chat.title, host.suggestedTitle);
        expect(identical(chat.reading, reading), isTrue);
        expect(chat.composer.observation.text, 'Keep my draft');
        expect(tester.getRect(header), headerRect);
        expect(host.updates.last.$3['profile'], 'personal');
        await snapshot('renamed');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  test('Unsubmitted chat rename uses the canonical rename mutation', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    final issued = browser.chatActionsFor(chat.key);
    addTearDown(issued.dispose);
    expect(
      await issued.perform(
        BrowserAction.rename,
        name: 'Before the first message',
      ),
      isTrue,
    );
    expect(chat.title, 'Before the first message');
    expect(host.updates, isEmpty);
    final mutation = host.calls
        .where((call) => call.$2 == 'session.mutate')
        .single;
    expect(mutation.$3['operation'], 'rename');
    expect(mutation.$3['payload'], {'title': 'Before the first message'});
    expect(mutation.$3['expected_revision'], 0);
    expect(mutation.$3['request_id'], isNotEmpty);
  });

  test(
    'opening retains unread until the latest saved answer is visibly read',
    () async {
      await loadNewestUnread();
      final resource = controller.current!;
      final project = resource.projects.first;
      host.changes['personal']!['newest'] = {
        ...host.changes['personal']!['newest']!,
        'cwd': project['primary_path'],
      };
      await controller.switchProfile('personal');
      await controller.selectProject(resource.projects.first);
      await browser.search('improve the conversation list');

      final target = browser
          .project('improve the conversation list')
          .entries
          .singleWhere((entry) => entry.sessionKey == key());
      await browser.open(target);
      expect(host.updates, isEmpty);
      final chat = controller.current!.chat!;
      controller.setRouteVisibility(controller, true);
      chat.reading.installSavedHistory([
        {'id': 1, 'role': 'user', 'content': 'Question'},
        {'id': 2, 'role': 'assistant', 'content': 'Earlier reply'},
        {'id': 3, 'role': 'assistant', 'content': 'Latest reply'},
        {'id': 4, 'role': 'user', 'content': 'Thanks'},
      ]);
      await controller.acknowledgeVisibleReading(chat, 2);
      expect(
        host.updates,
        isEmpty,
        reason: 'An older answer cannot clear a newer one',
      );
      chat.reading.recordReading(null, readThrough: 4);
      await controller.acknowledgeVisibleReading(chat, 4);
      expect(host.updates, hasLength(1));
      expect(chat.markReadFailed, isFalse);
      expect(host.updates.single.$1, 'personal');
      expect(host.updates.single.$2, 'sessions/newest');
      expect(host.updates.single.$3, containsPair('unread', false));
      expect(host.updates.single.$3, containsPair('profile', 'personal'));
      expect(host.updates.single.$3['request_id'], isNotEmpty);
      expect(host.updates.single.$3['expected_revision'], 0);
      expect(host.updates.single.$3['expected_generation'], 0);
      for (final rows in [resource.sessions, resource.projectSessions]) {
        expect(
          rows.firstWhere((row) => row['id'] == 'newest')['unread'],
          false,
        );
      }

      expect(
        browser.state.profiles['personal']!.searchMatches,
        contains('newest'),
      );
      expect(
        browser
            .project('improve the conversation list')
            .entries
            .singleWhere((entry) => entry.sessionKey == target.sessionKey)
            .unread,
        isFalse,
      );

      await controller.mutateSession(
        key(),
        changes: {'unread': true},
        canDispatch: () => true,
      );
      expect(chat.reading.readingPosition.readThrough, 4);
      chat.reading.recordReading(null, readThrough: 4);
      await controller.acknowledgeVisibleReading(chat, 4);
      expect(host.updates, hasLength(3));
      expect(host.updates.last.$3['unread'], false);

      host.updates.clear();
      controller.showList();
      await controller.openSession(key());
      expect(host.updates, isEmpty);
    },
  );

  test(
    'direct open outside loaded rows does not infer that answers were read',
    () async {
      final directKey = key('notification-only');
      expect(
        controller.current!.sessions.any(
          (row) => row['id'] == directKey.sessionId,
        ),
        isFalse,
      );

      await controller.openSession(directKey);
      expect(host.updates, isEmpty);
    },
  );

  test(
    'failed direct-open history does not mark an unknown session read',
    () async {
      host.failHistory = true;

      await controller.openSession(key('notification-only'));

      expect(controller.current!.selectedSession, 'notification-only');
      expect(controller.current!.chat!.reading.historyError, isNotNull);
      expect(host.updates, isEmpty);
    },
  );

  test('failed history leaves an opened chat unread', () async {
    await loadNewestUnread();
    host.failHistory = true;

    await controller.openSession(key());

    expect(controller.current!.selectedSession, 'newest');
    expect(controller.current!.chat!.reading.historyError, isNotNull);
    expect(
      controller.current!.sessions.firstWhere(
        (row) => row['id'] == 'newest',
      )['unread'],
      true,
    );
    expect(host.updates, isEmpty);
  });

  test('navigation during history prevents a stale mark-read write', () async {
    await loadNewestUnread();
    final delay = host.historyDelays[('newest', 0)] = Completer<void>();
    host.reads.clear();
    final opening = controller.openSession(key());
    await waitForHistoryRead();

    await controller.navigateProfile('work');
    delay.complete();
    await opening;

    expect(controller.current!.scope.profileName, 'work');
    expect(host.updates, isEmpty);
  });

  test(
    'manual mark-unread during history prevents automatic clearing',
    () async {
      await loadNewestUnread();
      final delay = host.historyDelays[('newest', 0)] = Completer<void>();
      host.reads.clear();
      final opening = controller.openSession(key());
      await waitForHistoryRead();

      await controller.mutateSession(
        key(),
        changes: {'unread': true},
        canDispatch: () => true,
      );
      delay.complete();
      await opening;

      expect(host.updates, hasLength(1));
      expect(host.updates.single.$3['unread'], true);
      expect(
        controller.current!.sessions.firstWhere(
          (row) => row['id'] == 'newest',
        )['unread'],
        true,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'seeing the latest answer clears Chats and Recents unread ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(loadNewestUnread);
          final now = DateTime.now().millisecondsSinceEpoch / 1000;
          host.titleHistory = [
            for (var id = 1; id <= 20; id++)
              {
                'id': id,
                'role': 'assistant',
                'content': id == 20
                    ? 'Latest saved reply'
                    : 'Earlier reply $id',
                'timestamp': now - 20 + id,
              },
          ];
          final gate = host.mutationDelay = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          host.mutationStarted = Completer<void>();
          final chat = (await tester.runAsync(
            () => controller.openSession(key()),
          ))!;
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: wingTheme(brightness),
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
            ),
          );
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(chat.reading.readingPosition.readThrough, 20);
          await tester.runAsync(
            () => host.mutationStarted!.future.timeout(
              const Duration(seconds: 3),
            ),
          );
          expect(host.updates, hasLength(1));
          expect(
            controller.current!.sessions.firstWhere(
              (row) => row['id'] == 'newest',
            )['unread'],
            isTrue,
            reason: 'Keep unread until the receipt succeeds',
          );
          gate.complete();
          await tester.pumpAndSettle();
          expect(
            controller.current!.sessions.firstWhere(
              (row) => row['id'] == 'newest',
            )['unread'],
            isFalse,
          );
          expect(
            controller
                .recentChats()
                .singleWhere((row) => row.key == key())
                .unread,
            isFalse,
          );
          expect(chat.markReadFailed, isFalse);
          await captureFormFamily(
            tester,
            'bottom-read-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Chats').last);
          await tester.pumpAndSettle();
          final row = find.byKey(const ValueKey('chat-personal-newest'));
          await tester.scrollUntilVisible(
            row,
            240,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('chat-list-false')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(row.hitTestable(), findsOneWidget);
          expect(
            tester
                .widget<ChatStatusDot>(
                  find.descendant(
                    of: row,
                    matching: find.byType(ChatStatusDot),
                  ),
                )
                .status,
            isNot(ChatListStatus.unread),
          );
          await captureFormFamily(
            tester,
            'bottom-read-chats-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Recents').last);
          await tester.pumpAndSettle();
          expect(find.text('Latest saved reply'), findsWidgets);
          expect(find.text('New answer'), findsNothing);
          await captureFormFamily(
            tester,
            'bottom-read-recents-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
      testWidgets(
        'automatic read failure logs without a conversation warning ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(loadNewestUnread);
          host.failMutation = true;
          host.titleHistory = [
            {'id': 2, 'role': 'assistant', 'content': 'Viewed reply'},
          ];
          host.mutationStarted = Completer<void>();
          final chat = (await tester.runAsync(
            () => controller.openSession(key()),
          ))!;
          final previousPrint = debugPrint;
          final logs = <String>[];
          debugPrint = (message, {wrapWidth}) {
            if (message != null) logs.add(message);
          };
          try {
            await tester.pumpWidget(
              RepaintBoundary(
                key: formFamilyCapture,
                child: MaterialApp(
                  theme: wingTheme(brightness),
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
              ),
            );
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            expect(find.text('Viewed reply'), findsOneWidget);
            expect(chat.reading.readingPosition.readThrough, 2);
            await tester.runAsync(
              () => host.mutationStarted!.future.timeout(
                const Duration(seconds: 3),
              ),
            );
            host.mutationStarted = null;
            await tester.pumpAndSettle();
          } finally {
            debugPrint = previousPrint;
          }
          await captureFormFamily(
            tester,
            'read-status-${brightness.name}-$scale',
          );
          expect(host.updates, hasLength(1));
          expect(host.updates.single.$3['unread'], isFalse);
          expect(
            controller.current!.sessions.firstWhere(
              (row) => row['id'] == 'newest',
            )['unread'],
            isTrue,
          );
          expect(chat.runtime.error, isNull);
          expect(chat.markReadFailed, isTrue);
          expect(find.text('Viewed reply'), findsOneWidget);
          expect(
            find.textContaining('could not be marked as read'),
            findsNothing,
          );
          expect(find.text('Write rejected'), findsNothing);
          final diagnostic = logs
              .where((line) => line.startsWith('[WingConnection] '))
              .map(
                (line) =>
                    jsonDecode(line.substring('[WingConnection] '.length)),
              )
              .singleWhere(
                (event) => event['event'] == 'reading.acknowledgement_failed',
              );
          expect(diagnostic['connection'], chat.key.workspace.connectionId);
          expect(diagnostic['profile'], 'personal');
          expect(diagnostic['causes'], [
            {'type': 'StateError'},
          ]);
          expect(logs.join(), isNot(contains('Write rejected')));
          expect(logs.join(), isNot(contains('Viewed reply')));
          host.failMutation = false;
          await tester.runAsync(
            () => controller.acknowledgeVisibleReading(chat, 2),
          );
          await tester.pumpAndSettle();
          expect(host.updates, hasLength(2));
          expect(chat.markReadFailed, isFalse);
          expect(
            controller.current!.sessions.firstWhere(
              (row) => row['id'] == 'newest',
            )['unread'],
            isFalse,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  test(
    'failed automatic mark-read keeps unread and allows manual retry',
    () async {
      await loadNewestUnread();
      host.failMutation = true;

      await controller.openSession(key());

      final chat = controller.current!.chat!;
      controller.setRouteVisibility(controller, true);
      chat.reading.installSavedHistory([
        {'id': 2, 'role': 'assistant', 'content': 'Viewed reply'},
      ]);
      chat.reading.recordReading(null, readThrough: 1);
      await controller.acknowledgeVisibleReading(chat, 2);
      expect(controller.current!.selectedSession, 'newest');
      expect(
        controller.current!.sessions.firstWhere(
          (row) => row['id'] == 'newest',
        )['unread'],
        true,
      );
      expect(controller.current!.mutatingSessions, isEmpty);
      expect(chat.runtime.error, isNull);
      expect(chat.markReadFailed, isTrue);

      host.failMutation = false;
      host.titleHistory = chat.reading.messages;
      await controller.mutateSession(
        key(),
        changes: {'unread': false},
        canDispatch: () => true,
      );
      expect(chat.markReadFailed, isFalse);
      expect(chat.reading.readingPosition.readThrough, 2);
      expect(
        controller.current!.sessions.firstWhere(
          (row) => row['id'] == 'newest',
        )['unread'],
        false,
      );
    },
  );

  test(
    'manual read moves both markers to latest only after acknowledgement',
    () async {
      await loadNewestUnread();
      final memory = ConversationReadingRegistry(
        controller.preferences,
      ).chat(key());
      memory.record(const TranscriptBookmark(messageId: 7), readThrough: 8);
      final before = memory.position;
      host.titleHistory = [
        {'id': 9, 'role': 'assistant', 'content': 'Latest answer'},
        {'id': 10, 'role': 'user', 'content': 'Thanks'},
      ];
      final historyGate = host.historyDelays[('newest', 0)] = Completer<void>();
      final mutationGate = host.mutationDelay = Completer<void>();
      Future<void> until(bool Function() ready, String outcome) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(ready(), isTrue, reason: outcome);
      }

      final pending = controller.mutateSession(
        key(),
        changes: {'unread': false},
        canDispatch: () => true,
      );
      try {
        await until(
          () => host.reads.any((read) => read.$1.endsWith('/messages')),
          'Manual read must load the latest saved message before writing unread',
        );
        expect(controller.current!.mutatingSessions, contains('newest'));
        expect(identical(memory.position, before), isTrue);
        expect(host.updates, isEmpty);
        historyGate.complete();
        await until(
          () => host.updates.isNotEmpty,
          'Manual read must dispatch its owned unread update after history loads',
        );
        expect(identical(memory.position, before), isTrue);
        host.titleHistory.add({
          'id': 11,
          'role': 'assistant',
          'content': 'Later arrival',
        });
        mutationGate.complete();
        await pending.timeout(const Duration(seconds: 5));
      } finally {
        // Release both owned operations before the shared controller is disposed,
        // including when a held-phase assertion fails.
        if (!historyGate.isCompleted) historyGate.complete();
        if (!mutationGate.isCompleted) mutationGate.complete();
        await pending.timeout(const Duration(seconds: 5));
      }
      expect(memory.position.resume, isNull);
      expect(memory.position.readThrough, 10);
      expect(controller.current!.mutatingSessions, isEmpty);
      memory.record(const TranscriptBookmark(messageId: 7));
      final marked = memory.position;
      await controller.mutateSession(
        key(),
        changes: {'unread': true},
        canDispatch: () => true,
      );
      expect(identical(memory.position, marked), isTrue);
      expect(
        controller.current!.sessions.firstWhere(
          (r) => r['id'] == 'newest',
        )['unread'],
        true,
      );
    },
  );

  test('failed manual read leaves both markers unchanged', () async {
    await loadNewestUnread();
    final memory = ConversationReadingRegistry(
      controller.preferences,
    ).chat(key());
    memory.record(const TranscriptBookmark(messageId: 7), readThrough: 8);
    final before = memory.position;
    host.titleHistory = [
      {'id': 10, 'role': 'assistant', 'content': 'Latest'},
    ];
    host.failHistory = true;
    await expectLater(
      controller.mutateSession(
        key(),
        changes: {'unread': false},
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(host.updates, isEmpty);
    expect(identical(memory.position, before), isTrue);
    host.failHistory = false;
    host.failMutation = true;
    await expectLater(
      controller.mutateSession(
        key(),
        changes: {'unread': false},
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(identical(memory.position, before), isTrue);
  });

  test('manual mark-unread survives app reconnect', () async {
    await loadNewestUnread();
    await controller.openSession(key());
    await controller.mutateSession(
      key(),
      changes: {'unread': true},
      canDispatch: () => true,
    );
    host.updates.clear();

    await controller.reconnect(controller.current!.scope);

    expect(host.updates, isEmpty);
    expect(
      controller.current!.sessions.firstWhere(
        (row) => row['id'] == 'newest',
      )['unread'],
      true,
    );
  });

  test(
    'pin rename unread use body profile and update only owner rows',
    () async {
      final owner = key();
      await controller.mutateSession(
        owner,
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      await controller.mutateSession(
        owner,
        changes: {'title': 'Renamed', 'unread': true},
        canDispatch: () => true,
      );
      expect(host.updates.last.$3['profile'], 'personal');
      expect(
        controller.current!.sessions.firstWhere(
          (r) => r['id'] == 'newest',
        )['title'],
        'Renamed',
      );
      await controller.navigateProfile('work');
      expect(controller.current!.sessions.single['title'], 'Work chat');
      await expectLater(
        controller.mutateSession(
          owner,
          changes: {'pinned': false},
          canDispatch: () => true,
        ),
        throwsStateError,
      );
    },
  );
  test('failed writes preserve visible data and allow retry', () async {
    host.failMutation = true;
    await expectLater(
      controller.mutateSession(
        key(),
        changes: {'pinned': true},
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(
      controller.current!.sessions.firstWhere(
        (r) => r['id'] == 'newest',
      )['pinned'],
      isNot(true),
    );
    expect(controller.current!.mutatingSessions, isEmpty);
    host.failMutation = false;
    await controller.mutateSession(
      key(),
      changes: {'pinned': true},
      canDispatch: () => true,
    );
    expect(
      controller.current!.sessions.firstWhere(
        (r) => r['id'] == 'newest',
      )['pinned'],
      true,
    );
  });
  test('archive and unarchive are discoverable and survive refresh', () async {
    final browser = ChatBrowserData(controller);
    addTearDown(browser.dispose);
    await browser.refresh(archivedOnly: false);
    await controller.mutateSession(
      key(),
      changes: {'archived': true},
      canDispatch: () => true,
    );
    await browser.refresh(archivedOnly: false);
    expect(browser.entries.any((entry) => entry.sessionKey == key()), false);
    await browser.refresh(archivedOnly: true);
    expect(
      browser.entries.where((entry) => entry.sessionKey == key()),
      hasLength(1),
    );
    await controller.mutateSession(
      key(),
      changes: {'archived': false},
      canDispatch: () => true,
    );
    await browser.refresh(archivedOnly: true);
    expect(browser.entries.any((entry) => entry.sessionKey == key()), false);
    await browser.refresh(archivedOnly: false);
    expect(browser.entries.any((entry) => entry.sessionKey == key()), true);
  });
  test('refresh started during a write cannot restore stale flags', () async {
    host.mutationDelay = Completer<void>();
    final write = controller.mutateSession(
      key(),
      changes: {'pinned': true},
      canDispatch: () => true,
    );
    final delay = host.pageDelays[('personal', 0)] = Completer<void>();
    final readCount = host.reads.length;
    final refresh = controller.refresh();
    for (var tick = 0; tick < 100 && host.reads.length == readCount; tick++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(host.reads.length, greaterThan(readCount));
    host.mutationDelay!.complete();
    await write;
    delay.complete();
    await refresh;
    expect(
      controller.current!.sessions.firstWhere(
        (r) => r['id'] == 'newest',
      )['pinned'],
      true,
    );
  });
  for (final active in [false, true]) {
    test(
      'canonical delete retires ${active ? 'open' : 'cold'} chat with captured fences',
      () async {
        host.active = active;
        host.mutationRevision = 7;
        host.mutationGeneration = 3;
        await controller.mutateSession(
          key(),
          delete: true,
          canDispatch: () => true,
        );
        expect(host.deletes.single.$2, {
          'profile': 'personal',
          'request_id': isNotEmpty,
          'expected_revision': '7',
          'expected_generation': '3',
        });
        expect(host.active, false);
        expect(
          controller.current!.sessions.any((r) => r['id'] == 'newest'),
          false,
        );
        await controller.refresh();
        expect(
          controller.current!.sessions.any((r) => r['id'] == 'newest'),
          false,
        );
      },
    );
  }
  for (final response in [
    {'session_id': 'another-chat'},
    {'session_id': null},
    {'runtime_revision': null},
    {'runtime_generation': -1},
    {'exists': false},
  ]) {
    test('delete refuses malformed owner snapshot $response', () async {
      host.mutationSnapshotOverrides = response;
      await expectLater(
        controller.mutateSession(key(), delete: true, canDispatch: () => true),
        throwsFormatException,
      );
      expect(host.deleteAttempts, isEmpty);
      expect(controller.current!.quarantinedSessions, contains('newest'));
    });
  }
  for (final status in ['working', 'starting', 'waiting', 'unknown', null]) {
    test('canonical owner refuses delete while status is $status', () async {
      host.active = true;
      host.activeStatus = status;
      await expectLater(
        controller.mutateSession(key(), delete: true, canDispatch: () => true),
        throwsStateError,
      );
      expect(host.deletes, isEmpty);
      expect(
        controller.current!.sessions.any((r) => r['id'] == 'newest'),
        true,
      );
    });
  }
  for (final generationRace in [false, true]) {
    test(
      'delete rejects ${generationRace ? 'new turn' : 'row revision'} after snapshot without removing row',
      () async {
        host.claimAfterSnapshot = generationRace;
        host.invalidateRevisionAfterSnapshot = !generationRace;
        await expectLater(
          controller.mutateSession(
            key(),
            delete: true,
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(host.deletes, isEmpty);
        expect(host.deleteAttempts, hasLength(1));
        expect(
          controller.current!.sessions.any((r) => r['id'] == 'newest'),
          true,
        );
      },
    );
  }
  test('delete preserves another profile with the same durable ID', () async {
    host.foreignActive = true;
    await controller.mutateSession(
      key(),
      delete: true,
      canDispatch: () => true,
    );
    expect(host.foreignActive, true);
    expect(host.deletes.single.$2['profile'], 'personal');
    await controller.navigateProfile('work');
    expect(controller.current!.sessions.single['id'], 'newest');
  });
  test(
    'failed canonical delete keeps work until Keep and a new delete intent',
    () async {
      host.active = true;
      host.failMutation = true;
      await expectLater(
        controller.mutateSession(key(), delete: true, canDispatch: () => true),
        throwsStateError,
      );
      expect(host.deleteAttempts, hasLength(1));
      expect(
        controller.current!.sessions.any((r) => r['id'] == 'newest'),
        true,
      );
      host.failMutation = false;
      await keepBeforeNewDelete();
      await controller.mutateSession(
        key(),
        delete: true,
        canDispatch: () => true,
      );
      expect(host.deletes, hasLength(1));
      expect(host.deleteAttempts, hasLength(2));
      expect(
        host.deleteAttempts.first.$2['request_id'],
        isNot(host.deleteAttempts.last.$2['request_id']),
      );
    },
  );
  test(
    'late write and duplicate taps stay bound to the original profile',
    () async {
      host.mutationDelay = Completer<void>();
      final personal = controller.current!;
      final owner = key();
      final pending = controller.mutateSession(
        owner,
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      await controller.mutateSession(
        owner,
        changes: {'pinned': true},
        canDispatch: () => true,
      );
      await controller.navigateProfile('work');
      host.mutationDelay!.complete();
      await pending;
      expect(host.updates.length, 1);
      expect(
        personal.sessions.firstWhere((r) => r['id'] == 'newest')['pinned'],
        true,
      );
      expect(controller.current!.sessions.single['pinned'], isNot(true));
    },
  );
  test(
    'project new chat captures its folder and rejects a stale owner',
    () async {
      final owner = controller.current!.scope;
      final project = controller.current!.projects.first;
      final chat = await controller.createChat(
        inProject: project,
        owner: owner,
        canDispatch: () => true,
      );
      expect(chat.projectId, project['id']);
      expect(
        host.calls.lastWhere((call) => call.$2 == 'session.create').$3['cwd'],
        project['primary_path'],
      );
      await controller.navigateProfile('work');
      await expectLater(
        controller.createChat(
          inProject: project,
          owner: owner,
          canDispatch: () => true,
        ),
        throwsStateError,
      );
    },
  );
  testWidgets('long press offers pin and moves the chat to pinned', (
    tester,
  ) async {
    await show(tester);
    await menu(tester, 'newest');
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(host.updates.single.$3['pinned'], true);
    await menu(tester, 'newest');
    expect(find.text('Unpin'), findsOneWidget);
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(host.updates.last.$3['pinned'], false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'move uses canonical workspace mutation and keeps the other profile unchanged',
    () async {
      final owner = key();
      final project = controller.current!.projects.first;
      await browser.search('improve the conversation list');
      final target = browser
          .project('improve the conversation list')
          .entries
          .singleWhere((entry) => entry.sessionKey == owner);
      final action = (await browser.actionsFor(target))!;
      addTearDown(action.dispose);
      final destination = action.projects.singleWhere(
        (item) => item.id == project['id'],
      );
      expect(
        await action.perform(BrowserAction.move, target: destination),
        isTrue,
      );
      expect(host.moves.single.$2, {
        'session_id': 'runtime',
        'operation': 'workspace',
        'request_id': isNotEmpty,
        'expected_revision': 0,
        'expected_generation': 0,
        'payload': {'cwd': project['primary_path']},
        'profile': 'personal',
      });
      expect(
        browser
            .project('improve the conversation list')
            .entries
            .singleWhere((entry) => entry.sessionKey == owner)
            .cwd,
        project['primary_path'],
      );
      await controller.selectProject(controller.current!.projects.first);
      expect(
        controller.current!.projectSessions.any((r) => r['id'] == 'newest'),
        true,
      );
      await controller.navigateProfile('work');
      expect(controller.current!.sessions.single['cwd'], isNull);
      expect(
        await action.perform(BrowserAction.move, target: destination),
        isFalse,
      );
      expect(action.state.error, contains('Profile changed'));
      expect(host.moves.length, 1);
    },
  );
  test(
    'moving out refreshes the entered project and preserves global rows',
    () async {
      final first = controller.current!.projects.first;
      await controller.moveSessionToProject(
        key(),
        first,
        canDispatch: () => true,
      );
      await controller.selectProject(controller.current!.projects.first);
      final destination = controller.current!.projects[1];
      await controller.moveSessionToProject(
        key(),
        destination,
        canDispatch: () => true,
      );
      expect(controller.current!.selectedProject!['id'], first['id']);
      expect(
        controller.current!.projectSessions.any((r) => r['id'] == 'newest'),
        false,
      );
      expect(
        controller.current!.sessions.firstWhere(
          (r) => r['id'] == 'newest',
        )['cwd'],
        destination['primary_path'],
      );
    },
  );
  for (final opened in [false, true]) {
    test(
      'confirmed moves replace retained Recents membership ($opened)',
      () async {
        host.titleHistory = [
          {
            'id': 1,
            'role': 'assistant',
            'content': 'Recent answer',
            'timestamp': host.now,
          },
        ];
        final owner = key();
        final project = controller.current!.projects.first;
        await controller.moveSessionToProject(
          owner,
          project,
          canDispatch: () => true,
        );
        await controller.refreshRecents();
        if (opened) await controller.openSession(owner);
        String? recentProject() => controller
            .recentChats()
            .singleWhere((chat) => chat.key == owner)
            .project
            ?.id;
        expect(recentProject(), project['id']);
        await controller.moveSessionToProject(
          owner,
          null,
          canDispatch: () => true,
        );
        expect(recentProject(), isNull);
        final destination = controller.current!.projects[1];
        await controller.moveSessionToProject(
          owner,
          destination,
          canDispatch: () => true,
        );
        expect(recentProject(), destination['id']);
      },
    );
  }

  test('failed moves and busy runtimes do not change local rows', () async {
    final project = controller.current!.projects.first;
    final before = Map<String, dynamic>.from(
      controller.current!.sessions.firstWhere((r) => r['id'] == 'newest'),
    );
    host.active = true;
    host.activeStatus = 'working';
    await expectLater(
      controller.moveSessionToProject(key(), project, canDispatch: () => true),
      throwsStateError,
    );
    expect(host.moves, isEmpty);
    host.active = false;
    host.failMutation = true;
    await expectLater(
      controller.moveSessionToProject(key(), project, canDispatch: () => true),
      throwsStateError,
    );
    expect(
      controller.current!.sessions.firstWhere((r) => r['id'] == 'newest'),
      before,
    );
    expect(controller.current!.mutatingSessions, isEmpty);
  });
  test(
    'duplicate and delayed moves retain original profile ownership',
    () async {
      final owner = key();
      final personal = controller.current!;
      final project = personal.projects.first;
      host.mutationDelay = Completer<void>();
      final move = controller.moveSessionToProject(
        owner,
        project,
        canDispatch: () => true,
      );
      expect(
        await controller.moveSessionToProject(
          owner,
          project,
          canDispatch: () => true,
        ),
        false,
      );
      await controller.navigateProfile('work');
      host.mutationDelay!.complete();
      await move;
      expect(host.moves.length, 1);
      expect(
        personal.sessions.firstWhere((r) => r['id'] == 'newest')['cwd'],
        project['primary_path'],
      );
      expect(controller.current!.sessions.single['cwd'], isNull);
    },
  );
  test(
    'move refuses foreign projects and finishes without a follow-up project read',
    () async {
      final project = controller.current!.projects.first;
      await expectLater(
        controller.moveSessionToProject(key(), {
          ...project,
        }, canDispatch: () => true),
        throwsStateError,
      );
      expect(host.moves, isEmpty);
      host.failProjects = true;
      host.calls.clear();
      expect(
        await controller.moveSessionToProject(
          key(),
          project,
          canDispatch: () => true,
        ),
        true,
      );
      expect(controller.current!.projectsError, isNull);
      expect(host.calls.where((call) => call.$2 == 'projects.tree'), isEmpty);
    },
  );
  testWidgets('move picker lists profile folders and cancel is read-only', (
    tester,
  ) async {
    await show(tester);
    await menu(tester, 'newest');
    await tester.tap(find.text('Move to project'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Projects in personal'), findsOneWidget);
    expect(find.text('/Mobile app'), findsOneWidget);
    expect(find.text('Work project'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip == 'Cancel' ||
                widget.tooltip == 'Cancel project selection'),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.moves, isEmpty);
    await menu(tester, 'newest');
    await tester.tap(find.text('Move to project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    expect(find.text('Move chat?'), findsOneWidget);
    expect(find.textContaining('"Mobile app" in personal'), findsOneWidget);
    expect(host.moves, isEmpty);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(host.moves, isEmpty);
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move chat'));
    await tester.pumpAndSettle();
    expect((host.moves.single.$2['payload'] as Map)['cwd'], '/Mobile app');
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'move confirmation from Chats overflow keeps icon contrast ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await showWorkspace(
            tester,
            brightness: brightness,
            scale: scale,
            capture: true,
          );
          await filterChatsToProfile(tester, 'personal');
          await menu(tester, 'newest', overflow: true);
          await tester.tap(find.text('Move to project'));
          await tester.pumpAndSettle();
          final destination = find.byKey(const ValueKey('move-project-p2'));
          await tester.ensureVisible(destination);
          await tester.tap(destination);
          await tester.pumpAndSettle();
          final glyph = find.byIcon(Icons.drive_file_move_outlined);
          final paint = tester.widget<RichText>(
            find.descendant(of: glyph, matching: find.byType(RichText)),
          );
          expect(
            paint.text.style!.color,
            Theme.of(tester.element(glyph)).colorScheme.onPrimary,
          );
          expect(find.byTooltip('Move chat').hitTestable(), findsOneWidget);
          await captureFormFamily(
            tester,
            'move-overflow-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
          expect(host.moves, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('move from Chats works for an idle open chat', (tester) async {
    host.active = true;
    host.lazyResume = true;
    await show(tester);
    await menu(tester, 'newest');
    await tester.tap(find.text('Move to project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move chat'));
    await tester.pumpAndSettle();

    expect(host.moves, hasLength(1));
    expect((host.moves.single.$2['payload'] as Map)['cwd'], '/Mobile app');
    await controller.selectProject(
      controller.current!.projects.firstWhere((p) => p['id'] == 'p2'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-personal-newest')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saved chat move shows progress while its policy is prepared', (
    tester,
  ) async {
    host.movePreparationDelay = Completer<void>();
    addTearDown(() {
      if (!host.movePreparationDelay!.isCompleted) {
        host.movePreparationDelay!.complete();
      }
    });
    await show(tester);
    await menu(tester, 'newest', overflow: true);
    await tester.tap(find.text('Move to project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(host.movePreparations, ['newest']);
    expect(
      find.byType(CircularProgressIndicator).hitTestable(),
      findsOneWidget,
    );
    expect(
      host.reads.where((r) => r.$1.endsWith('/mutation-snapshot')),
      isEmpty,
    );
    expect(host.moves, isEmpty);
    expect(controller.current!.mutatingSessions, contains('newest'));
    host.movePreparationDelay!.complete();
    await tester.pumpAndSettle();
    expect(host.moves, hasLength(1));
    expect(find.byKey(const ValueKey('chat-project-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Unassigned opens projects independently of connection details', (
    tester,
  ) async {
    await controller.createChat(canDispatch: () => true);
    await showWorkspace(tester);
    await tester.tap(find.textContaining('Unassigned'));
    await tester.pumpAndSettle();
    expect(find.text('Move to project'), findsOneWidget);
    expect(find.byKey(const ValueKey('move-project-p2')), findsOneWidget);
    expect(find.text('Connection details'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip == 'Cancel' ||
                widget.tooltip == 'Cancel project selection'),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.moves, isEmpty);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'remove project reports busy refusal and retries after work finishes ${brightness.name} $scale',
        (tester) async {
          await tester.runAsync(() => controller.openSession(key()));
          final chat = controller.current!.chat!;
          await controller.moveSessionToProject(
            key(),
            controller.current!.projects.first,
            canDispatch: () => true,
          );
          host.moves.clear();
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(key: formFamilyCapture, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          );
          await tester.pumpAndSettle();
          emitChatEvent(controller, chat, 'message.start');
          expect(chat.runtime.blocksTurnAdmission, isTrue);
          host.activeStatus = 'working';
          await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Remove from project'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Move chat'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.text('Wait for this chat to finish before moving.'),
            findsOneWidget,
          );
          expect(host.moves, isEmpty);
          expect(host.defaultFolderProfiles, isEmpty);
          expect(tester.takeException(), isNull);
          await captureFormFamily(
            tester,
            'move-busy-${brightness.name}-$scale',
          );
          emitChatEvent(controller, chat, 'turn.end', {'status': 'completed'});
          host.activeStatus = 'idle';
          expect(chat.runtime.blocksTurnAdmission, isFalse);
          await tester.tap(find.byTooltip('Remove from project'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Move chat'));
          await tester.pumpAndSettle();
          expect(
            (host.moves.single.$2['payload'] as Map)['cwd'],
            '/personal/default',
          );
          expect(
            find.byKey(const ValueKey('chat-project-sheet')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'remove project confirms and shows progress through every move stage',
    (tester) async {
      await tester.runAsync(() => controller.openSession(key()));
      final chat = controller.current!.chat!;
      await tester.runAsync(
        () => controller.updateDraft(chat, 'Keep this draft'),
      );
      await controller.moveSessionToProject(
        key(),
        controller.current!.projects.first,
        canDispatch: () => true,
      );
      host.moves.clear();
      await showWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from project'));
      await tester.pumpAndSettle();
      expect(find.text('Move chat?'), findsOneWidget);
      expect(
        find.textContaining('default project of personal'),
        findsOneWidget,
      );
      expect(host.defaultFolderProfiles, isEmpty);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(host.moves, isEmpty);
      expect(controller.chatProjectLabel(chat), 'Mobile app');

      host.defaultFolderDelay = Completer<void>();
      host.snapshotDelay = Completer<void>();
      host.mutationDelay = Completer<void>();
      await tester.tap(find.byTooltip('Remove from project'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move chat').hitTestable());
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator).hitTestable(),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Move chat?'), findsNothing);
      expect(host.defaultFolderProfiles, ['personal']);
      expect(host.moves, isEmpty);
      expect(
        tester
            .widget<IconButton>(
              find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is IconButton &&
                        widget.tooltip == 'Remove from project',
                  )
                  .hitTestable(),
            )
            .onPressed,
        isNull,
      );
      host.defaultFolderDelay!.complete();
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator).hitTestable(),
        findsOneWidget,
      );
      expect(host.moves, isEmpty);
      host.snapshotDelay!.complete();
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator).hitTestable(),
        findsOneWidget,
      );
      expect(
        (host.moves.single.$2['payload'] as Map)['cwd'],
        '/personal/default',
      );
      expect(controller.chatProjectLabel(chat), 'Mobile app');
      host.mutationDelay!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsNothing);
      expect(
        find.text('Moved to the default project of personal'),
        findsOneWidget,
      );
      expect(controller.chatProjectLabel(chat), 'Unassigned');
      expect(chat.composer.observation.displayedText, 'Keep this draft');
      final entry = browser
          .project('')
          .entries
          .singleWhere((entry) => entry.sessionKey == chat.key);
      expect(entry.cwd, '/personal/default');
      expect(entry.project?.isHome ?? true, isTrue);
      await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove from project'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final failRead in [true, false]) {
    testWidgets(
      'remove project retains assignment after ${failRead ? 'default read' : 'move'} failure and retries',
      (tester) async {
        await tester.runAsync(() => controller.openSession(key()));
        final chat = controller.current!.chat!;
        await controller.moveSessionToProject(
          key(),
          controller.current!.projects.first,
          canDispatch: () => true,
        );
        host.moves.clear();
        host.failDefaultFolder = failRead;
        host.failMutation = !failRead;
        await showWorkspace(tester);
        await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Remove from project'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Move chat').hitTestable());
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            failRead ? 'Default folder unavailable' : 'Move rejected',
          ),
          findsOneWidget,
        );
        expect(controller.chatProjectLabel(chat), 'Mobile app');
        expect(find.byType(CircularProgressIndicator), findsNothing);
        host.failDefaultFolder = false;
        host.failMutation = false;
        await tester.tap(find.byTooltip('Remove from project'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Move chat').hitTestable());
        await tester.pumpAndSettle();
        expect(controller.chatProjectLabel(chat), 'Unassigned');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'remove project retires before mutation when profile changes during the default read',
    () async {
      await controller.moveSessionToProject(
        key(),
        controller.current!.projects.first,
        canDispatch: () => true,
      );
      host.moves.clear();
      final action = (await browser.actionsFor(
        browser
            .project('')
            .entries
            .singleWhere((entry) => entry.id == 'newest'),
      ))!;
      host.defaultFolderDelay = Completer<void>();
      final result = action.perform(BrowserAction.move);
      await Future<void>.delayed(Duration.zero);
      await controller.navigateProfile('work');
      host.defaultFolderDelay!.complete();
      expect(await result, isFalse);
      expect(host.moves, isEmpty);
      expect(host.defaultFolderProfiles, ['personal']);
      action.dispose();
    },
  );

  testWidgets(
    'remove project through Chats row actions updates its membership',
    (tester) async {
      final owner = key();
      await controller.moveSessionToProject(
        owner,
        controller.current!.projects.first,
        canDispatch: () => true,
      );
      host.moves.clear();
      await show(tester);
      await menu(tester, 'newest');
      await tester.tap(find.text('Move to project'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from project'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move chat').hitTestable());
      await tester.pumpAndSettle();
      expect(
        (host.moves.single.$2['payload'] as Map)['cwd'],
        '/personal/default',
      );
      final entry = browser
          .project('')
          .entries
          .singleWhere((entry) => entry.sessionKey == owner);
      expect(entry.project, isNull);
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-personal-newest')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('chat header moves an open chat and keeps its draft on reopen', (
    tester,
  ) async {
    await tester.runAsync(() => controller.openSession(key()));
    final chat = controller.current!.chat!;
    await tester.runAsync(() => controller.updateDraft(chat, 'Unsent draft'));
    await showWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move chat'));
    await tester.pumpAndSettle();

    expect(host.moves, hasLength(1));
    expect(controller.chatProjectLabel(chat), 'Mobile app');
    expect(chat.composer.observation.displayedText, 'Unsent draft');
    expect(find.text('Mobile app'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('move-project-p2')), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip == 'Cancel' ||
                widget.tooltip == 'Cancel project selection'),
      ),
    );
    await tester.pumpAndSettle();
    controller.showList();
    await tester.runAsync(() async {
      await controller.refresh();
      await controller.openSession(key());
    });
    await tester.pumpAndSettle();
    expect(
      controller.chatProjectLabel(controller.current!.chat!),
      'Mobile app',
    );
    expect(
      controller.current!.chat!.composer.observation.displayedText,
      'Unsent draft',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new chat header moves before sending the first message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    host.activeSessionKey = 'new-chat';
    host.resumeSessionId = 'new-chat';
    final chat = await controller.createChat(canDispatch: () => true);
    host.active = true;
    await showWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('chat-project-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move chat'));
    await tester.pumpAndSettle();

    expect(host.moves.single.$2['session_id'], 'runtime');
    expect(host.changes['personal']!['new-chat']!['cwd'], '/Mobile app');
    expect(controller.chatProjectLabel(chat), 'Mobile app');
    expect(find.text('Mobile app'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed move stays visible and can be retried without duplicate writes',
    (tester) async {
      host.failMutation = true;
      await show(tester);
      await menu(tester, 'newest');
      await tester.tap(find.text('Move to project'));
      await tester.pumpAndSettle();
      final destination = find.byKey(const ValueKey('move-project-p2'));
      await tester.tap(destination);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move chat'));
      await tester.pumpAndSettle();
      expect(find.text('Move rejected'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsOneWidget);
      expect(host.changes['personal']?['newest']?['cwd'], isNull);
      host.failMutation = false;
      host.mutationDelay = Completer<void>();
      await tester.tap(destination);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(destination);
      await tester.pump();
      expect(host.moves, hasLength(2));
      expect(tester.widget<ListTile>(destination).enabled, false);
      host.mutationDelay!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsNothing);
      expect(find.text('Moved to Mobile app'), findsOneWidget);
      expect(host.changes['personal']!['newest']!['cwd'], '/Mobile app');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'project picker rejects a profile switch before choosing a destination',
    (tester) async {
      await show(tester);
      await menu(tester, 'newest');
      await tester.tap(find.text('Move to project'));
      await tester.pumpAndSettle();
      await controller.navigateProfile('work');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('move-project-p2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move chat'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Profile changed'), findsOneWidget);
      expect(host.moves, isEmpty);
      expect(controller.current!.sessions.single['cwd'], isNull);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              (widget.tooltip == 'Cancel' ||
                  widget.tooltip == 'Cancel project selection'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final status in ['working', 'waiting', 'starting', 'unknown', null]) {
    test(
      'canonical owner refuses workspace mutation while status is $status',
      () async {
        host.active = true;
        host.activeStatus = status;
        await expectLater(
          controller.moveSessionToProject(
            key(),
            controller.current!.projects.first,
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(host.moves, isEmpty);
      },
    );
  }
  for (final generationRace in [false, true]) {
    test(
      'move refuses ${generationRace ? 'new turn' : 'row revision'} after captured snapshot',
      () async {
        host.claimAfterSnapshot = generationRace;
        host.invalidateRevisionAfterSnapshot = !generationRace;
        await expectLater(
          controller.moveSessionToProject(
            key(),
            controller.current!.projects.first,
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(host.moves, isEmpty);
      },
    );
  }
  test('move leaves a colliding runtime in another profile alone', () async {
    host.foreignActive = true;
    await controller.moveSessionToProject(
      key(),
      controller.current!.projects.first,
      canDispatch: () => true,
    );
    expect(host.moves.single.$2['profile'], 'personal');
    expect(host.foreignActive, true);
    await controller.navigateProfile('work');
    expect(controller.current!.sessions.single['cwd'], isNull);
  });
  for (final response in [
    {'session_id': 'another-chat'},
    {'session_id': null},
    {'runtime_revision': null},
    {'runtime_generation': -1},
    {'exists': false},
  ]) {
    test('move refuses malformed owner snapshot $response', () async {
      host.mutationSnapshotOverrides = response;
      await expectLater(
        controller.moveSessionToProject(
          key(),
          controller.current!.projects.first,
          canDispatch: () => true,
        ),
        throwsFormatException,
      );
      expect(host.moves, isEmpty);
    });
  }
  for (final delete in [false, true]) {
    test(
      '${delete ? 'delete' : 'move'} rechecks departure after held mutation snapshot',
      () async {
        host.snapshotDelay = Completer<void>();
        var current = true;
        final operation = delete
            ? controller.mutateSession(
                key(),
                delete: true,
                canDispatch: () => current,
              )
            : controller.moveSessionToProject(
                key(),
                controller.current!.projects.first,
                canDispatch: () => current,
              );
        final failure = expectLater(operation, throwsA(isA<Exception>()));
        await Future<void>.delayed(Duration.zero);
        current = false;
        host.snapshotDelay!.complete();
        await failure;
        expect(host.moves, isEmpty);
        expect(host.deleteAttempts, isEmpty);
      },
    );
  }

  testWidgets('delete confirmation cancel sends no request', (tester) async {
    await show(tester);
    await menu(tester, 'newest');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete chat?'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip == 'Cancel' ||
                widget.tooltip == 'Cancel project selection'),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.deletes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('confirmed delete removes an idle open chat from Chats', (
    tester,
  ) async {
    host.active = true;
    host.lazyResume = true;
    await show(tester);
    await menu(tester, 'newest');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Delete chat'),
      ),
    );
    await tester.pump();
    await waitForChatDeletionCleanup(tester, controller, key());
    await tester.pumpAndSettle();
    expect(host.deletes, hasLength(1));
    expect(find.byKey(const ValueKey('chat-personal-newest')), findsNothing);
    expect(find.textContaining('Close it before deleting'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('project menu opens a new chat in that project', (tester) async {
    await show(tester);
    await revealChatProject(tester, 'personal', 'p2');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-personal-p2')),
        matching: find.byTooltip('Project actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-action-new')));
    await tester.pumpAndSettle();
    expect(controller.current!.chat!.projectId, 'p2');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'runtime indicators and typed unread status retain their distinct labels',
    (tester) async {
      final runtime = ChatRuntime(runtimeId: 'indicator-runtime');
      final chat = composeChat(
        controller: controller,
        preferences: controller.preferences,
        key: ProfileSessionKey(controller.current!.scope, 'indicator'),
        runtime: runtime,
        title: 'Indicator',
      );
      for (final (status, label) in [
        (ChatExecution.running, 'Working'),
        (null, 'Input needed'),
        (ChatExecution.completed, 'Completed'),
        (ChatExecution.failed, 'Failed'),
      ]) {
        runtime.reconcileApprovals(runtime.captureApprovalRead(), const []);
        if (status == null) {
          runtime.receiveApproval({
            'request_id': 'indicator-input',
            'command': 'Review',
          });
        } else if (status == ChatExecution.running) {
          runtime.beginTurn(submitting: false);
        } else {
          runtime.completeTurn(
            failed: status == ChatExecution.failed,
            cancelled: false,
            error: null,
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProfileChatIndicator(
                runtime: chat.runtime,
                subagents: chat.subagents,
                unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byTooltip(label), findsOneWidget);
        expect(
          find.byType(StudioLoading),
          status == ChatExecution.running ? findsOneWidget : findsNothing,
        );
      }
      await tester.pumpWidget(
        MaterialApp(home: ChatStatusDot(chatListStatus({'unread': true}))),
      );
      expect(find.byTooltip('Unread'), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _RenameActionsFixture extends ProfileActionsFixture {
  List<Map<String, dynamic>> titleHistory = [];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      id == 'newest' ? titleHistory : super.historyRows(profile, id);
}
