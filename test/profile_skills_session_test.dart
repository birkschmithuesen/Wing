import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'support/administration_fixture.dart';

const _captureSkills = bool.fromEnvironment('SKILL_AUDIT_REVIEW');

Future<void> _captureSkill(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (!_captureSkills) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/feature-verification/skill-renders/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (!_captureSkills) return;
    const dir = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          File('$dir/${entry.value}').readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final preview in [false, true]) {
        testWidgets(
          preview
              ? 'opening a skill preview safely notifies its mounted hub ${brightness.name} $scale'
              : 'opening a skill detail safely notifies its mounted library ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final boundary = GlobalKey();
            final renderName =
                '${preview ? 'preview' : 'detail'}-${brightness.name}-$scale';
            final fixture = AdministrationFixture();
            final content = Completer<Map<String, dynamic>>();
            fixture.override = (_, path, _, _) async => switch (path) {
              'profiles' => {
                'profiles': [
                  {'name': 'personal'},
                ],
              },
              'profiles/active' => {
                'current': 'personal',
                'active': 'personal',
              },
              'skills' => _library,
              'skills/content' => content.future,
              'skills/hub/official' => {
                'skills': [
                  {
                    'name': 'research',
                    'description': 'Research',
                    'source': 'catalog',
                    'identifier': 'qa/research',
                  },
                ],
              },
              'skills/hub/preview' => content.future,
              _ => throw StateError('Unexpected request $path'),
            };
            late ProfileSkillsSession session;
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => RepaintBoundary(
                  key: boundary,
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                ),
                home: preview
                    ? AdminSkillHubPage(
                        createSession: () => session = ProfileSkillsSession.hub(
                          fixture.server.profile('personal'),
                        ),
                      )
                    : AdminSkillLibraryPage(
                        createSession: () =>
                            session = ProfileSkillsSession.library(
                              fixture.server.profile('personal'),
                            ),
                      ),
              ),
            );
            await tester.pumpAndSettle();
            expect(session.state.verified, isTrue);
            await tester.tap(find.text('research'));
            final detail = find.byType(
              preview ? AdminSkillPreview : AdminSkillDetail,
            );
            for (
              var frame = 0;
              detail.evaluate().isEmpty && frame < 20;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.takeException(), isNull);
            }
            expect(detail, findsOneWidget);
            expect(
              tester
                  .widget<StudioLoadingRegion>(
                    find.descendant(
                      of: detail,
                      matching: find.byType(StudioLoadingRegion),
                    ),
                  )
                  .busy,
              isTrue,
              reason:
                  'Initial read must be pending in the first destination build',
            );
            // The shared header publishes body registrations at frame end. Check
            // its actual indicator on the next frame while the read stays held.
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              find.descendant(of: detail, matching: find.byType(StudioLoading)),
              findsWidgets,
            );
            expect(session.state.busy, isTrue);
            await tester.pump(const Duration(milliseconds: 350));
            expect(find.byType(StudioLoading), findsWidgets);
            await _captureSkill(tester, boundary, '$renderName-pending');
            content.complete(
              preview
                  ? {
                      'identifier': 'qa/research',
                      'name': 'research',
                      'source': 'catalog',
                      'trust_level': 'community',
                      'skill_md': 'Opening instructions',
                    }
                  : {'name': 'research', 'content': 'Opening instructions'},
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              preview
                  ? session.state.preview?.content
                  : session.state.instructions?.content,
              'Opening instructions',
            );
            expect(session.state.verified, isTrue);
            await _captureSkill(tester, boundary, '$renderName-loaded');
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              find.byType(preview ? AdminSkillHubPage : AdminSkillLibraryPage),
              findsOneWidget,
            );
            expect(session.state.verified, isTrue);
          },
        );
      }
    }
  }

  test(
    'closing a borrowed skill editor revokes a held unsent save while the library remains',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileSkillsSession.library(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      fixture.override = (_, path, _, _) async => switch (path) {
        'profiles' => {
          'profiles': [
            {'name': 'personal'},
          ],
        },
        'profiles/active' => {'current': 'personal', 'active': 'personal'},
        'skills' => _library,
        'skills/content' => {
          'name': 'research',
          'content': 'Opening instructions',
        },
        _ => throw StateError('Unexpected request $path'),
      };
      var dispatches = 0;
      fixture.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            entered.complete();
            await release.future;
            if (!canDispatch()) {
              throw StateError('Child retired before dispatch');
            }
            dispatches++;
            onDispatched();
            return fixture.send(method, path, query, body);
          };
      await session.refresh();
      final detail = session.openSkill(session.state.installed.single);
      await session.loadDetail(detail);
      final editor = session.openEditor(detail);
      session.edit(editor, 'My instructions');
      final saving = session.save(editor);
      await entered.future;
      session.releaseEditor(editor);
      release.complete();
      await saving;
      expect(dispatches, 0);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      expect(session.state.edit!.draft, 'My instructions');
      expect(session.state.edit!.saved, 'Opening instructions');
      expect(session.state.reviewRequired, isFalse);
      await session.loadDetail(detail);
      expect(session.state.verified, isTrue);
      expect(session.state.instructions!.content, 'Opening instructions');
    },
  );

  test(
    'an acknowledged instruction save survives failing readback without repeating the write',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileSkillsSession.library(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      var content = 'Opening instructions', unavailable = false;
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (path == 'profiles/active') {
          return {'current': 'personal', 'active': 'personal'};
        }
        if (path == 'skills') return _library;
        if (method == 'PUT') {
          content = body!['content'] as String;
          unavailable = true;
          return {
            'success': true,
            'message': 'Skill updated',
            'path': '/profiles/personal/skills/research',
          };
        }
        if (path == 'skills/content') {
          if (unavailable) throw const FormatException('Malformed readback');
          return {'name': 'research', 'content': content};
        }
        throw StateError('Unexpected $method $path');
      };
      await session.refresh();
      final detail = session.openSkill(session.state.installed.single);
      await session.loadDetail(detail);
      final editor = session.openEditor(detail);
      session.edit(editor, 'Saved instructions');
      await session.save(editor);
      expect(content, 'Saved instructions');
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      expect(session.state.edit!.saved, 'Saved instructions');
      expect(session.state.edit!.draft, 'Saved instructions');
      expect(
        session.state.notice,
        'Instructions saved. Hermes can reload them in this chat.',
      );
      expect(session.state.verified, isFalse);
      expect(session.state.reviewRequired, isFalse);
      await session.save(editor);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      unavailable = false;
      await session.loadDetail(detail);
      expect(session.state.instructions!.content, 'Saved instructions');
      expect(session.state.verified, isTrue);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
    },
  );
}

const _library = <String, dynamic>{
  'data': [
    {
      'name': 'research',
      'description': 'Research',
      'provenance': 'agent',
      'locked': false,
      'usage': 3,
      'enabled': true,
    },
  ],
};
