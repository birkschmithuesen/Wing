import 'package:wing/core/services/bots_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/server_connection_label.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

class _ProjectDesignHost extends ProfileActionsFixture {
  final projectChanges = <String, Map<String, dynamic>>{};
  bool projectsVisible = true;
  @override
  List<Map<String, dynamic>> projects(String profile) => projectsVisible
      ? [
          for (final row in super.projects(profile))
            {...row, ...?projectChanges[row['id']]},
        ]
      : [];
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PROJECT_PICKER');
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
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });

  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late _ProjectDesignHost host;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ProjectDesignHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'project-design',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    await controller.createChat(canDispatch: () => true);
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/project-picker-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double width = 390,
    double scale = 1,
    double keyboard = 0,
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
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'separate header actions and Studio sheets ${brightness.name} $scale',
        (tester) async {
          final project = controller.current!.projects.first;
          host.projectChanges[project['id'] as String] = {
            'label': 'Wing Android workspace and release planning',
            'color': '#126D70',
            'icon': 'repo',
          };
          await controller.switchProfile('personal');
          await show(
            tester,
            brightness: brightness,
            width: scale == 2 ? 320 : 390,
            scale: scale,
          );
          final selector = find.byKey(const ValueKey('chat-project-picker'));
          expect(tester.getSize(selector).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .renderObject<RenderParagraph>(find.text('Host'))
                .didExceedMaxLines,
            isFalse,
          );
          expect(
            tester
                .getRect(selector)
                .overlaps(tester.getRect(find.byType(ServerConnectionLabel))),
            isFalse,
          );
          final semantics = tester.ensureSemantics();
          try {
            expect(
              tester.getSemantics(selector),
              matchesSemantics(
                label: 'Unassigned. Move to project',
                isButton: true,
                hasEnabledState: true,
                isEnabled: true,
                hasTapAction: true,
                isFocusable: true,
              ),
            );
            await tester.tap(find.text(controller.current!.chat!.title));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsNothing,
            );
            expect(find.byTooltip('Move to project'), findsNothing);
            expect(
              find.byKey(const ValueKey('chat-rename-title')),
              findsOneWidget,
            );
            await tester.tap(find.byTooltip('Cancel'));
            await tester.pumpAndSettle();
            await screenshot(tester, 'header-${brightness.name}-$scale');
            // Even the edge of the project's 48 dp target opens the selector.
            await tester.tapAt(
              tester.getBottomRight(selector) - const Offset(2, 2),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsOneWidget,
            );
            expect(find.byTooltip('Remove from project'), findsNothing);
            expect(tester.takeException(), isNull);
            await screenshot(tester, 'projects-${brightness.name}-$scale');
            await tester.tap(find.byTooltip('Cancel project selection'));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('connection-status-target')),
            );
            await tester.pumpAndSettle();
            expect(find.text('Connection details'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await screenshot(tester, 'connection-${brightness.name}-$scale');
            await tester.tap(find.byTooltip('Close connection details'));
            await tester.pumpAndSettle();
            expect(host.moves, isEmpty);
            host.projectChanges[project['id'] as String]!['label'] =
                'australia-rwc-2027';
            await controller.switchProfile('personal');
            final assignedResource = controller.current!;
            final assignedProject = assignedResource.projects.first;
            await controller.createChat(
              inProject: assignedProject,
              canDispatch: () =>
                  identical(controller.current, assignedResource) &&
                  assignedResource.projects.contains(assignedProject),
            );
            emitChatEvent(
              controller,
              controller.current!.chat!,
              'session.title',
              {
                'session_id': controller.current!.chat!.key.sessionId,
                'title': 'Find budget car rental in Perth',
              },
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final projectText = find.text('australia-rwc-2027');
            expect(projectText, findsOneWidget);
            await tester.tap(find.text('Find budget car rental in Perth'));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-rename-title')),
              findsOneWidget,
            );
            await tester.tap(find.byTooltip('Cancel'));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsNothing,
            );
            await tester.tap(projectText);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsOneWidget,
            );
            final remove = find.byTooltip('Remove from project');
            final destination = find.byKey(const ValueKey('move-project-p1'));
            await tester.ensureVisible(destination);
            await tester.tap(destination);
            await tester.pumpAndSettle();
            expect(find.text('Move chat?'), findsOneWidget);
            expect(
              find.textContaining('"Archive" in personal'),
              findsOneWidget,
            );
            expect(find.byTooltip('Move chat').hitTestable(), findsOneWidget);
            expect(host.moves, isEmpty);
            expect(tester.takeException(), isNull);
            await screenshot(tester, 'move-confirm-${brightness.name}-$scale');
            await tester.tap(find.byTooltip('Cancel'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(remove);
            expect(
              tester.getSize(remove).shortestSide,
              greaterThanOrEqualTo(48),
            );
            await screenshot(
              tester,
              'remove-project-${brightness.name}-$scale',
            );
            await tester.tap(remove);
            await tester.pumpAndSettle();
            expect(find.text('Move chat?'), findsOneWidget);
            expect(
              find.textContaining('default project of personal'),
              findsOneWidget,
            );
            expect(find.byTooltip('Move chat').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'remove-confirm-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Cancel'));
            await tester.pumpAndSettle();
            expect(host.moves, isEmpty);
            await tester.tap(find.byTooltip('Cancel project selection'));
            await tester.pumpAndSettle();
            if (scale == 1) {
              final title = find.text('Find budget car rental in Perth');
              final scope = tester.getRect(
                find.byKey(const ValueKey('chat-scope-inline')),
              );
              final target = tester.getRect(selector);
              expect(target.right, scope.right);
              expect(target.left, greaterThanOrEqualTo(scope.left));
              expect(target.top, greaterThanOrEqualTo(scope.top));
              expect(target.bottom, lessThanOrEqualTo(scope.bottom));
              expect(
                target.top,
                greaterThanOrEqualTo(tester.getRect(title).bottom),
              );
              expect(selector.hitTestable(), findsOneWidget);
            }
            await screenshot(
              tester,
              'header-assigned-${brightness.name}-$scale',
            );
            await tester.tap(selector);
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Remove from project'));
            await tester.pumpAndSettle();
            host.defaultFolderDelay = Completer<void>();
            host.failMutation = true;
            await tester.tap(find.byTooltip('Move chat').hitTestable());
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.text('Move chat?'), findsNothing);
            expect(
              find.byType(CircularProgressIndicator).hitTestable(),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'remove-pending-${brightness.name}-$scale',
            );
            host.defaultFolderDelay!.complete();
            await tester.pumpAndSettle();
            expect(find.text('Move rejected'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'remove-failure-${brightness.name}-$scale',
            );
            host.failMutation = false;
            await tester.tap(find.byTooltip('Remove from project'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Move chat').hitTestable());
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('chat-project-sheet')),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'remove-success-${brightness.name}-$scale',
            );
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'project search matches folders, clears and explains no results with keyboard',
    (tester) async {
      await show(tester, width: 320, scale: 2, keyboard: 280);
      await tester.tap(find.text('Unassigned'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('project-picker-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, '/Mobile');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('move-project-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('move-project-p1')), findsNothing);
      await tester.enterText(search, 'no matching folder');
      await tester.pumpAndSettle();
      expect(
        find.text('No matching projects. Try another name or folder.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byTooltip('Clear search'));
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.byKey(const ValueKey('move-project-p1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Cancel project selection'));
      await tester.pumpAndSettle();
      expect(host.moves, isEmpty);
    },
  );

  testWidgets(
    'project selector supports keyboard activation and disables during a chat mutation',
    (tester) async {
      await show(tester);
      final selector = find.byKey(const ValueKey('chat-project-picker'));
      Focus.of(tester.element(find.text('Unassigned'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel project selection'));
      await tester.pumpAndSettle();
      host.mutationDelay = Completer<void>();
      addTearDown(() {
        if (!host.mutationDelay!.isCompleted) host.mutationDelay!.complete();
      });
      final mutationOwner = controller.current!;
      final mutationKey = mutationOwner.chat!.key;
      final mutation = controller.mutateSession(
        mutationKey,
        changes: {'pinned': true},
        canDispatch: () =>
            identical(controller.current, mutationOwner) &&
            mutationOwner.chat?.key == mutationKey,
      );
      await tester.pump();
      expect(tester.widget<InkWell>(selector).onTap, isNull);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-project-sheet')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('connection-status-target')));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsOneWidget);
      expect(host.moves, isEmpty);
      host.mutationDelay!.complete();
      await mutation;
    },
  );

  testWidgets('empty project list explains availability and can be dismissed', (
    tester,
  ) async {
    host.projectsVisible = false;
    await controller.switchProfile('personal');
    await show(tester);
    await tester.tap(find.text('Unassigned'));
    await tester.pumpAndSettle();
    expect(
      find.text('No other projects with a working folder are available.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('project-picker-search')), findsNothing);
    await tester.tap(find.byTooltip('Cancel project selection'));
    await tester.pumpAndSettle();
    expect(host.moves, isEmpty);
  });
}
