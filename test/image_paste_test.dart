import 'support/composer_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/profile_queued_messages.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/image_clipboard.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

class _PasteAttachments extends AttachmentDraftService {
  _PasteAttachments(Directory cache)
    : super(cacheDirectoryProvider: () async => cache);

  Future<void>? beforeRemoval;
  final removalStarted = Completer<void>();
  final removalFinished = Completer<void>();

  @override
  Future<void> removeAll(Iterable<AttachmentDraft> drafts) async {
    removalStarted.complete();
    await beforeRemoval;
    await super.removeAll(drafts);
    removalFinished.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late SharedPreferences preferences;
  late _PasteAttachments attachments;
  final png = image.encodePng(
    image.Image(width: 3, height: 2)..clear(image.ColorRgb8(39, 127, 137)),
  );
  const composerKey = Key('profile-message-composer');

  const capture = bool.fromEnvironment('CAPTURE_PASTE_ORDER');
  const frameKey = ValueKey('paste-order-frame');

  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'Ahem': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$fonts/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> until(bool Function() complete) async {
    if (complete()) return;
    final completed = Completer<void>();
    void changed() {
      if (complete() && !completed.isCompleted) completed.complete();
    }

    controller.addListener(changed);
    controller.composerChanges.addListener(changed);
    try {
      await completed.future;
    } finally {
      controller.removeListener(changed);
      controller.composerChanges.removeListener(changed);
    }
  }

  Future<void> pumpFrames(WidgetTester tester) async {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() complete) async {
    for (var attempt = 0; attempt < 200 && !complete(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(complete(), isTrue, reason: 'Attachment cleanup must settle.');
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final context = tester.element(find.byKey(frameKey));
    var decoded = false;
    final images = Future.wait([
      for (final widget in tester.widgetList<Image>(find.byType(Image)))
        precacheImage(widget.image, context),
    ]).then((_) => decoded = true);
    for (var attempt = 0; attempt < 200 && !decoded; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(decoded, isTrue, reason: 'Decode the attachment before capture');
    await images;
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frameKey),
    );
    await tester.runAsync(() async {
      final bitmap = await boundary.toImage();
      try {
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/design-previews/paste-order')
          ..createSync(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        bitmap.dispose();
      }
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    cache = await Directory.systemTemp.createTemp('hermes-paste-test-');
    attachments = _PasteAttachments(cache);
    host = Host()..running = false;
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
      connectionIdentity: 'paste-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      attachmentService: attachments,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'message.start');
    emitChatEvent(controller, chat, 'session.info', {
      'open_requests': [],
      'running': false,
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImageClipboard.channel, null);
    controller.dispose();
    appPreferences.dispose();
    await cache.delete(recursive: true);
  });

  test(
    'paste stages a sanitized image with saved text and never submits',
    () async {
      await controller.updateDraft(chat, 'Describe this');
      await controller.addPastedImage(chat, () async => png);
      final draft = (await readComposerFixture(
        chat: chat,
        preferences: controller.preferences,
      ))!.attachments.single;
      expect(draft.isImage, isTrue);
      expect(draft.sanitized, isTrue);
      expect(draft.name, 'Pasted image.png');
      expect(
        image.decodeImage(await File(draft.cachedPath).readAsBytes())!.width,
        3,
      );
      expect(chat.composer.observation.text, 'Describe this');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'paste-test',
      );
      expect(store.summaries(profileName: 'a').single.attachmentCount, 1);
      await controller.removeAttachment(chat, draft.id);
      expect(await File(draft.cachedPath).exists(), isFalse);
    },
  );

  test(
    'pending clipboard read reserves its original chat across chat switches',
    () async {
      final read = Completer<Uint8List>();
      final pending = controller.addPastedImage(chat, () => read.future);
      expect(controller.canAddAttachment(chat), isFalse);
      final other = await controller.createChat(canDispatch: () => true);
      read.complete(png);
      await pending;
      expect(chat.composer.observation.attachments, hasLength(1));
      expect(other.composer.observation.attachments, isEmpty);
      expect(controller.canAddAttachment(chat), isTrue);
    },
  );

  for (final scenario
      in <({String name, Future<Uint8List> Function() read, Matcher error})>[
        (
          name: 'empty',
          read: () async => Uint8List(0),
          error: isA<AttachmentDraftException>(),
        ),
        (
          name: 'invalid',
          read: () async => Uint8List.fromList([1, 2, 3]),
          error: isA<AttachmentDraftException>(),
        ),
        (
          name: 'unavailable',
          read: () async => throw StateError('expired'),
          error: isA<StateError>(),
        ),
      ]) {
    test('${scenario.name} clipboard data leaves the draft intact', () async {
      await controller.updateDraft(chat, 'Keep this');
      await expectLater(
        controller.addPastedImage(chat, scenario.read),
        throwsA(scenario.error),
      );
      expect(chat.composer.observation.text, 'Keep this');
      expect(chat.composer.observation.attachments, isEmpty);
      expect(await cache.list().toList(), isEmpty);
      expect(controller.canAddAttachment(chat), isTrue);
    });
  }

  test('pasted images enforce the existing attachment count limit', () async {
    for (var i = 0; i < maxRemoteAttachmentDrafts; i++) {
      await controller.addPastedImage(chat, () async => png);
    }
    await expectLater(
      controller.addPastedImage(chat, () async => png),
      throwsA(isA<AttachmentDraftException>()),
    );
    expect(
      chat.composer.observation.attachments,
      hasLength(maxRemoteAttachmentDrafts),
    );
  });

  Future<void> show(
    WidgetTester tester, {
    bool settle = true,
    Brightness? brightness,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: frameKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == null ? null : wingTheme(brightness),
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
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await pumpFrames(tester);
    }
  }

  for (final configuration in [
    (running: false, brightness: Brightness.light, scale: 1.0),
    for (final brightness in Brightness.values)
      for (final scale in [1.0, 2.0])
        (running: true, brightness: brightness, scale: scale),
  ]) {
    for (final imageFirst in [true, false, null]) {
      final name =
          '${configuration.running}-${configuration.brightness.name}-${configuration.scale}-$imageFirst';
      testWidgets('pasted image keeps the primary action usable $name', (
        tester,
      ) async {
        final running = configuration.running;
        final cleanup = Completer<void>();
        if (!running) {
          attachments.beforeRemoval = cleanup.future;
          addTearDown(() async {
            if (!cleanup.isCompleted) cleanup.complete();
            if (attachments.removalStarted.isCompleted) {
              await pumpUntil(
                tester,
                () => attachments.removalFinished.isCompleted,
              );
            }
          });
        }
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(
          configuration.scale == 1 ? 390 : 320,
          850,
        );
        addTearDown(tester.view.reset);
        host.running = running;
        controller.connectionStatus.accessAvailable();
        controller.connectionStatus.liveChanged(
          chat.key.workspace.profileName,
          true,
        );
        if (running) emitChatEvent(controller, chat, 'message.start');
        final read = Completer<Uint8List>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ImageClipboard.channel,
          (call) async => call.method == 'hasImage' ? true : read.future,
        );
        await show(
          tester,
          settle: false,
          brightness: configuration.brightness,
          scale: configuration.scale,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        if (imageFirst == false) {
          await tester.enterText(find.byKey(composerKey), 'Describe this');
        }
        await pumpFrames(tester);
        await tester.longPressAt(
          tester.getTopLeft(find.byType(EditableText)) + const Offset(12, 12),
        );
        await pumpFrames(tester);
        if (find.text('Paste').evaluate().isEmpty) {
          await tester.tap(find.byTooltip('More'));
          await pumpFrames(tester);
        }
        await tester.runAsync(() => tester.tap(find.text('Paste')));
        await tester.pump();
        expect(find.bySemanticsLabel('Adding photo…'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byKey(composerKey)).enabled,
          isTrue,
        );
        await snapshot(tester, '$name-pending');
        read.complete(png);
        await tester.pump();
        await tester.runAsync(
          () => until(() => controller.canAddAttachment(chat)),
        );
        await pumpFrames(tester);
        expect(chat.composer.observation.preparing, isFalse);
        expect(chat.composer.observation.attachments, hasLength(1));
        if (imageFirst == true) {
          final imageOnlyButton = tester.widget<ComposerActionButton>(
            find.byType(ComposerActionButton),
          );
          expect(imageOnlyButton.unavailable[imageOnlyButton.primary], isNull);
          await tester.enterText(find.byKey(composerKey), 'Describe this');
          await pumpFrames(tester);
        }
        final button = tester.widget<ComposerActionButton>(
          find.byType(ComposerActionButton),
        );
        expect(button.unavailable[button.primary], isNull);
        expect(button.primary, ComposerAction.send);
        await snapshot(tester, '$name-ready');
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('Send'));
          await chat.composer.admittedWrites;
          await until(
            () => running
                ? chat.composer.observation.queue.isNotEmpty
                : host.calls.any((call) => call.$2 == 'prompt.submit'),
          );
        });
        await pumpFrames(tester);
        if (!running) {
          await pumpUntil(tester, () => attachments.removalStarted.isCompleted);
          expect(await tester.runAsync(() => cache.list().length), 1);
          cleanup.complete();
          await pumpUntil(
            tester,
            () => attachments.removalFinished.isCompleted,
          );
          expect(await tester.runAsync(() => cache.list().toList()), isEmpty);
        }
        expect(chat.composer.observation.text, isEmpty);
        expect(chat.composer.observation.attachments, isEmpty);
        if (running) {
          expect(
            chat.composer.observation.queue.single.text,
            imageFirst == null ? '' : 'Describe this',
          );
          expect(
            chat.composer.observation.queue.single.attachments,
            hasLength(1),
          );
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            isEmpty,
          );
          await tester.tap(find.text('1 queued'));
          await pumpFrames(tester);
          expect(
            find
                .descendant(
                  of: find.byType(ProfileQueuedMessages),
                  matching: find.text(
                    imageFirst == null
                        ? 'Pasted image.png'
                        : 'Describe this · Pasted image.png',
                  ),
                )
                .hitTestable(),
            findsOneWidget,
          );
          await snapshot(tester, '$name-queued');
        } else {
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            hasLength(1),
          );
          expect(
            attachments.removalFinished.isCompleted,
            isTrue,
            reason: 'Sending must finish cache cleanup before test teardown.',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('removing a pasted image preserves the separately picked image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await controller.addPastedImage(chat, () async => png);
      final picked = File('${cache.path}/picked.jpg');
      await picked.writeAsBytes(
        image.encodeJpg(image.Image(width: 4, height: 3)),
      );
      await controller.addAttachments(chat, [
        (path: picked.path, name: 'picked.jpg'),
      ]);
    });
    await show(tester);
    final thumbnails = find.byKey(const ValueKey('composer-image-thumbnail'));
    expect(thumbnails, findsNWidgets(2));
    expect(
      find.byTooltip('Remove Pasted image.png').hitTestable(),
      findsOneWidget,
    );
    expect(find.byTooltip('Remove picked.jpg').hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove Pasted image.png'));
      // The callback returns before its file deletion finishes. Let that
      // operation complete before tearDown removes the same cache directory.
      await chat.composer.admittedWrites;
      await until(() => controller.canAddAttachment(chat));
    });
    await pumpFrames(tester);
    expect(chat.composer.observation.attachments.single.name, 'picked.jpg');
    expect(find.byTooltip('Remove Pasted image.png'), findsNothing);
    expect(find.byTooltip('Remove picked.jpg').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard advertises image types and inserts into the draft', (
    tester,
  ) async {
    await show(tester);
    final field = tester.widget<TextField>(find.byKey(composerKey));
    final config = field.contentInsertionConfiguration!;
    expect(config.allowedMimeTypes, ImageClipboard.mimeTypes);
    await tester.tap(find.byKey(composerKey));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/textinput',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('TextInputClient.performAction', [
            -1,
            'TextInputAction.commitContent',
            {
              'mimeType': 'image/png',
              'uri': 'content://keyboard/image',
              'data': png,
            },
          ]),
        ),
        (_) {},
      );
      await until(() => controller.canAddAttachment(chat));
    });
    await tester.pumpAndSettle();
    expect(chat.composer.observation.attachments.single.isImage, isTrue);
    expect(
      find.byKey(const ValueKey('composer-image-thumbnail')),
      findsOneWidget,
    );
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets(
    'unreadable keyboard content shows an error without changing text',
    (tester) async {
      await controller.updateDraft(chat, 'Keep this');
      await show(tester);
      final field = tester.widget<TextField>(find.byKey(composerKey));
      field.contentInsertionConfiguration!.onContentInserted(
        const KeyboardInsertedContent(
          mimeType: 'image/png',
          uri: 'content://expired/image',
        ),
      );
      await tester.pumpAndSettle();
      expect(chat.composer.observation.text, 'Keep this');
      expect(chat.composer.observation.attachments, isEmpty);
      expect(find.textContaining('Unable to paste this image'), findsOneWidget);
    },
  );

  testWidgets('image-only clipboard exposes Paste in an empty composer', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ImageClipboard.channel,
      (call) async {
        calls.add(call.method);
        return call.method == 'hasImage' ? true : png;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await show(tester);
    await tester.longPress(find.byKey(composerKey));
    await tester.pumpAndSettle();
    expect(find.text('Paste'), findsOneWidget);
    expect(calls, ['hasImage']);
    await tester.runAsync(() async {
      await tester.tap(find.text('Paste'));
      await until(() => controller.canAddAttachment(chat));
    });
    await tester.pumpAndSettle();
    expect(calls, ['hasImage', 'readImage']);
    expect(chat.composer.observation.attachments, hasLength(1));
  });

  testWidgets('stalled clipboard read expires without blocking the composer', (
    tester,
  ) async {
    final clipboard = Completer<Uint8List>();
    await show(tester);
    final preparation = controller.addPastedImage(chat, () => clipboard.future);
    final failure = expectLater(preparation, throwsA(isA<StateError>()));
    expect(chat.composer.observation.preparing, isTrue);
    await tester.pump(const Duration(seconds: 20));
    await failure;
    expect(chat.composer.observation.preparing, isFalse);
    expect(controller.canAddAttachment(chat), isTrue);
    clipboard.complete(png);
    await tester.pump();
    expect(chat.composer.observation.attachments, isEmpty);
  });

  testWidgets('ordinary text still pastes at the selection', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ImageClipboard.channel,
      (call) async => false,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        if (call.method == 'Clipboard.getData') return {'text': 'Copied text'};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await show(tester);
    await tester.longPress(find.byKey(composerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(chat.composer.observation.text, 'Copied text');
    expect(chat.composer.observation.attachments, isEmpty);
  });
}
