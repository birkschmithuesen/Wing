import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_selection.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/project_icon_glyphs.dart';
import 'package:wing/core/widgets/profile_selector.dart';

import 'support/browser_mutations_fixture.dart';

const _identity = 'browser-filter-accessibility';
const _capture = bool.fromEnvironment('CAPTURE_BROWSER_FILTERS');
const _captureKey = ValueKey('browser-filter-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppPreferences owner;
  late ProfileWorkspaceController controller;
  late BrowserMutationsFixture host;

  setUpAll(() async {
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    final packageConfig = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(await packageConfig.readAsString());
    if (config is! Map<String, dynamic> || config['packages'] is! List) {
      throw StateError('The generated package configuration is invalid.');
    }
    final flutter = (config['packages'] as List)
        .where((row) => row is Map && row['name'] == 'flutter')
        .single;
    if (flutter['rootUri'] is! String) {
      throw StateError('The Flutter package root is invalid.');
    }
    final packageRoot = packageConfig.uri.resolve(flutter['rootUri'] as String);
    if (packageRoot.scheme != 'file') {
      throw StateError(
        'The Flutter package root must be a local SDK directory.',
      );
    }
    final fontDirectory = fonts.isEmpty
        ? Directory.fromUri(
            packageRoot,
          ).parent.parent.uri.resolve('bin/cache/artifacts/material_fonts/')
        : Directory(fonts).absolute.uri;
    for (final font in {
      'Roboto': fontDirectory.resolve('Roboto-Regular.ttf'),
      'MaterialIcons': fontDirectory.resolve('MaterialIcons-Regular.otf'),
      'WingIcons': File('assets/fonts/wing-icons.ttf').absolute.uri,
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File.fromUri(font.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> showBrowser(
    WidgetTester tester, {
    required Brightness brightness,
    required double scale,
    double width = 390,
    bool repair = false,
    bool projectAppearance = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (repair)
        ProfileSelectionCodec.storageKey(_identity): 'removed-profile',
    });
    final preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
    host = BrowserMutationsFixture();
    if (projectAppearance) {
      host.projectChanges['work/work-project'] = {
        'icon': 'star-full',
        'color': 'hsl(60 68% 58%)',
      };
    }
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'filter-view',
          label: 'Test server',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: _identity,
      preferences: preferences,
      appPreferences: owner,
      gatewayFactory: host.gateway,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      owner.dispose();
      SharedPreferences.resetStatic();
    });
    await controller.initialize();
    if (repair) {
      // Prove the user is choosing, rather than waiting on an opening request.
      expect(controller.requiresProfileSelectionRepair, isTrue);
      expect(controller.profileSelectionRepairBusy, isFalse);
      expect(controller.initialized, isFalse);
      expect(controller.current, isNull);
      expect(controller.discovery!.named('work'), isNotNull);
      expect(controller.error, contains('Choose'));
      expect(
        preferences.getString(ProfileSelectionCodec.storageKey(_identity)),
        'removed-profile',
      );
      expect(host.calls, isEmpty);
    } else {
      expect(controller.initialized, isTrue);
      expect(controller.current, isNotNull);
    }
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
        home: ProfileWorkspaceBrowser(
          onOpenBotChat: (_) {},
          createData: () => ChatBrowserData(controller),
          connectionLabel: controller.connection.label,
          connectionIcon: controller.connection.icon,
          connectionStatus: controller.connectionStatus,
          createColors: controller.createProfileColors,
          deletionRecovery: DeletedChatRecoveryNotice(
            presentation: controller.deletedDraftCleanupPresentation,
          ),
          newProject: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!_capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/browser-filter-review/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  void expectSelectedPadding(WidgetTester tester, String filter) {
    final control = find.byKey(ValueKey('chat-filter-${filter.toLowerCase()}'));
    final selectedColor = Theme.of(
      tester.element(control),
    ).colorScheme.primaryContainer;
    final surface = find.descendant(
      of: control,
      matching: find.byWidgetPredicate(
        (widget) => switch (widget) {
          ColoredBox(:final color) => color == selectedColor,
          DecoratedBox(decoration: BoxDecoration(:final color)) =>
            color == selectedColor,
          _ => false,
        },
      ),
    );
    // Rendered geometry depends on constraints, fonts and text scaling; a
    // source linter cannot establish the accent's spacing or action position.
    final accent = tester.getRect(surface);
    final label = tester.getRect(find.text('$filter 1'));
    expect(label.left - accent.left, greaterThanOrEqualTo(8));
    expect(accent.right - label.right, greaterThanOrEqualTo(8));
    expect(label.top - accent.top, greaterThanOrEqualTo(6));
    expect(accent.bottom - label.bottom, greaterThanOrEqualTo(6));
    final target = tester.getRect(control);
    expect(accent.top - target.top, greaterThanOrEqualTo(8));
    expect(target.bottom - accent.bottom, greaterThanOrEqualTo(8));
  }

  void expectDistributedFilters(WidgetTester tester, double width) {
    final rows = <double, List<Rect>>{};
    for (final filter in ['status', 'profile', 'project']) {
      final rect = tester.getRect(find.byKey(ValueKey('chat-filter-$filter')));
      rows.putIfAbsent(rect.center.dy, () => []).add(rect);
    }
    for (final row in rows.values) {
      final slotWidth = (width - 32 - 96) / row.length;
      for (var index = 0; index < row.length; index++) {
        expect(
          row[index].center.dx,
          closeTo(16 + 48 + slotWidth * (index + .5), .01),
          reason: 'Filters are equally distributed between the icon slots',
        );
        expect(row[index].width, closeTo(row.first.width, .01));
      }
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'project filter preserves saved appearance ${brightness.name}',
      (tester) async {
        await showBrowser(
          tester,
          brightness: brightness,
          scale: 1,
          projectAppearance: true,
        );
        await tester.tap(find.byKey(const ValueKey('chat-profile-work')));
        await tester.pumpAndSettle();
        final headingIcon = tester.widget<Icon>(
          find.byIcon(ProjectIconGlyphs.of('star-full')),
        );
        await tester.tap(find.byKey(const ValueKey('chat-filter-project')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('chat-menu-search')),
          'work',
        );
        await tester.pumpAndSettle();
        final project = find.byKey(
          const ValueKey('chat-menu-work/work-project'),
        );
        expect(project.hitTestable(), findsOneWidget);
        final menuIcon = find.descendant(
          of: project,
          matching: find.byIcon(ProjectIconGlyphs.of('star-full')),
        );
        expect(menuIcon, findsOneWidget);
        expect(tester.widget<Icon>(menuIcon).color, headingIcon.color);
        expect(
          find.descendant(
            of: project,
            matching: find.byIcon(ProjectIconGlyphs.of('folder-library')),
          ),
          findsNothing,
        );
        final home = find.byKey(const ValueKey('chat-menu-work/home'));
        expect(
          find.descendant(
            of: home,
            matching: find.byIcon(Icons.category_outlined),
          ),
          findsOneWidget,
        );
        await capture(tester, '${brightness.name}-project-icons');
        await tester.tap(project);
        await tester.pumpAndSettle();
        // Selecting an option keeps its project glyph and color.
        expect(menuIcon, findsOneWidget);
        expect(tester.widget<Icon>(menuIcon).color, headingIcon.color);
        await tester.tap(find.byTooltip('Close Project'));
        await tester.pumpAndSettle();
        expect(find.text('Project 1'), findsOneWidget);
        expectSelectedPadding(tester, 'Project');
        expectDistributedFilters(tester, 390);
        expect(tester.takeException(), isNull);
      },
    );

    for (final (width, scale) in [
      (390.0, 1.0),
      (320.0, 1.0),
      (390.0, 2.0),
      (320.0, 2.0),
    ]) {
      testWidgets(
        'all browser filters remain legible and reachable ${brightness.name} ${scale}x at${width.toInt()}',
        (tester) async {
          await showBrowser(
            tester,
            brightness: brightness,
            scale: scale,
            width: width,
          );
          expectDistributedFilters(tester, width);
          await capture(
            tester,
            '${brightness.name}-${scale}x${width == 390 ? '' : '-320'}',
          );
          final paintedLabels = <Rect>[];
          for (final label in ['Status', 'Profile', 'Project']) {
            final control = find.byKey(
              ValueKey('chat-filter-${label.toLowerCase()}'),
            );
            expect(control.hitTestable(), findsOneWidget);
            final target = tester.getRect(control);
            expect(target.width, greaterThanOrEqualTo(48));
            expect(target.height, greaterThanOrEqualTo(48));
            final text = find.descendant(
              of: control,
              matching: find.text(label),
            );
            final paragraph = tester.renderObject<RenderParagraph>(text);
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            );
            expect(
              boxes,
              hasLength(1),
              reason: '$label must remain one whole word',
            );
            final origin = paragraph.localToGlobal(Offset.zero);
            paintedLabels.add(boxes.single.toRect().shift(origin));
          }
          for (var index = 1; index < paintedLabels.length; index++) {
            final previous = paintedLabels[index - 1];
            final next = paintedLabels[index];
            if (previous.top < next.bottom && next.top < previous.bottom) {
              expect(
                next.left - previous.right,
                greaterThanOrEqualTo(8),
                reason: 'Neighbouring filter words need visible separation',
              );
            }
          }
          for (final label in ['Status', 'Profile', 'Project']) {
            await tester.tap(
              find.byKey(ValueKey('chat-filter-${label.toLowerCase()}')),
            );
            await tester.pumpAndSettle();
            expect(
              find.byTooltip('Close $label').hitTestable(),
              findsOneWidget,
            );
            await tester.tap(find.byTooltip('Close $label'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const ValueKey('chat-filter-status')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('chat-menu-idle')));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Close Status'));
          await tester.pumpAndSettle();
          expect(find.text('Status 1'), findsOneWidget);
          final clear = find.byKey(const ValueKey('workspace-clear-filters'));
          expect(clear.hitTestable(), findsOneWidget);
          final clearTarget = tester.getRect(clear);
          expect(clearTarget.width, greaterThanOrEqualTo(48));
          expect(clearTarget.height, greaterThanOrEqualTo(48));
          expect(
            clearTarget.right,
            closeTo(width - 16, .01),
            reason: 'Clear filters stays at the right page gutter',
          );
          expectSelectedPadding(tester, 'Status');
          expectDistributedFilters(tester, width);
          await capture(
            tester,
            '${brightness.name}-${scale}x-${width.toInt()}-selected',
          );
          await tester.tap(clear);
          await tester.pumpAndSettle();
          expect(find.text('Status 1'), findsNothing);
          expect(find.text('Status'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('chat-filter-profile')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('chat-menu-work')));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Close Profile'));
          await tester.pumpAndSettle();
          expectSelectedPadding(tester, 'Profile');
          expectDistributedFilters(tester, width);
          expect(tester.getRect(clear).right, closeTo(width - 16, .01));
          await capture(
            tester,
            '${brightness.name}-${scale}x-${width.toInt()}-profile-selected',
          );
          await tester.tap(clear);
          await tester.pumpAndSettle();
          expect(find.text('Profile 1'), findsNothing);
          expect(host.updates, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('required profile choice never claims chats are opening', (
    tester,
  ) async {
    await showBrowser(
      tester,
      brightness: Brightness.light,
      scale: 2,
      repair: true,
    );
    expect(find.byType(ProfileSelector), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-work')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Opening your chats'), findsNothing);
    expect(controller.requiresProfileSelectionRepair, isTrue);
    expect(host.calls, isEmpty);
    expect(host.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
