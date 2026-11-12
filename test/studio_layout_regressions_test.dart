import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/services/administration_logs_session.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'package:wing/core/services/profile_capabilities_session.dart';
import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'package:wing/core/widgets/admin_model_picker.dart';
import 'package:wing/core/models/model_choice.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/administration/admin_logs_page.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/profile_capabilities_screen.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/config_backup_card.dart';
import 'package:wing/core/widgets/profile_default_model_sheet.dart';
import 'support/administration_fixture.dart';

const export = bool.fromEnvironment('STUDIO_AUDIT_REVIEW');
final boundary = GlobalKey();

Future<void> capture(WidgetTester tester, String name) async {
  if (!export) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/studio-audit/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget app(Widget home, Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: wingTheme(brightness),
  builder: (context, child) => RepaintBoundary(
    key: boundary,
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
  ),
  home: home,
);

void main() {
  setUpAll(() async {
    if (!export) return;
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
  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
  }

  for (final brightness in Brightness.values) {
    testWidgets('large usage numbers wrap in ${brightness.name}', (
      tester,
    ) async {
      narrow(tester);
      final fixture = AdministrationFixture();
      fixture.override = (_, _, _, _) async => {
        'models': [
          {
            'model': 'example/long-production-model',
            'provider': 'Example provider',
            'input_tokens': 9007199254740991,
            'cache_read_tokens': 0,
            'output_tokens': 0,
            'estimated_cost': 1234567.12345,
          },
        ],
      };
      await tester.pumpWidget(
        app(
          AnalyticsPage(profile: fixture.server.profile('personal')),
          brightness,
        ),
      );
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('usage-breakdown-group'));
      await tester.scrollUntilVisible(
        group,
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('example/long-production-model'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final model = find.text('example/long-production-model');
      await Scrollable.ensureVisible(tester.element(model), alignment: .5);
      await tester.pumpAndSettle();
      expect(model.hitTestable(), findsOneWidget);
      await tester.tap(model);
      await tester.pumpAndSettle();
      expect(find.byType(AnalyticsPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label ==
                  'example/long-production-model: 9,007,199,254,740,991 tokens',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture(tester, 'usage-${brightness.name}-200-keyboard');
    });

    testWidgets(
      'skill editor actions fit with keyboard in ${brightness.name}',
      (tester) async {
        narrow(tester);
        final fixture = AdministrationFixture();
        fixture.override = (_, path, _, _) async => switch (path) {
          'skills' => {
            'data': [
              {
                'name': 'Research',
                'description': '',
                'provenance': 'agent',
                'locked': false,
                'usage': 0,
                'enabled': true,
              },
            ],
          },
          'skills/content' => {
            'name': 'Research',
            'content': 'Read the project context before editing.',
          },
          _ => throw StateError('Unexpected skill layout read $path'),
        };
        final session = ProfileSkillsSession.library(
          fixture.server.profile('personal'),
        );
        addTearDown(session.dispose);
        await session.refresh();
        final detail = session.openSkill(session.state.installed.single);
        await session.loadDetail(detail);
        final editor = session.openEditor(detail);
        await tester.pumpWidget(
          app(
            AdminSkillEditor(session: session, route: editor, detail: detail),
            brightness,
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Updated instruction');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Save skill').hitTestable(), findsOneWidget);
        await capture(tester, 'skill-editor-${brightness.name}-200-keyboard');
      },
    );

    testWidgets(
      'provider device code and actions scroll in ${brightness.name}',
      (tester) async {
        narrow(tester);
        final fixture = AdministrationFixture();
        fixture.override = (_, path, _, _) async => path == 'profiles'
            ? {
                'profiles': [
                  {'name': 'personal'},
                ],
              }
            : {
                'session_id': 'fixture',
                'flow': 'device_code',
                'verification_url': 'https://example.invalid/sign-in',
                'expires_in': 900,
                'user_code': 'LONG-DEVICE-CODE-123456789',
                'poll_interval': 60,
              };
        await tester.pumpWidget(
          app(
            AdminProviderSignIn(
              profile: fixture.server.profile('personal'),
              target: const ProviderSignInTarget(
                id: 'example',
                name: 'Example provider',
              ),
            ),
            brightness,
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Start sign-in'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start sign-in'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Open sign-in page'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, 'provider-code-${brightness.name}-200-keyboard');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'capabilities scope and failure remain reachable with keyboard in ${brightness.name}',
      (tester) async {
        narrow(tester);
        var reads = 0;
        final gateway = ProfileGateway(
          scope: WorkspaceScope(
            connectionId: 'fixture',
            profileName: 'research',
          ),
          get: (_, _) async {
            reads++;
            throw StateError('Offline');
          },
          rpc: (_, _) async => <String, dynamic>{},
          discover: () async => throw StateError('Unexpected discovery'),
        );
        await tester.pumpWidget(
          app(
            ProfileCapabilitiesScreen(
              onToolSetup: (_) async {},
              onLibrary: () async {},
              onHub: () async {},
              onPlugins: () async {},
              onConnectedApps: () async {},
              onMcpConnectors: () async {},
              createSession: () => ProfileCapabilitiesSession(gateway),
              connectionLabel: 'Development server with a long display name',
            ),
            brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Retry'));
        await tester.pumpAndSettle();
        await capture(
          tester,
          'capabilities-error-${brightness.name}-200-keyboard',
        );
        final previousReads = reads;
        expect(find.text('Retry').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(reads, greaterThan(previousReads));
        expect(find.text('Retry').hitTestable(), findsOneWidget);
      },
    );

    testWidgets(
      'long administration failure remains scrollable in ${brightness.name}',
      (tester) async {
        narrow(tester);
        var retries = 0;
        await tester.pumpWidget(
          app(
            AdminPage(
              title: 'Providers',
              scope: 'Development / research',
              child: SingleChildScrollView(
                child: AdminNotice.error(
                  'This operation could not be confirmed. Your account settings are kept. Check the connection to the server, then retry to refresh the last confirmed observation.',
                  retry: () => retries++,
                ),
              ),
            ),
            brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Retry'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Retry').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Retry'));
        expect(retries, 1);
        await capture(tester, 'admin-error-${brightness.name}-200-keyboard');
      },
    );

    testWidgets(
      'restore stays reachable with 320dp/200% and keyboard in ${brightness.name}',
      (tester) async {
        narrow(tester);
        BackupImportIntent? submitted;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    submitted = await showModalBottomSheet<BackupImportIntent>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => const ImportOptionsSheet(),
                    );
                  },
                  child: const Text('Open restore'),
                ),
              ),
            ),
            brightness,
          ),
        );
        await tester.tap(find.text('Open restore'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('import_passphrase_field')),
          'example-passphrase',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('import_confirm_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('import_confirm_button')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, 'restore-${brightness.name}-200-keyboard');
        await tester.tap(find.byKey(const Key('import_confirm_button')));
        await tester.pumpAndSettle();
        expect(submitted?.passphrase, 'example-passphrase');
        expect(find.byType(ImportOptionsSheet), findsNothing);
      },
    );

    testWidgets(
      'logs scroll filters and results with 320dp/200% keyboard in ${brightness.name}',
      (tester) async {
        narrow(tester);
        final fixture = AdministrationFixture();
        fixture.override = (_, _, query, _) async => {
          'file': query['file'],
          'lines': ['INFO Hermes is ready', 'WARNING Example diagnostic'],
        };
        await tester.pumpWidget(
          app(
            AdminLogsPage(
              createSession: () => AdministrationLogsSession(fixture.server),
            ),
            brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, 'logs-${brightness.name}-200-keyboard');
        await tester.tap(find.byTooltip('Refresh logs'));
        await tester.pumpAndSettle();
        expect(
          fixture.requests.where((request) => request.$2 == 'logs').length,
          2,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'default-model actions survive long header and keyboard in ${brightness.name}',
      (tester) async {
        narrow(tester);
        final gateway = ProfileGateway(
          rpc: (_, _) async => <String, dynamic>{},
          discover: () async => throw StateError('Unexpected discovery'),
          scope: WorkspaceScope(
            connectionId: 'fixture',
            profileName: 'personal-research-and-development',
          ),
          get: (path, _) async => path == 'model/info'
              ? {'provider': 'example', 'model': 'first-model'}
              : {
                  'providers': [
                    {
                      'slug': 'example',
                      'name': 'Example provider',
                      'models': ['first-model', 'second-model'],
                    },
                  ],
                },
        );
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showProfileDefaultModelSheet(
                    context,
                    gateway: gateway,
                    connectionLabel: 'Development server',
                  ),
                  child: const Text('Open models'),
                ),
              ),
            ),
            brightness,
          ),
        );
        await tester.tap(find.text('Open models'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('profile-model-save')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, 'default-model-${brightness.name}-200-keyboard');
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Open models'), findsOneWidget);
      },
    );

    testWidgets(
      'administration model search has recoverable empty state in ${brightness.name}',
      (tester) async {
        narrow(tester);
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => chooseAdminModel(
                    context,
                    const [
                      ModelChoice(provider: 'example', model: 'first-model'),
                    ],
                    scopeLabel: 'Models for example',
                    onRefresh: () async => const [
                      ModelChoice(provider: 'example', model: 'first-model'),
                    ],
                  ),
                  child: const Text('Choose'),
                ),
              ),
            ),
            brightness,
          ),
        );
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'no-such-model');
        await tester.pumpAndSettle();
        expect(find.text('No matching models'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(tester, 'admin-model-${brightness.name}-200-keyboard');
        await tester.tap(find.byTooltip('Clear model search'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('admin-model-provider-example')),
          findsOneWidget,
        );
      },
    );
  }
}
