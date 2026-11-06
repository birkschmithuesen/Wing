import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/profile_connectors_session.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/services/shared_draft_session.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/screens/administration/provider_recovery_routes.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/screens/administration/admin_connector_routes.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/main.dart';

import 'home_config_restore_test.dart' show createHomeFixture, homeEntryFactory;
import 'support/profile_browser_fixture.dart';
import 'support/administration_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_WORKSPACE_PICKER');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileBrowserFixture fixture;
  final first = SavedConnection(
    id: 'claw',
    label: 'Claw',
    host: 'localhost',
    port: 1,
    apiKey: '',
  );
  final second = SavedConnection(
    id: 'travel',
    label: 'Travel server',
    host: 'localhost',
    port: 2,
    apiKey: '',
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = ProfileBrowserFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(connection: first, dashboardOAuth: null),
      connectionIdentity: 'picker-claw',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> show(
    WidgetTester tester, {
    AppDestination destination = AppDestination.chats,
    Brightness brightness = Brightness.dark,
    double scale = 1,
    Future<void> Function(SavedConnection, AppDestination)? onConnection,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
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
          child: RepaintBoundary(key: const ValueKey('capture'), child: child!),
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
          initialDestination: destination,
          savedConnections: () => [first, second],
          onSelectConnection: onConnection,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final status = find.byKey(const ValueKey('connection-status-target'));
  final picker = find.byKey(const ValueKey('workspace-picker-target'));
  final analyticsPicker = find.byKey(
    const ValueKey('analytics-profile-picker-target'),
  );
  final work = find.byKey(const ValueKey('workspace-profile-work'));

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/workspace-picker-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final destination in [
    AppDestination.chats,
    AppDestination.activity,
    AppDestination.administration,
    AppDestination.health,
  ]) {
    testWidgets('${destination.name} picker follows the displayed scope', (
      tester,
    ) async {
      await show(tester, destination: destination);
      expect(tester.getSize(status).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(picker).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(status).overlaps(tester.getRect(picker)), isFalse);
      await tester.tapAt(tester.getBottomRight(status) - const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsOneWidget);
      expect(work, findsNothing);
      await tester.tap(find.byTooltip('Close connection details'));
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsNothing);
      final includesProfile =
          destination == AppDestination.administration ||
          destination == AppDestination.health;
      expect(work, includesProfile ? findsOneWidget : findsNothing);
      expect(
        find.text('Profile'),
        includesProfile || destination == AppDestination.chats
            ? findsWidgets
            : findsNothing,
      );
      expect(
        find.byTooltip(
          includesProfile ? 'Choose instance and profile' : 'Choose instance',
        ),
        findsOneWidget,
      );
      if (includesProfile) {
        await tester.tap(work);
      } else {
        expect(find.text('Claw · personal'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('workspace-connection-claw')),
        );
      }
      await tester.pumpAndSettle();
      expect(
        controller.current!.scope.profileName,
        includesProfile ? 'work' : 'personal',
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppDrawer>(find.byType(AppDrawer, skipOffstage: false))
            .selected,
        destination,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'saved alias updates the open chat ${brightness.name} at $scale',
        (tester) async {
          controller.observeConnectionLabel('claw.tarkilnetwork');
          final key = ProfileSessionKey(controller.current!.scope, 'newest');
          final chat = await controller.openSession(key);
          await controller.updateDraft(chat!, 'Keep this draft');
          await show(tester, brightness: brightness, scale: scale);
          expect(find.text('claw.tarkilnetwork'), findsOneWidget);
          await screenshot(tester, 'alias-before-${brightness.name}-$scale');

          controller.observeConnectionLabel(first.label);
          await tester.pumpAndSettle();
          expect(find.text('claw.tarkilnetwork'), findsNothing);
          expect(find.text('Claw'), findsOneWidget);
          expect(find.text('Keep this draft'), findsOneWidget);
          expect(controller.current!.chat, same(chat));
          await screenshot(tester, 'alias-after-${brightness.name}-$scale');

          await tester.tap(picker);
          await tester.pumpAndSettle();
          expect(find.text('Claw'), findsNWidgets(2));
          await screenshot(tester, 'alias-picker-${brightness.name}-$scale');
          await tester.tap(
            find.byKey(const ValueKey('workspace-connection-claw')),
          );
          await tester.pumpAndSettle();
          expect(find.text('Claw'), findsOneWidget);
          expect(find.text('Keep this draft'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('picker renders ${brightness.name} at $scale', (
        tester,
      ) async {
        await show(
          tester,
          destination: AppDestination.administration,
          brightness: brightness,
          scale: scale,
        );
        await screenshot(tester, 'header-${brightness.name}-$scale');
        await tester.tap(picker);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(tester, 'picker-${brightness.name}-$scale');
        final semantics = tester.ensureSemantics();
        await tester.pump();
        final selected = find.descendant(
          of: find.byKey(const ValueKey('workspace-profile-personal')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.selected == true,
          ),
        );
        expect(selected, findsOneWidget);
        expect(tester.getSemantics(selected), isSemantics(isSelected: true));
        semantics.dispose();
        await tester.tapAt(const Offset(5, 800));
        await tester.pumpAndSettle();
        expect(work, findsNothing);
        expect(controller.current!.scope.profileName, 'personal');
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-activity')));
        await tester.pumpAndSettle();
        expect(find.text('Claw · personal'), findsNothing);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        expect(work, findsNothing);
        expect(find.text('Profile'), findsNothing);
        expect(tester.takeException(), isNull);
        await screenshot(tester, 'connections-${brightness.name}-$scale');
      });
    }
  }

  testWidgets('connection choice retains current section', (tester) async {
    (String, AppDestination)? selected;
    await show(
      tester,
      destination: AppDestination.activity,
      onConnection: (connection, destination) async {
        selected = (connection.id, destination);
      },
    );
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-connection-travel')));
    await tester.pumpAndSettle();
    expect(selected, ('travel', AppDestination.activity));
  });

  testWidgets(
    'Chats menu returns from a conversation to the list and retains its draft',
    (tester) async {
      final key = ProfileSessionKey(controller.current!.scope, 'newest');
      final chat = await controller.openSession(key);
      await controller.updateDraft(chat!, 'Keep this draft');
      await show(tester);
      expect(find.text('Keep this draft'), findsOneWidget);

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-chats')));
      await tester.pumpAndSettle();

      expect(controller.current!.chat, isNull);
      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(find.text('Keep this draft'), findsNothing);
      expect(chat.composer.observation.displayedText, 'Keep this draft');

      await controller.openSession(key);
      await tester.pumpAndSettle();
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conversation header offers only connections and retains its draft',
    (tester) async {
      final chat = await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'newest'),
      );
      await controller.updateDraft(chat!, 'Keep this draft');
      String? selected;
      await show(
        tester,
        onConnection: (connection, destination) async {
          selected = connection.id;
          expect(destination, AppDestination.chats);
        },
      );
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(work, findsNothing);
      expect(find.text('Profile'), findsNothing);
      expect(find.byTooltip('Choose instance'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('workspace-connection-travel')),
      );
      await tester.pumpAndSettle();
      expect(selected, 'travel');
      expect(controller.current!.scope.profileName, 'personal');
      expect(chat.composer.observation.displayedText, 'Keep this draft');
    },
  );

  testWidgets('server-owned administration header offers only connections', (
    tester,
  ) async {
    await show(tester, destination: AppDestination.administration);
    adminPush(
      tester.element(find.byType(ServerConnectionLabel)),
      (context) => const AdminPage(
        title: 'Server logs',
        scope: 'Claw',
        child: Text('Logs'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(work, findsNothing);
    expect(find.text('Profile'), findsNothing);
    expect(find.byTooltip('Choose instance'), findsOneWidget);
  });

  testWidgets('failed profile switch retains confirmed scope', (tester) async {
    await show(tester, destination: AppDestination.administration);
    fixture.failWork = true;
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(controller.current!.scope.profileName, 'personal');
    expect(controller.error, isNotNull);
  });

  testWidgets(
    'drawer analytics defaults to All and filters without switching workspace',
    (tester) async {
      String? selectedInstance;
      await show(
        tester,
        destination: AppDestination.analytics,
        onConnection: (connection, destination) async {
          selectedInstance = connection.id;
          expect(destination, AppDestination.analytics);
        },
      );
      expect(find.text('Claw'), findsOneWidget);
      expect(find.byTooltip('Choose instance'), findsOneWidget);
      expect(
        tester.getRect(picker).overlaps(tester.getRect(analyticsPicker)),
        isFalse,
      );
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-all-profiles')),
        findsNothing,
      );
      expect(work, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('workspace-connection-travel')),
      );
      await tester.pumpAndSettle();
      expect(selectedInstance, 'travel');
      expect(find.text('All'), findsOneWidget);
      expect(find.byTooltip('Choose profile'), findsOneWidget);
      await tester.tap(analyticsPicker);
      await tester.pumpAndSettle();
      expect(work, findsOneWidget);
      final all = find.byKey(const ValueKey('workspace-all-profiles'));
      expect(all, findsOneWidget);
      expect(tester.getTopLeft(all).dy, lessThan(tester.getTopLeft(work).dy));
      expect(
        find.byKey(const ValueKey('workspace-connection-claw')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('workspace-connection-travel')),
        findsNothing,
      );
      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(controller.current!.scope.profileName, 'personal');
      expect(
        find.descendant(of: analyticsPicker, matching: find.text('work')),
        findsOneWidget,
      );
      expect(find.text('Hermes analytics'), findsOneWidget);
      expect(find.byType(HermesAnalyticsContent), findsOneWidget);
      expect(find.byTooltip('Refresh profile status'), findsNothing);
      await tester.tap(analyticsPicker);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(find.text('All'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'All analytics picker and held reads ${brightness.name} at $scale',
        (tester) async {
          final administration = AdministrationFixture('Claw');
          addTearDown(administration.server.close);
          controller.healthSession(repository: administration.server);
          Completer<void>? held;
          var fail = false;
          administration.override = (_, path, query, _) async {
            if (path == 'analytics/models') {
              if (query['profile'] == 'work') {
                await held?.future;
                if (fail) throw const FormatException('Unavailable');
              }
              return {
                'models': [
                  {
                    'model': 'example',
                    'provider': 'example',
                    'estimated_cost': query['profile'] == 'work' ? 7 : 3,
                    'input_tokens': 100,
                    'cache_read_tokens': 0,
                    'output_tokens': 10,
                  },
                ],
              };
            }
            return {
              'daily': [
                {
                  'day': '2026-10-14',
                  'input_tokens': 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 10,
                },
              ],
            };
          };
          await show(
            tester,
            destination: AppDestination.analytics,
            brightness: brightness,
            scale: scale,
          );
          expect(find.text('All'), findsOneWidget);
          expect(find.text('Claw'), findsOneWidget);
          expect(
            tester.getSize(analyticsPicker).height,
            greaterThanOrEqualTo(48),
          );
          expect(
            tester.getRect(picker).overlaps(tester.getRect(analyticsPicker)),
            isFalse,
          );
          expect(find.text('USD 10.00'), findsOneWidget);
          await screenshot(tester, 'analytics-all-${brightness.name}-$scale');
          await tester.tap(analyticsPicker);
          await tester.pumpAndSettle();
          final all = find.byKey(const ValueKey('workspace-all-profiles'));
          final selected = find.descendant(
            of: all,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected == true,
            ),
          );
          expect(selected, findsOneWidget);
          expect(tester.getSize(all).height, greaterThanOrEqualTo(48));
          await screenshot(
            tester,
            'analytics-picker-${brightness.name}-$scale',
          );
          final cachedReads = administration.requests.length;
          await tester.tap(work);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            find.descendant(of: analyticsPicker, matching: find.text('work')),
            findsOneWidget,
          );
          expect(controller.current!.scope.profileName, 'personal');
          await screenshot(
            tester,
            'analytics-cached-${brightness.name}-$scale',
          );
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text('USD 7.00'), findsOneWidget);
          expect(administration.requests.length, cachedReads);
          await tester.tap(analyticsPicker);
          await tester.pumpAndSettle();
          await tester.tap(all);
          await tester.pumpAndSettle();
          expect(find.text('USD 10.00'), findsOneWidget);
          final refresh = find.byWidgetPredicate(
            (widget) =>
                widget is IconButton && widget.tooltip == 'Refresh usage',
          );
          Future<void> revealRefresh() async {
            await tester.scrollUntilVisible(
              refresh,
              300,
              scrollable: find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is Scrollable &&
                        widget.axisDirection == AxisDirection.down,
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(refresh);
            await tester.pumpAndSettle();
          }

          await revealRefresh();
          held = Completer<void>();
          await tester.tap(refresh);
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          await screenshot(
            tester,
            'analytics-refresh-${brightness.name}-$scale',
          );
          fail = true;
          held.complete();
          held = null;
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            find.textContaining('work: Could not load model totals.'),
            findsOneWidget,
          );
          await screenshot(
            tester,
            'analytics-failed-${brightness.name}-$scale',
          );
          fail = false;
          await revealRefresh();
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Could not load model totals.'),
            findsNothing,
          );
          expect(controller.current!.scope.profileName, 'personal');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Analytics offers only profiles and reloads the selected owner', (
    tester,
  ) async {
    final administration = AdministrationFixture('Claw');
    addTearDown(administration.server.close);
    administration.override = (_, path, _, _) async =>
        path == 'analytics/models' ? {'models': []} : {'daily': []};
    await show(tester, destination: AppDestination.health);
    adminPushProfile(
      tester.element(find.byType(ServerConnectionLabel)),
      administration.server.profile('personal'),
      (_, profile) => AnalyticsPage(profile: profile),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Choose profile'), findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(work, findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-connection-claw')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('workspace-connection-travel')),
      findsNothing,
    );
    expect(find.text('Hermes instance'), findsNothing);
    await screenshot(tester, 'usage-profile-only');
    final before = administration.requests.length;
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(find.text('Hermes analytics'), findsOneWidget);
    expect(find.text('Claw / work'), findsOneWidget);
    expect(controller.current!.scope.profileName, 'work');
    expect(administration.requests.skip(before), isNotEmpty);
    expect(
      administration.requests
          .skip(before)
          .every((r) => r.$3['profile'] == 'work'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile picker keeps Connectors open on the selected profile', (
    tester,
  ) async {
    final administration = AdministrationFixture('Claw');
    addTearDown(administration.server.close);
    await show(tester, destination: AppDestination.health);
    final context = tester.element(find.byType(ServerConnectionLabel));
    adminPushProfile(
      context,
      administration.server.profile('personal'),
      (context, profile) => profileConnectorsPage(profile),
    );
    await tester.pumpAndSettle();
    expect(find.text('MCP connectors'), findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(find.text('MCP connectors'), findsOneWidget);
    expect(find.text('Claw / work'), findsOneWidget);
    expect(controller.current!.scope.profileName, 'work');
    expect(
      administration.requests.any(
        (request) =>
            request.$2 == 'mcp/servers' && request.$3['profile'] == 'work',
      ),
      isTrue,
    );
  });

  testWidgets(
    'list-borrowed connector detail admits fresh owners across personal work personal',
    (tester) async {
      final administration = AdministrationFixture('Claw');
      addTearDown(administration.server.close);
      administration.override = (method, path, query, body) async {
        expect(method, 'GET');
        expect(path, 'mcp/servers');
        return {
          'servers': [
            {
              'name': 'docs',
              'transport': 'http',
              'auth': null,
              'enabled': true,
              'source': 'config',
              'plugin': null,
            },
          ],
        };
      };
      administration.rpcOverride = (method, params) async {
        expectSync(method, 'mcp.servers.status');
        return {
          'checked_at': DateTime.now().millisecondsSinceEpoch,
          'servers': [
            {
              'name': 'docs',
              'transport': 'http',
              'source': 'config',
              'plugin': null,
              'tools': 0,
              'connected': false,
              'disabled': false,
              'status': 'configured',
              'needs_auth': false,
            },
          ],
        };
      };
      await show(tester, destination: AppDestination.health);
      adminPushProfile(
        tester.element(find.byType(ServerConnectionLabel)),
        administration.server.profile('personal'),
        (_, profile) => profileConnectorsPage(profile),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'docs'));
      await tester.pumpAndSettle();
      expect(find.text('Test connection'), findsOneWidget);
      expect(find.text('Claw / personal'), findsOneWidget);
      for (final selected in ['work', 'personal']) {
        final marker = administration.requests.length;
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('workspace-profile-$selected')));
        await tester.pumpAndSettle();
        expect(controller.current!.scope.profileName, selected);
        expect(find.text('Claw / $selected'), findsOneWidget);
        expect(find.text('Test connection'), findsOneWidget);
        expect(
          administration.requests
              .skip(marker)
              .where(
                (request) =>
                    request.$2 == 'mcp/servers' &&
                    request.$3['profile'] == selected,
              ),
          isNotEmpty,
        );
        expect(tester.takeException(), isNull);
      }
      expect(
        administration.requests.every((request) => request.$1 == 'GET'),
        isTrue,
      );
      expect(administration.rpcRequests, [
        ('personal', 'mcp.servers.status'),
        ('personal', 'mcp.servers.status'),
        ('work', 'mcp.servers.status'),
        ('personal', 'mcp.servers.status'),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Health Connectors stays open across profile changes and Back', (
    tester,
  ) async {
    await show(tester, destination: AppDestination.health);
    await tester.scrollUntilVisible(
      find.text('Connectors'),
      200,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('administration-health-findings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connectors'));
    await tester.pumpAndSettle();
    expect(find.text('Connectors'), findsOneWidget);
    for (final name in ['work', 'personal', 'work']) {
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('workspace-profile-$name')));
      await tester.pumpAndSettle();
      expect(find.text('Connectors'), findsOneWidget);
      expect(find.text('Claw / $name'), findsOneWidget);
      expect(find.text(AppDestination.health.label), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(AppDestination.health.label), findsOneWidget);
    expect(controller.current!.scope.profileName, 'work');
  });

  testWidgets('provider recovery reloads the selected profile before actions', (
    tester,
  ) async {
    final administration = AdministrationFixture('Claw');
    addTearDown(administration.server.close);
    administration.override = (method, path, query, body) async => {
      'providers': query['profile'] == 'personal'
          ? [
              {
                'id': 'claude-code',
                'flow': 'external',
                'status': {
                  'logged_in': true,
                  'source': 'claude_code_cli',
                  'has_refresh_token': true,
                  'expires_at': '2020-01-01T00:00:00Z',
                },
              },
            ]
          : [],
    };
    await show(tester, destination: AppDestination.administration);
    adminPushProfile(
      tester.element(find.byType(ServerConnectionLabel)),
      administration.server.profile('personal'),
      (context, profile) =>
          providerRecoveryPage(profile: profile, providerId: 'claude-code'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Renew access'), findsOneWidget);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(find.text('Claw / work'), findsOneWidget);
    expect(find.text('Renew access'), findsNothing);
    expect(find.text('Delete saved credentials'), findsNothing);
    expect(administration.requests.last.$3['profile'], 'work');
    expect(
      administration.requests.every((request) => request.$1 == 'GET'),
      isTrue,
    );
    expect(administration.consoleRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested profile routes keep their stack and reload both owners', (
    tester,
  ) async {
    final administration = AdministrationFixture('Claw');
    addTearDown(administration.server.close);
    await show(tester, destination: AppDestination.administration);
    adminPushProfile(
      tester.element(find.byType(ServerConnectionLabel)),
      administration.server.profile('personal'),
      (context, profile) => AdminPage(
        title: 'Parent',
        scope: profile.label,
        child: TextButton(
          onPressed: () => adminPushProfile(
            context,
            profile,
            (context, profile) => profileConnectorsPage(profile),
          ),
          child: const Text('Open connectors'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open connectors'));
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(find.text('MCP connectors'), findsOneWidget);
    expect(find.text('Claw / work'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Parent'), findsOneWidget);
    expect(find.text('Claw / work'), findsOneWidget);
    await tester.tap(find.text('Open connectors'));
    await tester.pumpAndSettle();
    expect(find.text('MCP connectors'), findsOneWidget);
    expect(find.text('Claw / work'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'nested selection keeps its page while loading (failure: $fails)',
      (tester) async {
        final administration = AdministrationFixture('Claw');
        addTearDown(administration.server.close);
        await show(tester, destination: AppDestination.health);
        adminPushProfile(
          tester.element(find.byType(ServerConnectionLabel)),
          administration.server.profile('personal'),
          (context, profile) => profileConnectorsPage(profile),
        );
        await tester.pumpAndSettle();
        final gate = Completer<void>();
        fixture.delays['work'] = gate;
        fixture.failWork = fails;
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(work);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('MCP connectors'), findsOneWidget);
        expect(find.text('Claw / personal'), findsOneWidget);
        expect(controller.switching, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text('MCP connectors'), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('MCP connectors'), findsOneWidget);
        expect(
          find.text(fails ? 'Claw / personal' : 'Claw / work'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'connector details resolve identity within the selected profile',
    (tester) async {
      final administration = AdministrationFixture('Claw');
      addTearDown(administration.server.close);
      administration.override = (method, path, query, body) async => {
        'servers': query['profile'] == 'personal'
            ? [
                {
                  'name': 'example',
                  'auth': 'oauth',
                  'transport': 'http',
                  'enabled': true,
                  'source': 'config',
                  'plugin': null,
                },
              ]
            : [],
      };
      await show(tester, destination: AppDestination.health);
      adminPushProfile(
        tester.element(find.byType(ServerConnectionLabel)),
        administration.server.profile('personal'),
        (context, profile) => AdminConnectorDetail(
          createRoute: () {
            final parent = ProfileConnectorsSession(profile);
            addTearDown(parent.dispose);
            return parent.openDetail('example', signInOnOpen: false);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test connection'), findsOneWidget);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(find.text('example'), findsOneWidget);
      expect(find.text('Claw / work'), findsOneWidget);
      expect(
        find.text('This connector is not available in this profile.'),
        findsOneWidget,
      );
      expect(find.text('Test connection'), findsNothing);
      expect(find.text('Sign in'), findsNothing);
      expect(
        administration.requests.every((request) => request.$1 == 'GET'),
        isTrue,
      );
    },
  );

  testWidgets(
    'editor reloads and saves only the selected profile, preserving dirty drafts',
    (tester) async {
      final administration = AdministrationFixture('Claw');
      addTearDown(administration.server.close);
      await show(tester, destination: AppDestination.administration);
      adminPushProfile(
        tester.element(find.byType(ServerConnectionLabel)),
        administration.server.profile('personal'),
        (context, profile) => AdminSettingsPage(
          profile: profile,
          title: 'Memory settings',
          fields: [memoryFields[2]],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2000'), findsOneWidget);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(find.text('Memory settings'), findsOneWidget);
      expect(find.text('3000'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '3500');
      await tester.pump();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('workspace-profile-personal')),
      );
      await tester.pumpAndSettle();
      expect(find.text('3500'), findsOneWidget);
      expect(controller.current!.scope.profileName, 'work');
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(
        (administration.configs['work']!['memory'] as Map)['memory_char_limit'],
        3500,
      );
      expect(
        (administration.configs['personal']!['memory']
            as Map)['memory_char_limit'],
        2000,
      );
      expect(
        administration.requests
            .where((request) => request.$1 == 'PUT')
            .every((request) => request.$3['profile'] == 'work'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested editor guard blocks workspace change', (tester) async {
    await show(tester, destination: AppDestination.administration);
    final context = tester.element(find.byType(ServerConnectionLabel));
    var guarded = false;
    final administration = AdministrationFixture('Claw');
    addTearDown(administration.server.close);
    adminPushProfile(
      context,
      administration.server.profile('personal'),
      (context, profile) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          guarded = !didPop;
        },
        child: const AdminPage(
          title: 'Edit',
          scope: 'Claw / personal',
          child: Text('Unsaved draft'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(work);
    await tester.pumpAndSettle();
    expect(guarded, isFalse);
    expect(
      find.text('Finish or discard your edits before switching profiles.'),
      findsOneWidget,
    );
    expect(find.text('Unsaved draft'), findsOneWidget);
    expect(controller.current!.scope.profileName, 'personal');
  });

  testWidgets(
    'Home replaces connection, preserves section and retained owner',
    (tester) async {
      final homeFixture = await createHomeFixture();
      final manager = homeFixture.manager;
      final appPreferences = homeFixture.appPreferences;
      final a = await manager.saveConnection('Claw', 'localhost', 1, '');
      final b = await manager.saveConnection('Travel', 'localhost', 2, '');
      final owners = <String, ProfileWorkspaceController>{};
      ProfileWorkspaceController owner(SavedConnection connection) =>
          owners.putIfAbsent(connection.id, () {
            final value = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: connection,
                dashboardOAuth: null,
              ),
              connectionIdentity: connection.id,
              preferences: manager.prefs,
              appPreferences: appPreferences,
              gatewayFactory: ProfileBrowserFixture().gateway,
            );
            return value;
          });
      await manager.prefs.setString('last_connection_id', a.id);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            createSharedDraftSession: (entry) => SharedDraftSession(
              connectionManager: manager,
              entrySession: entry,
              shareIntents: null,
            ),
            connManager: manager,
            appPreferences: appPreferences,
            createEntrySession: homeEntryFactory(
              tester,
              manager,
              appPreferences,
              create: owner,
              launchIntents: null,
            ),
            createBackupSession: () => BackupSession(
              configuration: ConfigBackupService(
                connectionManager: manager,
                appPreferences: appPreferences,
              ),
              io: ConfigBackupIo(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-activity')));
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('workspace-connection-${b.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProfileWorkspaceScreen>(find.byType(ProfileWorkspaceScreen))
            .controller
            .connection
            .id,
        b.id,
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppDrawer>(find.byType(AppDrawer)).selected,
        AppDestination.activity,
      );
      expect(manager.prefs.getString('last_connection_id'), b.id);
      expect(owners[a.id]!.initialized, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
