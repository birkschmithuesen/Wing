import 'support/form_family_capture.dart';
import 'package:wing/core/widgets/gateway_clarify_dialog.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/services/attachment_image_worker.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/bot_avatar.dart';
import 'package:wing/core/widgets/playful_portrait.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/screens/bots/bots_content.dart';
import 'package:wing/core/screens/bots/bot_profile_editor.dart';
import 'package:wing/core/screens/bots/bot_settings_screen.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/screens/bots/bots_create_screen.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bot_group_draft_session.dart';
import 'package:wing/core/services/bot_avatar_io.dart';
import 'package:wing/core/widgets/bot_group_picture.dart';
import 'package:wing/core/widgets/bot_group_identity.dart';
import 'package:wing/core/services/bot_screen_window.dart';
import 'package:wing/core/services/bot_profile_edit_session.dart';
import 'package:wing/core/theme/profile_colors.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/bots_fixture.dart';
import 'support/composer_fixture.dart' show emitChatEvent;
import 'support/administration_fixture.dart';
import 'support/profile_browser_fixture.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';

const _export = bool.fromEnvironment('STUDIO_REVIEW');

class _BotConversationBrowser extends ProfileBrowserFixture {
  Completer<void>? resumeDelay;
  Completer<void>? markReadDelay;
  List<Map<String, dynamic>>? openingHistory;
  Map<String, dynamic>? clarificationResult;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      ownedPatch: markReadDelay == null
          ? null
          : (path, body, canDispatch, onDispatched) async {
              if (!canDispatch()) {
                throw StateError('Retired read acknowledgement');
              }
              onDispatched();
              await markReadDelay!.future;
              return {'ok': true, ...body};
            },
      rpc: (method, params) async {
        if (method == 'session.resume') await resumeDelay?.future;
        if (method == 'clarify.lock' && clarificationResult != null) {
          return clarificationResult!;
        }
        return base.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    ...super.sessions(profile),
    {
      'id': 'canonical-root',
      'title': 'Bot Chat',
      'profile': profile,
      'last_active': now,
      'unread': markReadDelay != null,
    },
    {
      'id': 'canonical-tip',
      'title': 'Compacted conversation',
      'profile': profile,
      'last_active': now,
      'unread': false,
    },
    {
      'id': 'ordinary',
      'title': 'Bot Chat',
      'profile': profile,
      'last_active': now,
      'unread': false,
    },
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      openingHistory ??
      [
        {'id': 1, 'role': 'user', 'content': 'Can you help me plan my week?'},
        {
          'id': 2,
          'role': 'assistant',
          'content':
              'Of course. What would you like to make time for this week?',
        },
      ];
}

class _RoomPicturePicker extends BotAvatarIo {
  @override
  Future<Uint8List?> pick() => File('assets/icon/icon.png').readAsBytes();
}

class _ReviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey frame,
  String name, {
  bool motion = false,
}) async {
  if (!_export) return;
  if (motion) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/bots-review')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _revealGroup(
  WidgetTester tester,
  Finder target, {
  double delta = 120,
}) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadFormFamilyFonts);
  if (_export) _ReviewBinding();

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final duplicate in [false, true]) {
        testWidgets(
          'bot draft footer stays above keyboard ${brightness.name} $scale clone=$duplicate',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            SharedPreferences.setMockInitialValues({});
            final fixture = BotsFixture();
            final session = BotsSession((_) async => [fixture.repository]);
            addTearDown(session.dispose);
            await session.refresh();
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
                  home: BotsCreateScreen(
                    session: session,
                    group: false,
                    clone: duplicate ? session.state.bots.first : null,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.enterText(
              find.widgetWithText(TextField, 'Profile name'),
              'new-profile',
            );
            await captureFormFamily(
              tester,
              'bot-$duplicate-${brightness.name}-$scale-normal',
            );
            tester.view.viewInsets = const FakeViewPadding(bottom: 260);
            await tester.pumpAndSettle();
            final footer = find.byTooltip('Create bot');
            expect(footer.hitTestable(), findsOneWidget);
            expect(
              tester.getRect(footer).bottom,
              lessThanOrEqualTo(
                tester.view.physicalSize.height - tester.view.viewInsets.bottom,
              ),
            );
            expect(tester.getSize(footer).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(footer).height, greaterThanOrEqualTo(48));
            await captureFormFamily(
              tester,
              'bot-$duplicate-${brightness.name}-$scale-keyboard',
            );
            expect(tester.takeException(), isNull);
            expect(fixture.commands, isEmpty);
          },
        );
      }
    }
  }
  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'transparent group pictures blend with their frame ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final bytes = await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawRect(
              const Rect.fromLTWH(85, 0, 85, 256),
              Paint()..color = const Color(0x80ff0000),
            );
            canvas.drawRect(
              const Rect.fromLTWH(170, 0, 86, 256),
              Paint()..color = const Color(0xffff0000),
            );
            final picture = recorder.endRecording();
            final raster = await picture.toImage(256, 256);
            final png = await raster.toByteData(format: ui.ImageByteFormat.png);
            raster.dispose();
            picture.dispose();
            return encodeRoomThumbnail((png!.buffer.asUint8List(), 45000));
          });
          final theme = wingTheme(brightness);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: RepaintBoundary(
                  key: frame,
                  child: ColoredBox(
                    color: theme.colorScheme.surface,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final color in [null, ProfileColorChoice.cyan])
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final size in [32.0, 40.0, 48.0, 64.0, 88.0])
                                BotGroupPicture(
                                  key: ValueKey('transparent-$color-$size'),
                                  image: bytes,
                                  color: color,
                                  size: size,
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(() async {
            for (final size in [32, 40, 48, 64, 88]) {
              await precacheImage(
                ResizeImage(MemoryImage(bytes!), width: size),
                frame.currentContext!,
              );
            }
          });
          await tester.pumpAndSettle();
          final samples = await tester.runAsync(() async {
            final boundary =
                frame.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final raster = await boundary.toImage();
            final rgba = await raster.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final samples = <Color>[];
            for (final color in [null, ProfileColorChoice.cyan]) {
              for (final size in [32.0, 40.0, 48.0, 64.0, 88.0]) {
                final rect = tester.getRect(
                  find.byKey(ValueKey('transparent-$color-$size')),
                );
                for (final x in [.16, .5, .84]) {
                  final offset =
                      (rect.center.dy.floor() * raster.width +
                          (rect.left + rect.width * x).floor()) *
                      4;
                  samples.add(
                    Color.fromARGB(
                      rgba!.getUint8(offset + 3),
                      rgba.getUint8(offset),
                      rgba.getUint8(offset + 1),
                      rgba.getUint8(offset + 2),
                    ),
                  );
                }
              }
            }
            raster.dispose();
            return samples;
          });
          await _capture(
            tester,
            frame,
            'transparent-group-${brightness.name}-$scale',
          );
          var index = 0;
          for (final background in [
            theme.colorScheme.primaryContainer,
            desktopProfileSwatches[ProfileColorChoice.cyan.slot!],
          ]) {
            for (var size = 0; size < 5; size++) {
              for (final expected in [
                background,
                Color.alphaBlend(const Color(0x80ff0000), background),
                const Color(0xffff0000),
              ]) {
                final actual = samples![index++];
                for (final (a, b) in [
                  (actual.r, expected.r),
                  (actual.g, expected.g),
                  (actual.b, expected.b),
                ]) {
                  expect(
                    a,
                    closeTo(b, 1 / 255),
                    reason: 'sample ${index - 1}: $actual expected $expected',
                  );
                }
              }
            }
          }
        },
      );

      testWidgets(
        'group avatar collage fits every member ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.profiles.addAll([
            for (var index = 0; index < 4; index++)
              BotsFixture.profile('bot$index', 'Bot $index'),
          ]);
          for (final (index, profile) in fixture.profiles.indexed) {
            profile['ui_meta']['hermes-bots']['shape'] = botShapes[index];
          }
          final bots = await fixture.repository.bots();
          final saved = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: RepaintBoundary(
                  key: frame,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: BotGroupIdentity(
                          group: saved.withIcon(
                            color: ProfileColorChoice.cyan,
                            revision: 1,
                          ),
                          bots: bots,
                          size: 48,
                        ),
                      ),
                      const SizedBox(height: 16),
                      for (var count = 2; count <= 6; count++) ...[
                        Text('$count bots'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final size in [32.0, 40.0, 48.0, 64.0]) ...[
                              BotGroupPicture(
                                key: ValueKey('collage-$count-$size'),
                                avatars: bots.take(count).toList(),
                                color: ProfileColorChoice.cyan,
                                size: size,
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (var count = 2; count <= 6; count++) {
            for (final size in [32.0, 40.0, 48.0, 64.0]) {
              final icon = find.byKey(ValueKey('collage-$count-$size'));
              await tester.ensureVisible(icon);
              await tester.pumpAndSettle();
              final avatars = find.descendant(
                of: icon,
                matching: find.byType(BotAvatar),
              );
              expect(avatars, findsNWidgets(count));
              final bounds = tester.getRect(icon);
              final faces = avatars.evaluate().toList();
              final rectangles = [
                for (final face in faces)
                  tester.getRect(find.byWidget(face.widget)),
              ];
              for (final rect in rectangles) {
                expect(
                  rectangles.where(
                    (other) => other != rect && rect.overlaps(other),
                  ),
                  isNotEmpty,
                );
              }
              final centers = rectangles.map((rect) => rect.center).toList();
              if (count == 3) {
                final byY = [...centers]..sort((a, b) => a.dy.compareTo(b.dy));
                expect(byY[0].dy, lessThan(byY[1].dy));
                expect(byY[1].dy, closeTo(byY[2].dy, .01));
                expect(byY[0].dx, closeTo((byY[1].dx + byY[2].dx) / 2, .01));
              } else if (count == 4) {
                final xs = centers.map((point) => point.dx.round()).toSet();
                final ys = centers.map((point) => point.dy.round()).toSet();
                expect(xs.length, 2);
                expect(ys.length, 2);
              } else if (count >= 5) {
                final center =
                    centers.reduce((a, b) => a + b) / count.toDouble();
                final distances = centers
                    .map((point) => (point - center).distance)
                    .toList();
                for (final distance in distances) {
                  expect(distance, closeTo(distances.first, .01));
                }
              }
              for (final avatar in faces) {
                final rect = tester.getRect(find.byWidget(avatar.widget));
                expect(bounds.contains(rect.topLeft), true);
                expect(bounds.contains(rect.bottomRight), true);
              }
            }
          }
          final identity = find.byType(BotGroupIdentity);
          await _capture(
            tester,
            frame,
            'group-collage-bottom-${brightness.name}-$scale',
          );
          await _revealGroup(tester, identity, delta: -200);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: identity, matching: find.byType(BotAvatar)),
            findsNWidgets(2),
          );
          expect(
            find.descendant(of: identity, matching: find.byType(Text)),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            frame,
            'group-collage-${brightness.name}-$scale',
          );
        },
      );
    }
  }

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BotScreenWindow.channel, (_) async => null);
    if (!_export) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'monospace': 'build/studio-mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'ready roster refresh stays quiet and fixed in ${brightness.name} at $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          var now = DateTime.now();
          final fixture = BotsFixture();
          final session = BotsSession(
            (_) async => [fixture.repository],
            now: () => now,
          );
          addTearDown(session.dispose);
          await session.refresh();
          final held = Completer<Map<String, dynamic>?>();
          fixture.readHook = (_, method, _) async =>
              ['profiles.list', 'groups.list', 'groups.state'].contains(method)
              ? held.future
              : null;
          now = now.add(const Duration(minutes: 5));
          final refresh = session.refresh();
          var view = const BotsViewState();
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: StatefulBuilder(
                builder: (context, setState) => BotsContent(
                  instanceHeader: const Align(
                    alignment: Alignment.centerLeft,
                    child: ServerConnectionLabel(label: 'Home server'),
                  ),
                  session: session,
                  viewState: view,
                  onViewChanged: (next) => setState(() => view = next),
                  onOpenMenu: () {},
                  onOpenGroupMemberChat: (_, _) async {},
                  onOpenChat: (_) async {},
                  onOpenGroup: (_) async {},
                ),
              ),
            ),
          );
          final searchPosition = tester.getTopLeft(
            find.byKey(const ValueKey('bots-search')),
          );
          for (final tab in ['Bots', 'Groups']) {
            await tester.tap(find.widgetWithText(Tab, tab));
            await tester.pump(const Duration(milliseconds: 300));
            final progress = find.byWidgetPredicate(
              (widget) =>
                  widget is StudioLoading && widget.label.startsWith('Loading'),
            );
            expect(progress, findsNothing);
            expect(
              tester.getTopLeft(find.byKey(const ValueKey('bots-search'))),
              searchPosition,
            );
            expect(
              tester
                  .widget<TextField>(find.byKey(const ValueKey('bots-search')))
                  .enabled,
              isNot(false),
            );
            expect(
              find.text(tab == 'Bots' ? 'Atlas' : 'Research team'),
              findsOneWidget,
            );
            await _capture(
              tester,
              frame,
              'loading-${tab.toLowerCase()}-${brightness.name}-$scale',
              motion: true,
            );
            expect(tester.takeException(), isNull);
          }
          fixture.room['name'] = 'Updated research team';
          held.complete(null);
          await refresh;
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is StudioLoading && widget.label.startsWith('Loading'),
            ),
            findsNothing,
          );
          expect(find.text('Updated research team'), findsOneWidget);
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('bots-search'))),
            searchPosition,
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group editing saved details, palette and keyboard ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final Map<String, dynamic> profile = jsonDecode(
            jsonEncode(BotsFixture.profile('default', 'Hermes')),
          );
          final photo = encodeRoomThumbnail((
            File('assets/icon/icon.png').readAsBytesSync(),
            45000,
          ));
          profile['ui_meta']['wing-group-icon:room-1'] = {
            'version': 1,
            'color': ProfileColorChoice.cyan.slot,
            'data': base64Encode(photo),
          };
          profile['ui_meta_revisions']['wing-group-icon:room-1'] = 3;
          fixture.profiles.add(profile);
          fixture.commandHook = (_, method, params) async {
            if (method != 'profiles.configure') return null;
            final meta = params['ui_meta'] as Map;
            final revisions = <String, int>{};
            (profile['ui_meta'] as Map).addAll(meta);
            for (final key in meta.keys) {
              revisions[key as String] = profile['ui_meta_revisions'][key] =
                  (profile['ui_meta_revisions'][key] as int? ?? 0) + 1;
            }
            return {
              'applied': {'ui_meta': true, 'ui_meta_revisions': revisions},
            };
          };
          final session = BotsSession((_) async => [fixture.repository]);
          addTearDown(session.dispose);
          await session.refresh();
          final group = session.state.groups.single;
          final draft = BotGroupDraftSession(
            session,
            existing: group,
            pictureIo: _RoomPicturePicker(),
          );
          final frame = GlobalKey();
          var keyboard = false;
          late StateSetter setMedia;
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => StatefulBuilder(
                builder: (context, setState) {
                  setMedia = setState;
                  return MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      viewInsets: EdgeInsets.only(bottom: keyboard ? 240 : 0),
                    ),
                    child: RepaintBoundary(key: frame, child: child),
                  );
                },
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BotsCreateScreen(
                          session: session,
                          group: true,
                          editGroup: group,
                          onOpenMemberChat: (_, _) async {},
                          createGroupDraft: () => draft,
                        ),
                      ),
                    ),
                    child: const Text('Open editor'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open editor'));
          await tester.pumpAndSettle();
          final name = find.byKey(const ValueKey('group-name'));
          final save = find.byKey(const ValueKey('group-save'));
          expect(
            tester.widget<TextField>(name).controller!.text,
            'Research team',
          );
          expect(tester.widget<IconButton>(save).onPressed, isNull);
          expect(find.text('Search bots'), findsNothing);
          final memberNote = find.text(
            'Members are fixed when the group is created.',
          );
          await _revealGroup(tester, memberNote);
          expect(memberNote, findsOneWidget);
          await _revealGroup(tester, name, delta: -120);
          await tester.runAsync(
            () => precacheImage(
              MemoryImage(photo),
              tester.element(find.byType(BotGroupPicture).first),
            ),
          );
          await tester.pumpAndSettle();
          await _capture(
            tester,
            frame,
            'group-editing-saved-${brightness.name}-$scale',
          );
          await _revealGroup(
            tester,
            find.byTooltip('Choose icon color'),
            delta: -120,
          );
          await tester.tap(find.byTooltip('Choose icon color'));
          await tester.pumpAndSettle();
          await _capture(
            tester,
            frame,
            'group-editing-palette-${brightness.name}-$scale',
          );
          await tester.tap(find.byKey(const ValueKey('group-color-rose')));
          await tester.pumpAndSettle();
          expect(draft.iconColor, ProfileColorChoice.rose);
          await tester.tap(find.byTooltip('Remove room picture'));
          await tester.pumpAndSettle();
          expect(draft.picture, isNull);
          await tester.runAsync(() async {
            await tester.tap(find.byTooltip('Upload room picture'));
            for (
              var attempt = 0;
              draft.pictureBusy && attempt < 500;
              attempt++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();
          expect(draft.picture, isNotNull);
          await tester.tap(find.byTooltip('Remove room picture'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Generate room picture'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField))
                .initialValue,
            contains('Atlas, Mira'),
          );
          await _capture(
            tester,
            frame,
            'group-editing-prompt-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Cancel picture generation'));
          await tester.pumpAndSettle();
          expect(fixture.commands, isEmpty);
          await _revealGroup(tester, name, delta: -120);
          await tester.enterText(
            name,
            scale == 1 ? 'Field team' : 'Research and evidence review team',
          );
          setMedia(() => keyboard = true);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(save).bottom,
            lessThanOrEqualTo(tester.view.physicalSize.height - 240),
          );
          await _capture(
            tester,
            frame,
            'group-editing-keyboard-${brightness.name}-$scale',
          );
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(find.text('Edit group'), findsNothing);
          expect(session.state.groups.single.name, draft.name);
          expect(
            session.state.groups.single.iconColor,
            ProfileColorChoice.rose,
          );
          expect(session.state.groups.single.picture, isNull);
          expect(fixture.commands.map((c) => c.$2), [
            'profiles.configure',
            'groups.rename',
          ]);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'group editing is reachable from roster and discussion and updates the open room',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = BotsFixture();
      final Map<String, dynamic> profile = jsonDecode(
        jsonEncode(BotsFixture.profile('default', 'Hermes')),
      );
      fixture.profiles.add(profile);
      fixture.commandHook = (_, method, params) async {
        if (method != 'profiles.configure') return null;
        (profile['ui_meta'] as Map).addAll(params['ui_meta'] as Map);
        final key = (params['ui_meta'] as Map).keys.single;
        profile['ui_meta_revisions'][key] = 1;
        return {
          'applied': {
            'ui_meta': true,
            'ui_meta_revisions': {key: 1},
          },
        };
      };
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      await session.refresh();
      var state = const BotsViewState(tab: 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: StatefulBuilder(
            builder: (context, setState) => BotsContent(
              session: session,
              viewState: state,
              onViewChanged: (next) => setState(() => state = next),
              onOpenMenu: () {},
              onOpenGroupMemberChat: (_, _) async {},
              onOpenChat: (_) async {},
              onOpenGroup: (group) => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => BotGroupScreen(
                    stopVoicePlayback: () async {},
                    voiceInputSettings: () =>
                        const LocalVoiceInputSettings(language: ''),
                    createSession: () => session.openGroup(group),
                    onEdit: (group) => openGroupEditor(
                      context,
                      session,
                      group,
                      onOpenMemberChat: (_, _) async {},
                    ),
                  ),
                ),
              ),
              instanceHeader: const Align(
                alignment: Alignment.centerLeft,
                child: ServerConnectionLabel(label: 'Home server'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit group Research team'));
      await tester.pumpAndSettle();
      expect(find.byType(BotsCreateScreen), findsOneWidget);
      expect(find.byType(BotGroupScreen), findsNothing);
      expect(fixture.commands, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actions for Research team'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit group'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-save')), findsOneWidget);
      expect(fixture.commands, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research team').first);
      await tester.pumpAndSettle();
      expect(find.byType(BotGroupScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Edit group'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-name')),
        'Updated discussion',
      );
      await tester.pump();
      expect(session.state.groups.single.iconRevision, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('group-name')))
            .enabled,
        true,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('group-save')))
            .onPressed,
        isNotNull,
      );
      expect(session.state.busy, false);
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(session.state.errors, isEmpty);
      expect(
        fixture.room['name'],
        'Updated discussion',
        reason: fixture.commands.map((c) => c.$2).join(', '),
      );
      expect(find.byType(BotsCreateScreen), findsNothing);
      expect(find.byType(BotGroupScreen), findsOneWidget);
      expect(find.text('Updated discussion'), findsOneWidget);
      expect(find.text('Research team'), findsNothing);
      expect(fixture.commands.where((c) => c.$2 == 'groups.create'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('group creation layout ${brightness.name} $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final semantics = tester.ensureSemantics();
        final size = scale == 1 ? const Size(390, 844) : const Size(320, 640);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        fixture.profiles.addAll([
          BotsFixture.profile('pace', 'Pace'),
          BotsFixture.profile('butler', 'Butler'),
          BotsFixture.profile('reminder', 'Reminder inbox'),
        ]);
        for (var index = 0; index < fixture.profiles.length; index++) {
          fixture.profiles[index]['ui_meta']['hermes-bots']['shape'] =
              botShapes[index];
        }
        if (scale == 2) {
          fixture.profiles.last['ui_meta']['hermes-bots']['title'] =
              'Reminder inbox with a long name';
        }
        final session = BotsSession((_) async => [fixture.repository]);
        addTearDown(session.dispose);
        await session.refresh();
        final frame = GlobalKey();
        var keyboard = false;
        late StateSetter setMedia;
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => StatefulBuilder(
              builder: (context, setState) {
                setMedia = setState;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    viewInsets: EdgeInsets.only(bottom: keyboard ? 240 : 0),
                  ),
                  child: RepaintBoundary(key: frame, child: child),
                );
              },
            ),
            home: BotsCreateScreen(session: session, group: true),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.byKey(const ValueKey('group-create'));
        IconButton create() => tester.widget<IconButton>(action);
        expect(create().onPressed, isNull);
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('group-name')))
              .autofocus,
          false,
        );
        await _capture(
          tester,
          frame,
          'group-creation-empty-${brightness.name}-$scale',
        );
        await _revealGroup(tester, find.text('0 of 6 selected'));
        expect(find.text('0 of 6 selected'), findsOneWidget);
        await _revealGroup(
          tester,
          find.byKey(const ValueKey('group-name')),
          delta: -120,
        );
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          'Launch team',
        );
        for (final profile in ['atlas', 'mira']) {
          final row = find.byKey(ValueKey('group-member-instance-1/$profile'));
          await _revealGroup(tester, row);
          await tester.pumpAndSettle();
          await tester.tapAt(
            tester
                .getRect(row)
                .intersect(tester.getRect(find.byType(ListView)))
                .center,
          );
          await tester.pumpAndSettle();
          expect(row, findsNothing);
          final picked = find.byKey(
            ValueKey('group-picked-instance-1/$profile'),
          );
          await _revealGroup(tester, picked, delta: -120);
          expect(picked, findsOneWidget);
          expect(
            tester.getSemantics(picked).flagsCollection.isSelected,
            ui.Tristate.isTrue,
          );
          final remove = find.byTooltip(
            'Remove ${profile == 'atlas' ? 'Atlas' : 'Mira'}',
          );
          expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
          final search = find.byKey(
            const ValueKey('group-member-search-instance-1'),
          );
          expect(
            tester.getRect(picked).bottom,
            lessThanOrEqualTo(tester.getRect(search).top),
          );
        }
        expect(create().onPressed, isNotNull);
        final icon = tester.widget<BotGroupPicture>(
          find.byType(BotGroupPicture).last,
        );
        expect(icon.avatars.map((bot) => bot?.profile.name), ['atlas', 'mira']);
        expect(icon.color?.slot, isNotNull);
        expect(
          find.descendant(
            of: find.byType(BotGroupPicture).last,
            matching: find.byType(BotAvatar),
          ),
          findsNWidgets(2),
        );
        await _revealGroup(tester, find.text('Members'), delta: -120);
        expect(find.text('2 of 6 selected'), findsOneWidget);
        expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        await _revealGroup(
          tester,
          find.byKey(const ValueKey('group-member-instance-1/reminder')),
        );
        await _capture(
          tester,
          frame,
          'group-creation-members-${brightness.name}-$scale',
        );
        await tester.drag(find.byType(ListView), const Offset(0, 1400));
        await tester.pumpAndSettle();
        await _capture(
          tester,
          frame,
          'group-creation-selected-${brightness.name}-$scale',
        );
        setMedia(() => keyboard = true);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(action).bottom,
          lessThanOrEqualTo(size.height - 240),
        );
        await _capture(
          tester,
          frame,
          'group-creation-keyboard-${brightness.name}-$scale',
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('group creation picture options ${brightness.name} $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = scale == 1
            ? const Size(390, 844)
            : const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        final session = BotsSession((_) async => [fixture.repository]);
        addTearDown(session.dispose);
        await session.refresh();
        final draft = BotGroupDraftSession(
          session,
          pictureIo: _RoomPicturePicker(),
        );
        for (final bot in draft.bots.take(2)) {
          draft.select(bot, true);
        }
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: frame, child: child),
            ),
            home: BotsCreateScreen(
              session: session,
              group: true,
              createGroupDraft: () => draft,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('group-create')))
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('group-name')))
              .controller!
              .text,
          isEmpty,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('Upload room picture'));
          for (var attempt = 0; draft.pictureBusy && attempt < 500; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(draft.picture, isNotNull);
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(draft.picture!),
            tester.element(find.byType(BotGroupPicture).first),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<BotGroupPicture>(find.byType(BotGroupPicture))
              .every((picture) => picture.image != null),
          true,
        );
        expect(find.byTooltip('Remove room picture'), findsOneWidget);
        await _capture(
          tester,
          frame,
          'group-creation-picture-${brightness.name}-$scale',
        );
        await tester.tap(find.byTooltip('Generate room picture'));
        await tester.pumpAndSettle();
        expect(find.text('Room picture'), findsOneWidget);
        expect(find.text('Room picture').hitTestable(), findsOneWidget);
        expect(find.byType(TextFormField).hitTestable(), findsOneWidget);
        for (final tooltip in [
          'Cancel picture generation',
          'Generate picture',
        ]) {
          final target = tester.getRect(find.byTooltip(tooltip));
          expect(target.width, greaterThanOrEqualTo(48));
          expect(target.height, greaterThanOrEqualTo(48));
        }
        final panel = tester.getRect(
          find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(Material),
              )
              .first,
        );
        final promptField = tester.getRect(find.byType(TextFormField));
        expect(promptField.left, greaterThan(panel.left));
        expect(promptField.right, lessThan(panel.right));
        expect(
          tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
          contains('Atlas, Mira'),
        );
        await _capture(
          tester,
          frame,
          'group-creation-prompt-${brightness.name}-$scale',
        );
        const editedPrompt = 'Two friendly robots beside a teal wing, no text.';
        await tester.enterText(find.byType(TextFormField), editedPrompt);
        await tester.tap(find.byTooltip('Cancel picture generation'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Generate room picture'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
          editedPrompt,
          reason: 'Closing the prompt must retain the text for the next edit.',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byTooltip('Generate picture')).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height - 240),
        );
        await _capture(
          tester,
          frame,
          'group-prompt-keyboard-${brightness.name}-$scale',
        );
        await tester.enterText(find.byType(TextFormField), '   ');
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Generate picture',
                ),
              )
              .onPressed,
          isNull,
        );
        await _capture(
          tester,
          frame,
          'group-prompt-empty-${brightness.name}-$scale',
        );
        await tester.enterText(find.byType(TextFormField), editedPrompt);
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Generate picture',
                ),
              )
              .onPressed,
          isNotNull,
        );
        for (final tooltip in [
          'Cancel picture generation',
          'Generate picture',
        ]) {
          final target = tester.getRect(find.byTooltip(tooltip));
          expect(target.top, greaterThanOrEqualTo(0));
          expect(
            target.bottom,
            lessThanOrEqualTo(tester.view.physicalSize.height - 240),
          );
          expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Cancel picture generation'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        fixture.commandHook = (_, method, _) async {
          if (method == 'image.generate') {
            throw StateError('Provider unavailable');
          }
          return null;
        };
        await tester.tap(find.byTooltip('Generate room picture'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Generate picture'));
        await tester.pumpAndSettle();
        expect(draft.error, contains('could not be prepared'));
        expect(draft.picture, isNotNull);
        expect(fixture.commands.single.$3['prompt'], editedPrompt);
        await _capture(
          tester,
          frame,
          'group-prompt-error-${brightness.name}-$scale',
        );
        await _revealGroup(tester, find.byTooltip('Generate room picture'));
        await tester.tap(find.byTooltip('Generate room picture'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
          editedPrompt,
        );
        await tester.tap(find.byTooltip('Cancel picture generation'));
        await tester.pumpAndSettle();
        await _revealGroup(tester, find.byTooltip('Remove Atlas'));
        await tester.tap(find.byTooltip('Remove Atlas'));
        await tester.pumpAndSettle();
        expect(draft.selected.single.title, 'Mira');
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('group-create')))
              .onPressed,
          isNull,
        );
        await _revealGroup(
          tester,
          find.byTooltip('Remove room picture'),
          delta: -120,
        );
        await tester.tap(find.byTooltip('Remove room picture'));
        await tester.pumpAndSettle();
        expect(draft.picture, isNull);
        expect(fixture.commands.single.$2, 'image.generate');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets(
    'group creation search retains selection and enforces six members',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = BotsFixture();
      fixture.profiles.addAll([
        for (final name in ['pace', 'butler', 'reminder', 'memory'])
          BotsFixture.profile(
            name,
            name == 'reminder' ? 'Reminder inbox with a long name' : name,
          ),
      ]);
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      await session.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: BotsCreateScreen(session: session, group: true),
        ),
      );
      await tester.pumpAndSettle();
      final search = find.byKey(
        const ValueKey('group-member-search-instance-1'),
      );
      for (final profile in [
        'atlas',
        'mira',
        'forge',
        'pace',
        'butler',
        'reminder',
      ]) {
        final row = find.byKey(ValueKey('group-member-instance-1/$profile'));
        await _revealGroup(tester, row);
        await tester.pumpAndSettle();
        await tester.tapAt(
          tester
              .getRect(row)
              .intersect(tester.getRect(find.byType(ListView)))
              .center,
        );
        await tester.pumpAndSettle();
      }
      await _revealGroup(tester, find.text('Members'), delta: -120);
      expect(find.text('6 of 6 selected'), findsOneWidget);
      final extra = find.byKey(
        const ValueKey('group-member-instance-1/memory'),
      );
      await _revealGroup(tester, extra);
      expect(tester.widget<ListTile>(extra).onTap, isNull);
      await _revealGroup(tester, search, delta: -120);
      await tester.enterText(search, '@bot_atlas');
      await tester.pumpAndSettle();
      final atlas = find.byKey(const ValueKey('group-member-instance-1/atlas'));
      expect(atlas, findsNothing);
      final pickedAtlas = find.byKey(
        const ValueKey('group-picked-instance-1/atlas'),
      );
      expect(pickedAtlas, findsOneWidget);
      await _revealGroup(tester, find.byTooltip('Remove Atlas'), delta: -120);
      await tester.tap(find.byTooltip('Remove Atlas'));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(atlas).selected, false);
      expect(tester.widget<ListTile>(atlas).onTap, isNotNull);
      expect(find.text('5 of 6 selected'), findsOneWidget);
      await tester.enterText(search, 'no matching bot');
      await tester.pumpAndSettle();
      expect(find.text('No bots match your search.'), findsOneWidget);
      expect(find.text('5 of 6 selected'), findsOneWidget);
      await tester.enterText(search, 'memory');
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(extra).onTap, isNotNull);
      await tester.tap(extra);
      await tester.pumpAndSettle();
      expect(find.text('6 of 6 selected'), findsOneWidget);
      expect(fixture.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group creation holds inputs and retries the same room ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final held = Completer<Map<String, dynamic>>();
          final iconMeta = <String, dynamic>{};
          final iconRevisions = <String, int>{};
          fixture.readHook = (_, method, params) async =>
              method == 'profiles.list' && params['include_sessions'] == false
              ? {
                  'profiles': [
                    {
                      'name': 'default',
                      'ui_meta': iconMeta,
                      'ui_meta_revisions': iconRevisions,
                    },
                  ],
                }
              : null;
          Future<Map<String, dynamic>?> saveIcon(
            String _,
            String method,
            Map<String, dynamic> params,
          ) async {
            if (method != 'profiles.configure') return null;
            final incoming = params['ui_meta'] as Map;
            final expected = params['ui_meta_expected_revisions'] as Map;
            final written = <String, int>{};
            for (final key in incoming.keys.cast<String>()) {
              expect(expected[key], iconRevisions[key] ?? 0);
              iconMeta[key] = incoming[key];
              written[key] = iconRevisions[key] = (iconRevisions[key] ?? 0) + 1;
            }
            return {
              'applied': {'ui_meta': true, 'ui_meta_revisions': written},
            };
          }

          fixture.commandHook = (profile, method, params) async =>
              method == 'groups.create'
              ? held.future
              : saveIcon(profile, method, params);
          final session = BotsSession((_) async => [fixture.repository]);
          addTearDown(session.dispose);
          await session.refresh();
          final frame = GlobalKey();
          bool? result;
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open group'),
                    onPressed: () async =>
                        result = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) =>
                                BotsCreateScreen(session: session, group: true),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open group'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('group-name')),
            'Launch team',
          );
          for (final profile in ['atlas', 'mira']) {
            final row = find.byKey(
              ValueKey('group-member-instance-1/$profile'),
            );
            await _revealGroup(tester, row);
            await tester.pumpAndSettle();
            await tester.tapAt(
              tester
                  .getRect(row)
                  .intersect(tester.getRect(find.byType(ListView)))
                  .center,
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('Create group'));
          await tester.pump();
          await tester.drag(find.byType(ListView), const Offset(0, 1400));
          await tester.pump();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.bySemanticsLabel('Creating group'), findsOneWidget);
          expect(
            tester
                .widget<IconButton>(find.byKey(const ValueKey('group-create')))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('group-name')))
                .enabled,
            false,
          );
          expect(
            tester
                .widgetList<ListTile>(find.byType(ListTile))
                .every((row) => row.onTap == null),
            true,
          );
          await tester.drag(find.byType(ListView), const Offset(0, 1400));
          await tester.pump();
          await _capture(
            tester,
            frame,
            'group-creation-pending-${brightness.name}-$scale',
            motion: true,
          );
          held.completeError(StateError('Connection lost before confirmation'));
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text(session.state.errors.first), findsOneWidget);
          expect(
            tester
                .widget<IconButton>(find.byKey(const ValueKey('group-create')))
                .onPressed,
            isNotNull,
          );
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('group-name')),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('group-name')))
                .enabled,
            false,
          );
          await tester.drag(find.byType(ListView), const Offset(0, 1400));
          await tester.pumpAndSettle();
          await _capture(
            tester,
            frame,
            'group-creation-failed-${brightness.name}-$scale',
          );
          fixture.commandHook = saveIcon;
          await tester.tap(find.byTooltip('Create group'));
          await tester.pumpAndSettle();
          final creates = fixture.commands
              .where((c) => c.$2 == 'groups.create')
              .toList();
          expect(creates, hasLength(2));
          expect(creates.last.$3, creates.first.$3);
          expect(creates.first.$3['name'], 'Launch team');
          expect(
            (creates.first.$3['members'] as List).map((m) => m['profile']),
            ['atlas', 'mira'],
          );
          expect(result, true);
          expect(find.text('Open group'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    testWidgets(
      'color taps repaint the saved shape preview before autosave in ${brightness.name}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        final meta = fixture.profiles.first['ui_meta']['hermes-bots'];
        meta['shape'] = 'cloud';
        meta['imageKind'] = 'shape';
        const png =
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
        final bot = (await fixture.repository.bots()).first.withAvatarHint(
          true,
        );
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: RepaintBoundary(
              key: frame,
              child: BotProfileEditor(
                createSession: () => BotProfileEditSession(
                  fixture.repository,
                  bot,
                  savedImage: base64Decode(png),

                  validateImage: (bot) async =>
                      (await fixture.repository.readAvatar(bot)).bytes,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final preview = find.byWidgetPredicate(
          (widget) => widget is BotAvatar && widget.size == 88,
        );
        Future<void> expectPreviewColor(Color expected) async {
          final rect = tester.getRect(preview);
          final sample = Offset(rect.center.dx, rect.top + rect.height * .65);
          final rendered = await tester.runAsync(() async {
            final boundary =
                frame.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final rgba = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final offset =
                (sample.dy.floor() * image.width + sample.dx.floor()) * 4;
            final color = Color.fromARGB(
              rgba!.getUint8(offset + 3),
              rgba.getUint8(offset),
              rgba.getUint8(offset + 1),
              rgba.getUint8(offset + 2),
            );
            image.dispose();
            return color;
          });
          expect(rendered!.toARGB32(), expected.toARGB32());
          expect(tester.widget<BotAvatar>(preview).image, isNull);
        }

        for (final index in [0, 8, 7]) {
          await tester.tap(find.byTooltip('Color ${index + 1}'));
          await tester.pump();
          expect(
            fixture.commands,
            isEmpty,
            reason: 'Preview precedes autosave',
          );
          await expectPreviewColor(desktopProfileSwatches[index]);
        }
        await tester.tap(find.byTooltip('Match profile color'));
        await tester.pump();
        await expectPreviewColor(BotAvatar.resolveColor('', bot.profile.name));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        await expectPreviewColor(BotAvatar.resolveColor('', bot.profile.name));
        expect(
          fixture.commands.single.$3['ui_meta']['hermes-bots']['color'],
          '',
        );
        await _capture(tester, frame, 'editor-live-color-${brightness.name}');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'settings reopens acknowledged avatar after save, removal and shape selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
      final administration = AdministrationFixture('Home server');
      administration.configs['atlas'] = {};
      final fixture = BotsFixture(server: administration.server);
      fixture.commandHook = (_, method, _) async => method == 'image.generate'
          ? {'success': true, 'image_data': png}
          : null;
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      await session.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: BotSettingsScreen(
            profile: administration.server.profile('atlas'),
            bot: session.state.bots.first,
            session: session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openEditor() async {
        await tester.tap(find.text('Edit name & appearance'));
        await tester.pumpAndSettle();
      }

      BotAvatar preview() => tester
          .widgetList<BotAvatar>(
            find.descendant(
              of: find.byType(BotProfileEditor),
              matching: find.byType(BotAvatar),
            ),
          )
          .singleWhere((avatar) => avatar.size == 88);
      Future<void> generate() async {
        await tester.scrollUntilVisible(
          find.byTooltip('Generate avatar'),
          240,
          scrollable: find
              .descendant(
                of: find.byType(BotProfileEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byTooltip('Generate avatar'));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      await openEditor();
      await generate();
      await openEditor();
      expect(preview().image, orderedEquals(base64Decode(png)));
      await tester.scrollUntilVisible(
        find.byTooltip('Remove avatar'),
        240,
        scrollable: find
            .descendant(
              of: find.byType(BotProfileEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byTooltip('Remove avatar'));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openEditor();
      expect(preview().image, isNull);
      await generate();
      await openEditor();
      await tester.ensureVisible(find.byTooltip('triangle'));
      await tester.tap(find.byTooltip('triangle'));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fixture.commands.last.$3['clear'], true);
      await openEditor();
      expect(preview().image, isNull);
      expect(preview().shape, 'triangle');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'canonical header borrows only its own live activity for motion',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final browser = _BotConversationBrowser();
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Home server',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'instance-1',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: browser.gateway,
      );
      await controller.initialize();
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'canonical-root'));
      final bots = BotsFixture();
      bots.profiles
        ..clear()
        ..add(BotsFixture.profile(scope.profileName, 'Atlas'));
      bots.profiles.single['canonical_session'] = {
        'id': 'canonical-root',
        'resolved_id': 'canonical-tip',
      };
      bots.profiles.single['ui_meta']['hermes-bots']['imageKind'] = 'shape';
      var reads = 0;
      bots.readHook = (_, _, _) async {
        reads++;
        return null;
      };
      final frame = GlobalKey();
      var brightness = Brightness.dark;
      var scale = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget host() => MaterialApp(
        theme: wingTheme(brightness),
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: frame,
          child: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () =>
                BotsSession((_) async => [bots.repository]),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.settleMarkdown();
      final face = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(LiveBotAvatar),
      );
      expect(face, findsOneWidget);
      BotAvatarMood mood() => tester.widget<LiveBotAvatar>(face).mood;
      expect(mood(), BotAvatarMood.idle);
      final chat = controller.current!.chat!;
      emitChatEvent(controller, chat, 'message.start');
      await tester.pump();
      expect(mood(), BotAvatarMood.idle);
      emitChatEvent(controller, chat, 'reasoning.delta', {
        'text': 'Considering the plan.',
      });
      await tester.pump();
      expect(mood(), BotAvatarMood.idle);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.settleMarkdown();
      await _capture(tester, frame, 'animated-canonical-header', motion: true);
      for (final theme in Brightness.values) {
        for (final textScale in [1.0, 2.0]) {
          brightness = theme;
          scale = textScale;
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          await tester.pumpWidget(host());
          await tester.pump(const Duration(milliseconds: 450));
          await tester.settleMarkdown();
          expect(face.hitTestable(), findsOneWidget);
          await _capture(
            tester,
            frame,
            'animated-canonical-header-${theme.name}-$scale',
            motion: true,
          );
          expect(tester.takeException(), isNull);
        }
      }
      emitChatEvent(controller, chat, 'message.complete', {
        'text': 'The plan is ready.',
      });
      await tester.pump();
      expect(mood(), BotAvatarMood.idle);
      final before = reads;
      await tester.pump(const Duration(seconds: 1));
      expect(reads, before);
      expect(bots.commands, isEmpty);
      expect(face.hitTestable(), findsOneWidget);
      await controller.openSession(ProfileSessionKey(scope, 'ordinary'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(LiveBotAvatar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      appPreferences.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'roster actions reach their selected bot and group ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final administration = AdministrationFixture('Home server');
          administration.configs['atlas'] = {};
          final fixture = BotsFixture(server: administration.server);
          final session = BotsSession((_) async => [fixture.repository]);
          try {
            await session.refresh();
            var view = const BotsViewState();
            final opened = <String>[];
            final frame = GlobalKey();
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: StatefulBuilder(
                  builder: (context, setState) => BotsContent(
                    instanceHeader: const Align(
                      alignment: Alignment.centerLeft,
                      child: ServerConnectionLabel(label: 'Home server'),
                    ),
                    session: session,
                    viewState: view,
                    onViewChanged: (next) => setState(() => view = next),
                    onOpenMenu: () {},
                    onOpenGroupMemberChat: (_, _) async {},
                    onOpenChat: (bot) async {
                      final key = await session.open(bot, canUse: () => true);
                      if (key != null) opened.add(key.sessionId);
                    },
                    onOpenGroup: (group) => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => BotGroupScreen(
                          stopVoicePlayback: () async {},
                          voiceInputSettings: () =>
                              const LocalVoiceInputSettings(language: ''),
                          createSession: () => session.openGroup(group),
                          onEdit: (group) => openGroupEditor(
                            context,
                            session,
                            group,
                            onOpenMemberChat: (_, _) async {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final atlas = find.byKey(const ValueKey('bot-instance-1/atlas'));
            final forge = find.byKey(const ValueKey('bot-instance-1/forge'));
            expect(
              tester.getTopLeft(atlas).dy,
              lessThan(tester.getTopLeft(forge).dy),
            );
            expect(find.text('All saved instances'), findsNothing);
            expect(find.byType(ServerConnectionLabel), findsOneWidget);
            expect(
              tester.getBottomLeft(find.byType(ServerConnectionLabel)).dy,
              lessThanOrEqualTo(tester.getTopLeft(find.byType(TabBar)).dy),
            );
            expect(find.byIcon(Icons.refresh), findsNothing);
            expect(find.byType(FloatingActionButton), findsOneWidget);
            expect(find.byTooltip('Create bot'), findsOneWidget);
            expect(find.byTooltip('Create bot').hitTestable(), findsOneWidget);
            expect(find.byType(RefreshIndicator), findsNothing);
            expect(find.text('Pinned'), findsNothing);
            expect(find.byTooltip('Pinned'), findsOneWidget);
            final previews = tester
                .widgetList<Text>(find.byType(Text))
                .where(
                  (text) => text.data?.startsWith('I found three') == true,
                );
            expect(previews.single.overflow, TextOverflow.ellipsis);
            await _capture(tester, frame, 'bots-${brightness.name}-$scale');
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -1200),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .getBottomRight(
                    find.byKey(const ValueKey('bot-instance-1/mira')),
                  )
                  .dy,
              lessThan(tester.getTopLeft(find.byType(FloatingActionButton)).dy),
            );
            expect(
              find.byTooltip('Actions for Mira').hitTestable(),
              findsOneWidget,
            );
            await _capture(
              tester,
              frame,
              'bots-bottom-${brightness.name}-$scale',
            );
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, 1200),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Groups').first);
            await tester.pumpAndSettle();
            expect(find.text('Research team'), findsOneWidget);
            expect(find.byTooltip('Create group'), findsOneWidget);
            expect(find.text('Atlas'), findsNothing);
            final groupIcon = find.byTooltip('Edit group Research team');
            expect(tester.getSize(groupIcon).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(groupIcon).height, greaterThanOrEqualTo(48));
            await _capture(tester, frame, 'groups-${brightness.name}-$scale');
            await tester.tap(groupIcon);
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsOneWidget);
            expect(find.byType(BotGroupScreen), findsNothing);
            expect(fixture.commands, isEmpty);
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.text('Research team'), findsOneWidget);
            expect(find.byTooltip('Create group'), findsOneWidget);
            await tester.tap(find.widgetWithText(Tab, 'Bots'));
            await tester.pumpAndSettle();
            final avatar = find.byTooltip('Edit name & appearance for Atlas');
            expect(tester.getSize(avatar).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(avatar).height, greaterThanOrEqualTo(48));
            await tester.tap(avatar);
            await tester.pumpAndSettle();
            expect(find.byType(BotProfileEditor), findsOneWidget);
            expect(opened, isEmpty);
            expect(fixture.commands, isEmpty);
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Atlas').last);
            await tester.pumpAndSettle();
            expect(opened, ['atlas-chat']);
            await tester.tap(find.byTooltip('Actions for Atlas'));
            await tester.pumpAndSettle();
            await _capture(tester, frame, 'menu-${brightness.name}-$scale');
            expect(
              tester
                  .widgetList<PopupMenuItem<String>>(
                    find.byWidgetPredicate(
                      (widget) => widget is PopupMenuItem<String>,
                    ),
                  )
                  .map((item) => item.value)
                  .whereType<String>()
                  .toList(),
              ['screen', 'pin', 'hide', 'settings'],
            );
            expect(tester.takeException(), isNull);
          } finally {
            session.dispose();
            await tester.pumpWidget(const SizedBox.shrink());
            administration.server.close();
          }
        },
      );
      testWidgets(
        'bot appearance conflict recovery retains acknowledged edits ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final administration = AdministrationFixture('Home server');
          administration.configs['atlas'] = {};
          final fixture = BotsFixture(server: administration.server);
          final session = BotsSession((_) async => [fixture.repository]);
          try {
            await session.refresh();
            var view = const BotsViewState();
            final opened = <String>[];
            final frame = GlobalKey();
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: StatefulBuilder(
                  builder: (context, setState) => BotsContent(
                    instanceHeader: const Align(
                      alignment: Alignment.centerLeft,
                      child: ServerConnectionLabel(label: 'Home server'),
                    ),
                    session: session,
                    viewState: view,
                    onViewChanged: (next) => setState(() => view = next),
                    onOpenMenu: () {},
                    onOpenGroupMemberChat: (_, _) async {},
                    onOpenChat: (bot) async {
                      final key = await session.open(bot, canUse: () => true);
                      if (key != null) opened.add(key.sessionId);
                    },
                    onOpenGroup: (group) => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => BotGroupScreen(
                          stopVoicePlayback: () async {},
                          voiceInputSettings: () =>
                              const LocalVoiceInputSettings(language: ''),
                          createSession: () => session.openGroup(group),
                          onEdit: (group) => openGroupEditor(
                            context,
                            session,
                            group,
                            onOpenMemberChat: (_, _) async {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.byTooltip('Actions for Atlas'));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('bot-menu-settings')));
            await tester.pumpAndSettle();
            expect(find.text('Bot settings'), findsOneWidget);
            expect(find.text('Rename profile'), findsNothing);
            await _capture(tester, frame, 'settings-${brightness.name}-$scale');
            await tester.tap(find.text('Edit name & appearance'));
            await tester.pumpAndSettle();
            expect(find.byType(BotProfileEditor), findsOneWidget);
            expect(find.byTooltip('Save appearance'), findsNothing);
            await tester.tap(find.byTooltip('Reload saved appearance'));
            await tester.pumpAndSettle();
            expect(
              find.textContaining('Saved appearance reloaded'),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await _capture(tester, frame, 'editor-${brightness.name}-$scale');
            fixture.conflict = true;
            await tester.enterText(
              find.widgetWithText(TextField, 'Bot name'),
              'Atlas draft',
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pumpAndSettle();
            expect(
              find.textContaining('This bot changed in another client'),
              findsOneWidget,
            );
            await _capture(
              tester,
              frame,
              'editor-conflict-${brightness.name}-$scale',
            );
            fixture.conflict = false;
            await tester.tap(find.byTooltip('Reload saved appearance'));
            await tester.pumpAndSettle();
            expect(
              find.textContaining('This bot changed in another client'),
              findsNothing,
            );
            expect(
              find.text('Review your edits before retrying.'),
              findsOneWidget,
            );
            await _capture(
              tester,
              frame,
              'editor-review-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Retry saving appearance'));
            await tester.pumpAndSettle();
            expect(find.byTooltip('Retry saving appearance'), findsNothing);
            await tester.scrollUntilVisible(
              find.byTooltip('Generate avatar'),
              240,
              scrollable: find
                  .descendant(
                    of: find.byType(BotProfileEditor),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await _capture(
              tester,
              frame,
              'editor-bottom-${brightness.name}-$scale',
            );
            expect(find.byTooltip('Upload avatar'), findsOneWidget);
            expect(find.byTooltip('Generate avatar'), findsOneWidget);
            await tester.scrollUntilVisible(
              find.widgetWithText(TextField, 'Bot name'),
              -300,
              scrollable: find
                  .descendant(
                    of: find.byType(BotProfileEditor),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.enterText(
              find.widgetWithText(TextField, 'Bot name'),
              'Atlas revised',
            );
            await tester.pumpAndSettle();
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.text('Discard edits?'), findsNothing);
            expect(find.byType(BotProfileEditor), findsNothing);
            expect(fixture.commands.last.$2, 'profiles.configure');
            // Reopening from settings uses the acknowledged appearance, not the
            // roster snapshot captured when this settings route was opened.
            await tester.tap(find.text('Edit name & appearance'));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<TextField>(find.widgetWithText(TextField, 'Bot name'))
                  .controller!
                  .text,
              'Atlas revised',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Duplicate bot'), 240);
            await tester.ensureVisible(find.text('Duplicate bot'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Duplicate bot'));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<BotsCreateScreen>(find.byType(BotsCreateScreen))
                  .clone!
                  .profile
                  .name,
              'atlas',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Advanced'), 240);
            await tester.tap(find.text('Advanced'));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Rename profile'), 240);
            expect(
              find.text('Change the underlying profile name'),
              findsOneWidget,
            );
            await tester.tap(find.text('Rename profile'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            await tester.tap(find.byTooltip('Cancel').last);
            await tester.pumpAndSettle();
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.text('Bot settings'), findsOneWidget);
            await tester.scrollUntilVisible(find.byTooltip('Delete bot'), 240);
            expect(
              tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is IconButton &&
                          widget.tooltip == 'Delete bot',
                    ),
                  )
                  .onPressed,
              isNotNull,
            );
            await _capture(
              tester,
              frame,
              'settings-bottom-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Delete bot'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            await tester.tap(find.byTooltip('Cancel').last);
            await tester.pumpAndSettle();
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.text('Bot settings'), findsOneWidget);
            expect(
              administration.requests.where((request) => request.$1 != 'GET'),
              isEmpty,
            );
            expect(tester.takeException(), isNull);
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          } finally {
            session.dispose();
            await tester.pumpWidget(const SizedBox.shrink());
            administration.server.close();
          }
        },
      );
      testWidgets(
        'group send retry preserves one accepted message ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final administration = AdministrationFixture('Home server');
          administration.configs['atlas'] = {};
          final fixture = BotsFixture(server: administration.server);
          final session = BotsSession((_) async => [fixture.repository]);
          try {
            await session.refresh();
            var view = const BotsViewState();
            final opened = <String>[];
            final frame = GlobalKey();
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: StatefulBuilder(
                  builder: (context, setState) => BotsContent(
                    instanceHeader: const Align(
                      alignment: Alignment.centerLeft,
                      child: ServerConnectionLabel(label: 'Home server'),
                    ),
                    session: session,
                    viewState: view,
                    onViewChanged: (next) => setState(() => view = next),
                    onOpenMenu: () {},
                    onOpenGroupMemberChat: (_, _) async {},
                    onOpenChat: (bot) async {
                      final key = await session.open(bot, canUse: () => true);
                      if (key != null) opened.add(key.sessionId);
                    },
                    onOpenGroup: (group) => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => BotGroupScreen(
                          stopVoicePlayback: () async {},
                          voiceInputSettings: () =>
                              const LocalVoiceInputSettings(language: ''),
                          createSession: () => session.openGroup(group),
                          onEdit: (group) => openGroupEditor(
                            context,
                            session,
                            group,
                            onOpenMemberChat: (_, _) async {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            session.setVisible(false);
            await tester.tap(find.byTooltip('Create bot'));
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsOneWidget);
            await _capture(tester, frame, 'create-${brightness.name}-$scale');
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(Tab, 'Groups'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Create group'));
            await tester.pumpAndSettle();
            await _capture(
              tester,
              frame,
              'create-group-${brightness.name}-$scale',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Research team'));
            await tester.pumpAndSettle();
            fixture.sendLost = true;
            await tester.enterText(
              find.byType(TextField),
              'Please review the plan',
            );
            await tester.pump();
            await tester.tap(find.byTooltip('Send group message'));
            await tester.pumpAndSettle();
            expect(find.byTooltip('Retry same message'), findsOneWidget);
            expect(
              tester.widget<TextField>(find.byType(TextField)).readOnly,
              true,
            );
            expect(find.byType(ActionChip), findsNothing);
            await _capture(
              tester,
              frame,
              'group-retry-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Retry same message'));
            await tester.pumpAndSettle();
            expect(fixture.events, hasLength(1));
            await _capture(
              tester,
              frame,
              'group-chat-${brightness.name}-$scale',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(Tab, 'Bots'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          } finally {
            session.dispose();
            await tester.pumpWidget(const SizedBox.shrink());
            administration.server.close();
          }
        },
      );
      testWidgets(
        'bot screen menu opens the captured display lease ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final administration = AdministrationFixture('Home server');
          administration.configs['atlas'] = {};
          final status = ServerConnectionStatus('Home server')
            ..accessAvailable()
            ..liveChanged('default', true);
          final otherStatus = ServerConnectionStatus('Home server');
          addTearDown(status.dispose);
          addTearDown(otherStatus.dispose);
          final base = administration.server;
          final server = AdministrationRepository(
            connectionId: base.connectionId,
            connectionIdentity: base.connectionIdentity,
            connectionLabel: base.connectionLabel,
            request: base.request,
            settingsWrite: base.settingsWrite,
            ownedMutation: base.ownedMutation,
            gateway: (name) => base.gateway(name)..connectionStatus = status,
          );
          final fixture = BotsFixture(server: server);
          final session = BotsSession((_) async => [fixture.repository]);
          await session.refresh();
          var view = const BotsViewState();
          final opened = <String>[];
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          addTearDown(session.dispose);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: ServerConnectionScope(
                  status: otherStatus,
                  child: RepaintBoundary(key: frame, child: child!),
                ),
              ),
              home: StatefulBuilder(
                builder: (context, setState) => BotsContent(
                  instanceHeader: const Align(
                    alignment: Alignment.centerLeft,
                    child: ServerConnectionLabel(label: 'Home server'),
                  ),
                  session: session,
                  viewState: view,
                  onViewChanged: (next) => setState(() => view = next),
                  onOpenMenu: () {},
                  onOpenGroupMemberChat: (_, _) async {},
                  onOpenChat: (bot) async {
                    final key = await session.open(bot, canUse: () => true);
                    if (key != null) opened.add(key.sessionId);
                  },
                  onOpenGroup: (group) => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => BotGroupScreen(
                        stopVoicePlayback: () async {},
                        voiceInputSettings: () =>
                            const LocalVoiceInputSettings(language: ''),
                        createSession: () => session.openGroup(group),
                        onEdit: (group) => openGroupEditor(
                          context,
                          session,
                          group,
                          onOpenMemberChat: (_, _) async {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          fixture.readHook = (_, method, _) async => method == 'display.status'
              ? {
                  'supported': true,
                  'installed': true,
                  'running': false,
                  'lease': {
                    'holder': 'human',
                    'viewer_hash': 'abcd1234abcd',
                    'epoch': 1,
                  },
                }
              : null;
          await tester.tap(find.byTooltip('Actions for Atlas'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('bot-menu-screen')));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Human has control'), findsOneWidget);
          final screenHeader = tester.widget<ServerConnectionLabel>(
            find.byType(ServerConnectionLabel),
          );
          expect(screenHeader.status, same(status));
          final led = find.byKey(const ValueKey('server-connection-led'));
          final tokens = Theme.of(tester.element(led)).extension<WingTokens>()!;
          Color? ledColor() =>
              (tester.widget<Container>(led).decoration! as BoxDecoration)
                  .color;
          expect(ledColor(), tokens.success);
          otherStatus.beginRecovery('unrelated-instance');
          await tester.pump();
          expect(ledColor(), tokens.success);
          status.beginRecovery('display-instance');
          await tester.pump();
          expect(ledColor(), tokens.warning);
          status.endRecovery('display-instance');
          await tester.pump();
          expect(ledColor(), tokens.success);
          await _capture(
            tester,
            frame,
            'screen-privacy-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('latest activity orders bots ${brightness.name} $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = scale == 1
            ? const Size(390, 844)
            : const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var now = DateTime.now();
        final fixture = BotsFixture();
        fixture.profiles[0]['canonical_session'] = <String, dynamic>{
          ...fixture.profiles[0]['canonical_session'],
          'last_active': 1000,
        };
        fixture.profiles[1]['last_session'] = <String, dynamic>{
          ...fixture.profiles[1]['last_session'],
          'last_active': 3000,
        };
        fixture.profiles[2]['worker_session'] = {
          'id': 'forge-worker',
          'source': 'tool',
          'last_active': 2000,
        };
        final session = BotsSession(
          (_) async => [fixture.repository],
          now: () => now,
        );
        addTearDown(session.dispose);
        await session.refresh();
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: RepaintBoundary(
              key: frame,
              child: BotsContent(
                instanceHeader: const ServerConnectionLabel(
                  label: 'Home server',
                ),
                session: session,
                viewState: const BotsViewState(),
                onViewChanged: (_) {},
                onOpenMenu: () {},
                onOpenGroupMemberChat: (_, _) async {},
                onOpenChat: (_) async {},
                onOpenGroup: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        double top(String name) =>
            tester.getTopLeft(find.byKey(ValueKey('bot-instance-1/$name'))).dy;
        expect(top('mira'), lessThan(top('forge')));
        expect(top('forge'), lessThan(top('atlas')));
        await _capture(
          tester,
          frame,
          'activity-order-${brightness.name}-$scale',
        );
        fixture.profiles[0]['canonical_session'] = <String, dynamic>{
          ...fixture.profiles[0]['canonical_session'],
          'last_active': 4000,
        };
        now = now.add(const Duration(seconds: 30));
        await session.refresh();
        await tester.pumpAndSettle();
        expect(top('atlas'), lessThan(top('mira')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('search and hidden bots never write profiles', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = BotsFixture();
    var rosterReads = 0;
    fixture.readHook = (_, method, _) async {
      if (method == 'profiles.list') rosterReads++;
      return null;
    };
    fixture.profiles.first['ui_meta']['hermes-bots']['hidden'] = true;
    final session = BotsSession((_) async => [fixture.repository]);
    addTearDown(session.dispose);
    await session.refresh();
    var view = const BotsViewState();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        theme: wingTheme(Brightness.dark),
        home: StatefulBuilder(
          builder: (context, setState) => BotsContent(
            instanceHeader: const Align(
              alignment: Alignment.centerLeft,
              child: ServerConnectionLabel(label: 'Home server'),
            ),
            session: session,
            viewState: view,
            onViewChanged: (next) => setState(() => view = next),
            onOpenMenu: () {},
            onOpenGroupMemberChat: (_, _) async {},
            onOpenChat: (_) async {},
            onOpenGroup: (group) => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => session.openGroup(group),
                  onEdit: (group) => openGroupEditor(
                    context,
                    session,
                    group,
                    onOpenMemberChat: (_, _) async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Atlas'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('bots-search')), 'Mira');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-instance-1/mira')), findsOneWidget);
    expect(find.text('Forge'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Forge'), findsOneWidget);
    expect(find.text('Mira'), findsOneWidget);
    final beforeMenu = rosterReads;
    await tester.tap(find.byTooltip('Roster options'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh bots and groups'), findsNothing);
    await tester.tap(find.byType(CheckedPopupMenuItem<String>));
    await tester.pumpAndSettle();
    expect(view.showHidden, true);
    expect(rosterReads, beforeMenu);
    expect(find.text('Forge'), findsOneWidget);
    await tester.fling(find.byType(ListView).first, const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(rosterReads, beforeMenu);
    expect(fixture.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['default', 'rename', 'delete']) {
    testWidgets(
      'Bot settings protects or retires the captured profile: $action',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final administration = AdministrationFixture('Captured server');
        final name = action == 'default' ? 'default' : 'atlas';
        administration.configs[name] = {};
        final fixture = BotsFixture(server: administration.server);
        fixture.profiles
          ..clear()
          ..add(BotsFixture.profile(name, 'Atlas'));
        final session = BotsSession((_) async => [fixture.repository]);
        addTearDown(session.dispose);
        await session.refresh();
        var writes = 0;
        administration.mutationOverride =
            (method, path, query, body, canDispatch, onDispatched) async {
              expect(canDispatch(), true);
              onDispatched();
              writes++;
              expect(path, 'profiles/atlas');
              expect(method, action == 'rename' ? 'PATCH' : 'DELETE');
              administration.configs.remove('atlas');
              if (action == 'rename') administration.configs['renamed'] = {};
              return {'ok': true, 'path': '/profiles/atlas', 'name': 'renamed'};
            };
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: IconButton(
                  tooltip: 'Open settings',
                  icon: const Icon(Icons.tune),
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BotSettingsScreen(
                        profile: administration.server.profile(name),
                        bot: session.state.bots.single,
                        session: session,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Open settings'));
        await tester.pumpAndSettle();
        if (action == 'default') {
          await tester.scrollUntilVisible(find.byTooltip('Delete bot'), 240);
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is IconButton && widget.tooltip == 'Delete bot',
                  ),
                )
                .onPressed,
            isNull,
          );
          expect(
            find.text('The default profile cannot be deleted'),
            findsOneWidget,
          );
          expect(writes, 0);
        } else {
          if (action == 'rename') {
            await tester.scrollUntilVisible(find.text('Advanced'), 240);
            await tester.tap(find.text('Advanced'));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Rename profile'), 240);
            await tester.tap(find.text('Rename profile'));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextFormField), 'renamed');
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Save profile name'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Rename').last);
          } else {
            await tester.scrollUntilVisible(find.byTooltip('Delete bot'), 240);
            await tester.tap(find.byTooltip('Delete bot'));
            await tester.pumpAndSettle();
            expect(writes, 0);
            await tester.tap(find.byTooltip('Delete profile'));
          }
          await tester.pumpAndSettle();
          expect(writes, 1);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(BotSettingsScreen), findsNothing);
          expect(find.byTooltip('Open settings'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Chats profile long press opens exact Bot chat and returns to Chats ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final browser = _BotConversationBrowser();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'host',
                label: 'Home server',
                host: 'localhost',
                port: 1,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'instance-1',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: (scope) {
              final base = browser.gateway(scope);
              return ProfileGateway(
                scope: scope,
                discover: base.discover,
                get: base.read,
                rpc: base.call,
                ownedPatch: (endpoint, body, canDispatch, onDispatched) async {
                  expect(canDispatch(), isTrue);
                  expect(body['unread'], isFalse);
                  onDispatched();
                  return {'ok': true, 'unread': false};
                },
              );
            },
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          final bots = BotsFixture();
          bots.profiles
            ..clear()
            ..addAll([
              BotsFixture.profile('personal', 'Personal Bot'),
              BotsFixture.profile('work', 'Work Bot'),
            ]);
          for (final profile in bots.profiles) {
            profile['canonical_session'] = {
              'id': 'canonical-root',
              'resolved_id': 'canonical-tip',
            };
          }
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          // The retained app owner can predate saved-connection discovery.
          var sources = <BotsRepository>[];
          var failSources = false;
          Completer<void>? sourceDelay;
          Completer<void>? sourceStarted;
          final botSession = BotsSession((_) async {
            if (sourceStarted case final started?) {
              if (!started.isCompleted) started.complete();
            }
            await sourceDelay?.future;
            if (failSources) throw StateError('Discovery offline');
            return sources;
          });
          await botSession.refresh();
          sources = [bots.repository];
          // Startup warming must also encounter the unavailable discovery;
          // otherwise the retained roster already admits this Bot offline.
          failSources = true;
          final frame = GlobalKey();
          await tester.pumpMarkdownWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: frame,
                child: ProfileWorkspaceScreen(
                  controller: controller,
                  createBotsSession: () => botSession,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
          await tester.pumpAndSettle();
          expect(controller.current!.chat, isNull);
          expect(find.text('Profile 1'), findsOneWidget);
          failSources = true;
          await tester.longPress(
            find.byKey(const ValueKey('chat-profile-personal')),
          );
          await tester.pumpAndSettle();
          expect(find.text('Bot profile is unavailable'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          expect(controller.current!.chat, isNull);
          failSources = false;
          await tester.tap(find.byTooltip('Retry'));
          await tester.pumpAndSettle();
          expect(
            controller.current!.chat!.key.workspace.profileName,
            'personal',
          );
          expect(controller.current!.chat!.key.sessionId, 'canonical-root');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Profile 1'), findsOneWidget);
          for (final profile in ['personal', 'work']) {
            await tester.longPress(
              find.byKey(ValueKey('chat-profile-$profile')),
            );
            await tester.settleTranscript();
            await tester.pumpAndSettle();
            expect(find.text('Bot profile is unavailable'), findsNothing);
            expect(controller.current!.chat, isNotNull);
            expect(
              controller.current!.chat!.key.workspace.profileName,
              profile,
            );
            expect(controller.current!.chat!.key.sessionId, 'canonical-root');
            expect(controller.current!.chat!.markReadFailed, isFalse);
            expect(
              find.text(profile == 'personal' ? 'Personal Bot' : 'Work Bot'),
              findsNWidgets(2),
            );
            expect(find.byType(BotAvatar), findsNWidgets(2));
            expect(find.byType(BotsContent), findsNothing);
            expect(bots.commands, isEmpty);
            expect(
              browser.calls.where((call) => call.$2 == 'session.create'),
              isEmpty,
            );
            await tester.settleMarkdown();
            await tester.pumpAndSettle();
            expect(
              find.text(
                'Of course. What would you like to make time for this week?',
                findRichText: true,
              ),
              findsOneWidget,
            );
            await _capture(
              tester,
              frame,
              'profile-shortcut-$profile-${brightness.name}-$scale',
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(controller.current!.chat, isNull);
            expect(
              find.byKey(const ValueKey('chat-profile-work')),
              findsOneWidget,
            );
            expect(find.text('Profile 1'), findsOneWidget);
          }
          browser.failHistory = true;
          await tester.longPress(
            find.byKey(const ValueKey('chat-profile-personal')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.byTooltip('Retry'), findsOneWidget);
          await _capture(
            tester,
            frame,
            'profile-shortcut-failed-${brightness.name}-$scale',
          );
          browser.failHistory = false;
          await tester.tap(find.byTooltip('Retry'));
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          expect(
            controller.current!.chat!.key.workspace.profileName,
            'personal',
          );
          expect(controller.current!.chat!.key.sessionId, 'canonical-root');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Profile 1'), findsOneWidget);

          final held = Completer<void>();
          final started = Completer<void>();
          sourceStarted = started;
          sourceDelay = held;
          await tester.longPress(
            find.byKey(const ValueKey('chat-profile-personal')),
          );
          await tester.pump();
          expect(started.isCompleted, isTrue);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            find.byKey(const ValueKey('chat-profile-personal')),
            findsNothing,
          );
          await _capture(
            tester,
            frame,
            'profile-shortcut-pending-${brightness.name}-$scale',
            motion: true,
          );
          await tester.tap(find.byTooltip('Back'));
          await tester.pump();
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.byKey(const ValueKey('nav-settings')));
          await tester.pump(const Duration(milliseconds: 400));
          held.complete();
          await tester.pump(const Duration(milliseconds: 500));
          expect(controller.current!.chat, isNull);
          expect(
            find.byKey(const ValueKey('chat-profile-personal')),
            findsNothing,
          );
          expect(bots.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Bot chat enters immediately through held identity resume and history ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final browser = _BotConversationBrowser();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'host',
                label: 'Home server',
                host: 'localhost',
                port: 1,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'instance-1',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: browser.gateway,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          // An earlier selected chat must never flash beneath the new bot title.
          await controller.openSession(
            ProfileSessionKey(controller.current!.scope, 'ordinary'),
          );
          final bots = BotsFixture();
          bots.profiles
            ..clear()
            ..add(BotsFixture.profile('personal', 'Atlas'));
          bots.profiles.single['canonical_session']['id'] = 'canonical-root';
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: AppDestination.bots,
                createBotsSession: () =>
                    BotsSession((_) async => [bots.repository]),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('bots-search')),
            'Atlas',
          );
          final identity = Completer<void>();
          final resume = browser.resumeDelay = Completer<void>();
          final history = Completer<void>();
          browser.historyDelays[('canonical-root', 0)] = history;
          bots.readHook = (_, method, _) async {
            if (method == 'profiles.list') await identity.future;
            return null;
          };
          await tester.tap(find.text('Atlas').last);
          await tester.pump();
          await tester.pump();
          expect(find.byType(BotsContent), findsNothing);
          expect(find.text('Atlas'), findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byType(ProfileMessage), findsNothing);
          expect(find.byTooltip('Back'), findsOneWidget);
          expect(find.text('You can keep writing'), findsNothing);
          final backRect = tester.getRect(find.byTooltip('Back'));
          await _capture(
            tester,
            frame,
            'bot-opening-${brightness.name}-$scale',
            motion: true,
          );
          identity.complete();
          for (var i = 0; i < 10; i++) {
            await tester.pump();
          }
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.getRect(find.byTooltip('Back')), backRect);
          expect(find.byType(ProfileMessage), findsNothing);
          resume.complete();
          for (var i = 0; i < 10; i++) {
            await tester.pump();
          }
          expect(
            browser.reads.any(
              (read) => read.$1 == 'sessions/canonical-root/messages',
            ),
            isTrue,
          );
          // A slow history response can outlast the former 20-second cutoff.
          await tester.pump(const Duration(seconds: 25));
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byType(BotsContent), findsNothing);
          expect(find.text('You can keep writing'), findsNothing);
          expect(tester.getRect(find.byTooltip('Back')), backRect);
          history.complete();
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(controller.current!.chat!.key.sessionId, 'canonical-root');
          expect(
            find.text(
              'Of course. What would you like to make time for this week?',
              findRichText: true,
            ),
            findsOneWidget,
          );
          expect(find.byType(StudioLoading), findsNothing);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(BotsContent), findsOneWidget);

          // Failed opening stays on the entered screen with a retry action.
          browser.failHistory = true;
          await tester.tap(find.text('Atlas').last);
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(find.byType(BotsContent), findsNothing);
          expect(find.byTooltip('Retry'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          await _capture(
            tester,
            frame,
            'bot-opening-error-${brightness.name}-$scale',
            motion: true,
          );
          browser.failHistory = false;
          await tester.tap(find.byTooltip('Retry'));
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(BotsContent), findsOneWidget);

          // Back retires each I/O phase; later completion cannot select a chat.
          for (final stage in ['identity', 'resume', 'history']) {
            final held = Completer<void>();
            bots.readHook = (_, method, _) async {
              if (stage == 'identity' && method == 'profiles.list') {
                await held.future;
              }
              return null;
            };
            browser.resumeDelay = stage == 'resume' ? held : null;
            browser.historyDelays.remove(('canonical-root', 0));
            if (stage == 'history') {
              browser.historyDelays[('canonical-root', 0)] = held;
            }
            await tester.tap(find.text('Atlas').last);
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(find.byType(StudioLoading), findsOneWidget);
            await tester.binding.handlePopRoute();
            await tester.pump();
            await tester.pump();
            expect(find.byType(BotsContent), findsOneWidget);
            held.complete();
            await tester.pumpAndSettle();
            expect(controller.current!.chat, isNull);
            expect(find.byType(BotsContent), findsOneWidget);
            expect(
              tester
                  .widget<TextField>(find.byKey(const ValueKey('bots-search')))
                  .controller!
                  .text,
              'Atlas',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final entry in [
        'fresh',
        'retained',
        'refresh pending',
        'unread opening',
        'new messages',
      ]) {
        final revisit =
            entry == 'retained' ||
            entry == 'refresh pending' ||
            entry == 'new messages';
        testWidgets(
          'Bot entry preserves reading $entry ${brightness.name} $scale',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            final browser = _BotConversationBrowser()
              ..openingHistory = [
                for (var i = 1; i <= 30; i++)
                  {
                    'id': i,
                    'role': 'assistant',
                    'content':
                        'Earlier reply $i. ${'A paragraph of previous conversation. ' * 12}',
                  },
                {
                  'id': 31,
                  'role': 'user',
                  'content': 'Latest request visible on opening',
                },
              ];
            if (entry == 'unread opening') {
              browser.markReadDelay = Completer<void>();
            }
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: SavedConnection(
                  id: 'host',
                  label: 'Home server',
                  host: 'localhost',
                  port: 1,
                  apiKey: '',
                ),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'instance-1',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: browser.gateway,
            );
            addTearDown(controller.dispose);
            addTearDown(appPreferences.dispose);
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox());
              for (final held in [browser.resumeDelay, browser.markReadDelay]) {
                if (held != null && !held.isCompleted) held.complete();
              }
              await tester.pump();
            });
            await controller.initialize();
            final bots = BotsFixture();
            bots.profiles
              ..clear()
              ..add(BotsFixture.profile('personal', 'Atlas'));
            bots.profiles.single['canonical_session']['id'] = 'canonical-root';
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final frame = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: frame,
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
                    initialDestination: AppDestination.bots,
                    createBotsSession: () =>
                        BotsSession((_) async => [bots.repository]),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            Future<void> until(bool Function() ready, String outcome) async {
              final deadline = DateTime.now().add(const Duration(seconds: 5));
              do {
                await tester.pump(const Duration(milliseconds: 50));
                expect(tester.takeException(), isNull, reason: outcome);
                if (ready()) return;
                await tester.runAsync(
                  () => Future<void>.delayed(Duration.zero),
                );
              } while (DateTime.now().isBefore(deadline));
              fail('Timed out waiting for $outcome');
            }

            Future<void> open() async {
              await tester.tap(find.text('Atlas').last);
              await until(
                () =>
                    find
                        .byKey(const ValueKey('profile-transcript'))
                        .evaluate()
                        .isNotEmpty &&
                    find.byType(StudioLoading).evaluate().isEmpty,
                'the opened bot conversation with its history read completed',
              );
              await tester.settleMarkdown();
              await tester.pumpAndSettle();
            }

            if (entry == 'unread opening') {
              await tester.tap(find.text('Atlas').last);
              await until(
                () =>
                    find
                        .byKey(const ValueKey('profile-transcript'))
                        .evaluate()
                        .isNotEmpty &&
                    find.byType(StudioLoading).evaluate().isEmpty,
                'the unread conversation without waiting for a mark-read write',
              );
              await tester.settleMarkdown();
              expect(
                find
                    .text(
                      'Latest request visible on opening',
                      findRichText: true,
                    )
                    .hitTestable(),
                findsOneWidget,
              );
              expect(find.byType(StudioLoading), findsNothing);
              expect(
                controller.current!.chat!.reading.readingPosition.readThrough,
                30,
              );
              await _capture(
                tester,
                frame,
                'bot-read-ready-${brightness.name}-$scale',
                motion: true,
              );
              browser.markReadDelay!.complete();
              await tester.pumpAndSettle();
            } else {
              await open();
            }
            Object? anchorId;
            double? anchorTop;
            Finder anchor() => find.byWidgetPredicate(
              (widget) =>
                  widget is ProfileMessage && widget.message.id == anchorId,
            );
            void expectReadingPoint() {
              expect(
                anchor(),
                findsOneWidget,
                reason:
                    'Saved message $anchorId, visible IDs ${tester.widgetList<ProfileMessage>(find.byType(ProfileMessage)).map((message) => message.message.id).toList()}, offset ${controller.current!.chat!.reading.readingPosition.resume}, previous top $anchorTop',
              );
              final viewport = tester.getRect(
                find.byKey(const ValueKey('profile-transcript')),
              );
              expect(
                tester.getRect(anchor()).top - viewport.top,
                closeTo(anchorTop!, 2),
                reason: 'The same message stays at the reading point',
              );
            }

            if (revisit) {
              await tester.drag(
                find.byKey(const ValueKey('profile-transcript')),
                const Offset(0, 600),
              );
              await tester.pumpAndSettle();
              await tester.settleMarkdown();
              expect(
                find.byKey(const ValueKey('jump-to-latest')),
                findsOneWidget,
              );
              final viewport = tester.getRect(
                find.byKey(const ValueKey('profile-transcript')),
              );
              final visible = find
                  .byType(ProfileMessage)
                  .evaluate()
                  .where(
                    (element) => tester
                        .getRect(find.byWidget(element.widget))
                        .overlaps(viewport),
                  )
                  .toList();
              visible.sort(
                (a, b) => tester
                    .getRect(find.byWidget(b.widget))
                    .intersect(viewport)
                    .height
                    .compareTo(
                      tester
                          .getRect(find.byWidget(a.widget))
                          .intersect(viewport)
                          .height,
                    ),
              );
              anchorId = (visible.first.widget as ProfileMessage).message.id;
              anchorTop = tester.getRect(anchor()).top - viewport.top;
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
              expect(find.byType(BotsContent), findsOneWidget);
              if (entry == 'new messages') {
                browser.openingHistory!.addAll([
                  for (var id = 32; id <= 36; id++)
                    {
                      'id': id,
                      'role': 'assistant',
                      'content':
                          'New reply $id. ${'New content while away. ' * 8}',
                    },
                ]);
              }
              if (entry == 'refresh pending') {
                final refresh = browser.resumeDelay = Completer<void>();
                await tester.tap(find.text('Atlas').last);
                await until(
                  () =>
                      anchor().evaluate().isNotEmpty &&
                      find.byType(StudioLoading).evaluate().isNotEmpty,
                  'the retained reading point while refresh remains held',
                );
                await tester.settleMarkdown();
                await tester.pump();
                expectReadingPoint();
                expect(find.byType(StudioLoading), findsOneWidget);
                await _capture(
                  tester,
                  frame,
                  'bot-retained-refresh-${brightness.name}-$scale',
                  motion: true,
                );
                refresh.complete();
                await tester.pumpAndSettle();
              } else {
                await open();
              }
            }
            if (revisit) {
              expectReadingPoint();
              expect(
                find.byKey(const ValueKey('jump-to-latest')),
                findsOneWidget,
              );
            } else {
              expect(
                find
                    .text(
                      'Latest request visible on opening',
                      findRichText: true,
                    )
                    .hitTestable(),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('jump-to-latest')),
                findsNothing,
              );
            }
            expect(find.byType(StudioLoading), findsNothing);
            await _capture(
              tester,
              frame,
              'bot-reading-$entry-${brightness.name}-$scale',
            );
            if (entry == 'new messages') {
              await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
              await tester.pumpAndSettle();
              await tester.settleMarkdown();
              final newest = find.byWidgetPredicate(
                (widget) => widget is ProfileMessage && widget.message.id == 36,
              );
              expect(newest, findsOneWidget);
              expect(
                tester
                    .getRect(newest)
                    .overlaps(
                      tester.getRect(
                        find.byKey(const ValueKey('profile-transcript')),
                      ),
                    ),
                isTrue,
                reason: 'Latest reveals the messages received while away',
              );
              expect(
                find.byKey(const ValueKey('jump-to-latest')),
                findsNothing,
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  testWidgets(
    'Bots drawer opens a canonical chat and Back retains the roster search',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final browser = _BotConversationBrowser();
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Home server',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'instance-1',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: browser.gateway,
      );
      await controller.initialize();
      final bots = BotsFixture();
      bots.profiles
        ..clear()
        ..add(
          BotsFixture.profile(
            'personal',
            'Atlas',
            pinned: true,
            preview: 'The continuing bot chat',
          ),
        );
      bots.profiles.single['canonical_session']['id'] = 'pin-one';
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () =>
                BotsSession((_) async => [bots.repository]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-bots')));
      await tester.pumpAndSettle();
      expect(find.byType(BotsContent), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bots-search')),
        'Atlas',
      );
      await tester.pumpAndSettle();
      final rosterRead = Completer<void>();
      bots.readHook = (profile, method, params) async {
        if (method == 'profiles.list') await rosterRead.future;
        return null;
      };
      await tester.tap(find.text('Atlas').last);
      await tester.pump();
      await tester.pump();
      expect(find.byType(BotsContent), findsNothing);
      expect(find.byType(StudioLoading), findsOneWidget);
      rosterRead.complete();
      await tester.pumpAndSettle();
      expect(controller.current!.chat!.key.sessionId, 'pin-one');
      expect(controller.current!.chat!.key.workspace.profileName, 'personal');
      expect(find.byType(BotAvatar), findsNWidgets(2));
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppDrawer>(find.byType(AppDrawer)).selected,
        AppDestination.chats,
      );
      await tester.tap(find.byKey(const ValueKey('nav-bots')));
      await tester.pumpAndSettle();
      bots.profiles.single['ui_meta']['hermes-bots']['shape'] = 'triangle';
      await tester.tap(find.text('Atlas').last);
      await tester.settleTranscript();
      await tester.pumpAndSettle();
      expect(find.byType(BotAvatar), findsNWidgets(2));
      expect(
        tester
            .widget<BotAvatar>(
              find.descendant(
                of: find.byType(AppBar),
                matching: find.byType(BotAvatar),
              ),
            )
            .shape,
        'triangle',
      );
      expect(find.text('Atlas'), findsNWidgets(2));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BotsContent), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bots-search')))
            .controller!
            .text,
        'Atlas',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      appPreferences.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'canonical bot shares framed reply and footer design in ${brightness.name} at $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final browser = _BotConversationBrowser();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'host',
                label: 'Home server',
                host: 'localhost',
                port: 1,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'instance-1',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: browser.gateway,
          );
          await controller.initialize();
          final scope = controller.current!.scope;
          await controller.openSession(
            ProfileSessionKey(scope, 'canonical-root'),
          );
          final botName = scale == 1
              ? 'Atlas'
              : 'Atlas with a very long bot display name';
          const avatarPng =
              'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAJUlEQVR4nGNwCj/ynxLMMGoApgH/byeBMbHiw9GAgY+FUQNIxwDOD2oPx3g6jQAAAABJRU5ErkJggg==';
          final administration = AdministrationFixture('Home server');
          administration.override = (method, path, query, body) async {
            expect(method, 'GET');
            expect(path, 'mcp/servers');
            expect(query, {'profile': 'personal'});
            return {
              'servers': [
                {
                  'name': 'Bot documents',
                  'transport': 'http',
                  'auth': 'oauth',
                  'enabled': true,
                  'source': 'config',
                  'plugin': null,
                },
              ],
            };
          };
          final bots = BotsFixture(server: administration.server);
          bots.profiles
            ..clear()
            ..add(BotsFixture.profile('personal', botName));
          bots.profiles.single['canonical_session'] = {
            'id': 'canonical-root',
            'resolved_id': 'canonical-tip',
          };
          bots.profiles.single['has_avatar'] = scale == 2;
          var rosterReads = 0;
          Completer<Map<String, dynamic>?>? heldRoster;
          bots.readHook = (_, method, _) async {
            if (method == 'profiles.list') {
              rosterReads++;
              if (heldRoster != null) return heldRoster.future;
            }
            if (method == 'profiles.get_asset') {
              return {'found': true, 'data': avatarPng};
            }
            return null;
          };
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () =>
                    BotsSession((_) async => [bots.repository]),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Bot Chat'), findsNothing);
          expect(find.text(botName), findsNWidgets(2));
          final avatar = find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(BotAvatar),
          );
          expect(avatar, findsOneWidget);
          final face = tester.widget<BotAvatar>(avatar);
          expect(face.name, botName);
          expect(face.shape, 'squircle');
          expect(face.color, '#65c7bc');
          expect(face.image, scale == 2 ? base64Decode(avatarPng) : isNull);
          if (scale == 2) {
            final uploaded = find.descendant(
              of: avatar,
              matching: find.byType(Image),
            );
            await tester.runAsync(
              () => precacheImage(
                tester.widget<Image>(uploaded).image,
                tester.element(avatar),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<RawImage>(
                    find.descendant(
                      of: avatar,
                      matching: find.byType(RawImage),
                    ),
                  )
                  .image,
              isNotNull,
            );
          }
          expect(avatar.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(avatar).right,
            lessThanOrEqualTo(
              tester
                  .getRect(
                    find.descendant(
                      of: find.byType(AppBar),
                      matching: find.text(botName),
                    ),
                  )
                  .left,
            ),
          );
          expect(
            tester.getCenter(avatar).dy,
            closeTo(
              tester
                  .getCenter(
                    find.descendant(
                      of: find.byType(AppBar),
                      matching: find.text(botName),
                    ),
                  )
                  .dy,
              0.1,
            ),
          );
          final reply = find.byWidgetPredicate(
            (widget) =>
                widget is ProfileMessage && widget.message.role == 'assistant',
          );
          expect(
            find.descendant(of: reply, matching: find.byType(BotAvatar)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: reply, matching: find.text(botName)),
            findsOneWidget,
          );
          final copy = find.descendant(
            of: reply,
            matching: find.byTooltip('Copy message'),
          );
          expect(copy.hitTestable(), findsOneWidget);
          expect(find.byType(PlayfulPortrait), findsNothing);
          expect(find.text('Hermes'), findsNothing);
          expect(find.byTooltip('Open navigation menu'), findsOneWidget);
          expect(find.byTooltip('Chat actions'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('chat-project-picker')),
            findsNothing,
          );
          expect(find.text('Project unavailable'), findsNothing);
          expect(find.text('Unassigned'), findsNothing);
          expect(find.text('·'), findsNothing);
          expect(find.text('Home server'), findsOneWidget);
          expect(
            tester.widget<WingAppBar>(find.byType(WingAppBar)).contextHeight,
            48,
          );
          await tester.settleMarkdown();
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Of course. What would you like to make time for this week?',
              findRichText: true,
            ),
            findsOneWidget,
          );
          await _capture(tester, frame, 'bot-chat-${brightness.name}-$scale');
          final reads = rosterReads;
          await controller.updateDraft(
            controller.current!.chat!,
            'Hello Atlas',
          );
          await tester.pumpAndSettle();
          expect(rosterReads, reads);
          final chat = controller.current!.chat!;
          expect(
            tester.getSize(find.byTooltip('Bot settings')).height,
            greaterThanOrEqualTo(48),
          );
          for (final target in [
            avatar,
            find.descendant(
              of: find.byType(AppBar),
              matching: find.text(botName),
            ),
          ]) {
            await tester.tap(target);
            await tester.pumpAndSettle();
            final settings = tester.widget<BotSettingsScreen>(
              find.byType(BotSettingsScreen),
            );
            expect(settings.bot.scope, scope);
            expect(settings.profile.name, 'personal');
            expect(settings.profile.server, same(administration.server));
            expect(find.text('Edit name & appearance'), findsOneWidget);
            expect(find.text('Role & instructions'), findsOneWidget);
            await _capture(
              tester,
              frame,
              'bot-chat-settings-${brightness.name}-$scale',
            );
            await tester.scrollUntilVisible(find.text('MCP connectors'), 200);
            await tester.pumpAndSettle();
            expect(find.text('MCP connectors'), findsOneWidget);
            await _capture(
              tester,
              frame,
              'bot-chat-settings-mcp-${brightness.name}-$scale',
            );
            await tester.tap(find.text('MCP connectors'));
            await tester.pumpAndSettle();
            expect(find.byType(AdminConnectorsPage), findsOneWidget);
            await tester.scrollUntilVisible(
              find.text('Bot documents'),
              120,
              scrollable: find
                  .descendant(
                    of: find.byType(AdminConnectorsPage),
                    matching: find.byType(Scrollable),
                  )
                  .last,
            );
            expect(find.text('Bot documents'), findsOneWidget);
            expect(controller.current!.chat, same(chat));
            await _capture(
              tester,
              frame,
              'bot-chat-mcp-${brightness.name}-$scale',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.byType(BotSettingsScreen), findsOneWidget);
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(controller.current!.chat, same(chat));
            expect(chat.composer.observation.text, 'Hello Atlas');
            expect(avatar, findsOneWidget);
            expect(find.text(botName), findsNWidgets(2));
          }
          await controller.openSession(
            ProfileSessionKey(scope, 'canonical-tip'),
          );
          await tester.pumpAndSettle();
          expect(avatar, findsOneWidget);
          expect(find.text('Compacted conversation'), findsNothing);
          expect(
            find.byKey(const ValueKey('chat-project-picker')),
            findsNothing,
          );
          // A delayed lookup for one chat must not decorate a different chat.
          heldRoster = Completer<Map<String, dynamic>?>();
          await controller.openSession(
            ProfileSessionKey(scope, 'canonical-root'),
          );
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          // The root and tip share the same confirmed bot identity.
          expect(find.text(botName), findsNWidgets(2));
          await controller.openSession(ProfileSessionKey(scope, 'ordinary'));
          await tester.pumpAndSettle();
          expect(find.byType(BotAvatar), findsNothing);
          expect(find.text('Hermes'), findsNothing);
          heldRoster.complete(null);
          heldRoster = null;
          await tester.pumpAndSettle();
          expect(find.byType(BotAvatar), findsNothing);
          expect(find.text('Bot Chat'), findsOneWidget);
          expect(find.byTooltip('Bot settings'), findsNothing);
          expect(
            find.byKey(const ValueKey('chat-project-picker')),
            findsOneWidget,
          );
          expect(find.text('Hermes'), findsNothing);
          expect(tester.takeException(), isNull);
          semantics.dispose();
          await controller.openSession(
            ProfileSessionKey(scope, 'canonical-root'),
          );
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          final questionChat = controller.current!.chat!;
          final question = {
            'request_id': 'bot-cleared-question',
            'questions': [
              {'qid': 'q0', 'question': 'Already answered on desktop?'},
            ],
          };
          emitChatEvent(controller, questionChat, 'clarify', question);
          await tester.pump();
          await tester.pump();
          // Reopening preserves the reading point. Follow the attention
          // control to the new question without an automatic reading jump.
          final attention = find.byKey(const ValueKey('jump-to-latest'));
          expect(
            find.descendant(
              of: attention,
              matching: find.byTooltip('Input needed'),
            ),
            findsOneWidget,
          );
          await tester.tap(attention);
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          expect(find.byType(GatewayClarifyDialog), findsOneWidget);
          browser.clarificationResult = {'status': 'expired'};
          await tester.ensureVisible(find.byKey(const Key('clarify-skip')));
          await tester.tap(find.byKey(const Key('clarify-skip')));
          await tester.pumpAndSettle();
          expect(questionChat.runtime.pendingQuestion, isNull);
          emitChatEvent(controller, questionChat, 'clarify', question);
          await tester.pump();
          expect(find.byType(GatewayClarifyDialog), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          appPreferences.dispose();
        },
      );
    }
  }

  for (final (retained, brightness, scale) in [
    for (final retained in ['cached', 'roster', 'first read'])
      for (final brightness in Brightness.values)
        for (final scale in [1.0, 2.0]) (retained, brightness, scale),
  ]) {
    testWidgets(
      'bot header renders $retained identity during held reads ${brightness.name} $scale',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final browser = _BotConversationBrowser();
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'host',
              label: 'Home server',
              host: 'localhost',
              port: 1,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'instance-1',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: browser.gateway,
        );
        await controller.initialize();
        final scope = controller.current!.scope;
        final key = ProfileSessionKey(scope, 'canonical-root');
        await controller.openSession(key);
        const png =
            'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAJUlEQVR4nGNwCj/ynxLMMGoApgH/byeBMbHiw9GAgY+FUQNIxwDOD2oPx3g6jQAAAABJRU5ErkJggg==';
        final fixture = BotsFixture();
        fixture.profiles
          ..clear()
          ..add(BotsFixture.profile('personal', 'Atlas'));
        fixture.profiles.single['canonical_session'] = {
          'id': 'canonical-root',
          'resolved_id': 'canonical-tip',
        };
        fixture.profiles.single['has_avatar'] = true;
        final held = Completer<Map<String, dynamic>?>();
        var holding = false;
        var heldReadStarted = false;
        fixture.readHook = (_, method, _) async {
          if (holding &&
              method ==
                  (retained == 'first read'
                      ? 'profiles.get_asset'
                      : 'profiles.list')) {
            heldReadStarted = true;
            return held.future;
          }
          if (method == 'profiles.get_asset') {
            return {'found': true, 'data': png};
          }
          return null;
        };
        final owner = BotsSession((_) async => [fixture.repository]);
        if (retained == 'cached') await owner.botForConversation(key);
        if (retained == 'roster') await owner.refresh();
        if (retained != 'first read') {
          final borrower = owner.createAvatarBorrower()..replaceDemand({scope});
          await owner.reloadAvatar(scope);
          borrower.dispose();
        }
        owner.invalidateAppearances();
        holding = true;
        final frame = GlobalKey();
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: frame, child: child!),
            ),
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () => owner,
            ),
          ),
        );
        if (retained == 'first read') {
          for (var frame = 0; frame < 8; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
        }
        expect(heldReadStarted, isTrue);
        expect(find.text('Bot Chat'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Atlas'),
          ),
          findsOneWidget,
        );
        final avatar = find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(BotAvatar),
        );
        expect(avatar, findsOneWidget);
        expect(
          tester.widget<BotAvatar>(avatar).image,
          retained == 'first read' ? isNull : base64Decode(png),
        );
        final bounds = tester.getRect(avatar);
        await tester.settleMarkdown();
        if (retained != 'first read') {
          final image = tester.widget<BotAvatar>(avatar).image!;
          await tester.runAsync(
            () => precacheImage(MemoryImage(image), tester.element(avatar)),
          );
          await tester.pump();
          expect(
            tester
                .renderObject<RenderImage>(
                  find.descendant(of: avatar, matching: find.byType(RawImage)),
                )
                .image,
            isNotNull,
          );
        }
        await _capture(
          tester,
          frame,
          'bot-header-held-$retained-${brightness.name}-$scale',
        );
        held.complete(
          retained == 'first read' ? {'found': true, 'data': png} : null,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Atlas'),
          ),
          findsOneWidget,
        );
        expect(tester.widget<BotAvatar>(avatar).image, base64Decode(png));
        expect(tester.getRect(avatar), bounds);
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        appPreferences.dispose();
      },
    );
  }

  for (final entry in ['roster', 'discussion']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'group editor member opens Bot Chat from $entry ${brightness.name} $scale',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            addTearDown(appPreferences.dispose);
            final browser = _BotConversationBrowser();
            final administration = AdministrationFixture('Home server');
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: SavedConnection(
                  id: 'host',
                  label: 'Home server',
                  host: 'localhost',
                  port: 1,
                  apiKey: '',
                ),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'instance-1',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: (scope) {
                final base = browser.gateway(scope);
                return ProfileGateway(
                  scope: scope,
                  discover: base.discover,
                  get: (path, query) => path == 'model/options'
                      ? administration.server
                            .profile(scope.profileName)
                            .gateway
                            .read(path, query)
                      : base.read(path, query),
                  rpc: base.call,
                );
              },
            );
            addTearDown(controller.dispose);
            await controller.initialize();
            final bots = BotsFixture(server: administration.server);
            bots.profiles
              ..clear()
              ..addAll([
                BotsFixture.profile('default', 'Hermes'),
                BotsFixture.profile('personal', 'Atlas'),
                BotsFixture.profile('work', 'Mira'),
              ]);
            bots.profiles.last['canonical_session'] = {
              'id': 'canonical-root',
              'resolved_id': 'canonical-tip',
            };
            bots.room['members'][0]['profile'] = 'personal';
            bots.room['members'][1]['profile'] = 'work';
            await tester.binding.setSurfaceSize(
              Size(scale == 1 ? 390 : 320, 844),
            );
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final frame = GlobalKey();
            await tester.pumpMarkdownWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  initialDestination: AppDestination.bots,
                  createBotsSession: () =>
                      BotsSession((_) async => [bots.repository]),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(Tab, 'Groups'));
            await tester.pumpAndSettle();
            if (entry == 'roster') {
              await tester.tap(find.byTooltip('Edit group Research team'));
            } else {
              await tester.tap(find.text('Research team'));
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('Edit group'));
            }
            await tester.pumpAndSettle();
            final name = find.byKey(const ValueKey('group-name'));
            expect(tester.widget<TextField>(name).enabled, isTrue);
            await tester.enterText(name, 'Unsaved room name');
            final member = find.widgetWithText(ListTile, 'Mira');
            await _revealGroup(tester, member);
            await _capture(
              tester,
              frame,
              'member-chat-editor-$entry-${brightness.name}-$scale',
            );
            final identity = Completer<void>();
            final resume = browser.resumeDelay = Completer<void>();
            final history = Completer<void>();
            browser.historyDelays[('canonical-root', 0)] = history;
            bots.readHook = (_, method, _) async {
              if (method == 'profiles.list') await identity.future;
              return null;
            };
            expect(tester.widget<ListTile>(member).onTap, isNotNull);
            await tester.tap(
              find.descendant(of: member, matching: find.text('Mira')),
            );
            await tester.pump();
            expect(
              tester
                  .widget<ProfileWorkspaceScreen>(
                    find
                        .byType(ProfileWorkspaceScreen, skipOffstage: false)
                        .last,
                  )
                  .initialBot
                  ?.profile
                  .name,
              'work',
            );
            await tester.pump();
            expect(find.byType(StudioLoading), findsOneWidget);
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.byType(BotsCreateScreen), findsNothing);
            expect(find.byType(ProfileMessage), findsNothing);
            await _capture(
              tester,
              frame,
              'member-chat-pending-$entry-${brightness.name}-$scale',
              motion: true,
            );
            identity.complete();
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(find.byType(StudioLoading), findsOneWidget);
            resume.complete();
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(find.byType(StudioLoading), findsOneWidget);
            history.complete();
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            expect(controller.current!.chat!.key.workspace.profileName, 'work');
            expect(controller.current!.chat!.key.sessionId, 'canonical-root');
            expect(find.byType(StudioLoading), findsNothing);
            await _capture(
              tester,
              frame,
              'member-chat-loaded-$entry-${brightness.name}-$scale',
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsOneWidget);
            await _revealGroup(tester, name, delta: -120);
            expect(
              tester.widget<TextField>(name).controller!.text,
              'Unsaved room name',
            );
            expect(bots.commands, isEmpty);

            // The avatar uses the same captured target and failure/retry flow.
            await _revealGroup(tester, member);
            browser.failHistory = true;
            await tester.tap(
              find.descendant(
                of: member,
                matching: find.byType(BorrowedBotAvatar),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsNothing);
            expect(find.byTooltip('Retry'), findsOneWidget);
            expect(find.byType(StudioLoading), findsNothing);
            await _capture(
              tester,
              frame,
              'member-chat-error-$entry-${brightness.name}-$scale',
            );
            browser.failHistory = false;
            final retry = Completer<void>();
            browser.historyDelays[('canonical-root', 0)] = retry;
            await tester.tap(find.byTooltip('Retry'));
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(find.byType(StudioLoading), findsOneWidget);
            // Back during a held read retires navigation and retains the draft.
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsOneWidget);
            retry.complete();
            await tester.pumpAndSettle();
            expect(find.byType(BotsCreateScreen), findsOneWidget);
            await _revealGroup(tester, name, delta: -120);
            expect(
              tester.widget<TextField>(name).controller!.text,
              'Unsaved room name',
            );
            expect(bots.commands, isEmpty);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group popup reaches captured bot settings and canonical private chat ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(activity.dispose);
          final administration = AdministrationFixture('Home server');
          final browser = _BotConversationBrowser();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'host',
                label: 'Home server',
                host: 'localhost',
                port: 1,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'instance-1',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: (scope) {
              final base = browser.gateway(scope);
              return ProfileGateway(
                scope: scope,
                discover: base.discover,
                get: (path, query) => path == 'model/options'
                    ? administration.server
                          .profile(scope.profileName)
                          .gateway
                          .read(path, query)
                    : base.read(path, query),
                rpc: base.call,
              );
            },
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final bots = BotsFixture(server: administration.server);
          bots.profiles
            ..clear()
            ..addAll([
              BotsFixture.profile('personal', 'Atlas'),
              BotsFixture.profile('work', 'Mira'),
            ]);
          bots.profiles.last['canonical_session'] = {
            'id': 'canonical-root',
            'resolved_id': 'canonical-tip',
          };
          bots.room['members'][0]['profile'] = 'personal';
          bots.room['members'][1]['profile'] = 'work';
          bots.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'actor': {'kind': 'member', 'id': 'mira', 'profile': 'work'},
            'payload': {'text': 'Mira shared answer'},
            'created_at': 1791756000.0,
          });
          await tester.binding.setSurfaceSize(
            Size(scale == 1 ? 390 : 320, 844),
          );
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final frame = GlobalKey();
          await tester.pumpMarkdownWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => ChatNoticeActivityScope(
                activity: activity,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: AppDestination.bots,
                createBotsSession: () =>
                    BotsSession((_) async => [bots.repository]),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(Tab, 'Groups'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Research team'));
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.byType(BotGroupScreen), findsOneWidget);
          bots.pending.add({
            'kind': 'retry',
            'task_id': 'hosted-refresh-retry',
            'member_id': 'atlas',
            'execution_generation': 7,
          });
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          final refresh = find.text('Refresh group');
          final popup = ModalRoute.of(tester.element(refresh))!;
          var popupRetired = false;
          unawaited(popup.completed.then((_) => popupRetired = true));
          await tester.tap(refresh);
          for (var frame = 0; frame < 60; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (popupRetired &&
                find.byTooltip('Retry group attempt').evaluate().isNotEmpty &&
                find.byTooltip('Refreshing group').evaluate().isEmpty) {
              break;
            }
          }
          await _capture(
            tester,
            frame,
            'group-refresh-menu-${brightness.name}-$scale',
          );
          expect(popupRetired, isTrue);
          expect(find.byTooltip('Retry group attempt'), findsOneWidget);
          expect(find.byTooltip('Refreshing group'), findsNothing);
          expect(
            find.byTooltip('Retry group attempt').hitTestable(),
            findsOneWidget,
            reason:
                'Retry ${tester.getRect(find.byTooltip('Retry group attempt'))} '
                'in transcript ${tester.getRect(find.byKey(const ValueKey('profile-transcript')))}',
          );
          bots.pending.clear();
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh group'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Retry group attempt'), findsNothing);
          final input = find.byKey(const ValueKey('group-message-composer'));
          await tester.enterText(input, 'Keep my group draft');
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Options for Mira'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Bot settings'));
          await tester.pumpAndSettle();
          final settings = tester.widget<BotSettingsScreen>(
            find.byType(BotSettingsScreen),
          );
          expect(settings.profile.name, 'work');
          expect(settings.bot.scope.connectionIdentity, 'instance-1');
          expect(find.text('Role & instructions'), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(input).controller!.text,
            'Keep my group draft',
          );
          await tester.tap(find.byTooltip('Options for Mira'));
          await tester.pumpAndSettle();
          final identity = Completer<void>();
          final resume = browser.resumeDelay = Completer<void>();
          final history = Completer<void>();
          browser.historyDelays[('canonical-root', 0)] = history;
          bots.readHook = (_, method, _) async {
            if (method == 'profiles.list') await identity.future;
            return null;
          };
          await tester.tap(find.text('Chat directly'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(BotGroupScreen), findsNothing);
          expect(find.text('Mira'), findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byType(ProfileMessage), findsNothing);
          final backRect = tester.getRect(find.byTooltip('Back'));
          await _capture(
            tester,
            frame,
            'group-chat-opening-${brightness.name}-$scale',
            motion: true,
          );
          identity.complete();
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byType(ProfileMessage), findsNothing);
          expect(tester.getRect(find.byTooltip('Back')), backRect);
          resume.complete();
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(
            browser.reads.any(
              (read) => read.$1 == 'sessions/canonical-root/messages',
            ),
            isTrue,
          );
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byType(ProfileMessage), findsNothing);
          expect(tester.getRect(find.byTooltip('Back')), backRect);
          history.complete();
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(controller.current!.chat!.key.workspace.profileName, 'work');
          expect(controller.current!.chat!.key.sessionId, 'canonical-root');
          expect(find.byType(BotGroupScreen), findsNothing);
          expect(
            find.descendant(
              of: find.byTooltip('Bot settings'),
              matching: find.text('Mira'),
            ),
            findsOneWidget,
          );
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            tester.getRect(find.byTooltip('Open navigation menu')),
            backRect,
          );
          await _capture(
            tester,
            frame,
            'group-chat-loaded-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(
            find.byType(BotGroupScreen, skipOffstage: false),
            findsNothing,
          );
          expect(controller.current!.chat, isNull);
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('bots-search')))
                .decoration!
                .hintText,
            'Search groups',
          );
          expect(find.byType(BotsContent), findsOneWidget);
          expect(find.byType(BotGroupScreen), findsNothing);

          Future<void> openDirectChat() async {
            await tester.tap(find.text('Research team'));
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            await tester.tap(find.byTooltip('Options for Mira'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Chat directly'));
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          }

          browser.failHistory = true;
          await openDirectChat();
          expect(find.byType(BotGroupScreen), findsNothing);
          expect(find.byTooltip('Retry'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          await _capture(
            tester,
            frame,
            'group-chat-error-${brightness.name}-$scale',
            motion: true,
          );
          browser.failHistory = false;
          final retryHistory = Completer<void>();
          browser.historyDelays[('canonical-root', 0)] = retryHistory;
          await tester.tap(find.byTooltip('Retry'));
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byTooltip('Retry'), findsNothing);
          retryHistory.complete();
          await tester.settleTranscript();
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();

          for (final stage in ['identity', 'resume', 'history']) {
            final held = Completer<void>();
            bots.readHook = (_, method, _) async {
              if (stage == 'identity' && method == 'profiles.list') {
                await held.future;
              }
              return null;
            };
            browser.resumeDelay = stage == 'resume' ? held : null;
            browser.historyDelays.remove(('canonical-root', 0));
            if (stage == 'history') {
              browser.historyDelays[('canonical-root', 0)] = held;
            }
            await openDirectChat();
            expect(find.byType(StudioLoading), findsOneWidget);
            await _capture(
              tester,
              frame,
              'group-chat-held-$stage-${brightness.name}-$scale',
              motion: true,
            );
            expect(
              find.byKey(const ValueKey('profile-transcript')),
              stage == 'identity' ? findsNothing : findsOneWidget,
              reason:
                  'The retained transcript is admitted while $stage is held',
            );
            await tester.binding.handlePopRoute();
            if (stage == 'history') held.complete();
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.byType(BotsContent), findsOneWidget);
            expect(
              find.byType(BotGroupScreen, skipOffstage: false),
              findsNothing,
            );
            if (!held.isCompleted) held.complete();
            await tester.pumpAndSettle();
            expect(controller.current!.chat, isNull);
            expect(find.byType(BotsContent), findsOneWidget);
          }
          expect(bots.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('saved and streaming replies omit repeated author headers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 2.0]) {
      for (final streaming in [false, true]) {
        await tester.pumpMarkdownWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: ProfileMessage(
                message: TranscriptMessage.fromRow({
                  'id': 1,
                  'role': 'assistant',
                  'content': 'I can help with that.',
                }, streaming: streaming),
                onReadAloud: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Hermes'), findsNothing);
        expect(find.byType(BotAvatar), findsNothing);
        expect(find.byType(PlayfulPortrait), findsNothing);
        expect(
          find.byTooltip('Copy message'),
          streaming ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
