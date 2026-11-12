import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/administration/admin_mcp_setup_page.dart';
import 'package:wing/core/screens/administration/admin_navigation.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/mcp_setup.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/workspace_picker.dart';
import 'package:wing/core/widgets/workspace_profile_navigation.dart';

import 'support/administration_fixture.dart';

void main() {
  late AdministrationFixture fixture;
  late WorkspaceProfileNavigation navigation;
  late ServerConnectionStatus status;
  late List<String> selected;
  setUp(() {
    fixture = AdministrationFixture();
    navigation = WorkspaceProfileNavigation();
    status = ServerConnectionStatus('Fixture server');
    selected = [];
  });
  tearDown(() {
    navigation.dispose();
    status.dispose();
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServerConnectionScope(
          status: status,
          profileNavigation: navigation,
          onPickWorkspace: (anchor, {required mode}) async {
            final choice = await showWorkspacePicker(
              anchor,
              connections: [],
              connectionId: 'fixture',
              profiles: const [
                HermesProfile(name: 'personal'),
                HermesProfile(name: 'work'),
              ],
              profileName: navigation.profileName ?? 'personal',
              busy: false,
              mode: mode,
            );
            final profile = choice?.id;
            if (choice?.kind == WorkspaceChoiceKind.profile &&
                profile != null &&
                profile != (navigation.profileName ?? 'personal')) {
              await navigation.switchTo(profile, () async {
                selected.add(profile);
                return true;
              });
            }
          },
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => adminPushProfile(
                  context,
                  fixture.server.profile('personal'),
                  (_, profile) => AdminMcpSetupPage(
                    createSession: () => McpSetupSession(profile),
                  ),
                ),
                child: const Text('Open setup'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open setup'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseWork(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('workspace-picker-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-profile-work')));
    await tester.pumpAndSettle();
  }

  testWidgets('pristine setup leaves without a discard prompt', (tester) async {
    await show(tester);
    expect(navigation.canRequestSwitch, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard edits?'), findsNothing);
    expect(find.text('Open setup'), findsOneWidget);
  });

  testWidgets('Back keeps credentials until explicit discard', (tester) async {
    await show(tester);
    final name = find.byKey(const ValueKey('mcp-field-Connector name'));
    await tester.enterText(name, 'Unfinished connector');
    await tester.pump();
    expect(
      ModalRoute.of(
        tester.element(find.byType(AdminMcpSetupPage)),
      )!.popDisposition,
      RoutePopDisposition.doNotPop,
    );
    expect(navigation.canRequestSwitch, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(name).controller!.text,
      'Unfinished connector',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Open setup'), findsOneWidget);
    expect(fixture.requests, isEmpty);
  });

  testWidgets(
    'cancelled picker and Keep preserve draft; Discard changes captured profile',
    (tester) async {
      await show(tester);
      final name = find.byKey(const ValueKey('mcp-field-Connector name'));
      await tester.enterText(name, 'Transient draft');
      await tester.tap(find.byKey(const ValueKey('workspace-picker-target')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(find.text('Discard edits?'), findsNothing);
      await chooseWork(tester);
      expect(find.text('Discard edits?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(
        tester.widget<TextField>(name).controller!.text,
        'Transient draft',
      );
      await chooseWork(tester);
      await tester.tap(find.byTooltip('Discard'));
      await tester.pumpAndSettle();
      expect(selected, ['work']);
      expect(find.text('Server A / work'), findsOneWidget);
      expect(tester.widget<TextField>(name).controller!.text, isEmpty);
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets('an unrelated guarded route still blocks profile switching', (
    tester,
  ) async {
    await show(tester);
    final editorContext = tester.element(find.byType(AdminMcpSetupPage));
    final navigator = Navigator.of(editorContext);
    final route = MaterialPageRoute<void>(
      builder: (_) => const PopScope(
        canPop: false,
        child: Scaffold(body: Text('Other guarded operation')),
      ),
    );
    navigator.push(route);
    await tester.pumpAndSettle();
    navigation.register(route);
    expect(
      await navigation.switchTo('work', () async {
        selected.add('work');
        return true;
      }),
      isFalse,
    );
    expect(selected, isEmpty);
    expect(find.text('Other guarded operation'), findsOneWidget);
    navigation.unregister(route);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AdminMcpSetupPage), findsOneWidget);
  });

  testWidgets(
    'busy setup blocks Back and profile replacement until save settles',
    (tester) async {
      final pending = Completer<void>();
      fixture.rpcOverride = (method, params) async {
        if (method == 'mcp.servers.list') return {'servers': []};
        await pending.future;
        return {
          'ok': true,
          'name': params['name'],
          'server': {
            'name': params['name'],
            'transport': 'http',
            'auth': 'oauth',
            'enabled': true,
            'source': 'config',
            'plugin': null,
          },
        };
      };
      await show(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-field-Connector name')),
        'work-docs',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-field-MCP address')),
        'https://example.test/mcp',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.scrollUntilVisible(
        find.byTooltip('Add connector and sign in'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Add connector and sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add connector and sign in'));
      await tester.pump();
      expect(fixture.rpcRequests, [
        ('personal', 'mcp.servers.list'),
        ('personal', 'mcp.servers.add'),
      ]);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Discard edits?'), findsNothing);
      expect(
        await navigation.switchTo('work', () async {
          selected.add('work');
          return true;
        }),
        isFalse,
      );
      expect(selected, isEmpty);
      expect(find.byType(AdminMcpSetupPage), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open setup'), findsOneWidget);
    },
  );
}
