import 'package:wing/core/services/bots_session.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/services/server_files_browser.dart';
import 'package:wing/core/services/server_files_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/widgets/project_folder_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProjectScreenHost {
  final calls = <(String, Map<String, dynamic>)>[];
  final projects = <Map<String, dynamic>>[];

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: () async => const ProfileDiscovery(
      profiles: [HermesProfile(name: 'work')],
      currentName: 'work',
      activeName: 'work',
    ),
    ownedPost: (endpoint, body, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Creation retired');
      onDispatched();
      calls.add((endpoint, body));
      return {
        'ok': true,
        'path': body['path'],
        'entry': {'path': body['path'], 'is_directory': true},
      };
    },
    get: (path, query) async {
      if (path == 'fs/default-cwd') return {'cwd': '/srv', 'branch': null};
      if (path == 'files') return directory(query['path'] ?? '/srv');
      if (path != 'sessions') throw StateError('Unexpected read $path');
      return {
        'sessions': const [],
        'offset': int.parse(query['offset']!),
        'limit': int.parse(query['limit']!),
        'total': 0,
      };
    },
    rpc: (method, params) async {
      calls.add((method, params));
      switch (method) {
        case 'session.active_list':
          return {'sessions': const []};
        case 'projects.tree':
          return {'projects': projects};
        case 'projects.discover_repos':
          return {
            'repos': const [
              {
                'root': '/srv/Client Work',
                'label': 'Client Work',
                'sessions': 2,
                'last_active': 10,
              },
            ],
            'discovery_policy': const {'enabled': true},
          };
        case 'projects.create':
          projects.add({
            'id': 'created',
            'label': params['name'],
            'path': params['primary_path'],
            'lastActive': 11,
          });
          return {
            'project': {
              'id': 'created',
              'name': params['name'],
              'primary_path': params['primary_path'],
            },
          };
        default:
          throw StateError('Unexpected RPC $method');
      }
    },
  );
}

Map<String, dynamic> directory(String path) => {
  'path': path,
  'parent': path == '/srv' ? null : '/srv',
  'entries': path == '/srv'
      ? [
          for (final name in ['Client Work', 'Docs'])
            {'name': name, 'path': '/srv/$name', 'is_directory': true},
          {
            'name': 'notes.txt',
            'path': '/srv/notes.txt',
            'is_directory': false,
            'size': 3,
            'mime_type': 'text/plain',
          },
        ]
      : [],
};

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PROJECT_FOLDER');
  const captureKey = ValueKey('project-folder-capture');
  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': '$fonts/Roboto-Regular.ttf',
      'MaterialIcons': '$fonts/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(font.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });
  Future<void> capturePicker(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/design-previews/folder-recovery/$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> showPicker(
    WidgetTester tester, {
    required ServerFilesRepository files,
    ValueChanged<String?>? onResult,
    String? initialPath,
    Brightness brightness = Brightness.dark,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(scale == 1 ? 390 : 320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: captureKey, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                final result = await showDialog<String>(
                  context: context,
                  builder: (_) => ProjectFolderPickerDialog(
                    initialPath: initialPath,
                    createBrowser: () =>
                        ServerFilesBrowser(files: files, isCurrent: () => true),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'missing saved folder can browse Hermes folders ${brightness.name} $scale',
        (tester) async {
          final reads = <String?>[];
          final firstRoot = Completer<Map<String, dynamic>>();
          final retryRoot = Completer<Map<String, dynamic>>();
          String? selected;
          await showPicker(
            tester,
            brightness: brightness,
            scale: scale,
            initialPath: '/srv/Missing project',
            onResult: (value) => selected = value,
            files: ServerFilesRepository(
              read: (_, query) {
                final path = query['path'];
                reads.add(path);
                if (path == '/srv/Missing project') {
                  return Future.error(StateError('ENOENT'));
                }
                if (reads.length == 2) return firstRoot.future;
                if (reads.length == 3) return retryRoot.future;
                return Future.value(directory(path ?? '/srv'));
              },
              write: null,
            ),
          );
          IconButton action(String key) =>
              tester.widget<IconButton>(find.byKey(ValueKey(key)));
          expect(reads, ['/srv/Missing project']);
          expect(action('project-folder-up').onPressed, isNull);
          expect(action('project-folder-continue').onPressed, isNull);
          expect(action('project-folder-home').onPressed, isNotNull);
          expect(
            find.textContaining('Could not open this folder'),
            findsOneWidget,
          );
          await capturePicker(
            tester,
            'folder-recovery-${brightness.name}-$scale-error',
          );
          await tester.tap(find.byKey(const ValueKey('project-folder-home')));
          await tester.pump();
          await tester.pump();
          expect(reads, ['/srv/Missing project', null]);
          expect(find.bySemanticsLabel('Loading folders'), findsOneWidget);
          expect(action('project-folder-home').onPressed, isNull);
          expect(action('project-folder-continue').onPressed, isNull);
          await capturePicker(
            tester,
            'folder-recovery-${brightness.name}-$scale-loading',
          );
          firstRoot.completeError(StateError('root read failed'));
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel('Loading folders'), findsNothing);
          expect(
            find.textContaining('Could not open this folder'),
            findsOneWidget,
          );
          expect(action('project-folder-home').onPressed, isNotNull);
          await tester.tap(find.byTooltip('Retry folder loading'));
          await tester.pump();
          await tester.pump();
          expect(reads, ['/srv/Missing project', null, null]);
          expect(find.bySemanticsLabel('Loading folders'), findsOneWidget);
          retryRoot.complete(directory('/srv'));
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel('Loading folders'), findsNothing);
          expect(
            find.textContaining('Could not open this folder'),
            findsNothing,
          );
          expect(find.text('Client Work'), findsOneWidget);
          await capturePicker(
            tester,
            'folder-recovery-${brightness.name}-$scale-root',
          );
          await tester.tap(
            find.byKey(const ValueKey('project-folder-/srv/Docs')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('project-folder-continue')),
          );
          await tester.pumpAndSettle();
          expect(selected, '/srv/Docs');
          expect(reads, ['/srv/Missing project', null, null, '/srv/Docs']);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('folder navigation and selection ${brightness.name} $scale', (
        tester,
      ) async {
        String? result;
        final reads = <String?>[];
        await showPicker(
          tester,
          brightness: brightness,
          scale: scale,
          files: ServerFilesRepository(
            read: (_, query) async {
              reads.add(query['path']);
              return directory(query['path'] ?? '/srv');
            },
            write: null,
          ),
          onResult: (value) => result = value,
        );
        expect(reads, [null]);
        expect(find.text('notes.txt'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('project-folder-up')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('project-folder-/srv/Client Work')),
        );
        await tester.pumpAndSettle();
        expect(find.text('/srv/Client Work'), findsOneWidget);
        expect(find.text('No folders here'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('project-folder-up')));
        await tester.pumpAndSettle();
        expect(find.text('/srv'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('project-folder-/srv/Docs')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-folder-continue')));
        await tester.pumpAndSettle();
        expect(result, '/srv/Docs');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final fail in [false, true]) {
    testWidgets('held folder refresh ${fail ? 'failure' : 'success'}', (
      tester,
    ) async {
      final gate = Completer<Map<String, dynamic>>();
      var calls = 0;
      await showPicker(
        tester,
        files: ServerFilesRepository(
          read: (_, query) {
            calls++;
            return calls == 1 ? Future.value(directory('/srv')) : gate.future;
          },
          write: null,
        ),
      );
      await tester.tap(find.byTooltip('Refresh folders'));
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Loading folders'), findsOneWidget);
      expect(find.text('Client Work'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('project-folder-continue')),
            )
            .onPressed,
        isNull,
      );
      if (fail) {
        gate.completeError(StateError('denied'));
      } else {
        gate.complete(directory('/srv/Docs'));
      }
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Loading folders'), findsNothing);
      if (fail) {
        expect(
          find.textContaining('Could not open this folder'),
          findsOneWidget,
        );
      } else {
        expect(find.text('/srv/Docs'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('new folder holds progress and opens the confirmed directory', (
    tester,
  ) async {
    final gate = Completer<void>();
    final writes = <String>[];
    await showPicker(
      tester,
      files: ServerFilesRepository(
        read: (_, query) async => directory(query['path'] ?? '/srv'),
        write: (_, body, active) async {
          await gate.future;
          if (!active()) throw StateError('retired');
          writes.add(body['path'] as String);
          return {
            'ok': true,
            'path': '/srv/Created',
            'entry': {'path': '/srv/Created', 'is_directory': true},
          };
        },
      ),
    );
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('project-new-folder-name')),
      'Created',
    );
    await tester.pump();
    final close = find.byTooltip('Close new folder');
    expect(
      find.descendant(of: close, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-new-folder-name')), findsNothing);
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('project-new-folder-name')),
          )
          .controller!
          .text,
      'Created',
    );
    await tester.tap(find.byKey(const ValueKey('project-new-folder-create')));
    await tester.pump();
    await tester.pump();
    expect(find.bySemanticsLabel('Creating folder'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('project-folder-continue')),
          )
          .onPressed,
      isNull,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(writes, ['/srv/Created']);
    expect(find.text('/srv/Created'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-new-folder-name')), findsNothing);
    expect(find.bySemanticsLabel('Creating folder'), findsNothing);
  });

  testWidgets('workspace create uses the shared managed folder browser', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = _ProjectScreenHost();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'project-picker',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(460, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Chat list options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New project'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('project-name-field')),
      'New workspace',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('project-choose-folder')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('project-folder-/srv/Client Work')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-folder-continue')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('project-create-confirm')));
    await tester.pumpAndSettle();

    final create = host.calls.singleWhere(
      (call) => call.$1 == 'projects.create',
    );
    final mkdir = host.calls
        .where((call) => call.$1.startsWith('files/mkdir'))
        .single;
    expect(mkdir.$1, 'files/mkdir?profile=work');
    expect(mkdir.$2, {'path': '/srv/Client Work'});
    expect(create.$2, {
      'name': 'New workspace',
      'folders': ['/srv/Client Work'],
      'primary_path': '/srv/Client Work',
      'color': '',
      'icon': 'folder-library',
      'profile': 'work',
    });
  });
}
