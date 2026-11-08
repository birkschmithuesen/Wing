import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/wing_plugin.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/wing_plugin_session.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_plugin_settings_card.dart';
import 'support/form_family_capture.dart';

WingPluginRelease release([String version = '0.3.0']) =>
    WingPluginRelease.decode({
      'tag_name': 'v$version',
      'draft': false,
      'prerelease': false,
    });
Map<String, dynamic> plugin(String version, {bool enabled = true}) => {
  'key': 'wing',
  'name': 'wing',
  'description': 'Wing features',
  'source': 'user',
  'version': version,
  'status': enabled ? 'enabled' : 'disabled',
};

class Fixture {
  final names = ['default', 'personal', 'work'];
  final rows = <String, Map<String, dynamic>?>{
    'default': plugin('0.2.3'),
    'personal': null,
    'work': plugin('0.3.0', enabled: false),
  };
  final calls = <Map<String, dynamic>>[];
  final failedReads = <String>{};
  String? failWrite, failReadback, refuseUpdate;
  Completer<void>? readGate, writeGate, connectGate, releaseGate, readbackGate;
  bool failRelease = false, loseReceipt = false, closed = false;
  final gateways = <String, ProfileGateway>{};
  late final AdministrationRepository server = AdministrationRepository(
    connectionId: 'fixture',
    connectionIdentity: 'fixture-backend',
    connectionLabel: 'Home Hermes',
    request: (_, endpoint, _, _) async {
      if (endpoint == 'profiles') {
        return {
          'profiles': [
            for (final name in names) {'name': name},
          ],
        };
      }
      if (endpoint == 'profiles/active') return {'active': 'default'};
      throw StateError('Unexpected read $endpoint');
    },
    settingsWrite: (_, _, _, _) async => throw StateError('Unexpected write'),
    ownedMutation: (_, _, _, _, _, _) async =>
        throw StateError('Unexpected write'),
    close: () => closed = true,
    gateway: (name) => gateways.putIfAbsent(
      name,
      () => ProfileGateway(
        scope: WorkspaceScope(connectionId: 'fixture', profileName: name),
        get: (_, _) async => throw StateError('Unexpected get'),
        discover: () => server.discover(),
        connect: () async {
          await connectGate?.future;
        },
        rpc: (method, params) async {
          expect(method, 'plugins.manage');
          expect(params['profile'], name);
          calls.add({...params});
          final action = params['action'];
          if (action == 'list') {
            await readGate?.future;
            if (writes.any((call) => call['profile'] == name)) {
              await readbackGate?.future;
            }
            if (failedReads.contains(name) ||
                failReadback == name &&
                    writes.any((call) => call['profile'] == name)) {
              throw JsonRpcError(method, 'Read unavailable', code: 4021);
            }
            return {
              'plugins': [
                if (rows[name] != null) rows[name],
                {...plugin('9.9.9'), 'key': 'other', 'name': 'other'},
              ],
            };
          }
          await writeGate?.future;
          if (failWrite == name) {
            throw JsonRpcError(method, 'Pinned installation', code: 4021);
          }
          if (action == 'update' && refuseUpdate == name) {
            return {
              'ok': false,
              'consent_required': true,
              'error': 'New capabilities need review.',
              'delta_lines': ['Adds email draft tools.'],
            };
          }
          if (action == 'install') {
            expect(params, {
              'profile': name,
              'action': 'install',
              'identifier': WingPluginRelease.repository,
              'enable': true,
            });
            rows[name] = plugin('0.3.0');
            return {
              'ok': true,
              'plugin_name': 'wing',
              'enabled': true,
              'restart_required': false,
            };
          }
          if (action == 'update') {
            expect(params, {
              'profile': name,
              'action': 'update',
              'name': 'wing',
            });
            rows[name]!['version'] = '0.3.0';
            if (loseReceipt) throw StateError('Lost reply');
            return {
              'ok': true,
              'name': 'wing',
              'unchanged': false,
              'restart_required': false,
            };
          }
          expect(params, {
            'profile': name,
            'action': 'toggle',
            'key': 'wing',
            'enable': true,
          });
          rows[name]!['status'] = 'enabled';
          return {
            'ok': true,
            'name': 'wing',
            'unchanged': false,
            'restart_required': false,
            'gateway_reloaded': true,
          };
        },
      ),
    ),
  );
  Iterable<Map<String, dynamic>> get writes =>
      calls.where((call) => call['action'] != 'list');
  WingPluginSession session() => WingPluginSession(
    server,
    readRelease: () async {
      await releaseGate?.future;
      if (failRelease) throw StateError('GitHub down');
      return release();
    },
  );
}

Future<void> frame(
  WidgetTester tester,
  WingPluginSession session, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  Object key = 'server',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      home: RepaintBoundary(
        key: formFamilyCapture,
        child: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            appBar: AppBar(
              title: const Text('App settings'),
              actions: const [StudioLoadingSlot()],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Wing plugin'),
                  WingPluginSettingsCard(
                    key: ValueKey(key),
                    createSession: () => session,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const refresh = 'Refresh Wing plugin versions';
const apply = 'Install or update Wing in all profiles';

void main() {
  setUpAll(loadFormFamilyFonts);
  test('stable versions compare numerically and reject previews', () {
    expect(
      WingPluginVersion.parse(
        '0.10.0',
      )!.compareTo(WingPluginVersion.parse('0.9.9')!),
      greaterThan(0),
    );
    for (final bad in ['v0.3.0', '0.3', '0.3.0-beta', '00.3.0']) {
      expect(WingPluginVersion.parse(bad), isNull);
    }
    expect(
      () => WingPluginRelease.decode({
        'tag_name': 'v0.3.0',
        'draft': false,
        'prerelease': true,
      }),
      throwsFormatException,
    );
  });
  test(
    'all profiles get scoped install update enable and verified versions',
    () async {
      final fixture = Fixture();
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.canApply, isTrue);
      expect(session.profiles[1].installedLabel, 'Not installed');
      await session.applyToAll();
      expect(fixture.writes.map((call) => call['action']), [
        'update',
        'install',
        'toggle',
      ]);
      expect(
        session.profiles.every(
          (row) =>
              row.plugin?.version == '0.3.0' &&
              row.plugin!.enabled &&
              row.error == null,
        ),
        isTrue,
      );
      expect(session.canApply, isFalse);
    },
  );
  test(
    'shared installation is re-read before following profile update',
    () async {
      final fixture = Fixture();
      fixture.rows['personal'] = fixture.rows['default'];
      fixture.rows['work'] = plugin('0.4.0');
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      await session.applyToAll();
      expect(fixture.writes.length, 1);
      expect(session.profiles[1].plugin!.version, '0.3.0');
      expect(fixture.rows['work']!['version'], '0.4.0');
    },
  );
  test(
    'partial refusal preserves results and continues other profiles without force',
    () async {
      final fixture = Fixture()..refuseUpdate = 'default';
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      await session.applyToAll();
      expect(session.profiles.first.error, contains('New capabilities'));
      expect(session.profiles[1].plugin!.version, '0.3.0');
      expect(session.profiles[2].plugin!.enabled, isTrue);
      expect(session.canApply, isFalse);
      expect(
        fixture.writes.every(
          (call) =>
              !call.containsKey('force') &&
              !call.containsKey('accept_capabilities'),
        ),
        isTrue,
      );
    },
  );
  test(
    'GitHub failure leaves backend inventory visible and refresh recovers',
    () async {
      final fixture = Fixture()..failRelease = true;
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.profiles.length, 3);
      expect(session.releaseError, isNotNull);
      expect(session.canApply, isFalse);
      fixture.failRelease = false;
      await session.refresh();
      expect(session.releaseError, isNull);
      expect(session.canApply, isTrue);
    },
  );
  test(
    'read failure is unknown not absent and cannot dispatch an install',
    () async {
      final fixture = Fixture()..failedReads.add('personal');
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      await session.applyToAll();
      expect(session.profiles[1].installedLabel, 'Version unavailable');
      expect(fixture.writes, isEmpty);
    },
  );
  test(
    'lost receipt and acknowledged write with unavailable readback stay distinct',
    () async {
      for (final loseReceipt in [true, false]) {
        final fixture = Fixture()..loseReceipt = loseReceipt;
        if (!loseReceipt) fixture.failReadback = 'default';
        final session = fixture.session();
        await session.refresh();
        await session.applyToAll();
        expect(
          session.profiles.first.error,
          contains(loseReceipt ? 'outcome is unknown' : 'Change accepted'),
        );
        expect(session.canApply, isFalse);
        session.dispose();
      }
    },
  );
  test(
    'leaving during connection prevents dispatch and retains in-flight lease',
    () async {
      final fixture = Fixture();
      final session = fixture.session();
      await session.refresh();
      fixture.connectGate = Completer<void>();
      final pending = session.applyToAll();
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      fixture.server.close();
      expect(fixture.closed, isFalse);
      fixture.connectGate!.complete();
      await pending;
      expect(fixture.writes, isEmpty);
      expect(fixture.closed, isTrue);
    },
  );
  test(
    'leaving after dispatched write stops remaining profiles and repeated clicks',
    () async {
      final fixture = Fixture()..writeGate = Completer<void>();
      final session = fixture.session();
      await session.refresh();
      final pending = session.applyToAll();
      await Future<void>.delayed(Duration.zero);
      await session.applyToAll();
      expect(fixture.writes.length, 1);
      session.dispose();
      fixture.writeGate!.complete();
      await pending;
      expect(fixture.writes.length, 1);
    },
  );
  testWidgets(
    'automatic read stays quiet; refresh and update show held visible feedback',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = Fixture()..readGate = Completer<void>();
      final session = fixture.session();
      await frame(tester, session);
      expect(find.byType(StudioLoading), findsNothing);
      fixture.readGate!.complete();
      fixture.readGate = null;
      await flush(tester);
      fixture.releaseGate = Completer<void>();
      await tester.tap(find.byTooltip(refresh));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      await captureFormFamily(tester, 'wing-plugin-refresh');
      fixture.releaseGate!.complete();
      fixture.releaseGate = null;
      await flush(tester);
      expect(find.byType(StudioLoading), findsNothing);
      fixture.writeGate = Completer<void>();
      await tester.tap(find.byTooltip(apply));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == apply,
              ),
            )
            .onPressed,
        isNull,
      );
      await captureFormFamily(tester, 'wing-plugin-update');
      fixture.writeGate!.complete();
      await flush(tester);
      expect(find.byType(StudioLoading), findsNothing);
      expect(session.profiles.every((row) => row.error == null), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'update feedback covers readback and failure; reduced motion stays visible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fixture = Fixture()
        ..writeGate = Completer<void>()
        ..readbackGate = Completer<void>()
        ..refuseUpdate = 'default';
      final session = fixture.session();
      await frame(tester, session);
      await flush(tester);
      await tester.tap(find.byTooltip(apply));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      fixture.writeGate!.complete();
      await flush(tester);
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(session.profiles.first.error, contains('New capabilities'));
      fixture.readbackGate!.complete();
      await flush(tester);
      expect(find.byType(StudioLoading), findsNothing);
      expect(session.profiles[1].plugin!.enabled, isTrue);
      await captureFormFamily(tester, 'wing-plugin-partial-result');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'refresh failure settles feedback and replacement ignores old completion',
    (tester) async {
      final first = Fixture();
      final session = first.session();
      await frame(tester, session);
      await flush(tester);
      first.releaseGate = Completer<void>();
      first.failRelease = true;
      await tester.tap(find.byTooltip(refresh));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      first.releaseGate!.complete();
      first.releaseGate = null;
      await flush(tester);
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.textContaining('Could not check GitHub'), findsOneWidget);
      first.readGate = Completer<void>();
      await tester.tap(find.byTooltip(refresh));
      await tester.pump();
      final second = Fixture();
      second.rows['default'] = plugin('0.9.0');
      await frame(tester, second.session(), key: 'new-server');
      await flush(tester);
      first.readGate!.complete();
      await flush(tester);
      expect(find.text('Version 0.9.0 · enabled'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('settings render ${brightness.name} $scale', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = Fixture();
        await frame(
          tester,
          fixture.session(),
          brightness: brightness,
          scale: scale,
        );
        await flush(tester);
        await captureFormFamily(
          tester,
          'wing-plugin-${brightness.name}-$scale',
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byTooltip(apply)).height,
          greaterThanOrEqualTo(48),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
