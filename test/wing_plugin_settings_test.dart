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

const releaseSha = 'a39afe7ae4acc2f2da50d73b6a117a5ce2f61e1a';
const oldSha = '5b985c598248d6d4ad22c1d61817e777d3ea3d09';
WingPluginRelease release([String version = '0.3.0']) =>
    WingPluginRelease.decode({
      'target_commitish': releaseSha,
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
  String refusal = 'Pinned installation';
  Completer<void>? readGate, writeGate, connectGate, releaseGate, readbackGate;
  bool failRelease = false, loseReceipt = false, closed = false;
  bool wrongInstalledPin = false;
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
            throw JsonRpcError(method, refusal, code: 4021);
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
              'ref': releaseSha,
              'force': rows[name]?['pinned_sha'] != null,
            });
            rows[name] = {
              ...plugin('0.3.0'),
              'pinned_sha': wrongInstalledPin ? oldSha : releaseSha,
            };
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
    RepaintBoundary(
      key: formFamilyCapture,
      child: MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: MediaQuery(
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
                  const Text('Hermes'),
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

Future<void> openManager(WidgetTester tester) async {
  await tester.tap(find.text('Wing plugin'));
  await flush(tester);
}

const refresh = 'Refresh Wing plugin versions';
const apply = 'Install or update Wing in all profiles';

void main() {
  setUpAll(loadFormFamilyFonts);
  test('backend refusal preserves its actionable reason', () async {
    final fixture = Fixture()..failWrite = 'default';
    final session = fixture.session();
    addTearDown(session.dispose);
    await session.refresh();
    await session.applyToAll();
    expect(session.profiles.first.error, contains('Pinned installation'));
  });
  test(
    'pinned installs use exact release only after matching approval',
    () async {
      final fixture = Fixture();
      fixture.rows['default']!['pinned_sha'] = oldSha;
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.hasPinnedUpdates, isTrue);
      await session.applyToAll();
      expect(
        fixture.writes.where((call) => call['profile'] == 'default'),
        isEmpty,
      );
      expect(session.profiles.first.error, contains('pinned'));
      await session.refresh();
      await session.applyToAll(approvedPinnedRelease: session.release);
      expect(fixture.writes.where((call) => call['force'] == true).single, {
        'profile': 'default',
        'action': 'install',
        'identifier': WingPluginRelease.repository,
        'enable': true,
        'ref': releaseSha,
        'force': true,
      });
      expect(session.profiles.first.plugin!.pinnedSha, releaseSha);
      expect(session.profiles.every((row) => row.error == null), isTrue);
    },
  );
  test(
    'refresh retires approval and newly pinned copies require review',
    () async {
      final fixture = Fixture();
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      final oldRelease = session.release;
      fixture.rows['default']!['pinned_sha'] = oldSha;
      await session.refresh();
      await session.applyToAll(approvedPinnedRelease: oldRelease);
      expect(
        fixture.writes.where((call) => call['profile'] == 'default'),
        isEmpty,
      );
      expect(fixture.writes, isEmpty);
      expect(session.error, contains('release changed'));
      // A pin appearing after observation also cannot trigger a forced write.
      fixture.calls.clear();
      await session.applyToAll();
      expect(
        fixture.writes.where((call) => call['profile'] == 'default'),
        isEmpty,
      );
      expect(session.profiles.first.error, contains('pinned'));
    },
  );
  test(
    'installation is not verified from version alone when pin differs',
    () async {
      final fixture = Fixture()..wrongInstalledPin = true;
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      await session.applyToAll();
      expect(session.profiles[1].error, contains('commit does not match'));
      expect(session.canApply, isFalse);
    },
  );
  test('refusal details redact credentials without losing the reason', () async {
    final fixture = Fixture()
      ..failWrite = 'default'
      ..refusal =
          'Pinned installation: password=very-secret; https://user:secret@example.com/plugin?token=hidden';
    final session = fixture.session();
    addTearDown(session.dispose);
    await session.refresh();
    await session.applyToAll();
    final error = session.profiles.first.error!;
    expect(error, contains('Pinned installation'));
    for (final secret in ['very-secret', 'user:secret', 'hidden']) {
      expect(error, isNot(contains(secret)));
    }
  });
  test(
    'inline pin review is required and cancelled without mutation',
    () async {
      final fixture = Fixture();
      fixture.rows['default']!['pinned_sha'] = oldSha;
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.overview.summary, contains('pinned'));
      await session.requestApply();
      expect(session.reviewRelease, same(session.release));
      expect(fixture.writes, isEmpty);
      session.cancelReview();
      expect(session.reviewRelease, isNull);
      await session.requestApply();
      await session.confirmPinnedUpdate();
      expect(fixture.writes.first['force'], isTrue);
      expect(session.overview.title, 'Up to date');
    },
  );
  testWidgets('compact card opens manager and profiles on demand', (
    tester,
  ) async {
    final fixture = Fixture();
    for (final name in fixture.names) {
      fixture.rows[name] = null;
    }
    final session = fixture.session();
    await frame(tester, session);
    await flush(tester);
    expect(find.text('default'), findsNothing);
    expect(find.text('Extra features for Wing.'), findsOneWidget);
    expect(find.byTooltip(apply), findsNothing);
    await openManager(tester);
    expect(find.text('Not installed'), findsOneWidget);
    expect(find.text('default'), findsNothing);
    await tester.tap(find.text('Profiles'));
    await flush(tester);
    expect(find.text('default'), findsOneWidget);
    expect(find.text('personal'), findsOneWidget);
    await tester.pageBack();
    await flush(tester);
    await tester.tap(find.byTooltip(apply));
    await flush(tester);
    expect(session.overview.title, 'Up to date');
    expect(
      fixture.writes.every(
        (call) => call['action'] == 'install' && call['force'] == false,
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('stable versions compare numerically and reject previews', () {
    expect(
      WingPluginVersion.parse(
        '0.10.0',
      )!.compareTo(WingPluginVersion.parse('0.9.9')!),
      greaterThan(0),
    );
    for (final sha in [null, 'main', 'a39afe7']) {
      expect(
        () => WingPluginRelease.decode({
          'tag_name': 'v0.3.0',
          'draft': false,
          'prerelease': false,
          'target_commitish': sha,
        }),
        throwsFormatException,
      );
    }
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
              call['force'] != true && !call.containsKey('accept_capabilities'),
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
      expect(find.text('default'), findsNothing);
      await tester.tap(find.text('Wing plugin'));
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip(refresh), findsOneWidget);
      expect(find.byType(StudioLoading), findsOneWidget);
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
      await tester.pageBack();
      await flush(tester);
      expect(find.text('App settings'), findsOneWidget);
      expect(find.byType(StudioLoading), findsOneWidget);
      await openManager(tester);
      expect(find.byType(StudioLoading), findsOneWidget);
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
      await openManager(tester);
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
      await openManager(tester);
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
      expect(find.text('App settings'), findsOneWidget);
      await openManager(tester);
      expect(find.text('0.3.0 · 0.9.0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final target in ['default', 'personal', 'work']) {
    test('individual maintenance changes only $target', () async {
      final fixture = Fixture();
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      fixture.calls.clear();
      await session.requestApply(profileName: target);
      expect(fixture.writes, isNotEmpty);
      expect(fixture.calls.every((call) => call['profile'] == target), isTrue);
      expect(session.canApplyTo(target), isFalse);
      expect(
        session.profiles.firstWhere((row) => row.profile.name == target).result,
        isNotNull,
      );
      for (final other in fixture.names.where((name) => name != target)) {
        expect(session.canApplyTo(other), isTrue);
      }
    });
  }
  test('a failed other profile does not block the selected profile', () async {
    final fixture = Fixture()..failedReads.add('default');
    final session = fixture.session();
    addTearDown(session.dispose);
    await session.refresh();
    expect(session.canApply, isFalse);
    expect(session.canApplyTo('default'), isFalse);
    expect(session.canApplyTo('personal'), isTrue);
    await session.requestApply(profileName: 'personal');
    expect(fixture.writes.single['profile'], 'personal');
    expect(session.profiles.first.error, isNotNull);
    expect(session.canApplyTo('work'), isTrue);
  });
  test(
    'profile pin review is scoped, cancellable and retired by refresh',
    () async {
      final fixture = Fixture();
      fixture.rows['default']!['pinned_sha'] = oldSha;
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      await session.requestApply(profileName: 'default');
      expect(session.reviewProfileName, 'default');
      expect(fixture.writes, isEmpty);
      session.cancelReview();
      await session.confirmPinnedUpdate();
      expect(fixture.writes, isEmpty);
      await session.requestApply(profileName: 'default');
      await session.refresh();
      await session.confirmPinnedUpdate();
      expect(fixture.writes, isEmpty);
      await session.requestApply(profileName: 'default');
      await session.confirmPinnedUpdate();
      expect(fixture.writes.single['profile'], 'default');
      expect(fixture.writes.single['force'], isTrue);
      expect(session.canApplyTo('personal'), isTrue);
    },
  );
  test(
    'a removed selected profile never expands the command to all profiles',
    () async {
      final fixture = Fixture();
      final session = fixture.session();
      addTearDown(session.dispose);
      await session.refresh();
      fixture.names.remove('personal');
      await session.requestApply(profileName: 'personal');
      expect(fixture.writes, isEmpty);
      expect(session.error, contains('no longer available'));
      expect(session.canApplyTo('personal'), isFalse);
    },
  );
  test('failed single update requires refresh only for that profile', () async {
    final fixture = Fixture()..failWrite = 'default';
    final session = fixture.session();
    addTearDown(session.dispose);
    await session.refresh();
    await session.requestApply(profileName: 'default');
    expect(session.canApplyTo('default'), isFalse);
    expect(session.canApplyTo('personal'), isTrue);
    final count = fixture.writes.length;
    await session.requestApply(profileName: 'default');
    expect(fixture.writes.length, count);
    fixture.failWrite = null;
    await session.refresh();
    await session.requestApply(profileName: 'default');
    expect(session.profiles.first.error, isNull);
    expect(
      fixture.writes.every((call) => call['profile'] == 'default'),
      isTrue,
    );
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('individual profile controls ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = Fixture()..writeGate = Completer<void>();
        fixture.rows['default']!['pinned_sha'] = oldSha;
        final session = fixture.session();
        await frame(tester, session, brightness: brightness, scale: scale);
        await flush(tester);
        await openManager(tester);
        await tester.tap(find.text('Profiles'));
        await tester.pumpAndSettle();
        await captureFormFamily(
          tester,
          'wing-individual-${brightness.name}-$scale',
        );
        await tester.tap(find.byTooltip('Install or update Wing in default'));
        await tester.pumpAndSettle();
        expect(find.text('Profiles'), findsOneWidget);
        expect(
          find.text('Replace the pinned version?').hitTestable(),
          findsOneWidget,
        );
        expect(find.textContaining('in default with'), findsOneWidget);
        expect(fixture.writes, isEmpty);
        await captureFormFamily(
          tester,
          'wing-individual-review-${brightness.name}-$scale',
        );
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(fixture.writes, isEmpty);
        await tester.tap(find.byTooltip('Install or update Wing in default'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Replace pinned Wing in default'));
        await flush(tester);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(fixture.writes.single['profile'], 'default');
        await captureFormFamily(
          tester,
          'wing-individual-pending-${brightness.name}-$scale',
        );
        fixture.writeGate!.complete();
        await flush(tester);
        expect(find.byType(StudioLoading), findsNothing);
        expect(fixture.writes.single['profile'], 'default');
        expect(session.canApplyTo('personal'), isTrue);
        expect(session.profiles.first.error, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
      testWidgets('pinned review ${brightness.name} $scale', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = Fixture()..writeGate = Completer<void>();
        fixture.rows['default']!['pinned_sha'] = oldSha;
        final session = fixture.session();
        await frame(tester, session, brightness: brightness, scale: scale);
        await flush(tester);
        await openManager(tester);
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(apply));
        await tester.pumpAndSettle();
        expect(
          find.text('Replace the pinned version?').hitTestable(),
          findsOneWidget,
        );
        expect(find.textContaining('caution-level'), findsOneWidget);
        expect(fixture.writes, isEmpty);
        await captureFormFamily(
          tester,
          'wing-pin-review-${brightness.name}-$scale',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(fixture.writes, isEmpty);
        await tester.tap(find.byTooltip(apply));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip('Replace pinned Wing and update all profiles'),
        );
        await flush(tester);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(fixture.writes.single['force'], isTrue);
        fixture.writeGate!.complete();
        await flush(tester);
        expect(find.byType(StudioLoading), findsNothing);
        expect(session.profiles.every((row) => row.error == null), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      });
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
        expect(find.text('default'), findsNothing);
        await openManager(tester);
        await captureFormFamily(
          tester,
          'wing-manager-${brightness.name}-$scale',
        );
        expect(
          tester.getSize(find.byTooltip(apply)).height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.text('Profiles'));
        await tester.pumpAndSettle();
        expect(find.text('default'), findsOneWidget);
        await captureFormFamily(
          tester,
          'wing-profiles-${brightness.name}-$scale',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
