import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/widgets/connection_icon_picker.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/drawer_versions.dart';
import 'package:wing/core/screens/versions_updates_screen.dart';

void main() {
  SavedConnection connection(String name) => SavedConnection(
    id: name,
    label: name,
    host: 'localhost',
    port: 1,
    apiKey: '',
    icon: ConnectionIcon.home,
  );
  ProfileGateway gateway(
    SavedConnection server,
    Future<Map<String, dynamic>> Function() read,
  ) => ProfileGateway(
    scope: WorkspaceScope(connectionId: server.id, profileName: 'default'),
    get: (endpoint, _) async {
      final response = await read();
      return endpoint == 'health'
          ? {'ok': true, 'version': response['current_version']}
          : response;
    },
    rpc: (_, _) async => {},
    discover: () => throw UnimplementedError(),
  );

  for (final section in ['connection', 'server']) {
    testWidgets('$section entry preserves its intended interaction', (
      tester,
    ) async {
      final server = connection('Home server');
      final status = ServerConnectionStatus(server.label)
        ..accessAvailable()
        ..liveChanged('default', true);
      addTearDown(status.dispose);
      var reads = 0;
      VersionsController factory(ConnectionAccess? value) => VersionsController(
        gateway: gateway(value!.connection, () async {
          reads++;
          return {
            'current_version': '1.2.3',
            'update_available': true,
            'behind': 2,
          };
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(),
            drawer: AppDrawer(
              selected: AppDestination.chats,
              onSelected: (_) {},
              access: ConnectionAccess(
                connection: server,
                dashboardOAuth: null,
              ),
              connectionStatus: status,
              versionsControllerFactory: factory,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.sync), findsOneWidget);
      final connectionRect = tester.getRect(
        find.byKey(const ValueKey('menu-connection')),
      );
      final serverRect = tester.getRect(
        find.byKey(const ValueKey('menu-server-version')),
      );
      expect(connectionRect.bottom, serverRect.bottom);
      expect(connectionRect.right, lessThan(serverRect.left));
      expect(serverRect.height, greaterThanOrEqualTo(48));
      final identity = find.byKey(const ValueKey('menu-connection'));
      final icon = find.descendant(
        of: identity,
        matching: find.byIcon(ConnectionIcon.home.glyph),
      );
      final name = find.descendant(
        of: identity,
        matching: find.text('Home server'),
      );
      final led = find.descendant(
        of: identity,
        matching: find.byKey(const ValueKey('server-connection-led')),
      );
      expect(tester.getRect(icon).right, lessThan(tester.getRect(name).left));
      expect(tester.getRect(name).right, lessThan(tester.getRect(led).left));
      expect(find.byKey(const ValueKey('menu-client-version')), findsNothing);
      final target = section == 'connection'
          ? identity
          : find.byKey(const ValueKey('menu-server-version'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      if (section == 'connection') {
        expect(find.byType(VersionsUpdatesScreen), findsNothing);
        expect(find.text('Connection details'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(reads, 3);
        await tester.tap(find.byTooltip('Close connection details'));
        await tester.pumpAndSettle();
        expect(
          tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
          isTrue,
        );
        return;
      }
      expect(find.byType(VersionsUpdatesScreen), findsOneWidget);
      expect(find.text('Versions & updates'), findsOneWidget);
      expect(find.text('Version 1.0.1'), findsNothing);
      expect(find.byTooltip('Check for updates'), findsOneWidget);
      expect(find.text('View release'), findsNothing);
      expect(find.text('Releases'), findsNothing);
      expect(find.text('Home server'), findsOneWidget);
      expect(reads, 6);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no selected connection shows a quiet disabled identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DrawerVersions(controllerFactory: (_) => VersionsController()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('v1.0.1'), findsNothing);
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(find.text('No server selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-server-version')), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('menu-connection')))
          .onTap,
      isNull,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'long connection name keeps LED and version reachable at $scale text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final server = connection('My long home server connection');
        final status = ServerConnectionStatus(server.label)
          ..accessAvailable()
          ..liveChanged('default', true);
        addTearDown(status.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(),
              drawer: AppDrawer(
                selected: AppDestination.chats,
                onSelected: (_) {},
                access: ConnectionAccess(
                  connection: server,
                  dashboardOAuth: null,
                ),
                connectionStatus: status,
                versionsControllerFactory: (_) => VersionsController(
                  gateway: gateway(
                    server,
                    () async => {
                      'current_version': '1.2.3',
                      'update_available': true,
                      'behind': 2,
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        final version = find.byKey(const ValueKey('menu-server-version'));
        await tester.ensureVisible(version);
        await tester.pumpAndSettle();
        final identity = find.byKey(const ValueKey('menu-connection'));
        final led = find.descendant(
          of: identity,
          matching: find.byKey(const ValueKey('server-connection-led')),
        );
        expect(
          tester.getRect(led).right,
          lessThan(tester.getRect(version).left),
        );
        expect(find.byTooltip('${server.label}, Connected'), findsOneWidget);
        expect(tester.getRect(version).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(identity).height, greaterThanOrEqualTo(48));
        status.accessFailed(const SocketException('offline'));
        status.liveChanged('default', false);
        await tester.pumpAndSettle();
        expect(find.byTooltip('${server.label}, Disconnected'), findsOneWidget);
        expect(find.text('v1.2.3'), findsOneWidget);
        await tester.tap(identity);
        await tester.pumpAndSettle();
        expect(find.text('Connection details'), findsOneWidget);
        expect(find.text(server.label), findsWidgets);
        expect(find.text('Disconnected'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('server badge clears after current or failed upstream checks', (
    tester,
  ) async {
    var fail = false;
    var available = true;
    late VersionsController versions;
    final server = connection('Home');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DrawerVersions(
            access: ConnectionAccess(connection: server, dashboardOAuth: null),
            controllerFactory: (_) => versions = VersionsController(
              gateway: gateway(server, () async {
                if (fail) throw StateError('offline');
                return {
                  'current_version': '1.2.3',
                  'update_available': available,
                  'behind': available ? 2 : 0,
                };
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sync), findsOneWidget);
    available = false;
    await versions.refresh();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sync), findsNothing);
    fail = true;
    await versions.refresh();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(find.text('v1.2.3'), findsOneWidget);
    expect(find.text('v1.0.1'), findsNothing);
  });

  testWidgets('switching servers ignores an earlier server response', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    VersionsController factory(ConnectionAccess? value) => VersionsController(
      gateway: gateway(
        value!.connection,
        () async => value.connection.id == 'A'
            ? old.future
            : {
                'current_version': '2.0.0',
                'update_available': false,
                'behind': 0,
              },
      ),
    );
    Future<void> show(String name) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrawerVersions(
              access: ConnectionAccess(
                connection: connection(name),
                dashboardOAuth: null,
              ),
              controllerFactory: factory,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('A');
    await show('B');
    old.complete({
      'current_version': '1.0.0',
      'update_available': true,
      'behind': 3,
    });
    await tester.pumpAndSettle();
    expect(find.text('v2.0.0'), findsOneWidget);
    expect(find.text('v1.0.0'), findsNothing);
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
