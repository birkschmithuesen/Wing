import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/project_icon.dart';
import 'package:wing/core/screens/profile_project_actions.dart';
import 'package:wing/core/theme/project_icon_glyphs.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/project_icon_picker.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PROJECT_ICONS');
  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': '$fonts/Roboto-Regular.ttf',
      'MaterialIcons': '$fonts/MaterialIcons-Regular.otf',
      'WingProjectIcons': 'assets/fonts/codicons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });

  test('Hermes is the exact Desktop palette and exclusive to its tab', () {
    const expected = [
      'folder-library',
      'repo',
      'rocket',
      'beaker',
      'flame',
      'star-full',
      'heart',
      'zap',
      'target',
      'lightbulb',
      'tools',
      'device-desktop',
      'device-mobile',
      'terminal',
      'dashboard',
      'globe',
      'broadcast',
      'cloud',
      'database',
      'package',
      'book',
      'organization',
      'bug',
      'shield',
      'key',
      'gift',
      'telescope',
      'home',
    ];
    expect(projectIconCategories.first.label, 'Hermes');
    expect(projectIconCategories.first.icons, expected);
    expect(projectIconCategories, hasLength(5));
    for (final category in projectIconCategories.skip(1)) {
      expect(
        category.icons.where(expected.contains),
        isEmpty,
        reason: category.label,
      );
      expect(category.icons.toSet().length, category.icons.length);
    }
    expect(projectIconChoices, hasLength(92));
    expect(
      projectIconCategories.expand((c) => c.icons).toSet(),
      projectIconChoices.keys.toSet(),
    );
    expect(
      projectIconChoices.keys.map(ProjectIconGlyphs.of).toSet(),
      hasLength(92),
    );
    expect(
      ProjectIconGlyphs.of('folder'),
      isNot(ProjectIconGlyphs.of('folder-library')),
    );
    expect(ProjectIconGlyphs.of('device-desktop'), ProjectIconGlyphs.of('vm'));
  });

  test(
    'activity searches retain metadata and aliases without duplicate results',
    () {
      expect(
        searchProjectIcons('conference').map((i) => i.name),
        contains('organization'),
      );
      expect(
        searchProjectIcons('shopping').map((i) => i.name),
        containsAll(['credit-card', 'tag', 'package']),
      );
      expect(
        searchProjectIcons('trip').map((i) => i.name),
        containsAll(['map', 'compass', 'milestone']),
      );
      expect(
        searchProjectIcons('PACKING LIST').map((i) => i.name),
        contains('checklist'),
      );
      expect(
        searchProjectIcons('device-desktop').single.name,
        'device-desktop',
      );
      final all = searchProjectIcons('');
      expect(all, hasLength(92));
      expect(all.map((i) => i.name).toSet(), hasLength(92));
    },
  );

  Future<void> captureScreen(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        'build/design-previews/project-icon-native/site/renders/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> harness(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double width = 390,
    double scale = 1,
    double keyboard = 0,
    bool form = false,
    String initial = 'book',
    ValueChanged<String?>? onResult,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: const ValueKey('capture'), child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Chats')),
            body: Center(
              child: StudioButtonPress(
                child: IconButton(
                  key: const ValueKey('open-picker'),
                  tooltip: 'New project',
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    if (form) {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => ProjectEditorDialog.create(
                          loadDefaultFolder: () async => '/work',
                          createFolders: () => throw StateError(
                            'Folders are outside this icon-only journey',
                          ),
                          save: (_) async {},
                        ),
                      );
                    } else {
                      onResult?.call(
                        await showProjectIconPicker(
                          context,
                          initialIcon: initial,
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
    if (form) {
      await tester.ensureVisible(
        find.byKey(const ValueKey('project-choose-icon')),
      );
      final preview = find.byKey(const ValueKey('project-choose-icon'));
      final button = tester.widget<IconButton>(preview);
      expect(
        (button.icon as Icon).icon,
        ProjectIconGlyphs.of('folder-library'),
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(tester.getSize(preview).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(preview).height, greaterThanOrEqualTo(48));
      await captureScreen(
        tester,
        'form-${brightness.name}-${scale.toInt()}-${keyboard.toInt()}',
      );
      await tester.tap(preview);
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'confirmation alone publishes a searched icon and cancel preserves the draft',
    (tester) async {
      final results = <String?>[];
      await harness(tester, onResult: results.add);
      await tester.enterText(
        find.byKey(const ValueKey('project-icon-search-field')),
        'conference',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-icon-organization')));
      await tester.pumpAndSettle();
      expect(find.text('Groups & teams'), findsOneWidget);
      expect(results, isEmpty);
      await tester.tap(find.byTooltip('Cancel icon selection'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.byKey(const ValueKey('open-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('project-icon-preview-label')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('project-icon-preview-label')),
            )
            .data,
        'Book',
      );
      await tester.enterText(
        find.byKey(const ValueKey('project-icon-search-field')),
        'photo',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('project-icon-device-camera')),
      );
      await tester.tap(find.byKey(const ValueKey('project-icon-confirm')));
      await tester.pumpAndSettle();
      expect(results, [null, 'device-camera']);
    },
  );

  testWidgets(
    'empty search recovers, tabs clear search, reset is a separate action',
    (tester) async {
      String? result;
      await harness(tester, onResult: (value) => result = value);
      await tester.enterText(
        find.byKey(const ValueKey('project-icon-search-field')),
        'nothing-a7d9',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project-icon-empty')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('project-icon-category-work')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('project-icon-search-field')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byKey(const ValueKey('project-icon-search')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-icon-folder')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('project-icon-preview-label')),
            )
            .data,
        'Folder',
      );
      await tester.tap(find.byKey(const ValueKey('project-icon-reset')));
      await tester.pumpAndSettle();
      expect(find.text('Default icon'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-icon-confirm')));
      await tester.pumpAndSettle();
      expect(result, '');
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final keyboard in [0.0, 260.0]) {
        testWidgets(
          'creation icon tray ${brightness.name} at $scale text and $keyboard keyboard',
          (tester) async {
            await harness(
              tester,
              brightness: brightness,
              width: scale == 1 ? 390 : 320,
              scale: scale,
              keyboard: keyboard,
              form: true,
            );
            expect(
              tester
                  .widget<Text>(
                    find.byKey(const ValueKey('project-icon-category-label')),
                  )
                  .data,
              'Hermes',
            );
            final confirm = tester.getRect(
              find.byKey(const ValueKey('project-icon-confirm')),
            );
            expect(confirm.bottom, lessThanOrEqualTo(844 - keyboard));
            expect(
              find
                  .byKey(const ValueKey('project-icon-folder-library'))
                  .hitTestable(),
              findsOneWidget,
            );
            for (final category in projectIconCategories) {
              final button = find.byKey(
                ValueKey('project-icon-category-${category.name}'),
              );
              expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
              expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
            }
            await captureScreen(
              tester,
              'hermes-${brightness.name}-${scale.toInt()}-${keyboard.toInt()}',
            );
            await tester.tap(
              find.byKey(const ValueKey('project-icon-category-life')),
            );
            await tester.pumpAndSettle();
            await captureScreen(
              tester,
              'life-${brightness.name}-${scale.toInt()}-${keyboard.toInt()}',
            );
            await tester.enterText(
              find.byKey(const ValueKey('project-icon-search-field')),
              'conference',
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('project-icon-organization')),
            );
            await tester.pumpAndSettle();
            expect(
              find
                  .byKey(const ValueKey('project-icon-organization'))
                  .hitTestable(),
              findsOneWidget,
            );
            await captureScreen(
              tester,
              'groups-${brightness.name}-${scale.toInt()}-${keyboard.toInt()}',
            );
            await tester.tap(
              find.byKey(const ValueKey('project-icon-confirm')),
            );
            await tester.pumpAndSettle();
            expect(find.byType(ProjectIconPicker), findsNothing);
            expect(find.text('Groups & teams'), findsOneWidget);
            expect(
              (tester
                          .widget<IconButton>(
                            find.byKey(const ValueKey('project-choose-icon')),
                          )
                          .icon
                      as Icon)
                  .icon,
              ProjectIconGlyphs.of('organization'),
            );
            await captureScreen(
              tester,
              'form-selected-${brightness.name}-${scale.toInt()}-${keyboard.toInt()}',
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
