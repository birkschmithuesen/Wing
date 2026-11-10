import 'package:wing/core/services/bots_session.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/attachment_image_worker.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_attachment_tile.dart';
import 'package:wing/core/widgets/studio_error.dart';

import 'profile_workspace_controller_test.dart'
    show Host, PhotoPickerFixture, PhotoFileFixture;
import 'support/composer_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_PENDING_ATTACHMENTS');
const _frame = ValueKey('pending-attachments-frame');
const _composer = Key('profile-message-composer');

class _HeldImages extends AttachmentDraftService {
  _HeldImages({required super.cacheDirectoryProvider});

  Completer<void>? hold;
  int? failAt;
  int prepared = 0;

  @override
  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    void Function(AttachmentImageJob)? onImageJob,
  }) async {
    await hold?.future;
    if (++prepared == failAt) {
      throw const AttachmentDraftException(
        'Could not add this photo. Try again.',
      );
    }
    return super.prepareImage(
      sourcePath: sourcePath,
      displayName: displayName,
      existingDrafts: existingDrafts,
      onImageJob: onImageJob,
    );
  }
}

Future<void> _captureFrame(WidgetTester tester, String name) async {
  if (!_capture) return;
  final context = tester.element(find.byKey(_frame));
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
    reason: 'Visible attachment images must decode before capture',
  );
  await pending;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final bitmap = await boundary.toImage();
    try {
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/attachments-review/pending')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      bitmap.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
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

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'missing staged attachment shows persistent repair ${brightness.name} ${scale}x',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final sandbox = Directory.systemTemp.createTempSync(
            'wing-missing-attachment-',
          );
          addTearDown(() => sandbox.deleteSync(recursive: true));
          final controller = ProfileWorkspaceController(
            connectionIdentity: 'missing-attachment',
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
            gatewayFactory: Host().gateway,
            attachmentService: AttachmentDraftService(
              cacheDirectoryProvider: () async => sandbox,
            ),
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          await tester.pumpWidget(
            RepaintBoundary(
              key: _frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: ProfileWorkspaceScreen(
                  createBotsSession: () => BotsSession((_) async => const []),
                  controller: controller,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final (name, kind, mediaType) in [
            ('notes.txt', AttachmentDraftKind.genericFile, 'text/plain'),
            ('photo.png', AttachmentDraftKind.image, 'image/png'),
          ]) {
            await tester.runAsync(
              () => restoreComposerFixture(
                chat: chat,
                preferences: preferences,
                text: 'Keep my draft',
                attachments: [
                  AttachmentDraft(
                    id: name,
                    name: name,
                    cachedPath: '${sandbox.path}/$name',
                    byteLength: 24,
                    mediaType: mediaType,
                    kind: kind,
                    sanitized: kind == AttachmentDraftKind.image,
                  ),
                ],
              ),
            );
            await tester.pumpAndSettle();
            final tile = find.byType(ComposerAttachmentTile);
            final recovery = find.descendant(
              of: tile,
              matching: find.byType(StudioError),
            );
            expect(recovery, findsOneWidget);
            expect(
              find
                  .descendant(
                    of: tile,
                    matching: find.byType(SingleChildScrollView),
                  )
                  .hitTestable(),
              findsOneWidget,
            );
            expect(
              tester.widget<StudioError>(recovery).message,
              'File missing. Remove and reattach.',
            );
            expect(find.text(name), findsOneWidget);
            final remove = find.byTooltip('Remove $name');
            expect(remove.hitTestable(), findsOneWidget);
            expect(
              tester.getSize(remove).shortestSide,
              greaterThanOrEqualTo(48),
            );
            expect(find.byKey(_composer).hitTestable(), findsOneWidget);
            await _captureFrame(
              tester,
              'missing-$name-${brightness.name}-${scale}x',
            );
            await tester.tap(remove);
            for (
              var attempt = 0;
              attempt < 100 && chat.composer.observation.saving;
              attempt++
            ) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
            }
            await tester.pumpAndSettle();
            expect(recovery, findsNothing);
            expect(chat.composer.observation.attachments, isEmpty);
            expect(
              tester.widget<TextField>(find.byKey(_composer)).controller!.text,
              'Keep my draft',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final configuration in [
    (
      brightness: Brightness.light,
      width: 390.0,
      scale: 1.0,
      reduced: false,
      fail: false,
    ),
    (
      brightness: Brightness.dark,
      width: 390.0,
      scale: 1.0,
      reduced: false,
      fail: false,
    ),
    (
      brightness: Brightness.light,
      width: 320.0,
      scale: 2.0,
      reduced: false,
      fail: false,
    ),
    (
      brightness: Brightness.dark,
      width: 320.0,
      scale: 2.0,
      reduced: false,
      fail: false,
    ),
    (
      brightness: Brightness.dark,
      width: 320.0,
      scale: 2.0,
      reduced: true,
      fail: true,
    ),
  ]) {
    final name =
        '${configuration.brightness.name}-${configuration.width.toInt()}-${configuration.scale.toInt()}-${configuration.reduced}-${configuration.fail}';
    testWidgets('photo picker shows preparation and settles the batch $name', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(configuration.width, 850);
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      try {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final sandbox = Directory.systemTemp.createTempSync(
          'wing-pending-photos-',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));
        final attachments = _HeldImages(
          cacheDirectoryProvider: () async => sandbox,
        );
        final host = Host();
        final controller = ProfileWorkspaceController(
          connectionIdentity: 'pending-photos',
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
          attachmentService: attachments,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'Keep typing');
        final png = image.encodePng(
          image.Image(width: 8, height: 8)
            ..clear(image.ColorRgb8(39, 127, 137)),
        );
        final existing = File('${sandbox.path}/existing.png')
          ..writeAsBytesSync(png);
        await tester.runAsync(
          () => controller.addAttachments(chat, [
            (path: existing.path, name: 'existing.png'),
          ]),
        );
        final originalId = chat.composer.observation.attachments.single.id;
        var publishedBeforeReady = false;
        void observePreparation() {
          final observation = chat.composer.observation;
          if (observation.attachmentPreparation != null &&
              observation.attachments.any((file) => file.id != originalId)) {
            publishedBeforeReady = true;
          }
        }

        controller.addListener(observePreparation);
        addTearDown(() => controller.removeListener(observePreparation));

        final selected = [
          for (var index = 1; index <= 2; index++)
            File('${sandbox.path}/new-$index.png')..writeAsBytesSync(png),
        ];
        final originalPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = PhotoPickerFixture([
          for (final file in selected)
            PhotoFileFixture(file.uri, name: file.uri.pathSegments.last),
        ]);
        addTearDown(() => FilePickerPlatform.instance = originalPicker);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(configuration.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(configuration.scale),
                  disableAnimations: configuration.reduced,
                ),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                createBotsSession: () => BotsSession((_) async => const []),
                controller: controller,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final screen = tester.state(find.byType(ProfileWorkspaceScreen));
        final textController = tester
            .widget<TextField>(find.byKey(_composer))
            .controller!;
        attachments.hold = Completer<void>();
        if (configuration.fail) attachments.failAt = 3;
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Photos'));
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
          if (chat.composer.observation.preparing) break;
        }
        await tester.pump(const Duration(milliseconds: 250));
        final pending = find.byType(ComposerPendingAttachmentTile);
        expect(pending, findsOneWidget);
        expect(tester.getSize(pending), const Size(96, 96));
        expect(find.bySemanticsLabel('Adding 2 photos…'), findsOneWidget);
        expect(find.text('Adding'), findsOneWidget);
        expect(
          find.descendant(
            of: pending,
            matching: find.byType(CircularProgressIndicator),
          ),
          configuration.reduced ? findsNothing : findsOneWidget,
        );
        expect(chat.composer.observation.attachmentPreparation!.imageCount, 2);
        expect(chat.composer.observation.attachments.single.id, originalId);
        expect(controller.canAddAttachment(chat), isFalse);
        expect(tester.widget<TextField>(find.byKey(_composer)).enabled, isTrue);
        final initialPendingPosition = tester.getTopLeft(pending);
        final stripRect = tester.getRect(find.byType(ComposerAttachmentStrip));
        expect(stripRect.contains(tester.getCenter(pending)), isTrue);
        expect(initialPendingPosition.dx, greaterThanOrEqualTo(stripRect.left));
        expect(
          tester.getBottomRight(pending).dx,
          lessThanOrEqualTo(stripRect.right),
        );
        await tester.enterText(
          find.byKey(_composer),
          'Keep typing while photos are added',
        );
        await tester.pump(const Duration(milliseconds: 250));
        final pendingPosition = tester.getTopLeft(pending);
        await _captureFrame(tester, 'pending-$name');
        attachments.hold!.complete();
        for (var attempt = 0; attempt < 400; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (!chat.composer.observation.preparing) break;
        }
        expect(chat.composer.observation.preparing, isFalse);
        if (!configuration.fail && !configuration.reduced) {
          await tester.pump();
          expect(pending, findsOneWidget);
          expect(find.bySemanticsLabel('Adding 2 photos…'), findsNothing);
          await tester.pump(const Duration(milliseconds: 100));
          expect(pending, findsOneWidget);
        }
        await tester.pumpAndSettle();
        expect(pending, findsNothing);
        expect(chat.composer.observation.attachmentPreparation, isNull);
        expect(publishedBeforeReady, isFalse);
        expect(tester.state(find.byType(ProfileWorkspaceScreen)), same(screen));
        expect(
          tester.widget<TextField>(find.byKey(_composer)).controller,
          same(textController),
        );
        expect(
          chat.composer.observation.text,
          'Keep typing while photos are added',
        );
        expect(controller.canAddAttachment(chat), isTrue);
        expect(
          host.calls.where(
            (call) => call.$2 == 'prompt.submit' || call.$2 == 'file.attach',
          ),
          isEmpty,
        );
        final saved = await tester.runAsync(
          () => readComposerFixture(chat: chat, preferences: preferences),
        );
        expect(saved!.text, chat.composer.observation.text);
        if (configuration.fail) {
          expect(chat.composer.observation.attachments.single.id, originalId);
          expect(saved.attachments.single.id, originalId);
          expect(
            find.textContaining('Could not add this photo'),
            findsOneWidget,
          );
        } else {
          expect(chat.composer.observation.attachments, hasLength(3));
          expect(saved.attachments, hasLength(3));
          final firstNewThumbnail = find
              .byKey(const ValueKey('composer-image-thumbnail'))
              .at(1);
          expect(tester.getTopLeft(firstNewThumbnail), pendingPosition);
        }
        await _captureFrame(tester, 'settled-$name');
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
