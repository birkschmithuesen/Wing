import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/administration/admin_navigation.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/workspace_picker.dart';
import 'package:wing/core/widgets/workspace_profile_navigation.dart';
import 'support/administration_fixture.dart';

void main() {
  setUpAll(() async {
    if (!_captureEnabled) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(
                File('$path/${entry.value}').readAsBytesSync(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final initiallyStored in [false, true]) {
    testWidgets('picker reloads credential baseline from $initiallyStored', (
      tester,
    ) async {
      final fixture = _CredentialFixture(initiallyStored: initiallyStored);
      await _openCredential(tester, fixture);
      expect(
        find.text('Remove stored credential'),
        initiallyStored ? findsOneWidget : findsNothing,
      );
      await _chooseProfile(tester, 'work');
      expect(find.text('Server A / work'), findsOneWidget);
      expect(
        find.text('Remove stored credential'),
        initiallyStored ? findsNothing : findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'synthetic-new-key');
      await tester.pump();
      await tester.tap(find.byTooltip('Save credential'));
      await tester.pumpAndSettle();
      final writes = fixture.requests.where((r) => r.$1 == 'PUT');
      expect(writes, hasLength(1));
      expect(writes.single.$3['profile'], 'work');
      expect(find.textContaining('stored key state changed'), findsNothing);
      expect(find.text('Add service key'), findsOneWidget);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('credential preparation ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final fixture = _CredentialFixture();
        final initial = Completer<Map<String, dynamic>>();
        final retry = Completer<Map<String, dynamic>>();
        fixture.envRead = (profile, count) => count == 1
            ? Future.value(_metadata(false))
            : count == 2
            ? initial.future
            : retry.future;
        await _openCredential(
          tester,
          fixture,
          brightness: brightness,
          scale: scale,
          settle: false,
        );
        // The destination exists on its first frame, before metadata completes.
        expect(find.byType(AdminSecretPage), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AdminSecretPage),
            matching: find.byType(TextField),
          ),
          findsNothing,
        );
        await _frames(tester);
        _expectLoading();
        final prefix = '${brightness.name}-${scale.toInt()}';
        await _capture(tester, '$prefix-loading');
        initial.completeError(
          const AdministrationFailure('Cannot load credentials.'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Cannot load credentials.'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        await _capture(tester, '$prefix-error');
        await tester.tap(find.byTooltip('Retry'));
        await _frames(tester);
        _expectLoading();
        retry.complete(_metadata(true));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Remove stored credential'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Remove stored credential'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        await _capture(tester, '$prefix-ready');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.enterText(find.byType(TextField), 'synthetic-new-key');
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byTooltip('Save credential')).bottom,
          lessThanOrEqualTo(844 - 260),
        );
        expect(
          tester.getSize(find.byTooltip('Save credential')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        await _capture(tester, '$prefix-keyboard');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('late metadata cannot republish after another picker selection', (
    tester,
  ) async {
    final fixture = _CredentialFixture();
    final old = Completer<Map<String, dynamic>>();
    await _openCredential(tester, fixture);
    fixture.envRead = (profile, _) =>
        profile == 'work' ? old.future : Future.value(_metadata(false));
    await _chooseProfile(tester, 'work', settle: false);
    await _frames(tester);
    _expectLoading();
    expect(find.byType(TextField), findsNothing);
    await _chooseProfile(tester, 'personal');
    expect(find.text('Server A / personal'), findsOneWidget);
    old.complete(_metadata(true));
    await tester.pumpAndSettle();
    expect(find.text('Remove stored credential'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving held preparation retires its error and actions', (
    tester,
  ) async {
    final fixture = _CredentialFixture();
    final held = Completer<Map<String, dynamic>>();
    fixture.envRead = (_, count) =>
        count == 1 ? Future.value(_metadata(false)) : held.future;
    await _openCredential(tester, fixture, settle: false);
    await _frames(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    held.completeError(const AdministrationFailure('Retired metadata error'));
    await tester.pumpAndSettle();
    expect(find.text('Add service key'), findsOneWidget);
    expect(find.text('Retired metadata error'), findsNothing);
    expect(find.byType(AdminSecretPage), findsNothing);
    expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final unavailable in ['missing', 'managed', 'custom']) {
    testWidgets('$unavailable credential never admits an editor', (
      tester,
    ) async {
      final fixture = _CredentialFixture();
      fixture.envRead = (_, count) async => count == 1
          ? _metadata(false)
          : unavailable == 'missing'
          ? {}
          : {
              'EXAMPLE_API_KEY': {
                'is_set': true,
                'channel_managed': unavailable == 'managed',
                'category': unavailable == 'custom' ? 'custom' : 'api_keys',
                'provider_label': 'Example',
              },
            };
      await _openCredential(tester, fixture);
      expect(find.text('This credential is unavailable.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Save credential'), findsNothing);
      expect(find.text('Remove stored credential'), findsNothing);
      expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
    });
  }

  testWidgets(
    'direct owner changes retire the draft but equivalent owners do not',
    (tester) async {
      final a = _CredentialFixture();
      final b = _CredentialFixture(initiallyStored: true);
      Future<void> show(
        AdministrationFixture fixture,
        String profile, {
        String name = 'EXAMPLE_API_KEY',
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: AdminSecretPage(
              profile: fixture.server.profile(profile),
              name: name,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(a, 'personal');
      await tester.enterText(find.byType(TextField), 'synthetic-draft');
      await show(a, 'personal');
      expect(find.text('synthetic-draft'), findsOneWidget);
      await show(b, 'personal');
      expect(find.text('synthetic-draft'), findsNothing);
      expect(find.text('Remove stored credential'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'synthetic-other-draft');
      await show(b, 'work');
      expect(find.text('synthetic-other-draft'), findsNothing);
      expect(find.text('Remove stored credential'), findsNothing);
      await show(b, 'work', name: 'DIFFERENT_API_KEY');
      expect(find.byType(TextField), findsNothing);
      expect(find.text('This credential is unavailable.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retired credential editor cannot write after held membership', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    final held = Completer<Map<String, dynamic>>();
    final entered = Completer<void>();
    fixture.override = (method, path, query, body) async {
      if (path == 'env') {
        return {
          'EXAMPLE_API_KEY': {
            'is_set': false,
            'channel_managed': false,
            'category': 'api_keys',
            'provider_label': 'Example',
          },
        };
      }
      if (path == 'profiles') {
        entered.complete();
        return held.future;
      }
      if (path == 'profiles/active') {
        return {'current': 'personal', 'active': 'personal'};
      }
      return {'ok': true, 'key': 'EXAMPLE_API_KEY'};
    };
    await tester.pumpWidget(
      MaterialApp(
        home: AdminSecretPage(
          profile: fixture.server.profile('personal'),
          name: 'EXAMPLE_API_KEY',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'synthetic-new-key');
    await tester.pump();
    await tester.tap(find.byTooltip('Save credential'));
    await tester.pump();
    expect(entered.isCompleted, true);
    await tester.pumpWidget(const SizedBox.shrink());
    held.complete({
      'profiles': [
        {'name': 'personal'},
      ],
    });
    await tester.pumpAndSettle();
    expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _CredentialFixture extends AdministrationFixture {
  _CredentialFixture({bool initiallyStored = false})
    : stored = {'personal': initiallyStored, 'work': !initiallyStored};
  final Map<String, bool> stored;
  final _reads = <String, int>{};
  Future<Map<String, dynamic>> Function(String profile, int count)? envRead;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (path != 'env') return super.send(method, path, query, body);
    requests.add((method, path, {...query}, body));
    final profile = query['profile']!;
    if (method != 'GET') {
      stored[profile] = method == 'PUT';
      return {'ok': true, 'key': 'EXAMPLE_API_KEY'};
    }
    final count = _reads.update(
      profile,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    return envRead?.call(profile, count) ?? _metadata(stored[profile]!);
  }
}

Map<String, dynamic> _metadata(bool stored) => {
  'EXAMPLE_API_KEY': {
    'is_set': stored,
    'channel_managed': false,
    'category': 'api_keys',
    'provider_label': 'Example',
  },
};

Future<void> _openCredential(
  WidgetTester tester,
  AdministrationFixture fixture, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool settle = true,
}) async {
  final navigation = WorkspaceProfileNavigation();
  final status = ServerConnectionStatus('Fixture server');
  addTearDown(navigation.dispose);
  addTearDown(status.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => RepaintBoundary(
        key: const ValueKey('credential-frame'),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
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
          if (choice?.kind == WorkspaceChoiceKind.profile &&
              choice?.id != null) {
            await navigation.switchTo(choice!.id!, () async => true);
          }
        },
        child: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => adminPushProfile(
                context,
                fixture.server.profile('personal'),
                (_, profile) => AdminServiceKeyCatalog(profile: profile),
              ),
              child: const Text('Open catalog'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open catalog'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Example'));
  // Navigator installs and lays out the route offstage before its first paint.
  await tester.pump();
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _chooseProfile(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  await tester.tap(find.byKey(const ValueKey('workspace-picker-target')));
  await _frames(tester);
  await tester.tap(find.byKey(ValueKey('workspace-profile-$name')));
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void _expectLoading() {
  expect(
    find.byWidgetPredicate(
      (w) => w is StudioLoading && w.label == 'Loading credential',
    ),
    findsOneWidget,
  );
}

const _captureEnabled = bool.fromEnvironment('CAPTURE_CREDENTIALS');
Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('credential-frame')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final target = File('build/design-previews/credential-profile/$name.png');
    target.parent.createSync(recursive: true);
    await target.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
