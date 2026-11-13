import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/profile_selection.dart';
import 'package:wing/core/screens/profile_workspace_browser.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_profile_bar.dart';
import 'package:wing/core/widgets/profile_selector.dart';

import 'support/browser_mutations_fixture.dart';

const _identity = 'profile-selection-repair-view';
const _capture = bool.fromEnvironment('CAPTURE_PROFILE_SELECTION_REPAIR');
const _captureKey = ValueKey('profile-selection-repair-capture');

class _RepairPlatform extends InMemorySharedPreferencesStore {
  _RepairPlatform(this.selectionKey) : super.empty();
  final String selectionKey;
  final writes = <Object>[];
  bool failNextWork = false;
  Completer<void>? entered;
  Completer<void>? _held;

  void holdWork() {
    entered = Completer<void>();
    _held = Completer<void>();
  }

  void release() {
    final held = _held;
    _held = null;
    if (held != null && !held.isCompleted) held.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == selectionKey) {
      writes.add(value);
      if (value == 'work') {
        final held = _held;
        if (held != null) {
          if (!entered!.isCompleted) entered!.complete();
          await held.future;
        }
        if (failNextWork) {
          failNextWork = false;
          return false;
        }
      }
    }
    return super.setValue(valueType, key, value);
  }
}

Finder _choice(String name) => find.byKey(ValueKey('profile-$name'));

Future<void> _captureView(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/profile-selection-repair-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previousPlatform;
  late _RepairPlatform platform;
  late AppPreferences owner;
  late ProfileWorkspaceController controller;
  late BrowserMutationsFixture host;
  var controllerClosed = false;

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

  Future<void> showRepair(
    WidgetTester tester, {
    Object saved = 'removed-profile',
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    platform = _RepairPlatform(
      'flutter.${ProfileSelectionCodec.storageKey(_identity)}',
    );
    SharedPreferencesStorePlatform.instance = platform;
    await platform.setValue(
      saved is int ? 'Int' : 'String',
      platform.selectionKey,
      saved,
    );
    platform.writes.clear();
    final preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
    host = BrowserMutationsFixture();
    controllerClosed = false;
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'repair-view',
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
      platform.release();
      await tester.pumpWidget(const SizedBox.shrink());
      if (!controllerClosed) controller.dispose();
      owner.dispose();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousPlatform;
    });
    await controller.initialize();
    // Establish genuine repair prerequisites before inspecting any widget.
    expect(controller.initialized, isFalse);
    expect(controller.current, isNull);
    expect(controller.discovery!.named('work'), isNotNull);
    expect(controller.error, contains('Choose'));
    expect((await platform.getAll())[platform.selectionKey], saved);
    expect(platform.writes, isEmpty);
    expect(host.calls, isEmpty);

    tester.view.physicalSize = scale == 1
        ? const Size(390, 844)
        : const Size(320, 640);
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

  Future<void> chooseWork(WidgetTester tester, {String? captureName}) async {
    expect(find.byType(ProfileSelector), findsOneWidget);
    await tester.ensureVisible(_choice('work'));
    await tester.pumpAndSettle();
    expect(_choice('work').hitTestable(), findsOneWidget);
    if (captureName != null) await _captureView(tester, captureName);
    final target = tester.getRect(_choice('work'));
    expect(target.width, greaterThanOrEqualTo(48));
    expect(target.height, greaterThanOrEqualTo(48));
    await tester.tap(_choice('work'));
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Chats repairs missing saved profile through direct choices ${brightness.name} ${scale}x',
        (tester) async {
          await showRepair(tester, brightness: brightness, scale: scale);
          expect(find.byType(ChatProfileBar), findsOneWidget);
          expect(
            find.textContaining('Choose an available profile'),
            findsOneWidget,
          );
          await _captureView(tester, 'missing-${brightness.name}-${scale}x');
          await chooseWork(
            tester,
            captureName: 'choices-${brightness.name}-${scale}x',
          );
          await tester.pumpAndSettle();
          // Observe actual acknowledged platform storage before navigation/UI.
          expect((await platform.getAll())[platform.selectionKey], 'work');
          expect(platform.writes, ['work']);
          expect(controller.current!.scope.profileName, 'work');
          expect(controller.initialized, isTrue);
          expect(controller.error, isNull);
          expect(find.byType(ProfileSelector), findsNothing);
          expect(find.byType(ChatProfileBar), findsOneWidget);
          expect(host.updates, isEmpty);
          expect(
            host.calls.where((call) => call.$2 == 'prompt.submit'),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final saved in <Object>['../invalid-profile', 7]) {
    testWidgets(
      'Chats repairs invalid saved choice $saved without raw writes',
      (tester) async {
        await showRepair(tester, saved: saved);
        await chooseWork(tester);
        await tester.pumpAndSettle();
        expect((await platform.getAll())[platform.selectionKey], 'work');
        expect(platform.writes, ['work']);
        expect(controller.current!.scope.profileName, 'work');
        expect(find.byType(ProfileSelector), findsNothing);
        expect(host.updates, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'held repair disables choices and failed ACK retains direct retry',
    (tester) async {
      await showRepair(tester);
      platform
        ..holdWork()
        ..failNextWork = true;
      await chooseWork(tester);
      for (
        var frame = 0;
        frame < 20 && !platform.entered!.isCompleted;
        frame++
      ) {
        await tester.pump();
      }
      expect(platform.entered!.isCompleted, isTrue);
      expect(
        (await platform.getAll())[platform.selectionKey],
        'removed-profile',
      );
      expect(platform.writes, ['work']);
      expect(find.byType(ProfileSelector), findsOneWidget);
      expect(tester.widget<TextButton>(_choice('work')).onPressed, isNull);
      expect(tester.widget<TextButton>(_choice('personal')).onPressed, isNull);
      await _captureView(tester, 'repair-held');
      platform.release();
      await tester.pumpAndSettle();
      expect(
        (await platform.getAll())[platform.selectionKey],
        'removed-profile',
      );
      expect(controller.current!.scope.profileName, 'work');
      expect(controller.error, isNotNull);
      expect(find.byType(ProfileSelector), findsOneWidget);
      expect(tester.widget<TextButton>(_choice('work')).onPressed, isNotNull);
      await chooseWork(tester);
      await tester.pumpAndSettle();
      expect((await platform.getAll())[platform.selectionKey], 'work');
      expect(platform.writes, ['work', 'removed-profile', 'work']);
      expect(find.byType(ProfileSelector), findsNothing);
      expect(host.updates, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing repair view borrows the admitted storage owner', (
    tester,
  ) async {
    await showRepair(tester);
    platform.holdWork();
    await chooseWork(tester);
    for (var frame = 0; frame < 20 && !platform.entered!.isCompleted; frame++) {
      await tester.pump();
    }
    expect(platform.entered!.isCompleted, isTrue);
    expect((await platform.getAll())[platform.selectionKey], 'removed-profile');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    controllerClosed = true;
    platform.release();
    await owner.settleProfileSelection(_identity);
    expect((await platform.getAll())[platform.selectionKey], 'work');
    await owner.setNotificationPreviews(false);
    expect(owner.current.notificationPreviewsAllowed, isFalse);
    expect(host.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
