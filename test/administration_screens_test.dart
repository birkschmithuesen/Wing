import 'package:wing/core/widgets/activity/skill_document_viewer.dart';
import 'package:wing/core/services/profile_tool_setup_session.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/administration/admin_memory_page.dart';
import 'package:wing/core/screens/administration/admin_tool_setup_page.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'package:wing/core/widgets/resource_filename.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'support/administration_fixture.dart';
import 'support/form_family_capture.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'helpers/pump_markdown_widget.dart';

final _fields = [
  AdminField(
    'memory.memory_char_limit',
    'Memory budget',
    AdminFieldKind.integer,
    minimum: 1,
  ),
];
void main() {
  setUpAll(loadFormFamilyFonts);
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'managed settings refusal keeps visible recovery ${brightness.name} $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = scale == 1
              ? const Size(390, 844)
              : const Size(320, 640);
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          addTearDown(tester.view.reset);
          final fixture = AdministrationFixture();
          final held = Completer<void>();
          const refusal =
              'memory.memory_char_limit is locked by your administrator.';
          fixture.override = (method, path, query, body) async {
            if (method == 'PUT' && path == 'config') {
              await held.future;
              throw const DashboardHttpException(
                403,
                'config?profile=personal',
                responseDetail: refusal,
              );
            }
            final handler = fixture.override;
            fixture.override = null;
            try {
              return await fixture.send(method, path, query, body);
            } finally {
              fixture.override = handler;
            }
          };
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: formFamilyCapture, child: child!),
              ),
              home: AdminSettingsPage(
                profile: fixture.server.profile('personal'),
                title: 'Memory settings',
                fields: _fields,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextFormField), '2500');
          await tester.pump();
          await tester.tap(find.byTooltip('Save changes'));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 400));
          await captureFormFamily(
            tester,
            'managed-settings-pending-${brightness.name}-$scale',
          );
          held.complete();
          await tester.pumpAndSettle();
          expect(find.text(refusal), findsOneWidget);
          expect(find.text('2500'), findsOneWidget);
          final save = find.byTooltip('Save changes').hitTestable();
          expect(save, findsOneWidget);
          final rect = tester.getRect(save);
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(
            rect.bottom,
            lessThanOrEqualTo(tester.view.physicalSize.height - 200),
          );
          // Long refusal text remains readable through the ordinary content
          // scroll while the fixed recovery controls stay above the keyboard.
          final errorText = find.text(refusal);
          final footerTop = tester.getRect(find.text('1 unsaved change')).top;
          for (
            var attempt = 0;
            attempt < 8 && tester.getRect(errorText).bottom > footerTop;
            attempt++
          ) {
            final gap = tester.getRect(errorText).bottom - footerTop;
            await tester.drag(
              find.byType(SingleChildScrollView).first,
              Offset(0, -(gap + 24).clamp(32.0, 80.0).toDouble()),
            );
            await tester.pumpAndSettle();
          }
          expect(
            tester.getRect(errorText).bottom,
            lessThanOrEqualTo(footerTop),
          );
          expect(tester.getRect(errorText).bottom, greaterThan(0));
          await captureFormFamily(
            tester,
            'managed-settings-refused-${brightness.name}-$scale',
          );
          fixture.override = null;
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(find.text(refusal), findsNothing);
          expect(fixture.settingsDispatches, 2);
          expect(find.text('Settings saved.'), findsOneWidget);
          expect(find.text('No unsaved changes'), findsOneWidget);
          expect(
            fixture.configs['personal']!['memory']['memory_char_limit'],
            2500,
          );
          final acknowledgement = tester.getRect(find.byType(SnackBar));
          final footer = tester.getRect(find.byType(AdminEditorActions));
          expect(acknowledgement.top, greaterThanOrEqualTo(0));
          expect(acknowledgement.bottom, lessThanOrEqualTo(footer.top));
          expect(
            footer.bottom,
            lessThanOrEqualTo(tester.view.physicalSize.height - 200),
          );
          await captureFormFamily(
            tester,
            'managed-settings-saved-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('Hub preview uses shared skill instructions without installing', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.override = (_, path, _, _) async => switch (path) {
      'skills/hub/official' => {
        'skills': [
          {
            'name': 'review',
            'description': 'Review supplied sources.',
            'source': 'Example',
            'identifier': 'example/review',
          },
        ],
      },
      'skills/hub/preview' => {
        'identifier': 'example/review',
        'name': 'review',
        'source': 'Example',
        'trust_level': 'community',
        'skill_md': '# Review\n\nInspect every source.',
      },
      _ => throw StateError('Unexpected request $path'),
    };
    final session = ProfileSkillsSession.hub(
      fixture.server.profile('personal'),
    );
    addTearDown(session.dispose);
    await session.refresh();
    final route = session.openPreview(session.state.catalog.single);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: AdminSkillPreview(session: session, route: route),
      ),
    );
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(find.byType(SkillDocumentViewer), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    await tester.tap(find.byTooltip('Skill actions'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Install skill'), findsOneWidget);
    expect(find.byTooltip('Edit instructions'), findsNothing);
    expect(fixture.requests.every((request) => request.$1 == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'administration uses the shared skill viewer ${brightness.name} $scale',
        (tester) async {
          const raw =
              '---\nname: research\ndescription: Review the evidence.\nmetadata:\n  version: 1.0\n  author: Example\n  hermes:\n    tags: [research, evidence]\nlicense: MIT\n---\n# Research\n\nRead the **original** evidence.\n';
          final fixture = AdministrationFixture();
          fixture.override = (_, path, _, _) async => switch (path) {
            'skills' => {
              'data': [
                {
                  'name': 'research',
                  'description': 'Review the evidence.',
                  'provenance': 'agent',
                  'locked': false,
                  'usage': 2,
                  'enabled': true,
                },
              ],
            },
            'skills/content' => {
              'name': 'research',
              'content': raw,
              'path': '/workspace/skills/research/SKILL.md',
            },
            _ => throw StateError('Unexpected request $path'),
          };
          final session = ProfileSkillsSession.library(
            fixture.server.profile('personal'),
          );
          addTearDown(session.dispose);
          await session.refresh();
          final route = session.openSkill(session.state.installed.single);
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
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
                child: child!,
              ),
              home: AdminSkillDetail(session: session, route: route),
            ),
          );
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.byType(SkillDocumentViewer), findsOneWidget);
          expect(find.text('Research'), findsOneWidget);
          expect(find.text('Review the evidence.'), findsOneWidget);
          expect(find.text('Version'), findsOneWidget);
          expect(find.text('MIT'), findsNothing);
          expect(find.text('evidence'), findsOneWidget);
          expect(find.byTooltip('Skill actions'), findsOneWidget);
          expect(find.text('Edit instructions'), findsNothing);
          await tester.tap(
            find.descendant(
              of: find.byType(ResourceViewerAppBar),
              matching: find.text('research'),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('/workspace/skills/research/SKILL.md'),
            findsOneWidget,
          );
          await tester.tapAt(const Offset(5, 400));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Copy skill name'));
          await tester.pump();
          expect(copied, 'research');
          await tester.ensureVisible(find.byTooltip('Show raw content'));
          await tester.tap(find.byTooltip('Show raw content'));
          await tester.pumpAndSettle();
          expect(find.text(raw), findsOneWidget);
          await tester.ensureVisible(find.byTooltip('Copy content'));
          await tester.tap(find.byTooltip('Copy content'));
          await tester.pump();
          expect(copied, raw);
          await tester.tap(find.byTooltip('Skill actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Edit instructions'));
          await tester.pumpAndSettle();
          expect(find.byType(AdminSkillEditor), findsOneWidget);
          expect(session.state.edit!.draft, raw);
          expect(
            fixture.requests.every((request) => request.$1 == 'GET'),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('managed provider selection explains required sign-in', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (method == 'PUT' && path == 'tools/toolsets/stt/provider') {
        return {
          'ok': true,
          'name': 'stt',
          'provider': 'Nous Subscription',
          'needs_nous_auth': true,
        };
      }
      return {
        'name': 'stt',
        'has_category': true,
        'active_provider': null,
        'providers': [
          {
            'name': 'Nous Subscription',
            'status': 'needs_auth',
            'requires_nous_auth': true,
            'is_active': false,
            'badge': '',
            'tag': '',
            'env_vars': [],
          },
        ],
      };
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: AdminToolSetupPage(
          createSession: () => ProfileToolSetupSession(
            fixture.server.profile('personal'),
            tool: 'stt',
          ),
          onCredential: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use provider'));
    await tester.pumpAndSettle();
    expect(
      find.text('Selection saved. This provider still needs account access.'),
      findsOneWidget,
    );
    expect(find.textContaining('could not be confirmed'), findsNothing);
  });
  testWidgets(
    'save confirmation stays above editor actions with the keyboard open',
    (tester) async {
      final fixture = AdministrationFixture();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: AdminSettingsPage(
            profile: fixture.server.profile('personal'),
            title: 'Memory settings',
            fields: _fields,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      final footer = tester.getRect(find.byTooltip('Cancel'));
      expect(footer.bottom, lessThanOrEqualTo(564));
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(footer.top),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'an externally changed field preserves the draft without overwriting it',
    (tester) async {
      final f = AdministrationFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: f.server.profile('personal'),
            title: 'Memory settings',
            fields: _fields,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      (f.configs['personal']!['memory'] as Map)['memory_char_limit'] = 4000;
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('changed elsewhere'), findsOneWidget);
      expect(find.text('2500'), findsOneWidget);
      expect(f.requests.where((r) => r.$1 == 'PUT'), isEmpty);
    },
  );

  testWidgets(
    'partial settings readback keeps both edits and never reports success',
    (tester) async {
      final f = AdministrationFixture();
      f.override = (method, path, query, body) async {
        // Use the real fixture contract except that this server ignores one field.
        final handler = f.override;
        f.override = null;
        try {
          final result = await f.send(method, path, query, body);
          if (method == 'PUT') {
            (f.configs['personal']!['memory'] as Map)['memory_enabled'] = true;
          }
          return result;
        } finally {
          f.override = handler;
        }
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: f.server.profile('personal'),
            title: 'Memory settings',
            fields: [memoryFields.first, _fields.first],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Save not confirmed'), findsOneWidget);
      expect(find.text('Settings saved.'), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, false);
      expect(find.text('2500'), findsOneWidget);
    },
  );
  testWidgets(
    'settings editor keeps original owner after a parent selection change',
    (tester) async {
      final f = AdministrationFixture();
      Future<void> show(String name) => tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: f.server.profile(name),
            title: 'Memory settings',
            fields: _fields,
          ),
        ),
      );
      await show('personal');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await show('work');
      await tester.pumpAndSettle();
      expect(find.text('Server A / personal'), findsOneWidget);
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      final write = f.requests.firstWhere((r) => r.$1 == 'PUT');
      expect(write.$3['profile'], 'personal');
      expect(f.configs['work']!['memory'], {
        'memory_enabled': false,
        'memory_char_limit': 3000,
      });
      expect(find.text('Settings saved.'), findsOneWidget);
    },
  );

  testWidgets(
    'unconfirmed settings save preserves draft and makes no success claim',
    (tester) async {
      final f = AdministrationFixture()..ignoreSave = true;
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: f.server.profile('personal'),
            title: 'Memory settings',
            fields: _fields,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('2500'), findsOneWidget);
      expect(find.textContaining('Save not confirmed'), findsOneWidget);
      expect(find.text('Settings saved.'), findsNothing);
    },
  );

  testWidgets(
    'pending save prevents duplicate submission and keeps target visible',
    (tester) async {
      final f = AdministrationFixture()..writeGate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSettingsPage(
            profile: f.server.profile('personal'),
            title: 'Memory settings',
            fields: _fields,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '2500');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pump();
      final save = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Save changes',
      );
      final progress = find.descendant(
        of: save,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(tester.widget<IconButton>(save).onPressed, isNull);
      expect(progress, findsOneWidget);
      expect(find.text('Server A / personal'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(progress, findsOneWidget);
      await tester.tap(save);
      await tester.pump();
      expect(f.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      f.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(f.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      expect(
        (f.configs['personal']!['memory'] as Map)['memory_char_limit'],
        2500,
      );
    },
  );

  testWidgets('memory failure is not rendered as an empty list', (
    tester,
  ) async {
    final f = AdministrationFixture()..failReads = true;
    await tester.pumpWidget(
      MaterialApp(home: AdminMemoryPage(profile: f.server.profile('personal'))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load'), findsOneWidget);
    expect(find.text('No retained memories in this profile.'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'malformed memory response becomes unavailable instead of a widget exception',
    (tester) async {
      final f = AdministrationFixture();
      f.override = (_, _, _, _) async => {'memory': 'broken'};
      await tester.pumpWidget(
        MaterialApp(
          home: AdminMemoryPage(profile: f.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('The server returned an invalid response.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('secret editor does not load existing secrets or expose input', (
    tester,
  ) async {
    final f = AdministrationFixture();
    f.override = (method, path, query, body) async => {
      'EXAMPLE_API_KEY': {
        'is_set': false,
        'channel_managed': false,
        'category': 'api_keys',
        'provider_label': 'Example',
        'redacted_value': 'preview-must-not-enter-form',
      },
    };
    await tester.pumpWidget(
      MaterialApp(
        home: AdminSecretPage(
          profile: f.server.profile('personal'),
          name: 'EXAMPLE_API_KEY',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.requests, hasLength(1));
    expect((f.requests.single.$1, f.requests.single.$2), ('GET', 'env'));
    expect(f.requests.single.$3, {'profile': 'personal'});
    expect(find.textContaining('preview-must-not-enter-form'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'settings fit 360dp, large text and open keyboard in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final f = AdministrationFixture();
        await tester.pumpWidget(
          MaterialApp(
            theme: profileWorkspaceTheme(wingTheme(brightness)),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: AdminSettingsPage(
              profile: f.server.profile('personal'),
              title: 'Memory settings',
              fields: _fields,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final save = tester.getRect(find.byTooltip('Save changes'));
        expect(save.bottom, lessThanOrEqualTo(520));
        expect(save.left, greaterThanOrEqualTo(0));
      },
    );
  }
}
