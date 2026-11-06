import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/context_occupancy.dart';
import 'package:wing/core/models/hosted_connector_accounts.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/model_catalog_details.dart';
import 'package:wing/core/screens/administration/admin_skills_page.dart';
import 'package:wing/core/screens/versions_updates_screen.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/hosted_connection_request_panel.dart';
import 'package:wing/core/widgets/model_card.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'support/administration_fixture.dart';
import 'support/backend_update_channel_fixture.dart';

const _capture = bool.fromEnvironment('HERMES023_REVIEW');
const _frame = ValueKey('hermes023-review');

class _Skills {
  final fixture = AdministrationFixture();
  bool locked = false, failWrite = false, failReadback = false;
  int writes = 0;
  Completer<void>? hold;
  Completer<void>? readHold;
  late final session = ProfileSkillsSession.library(
    fixture.server.profile('personal'),
  );
  _Skills() {
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (path == 'profiles/active') {
        return {'current': 'personal', 'active': 'personal'};
      }
      if (path == 'skills') {
        await readHold?.future;
        if (failReadback && writes > 0) throw TimeoutException('readback');
        return {
          'data': [
            {
              'name': 'research',
              'description': 'Read primary sources',
              'provenance': 'agent',
              'enabled': true,
              'usage': 3,
              'locked': locked,
            },
          ],
        };
      }
      if (path == 'skills/content') {
        return {
          'name': 'research',
          'content': '# Research\nRead primary sources and keep citations.',
        };
      }
      if (path == 'skills/lock') {
        expect(method, 'PUT');
        expect(query['profile'], 'personal');
        expect(body!['name'], 'research');
        writes++;
        await hold?.future;
        if (failWrite) throw TimeoutException('lost response');
        locked = body['locked'] as bool;
        return {'ok': true, 'name': 'research', 'locked': locked};
      }
      throw StateError('Unexpected $method $path');
    };
  }
}

Future<void> _mount(
  WidgetTester tester,
  Widget child,
  Brightness brightness,
  double scale,
) async {
  tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: scale == 2,
        ),
        child: RepaintBoundary(key: _frame, child: child!),
      ),
      home: child,
    ),
  );
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/design-previews/hermes023/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    for (final (family, path) in [
      ('Roboto', 'build/studio-roboto.ttf'),
      ('MaterialIcons', 'build/studio-icons.otf'),
      ('monospace', 'build/studio-mono.ttf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(path).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  test(
    'subscription exemption is independent of Free display and exhausted allowance',
    () {
      final plan = PlanUsage.parse({
        'kind': 'usage_window',
        'subscription_model_ids': ['sub'],
        'gauges': [
          {'label': 'day', 'scope': 'all', 'left_fraction': 0},
        ],
      })!;
      final provider = ModelProvider(
        slug: 'nous',
        name: 'Nous',
        planUsage: plan,
        usageLevels: {'sub': 'free', 'free': 'free'},
      );
      ModelChoice choice(String id) =>
          ModelChoice(provider: 'nous', model: id, providerInfo: provider);
      expect(choice('sub').allowanceLabel, isNull);
      expect(choice('sub').allowanceExempt, isTrue);
      expect(choice('sub').allowanceGauges, isEmpty);
      expect(choice('sub').planLimitLabel, isNull);
      expect(choice('free').allowanceLabel, 'Free');
      expect(choice('paid').planLimitLabel, 'Allowance used up');
      expect(
        ModelChoice(provider: 'other', model: 'sub').allowanceLabel,
        isNull,
      );
    },
  );
  testWidgets(
    'subscription model detail does not inherit credit-spend consequences',
    (tester) async {
      final plan = PlanUsage.parse({
        'kind': 'usage_window',
        'credits_pay': true,
        'subscription_model_ids': ['sub'],
        'gauges': [
          {'label': 'day', 'scope': 'all', 'left_fraction': 0},
        ],
      })!;
      final choice = ModelChoice(
        provider: 'nous',
        model: 'sub',
        providerInfo: ModelProvider(
          slug: 'nous',
          name: 'Nous',
          planUsage: plan,
          usageLevels: {'sub': 'free'},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModelCard(context, choice),
                child: const Text('Details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Free'), findsNothing);
      expect(find.text('After allowance'), findsNothing);
      expect(find.text('Uses credits'), findsNothing);
    },
  );
  test(
    'configured window pin does not conflate occupancy estimate or guess fallback',
    () {
      final row = {
        'context_used': 100,
        'context_max': 1000,
        'context_percent': 10,
        'context_estimated': true,
        'context_source': 'local_estimate',
        'config_context_length': 1000,
      };
      final pinned = ContextOccupancy.fromJson(row)!;
      expect(pinned.pinned, isTrue);
      expect(pinned.withoutCategories().pinned, isTrue);
      expect(
        ContextOccupancy.fromJson({
          ...row,
          'config_context_length': 2000,
        })!.pinned,
        isFalse,
      );
      expect(
        ContextOccupancy.fromJson({
          ...row,
          'config_context_length': null,
        })!.pinned,
        isFalse,
      );
    },
  );
  test(
    'Cloud updater ownership recognizes exact stock hosts and saved identity',
    () {
      SavedConnection connection(String host, {String? id, String? gateway}) =>
          SavedConnection(
            id: 'cloud',
            label: 'Cloud',
            host: host,
            port: 443,
            apiKey: '',
            cloudInstanceId: id,
            desktopGatewayUrl: gateway,
          );
      expect(connection('example.test', id: 'i1').cloudManagedUpdates, isTrue);
      expect(
        connection('one.agents.nousresearch.com').cloudManagedUpdates,
        isTrue,
      );
      expect(
        connection('one.agents.staging-nousresearch.com').cloudManagedUpdates,
        isTrue,
      );
      expect(
        connection(
          'example.test',
          gateway: 'https://one.agents.nousresearch.com',
        ).cloudManagedUpdates,
        isTrue,
      );
      expect(
        connection(
          'one.agents.nousresearch.com.attacker.test',
        ).cloudManagedUpdates,
        isFalse,
      );
      expect(connection('example.test').cloudManagedUpdates, isFalse);
    },
  );
  test(
    'skill lock has captured scope, held feedback, exact readback and manual edit rights',
    () async {
      final f = _Skills();
      addTearDown(f.session.dispose);
      await f.session.refresh();
      final route = f.session.openSkill(f.session.state.installed.single);
      await f.session.loadDetail(route);
      f.hold = Completer<void>();
      final pending = f.session.setLocked(route, true);
      await Future<void>.delayed(Duration.zero);
      expect(f.session.state.saving, isTrue);
      await f.session.setLocked(route, true);
      expect(f.writes, 1);
      expect(f.session.currentSkill(route)!.locked, isFalse);
      f.hold!.complete();
      expect(await pending, isTrue);
      expect(f.session.currentSkill(route)!.locked, isTrue);
      expect(f.session.canEdit(route), isTrue);
      expect(await f.session.setLocked(route, false), isTrue);
      expect(f.locked, isFalse);
    },
  );
  test(
    'skill lock response loss requires readback and never repeats an uncertain write',
    () async {
      final f = _Skills();
      addTearDown(f.session.dispose);
      await f.session.refresh();
      final route = f.session.openSkill(f.session.state.installed.single);
      await f.session.loadDetail(route);
      f.failWrite = true;
      expect(await f.session.setLocked(route, true), isFalse);
      expect(f.session.state.reviewRequired, isTrue);
      await f.session.setLocked(route, true);
      expect(f.writes, 1);
      f.failWrite = false;
      await f.session.loadDetail(route);
      expect(await f.session.setLocked(route, true), isTrue);
    },
  );
  test(
    'skill lock refuses changed observations and retired unsent intent',
    () async {
      final f = _Skills();
      addTearDown(f.session.dispose);
      await f.session.refresh();
      final route = f.session.openSkill(f.session.state.installed.single);
      await f.session.loadDetail(route);
      f.locked = true;
      expect(await f.session.setLocked(route, true), isFalse);
      expect(f.writes, 0);
      await f.session.loadDetail(route);
      f.session.releaseDetail(route);
      await f.session.setLocked(route, false);
      expect(f.writes, 0);
    },
  );
  test('departing during lock preflight retires the unsent command', () async {
    final f = _Skills();
    addTearDown(f.session.dispose);
    await f.session.refresh();
    final route = f.session.openSkill(f.session.state.installed.single);
    await f.session.loadDetail(route);
    f.readHold = Completer<void>();
    final pending = f.session.setLocked(route, true);
    await Future<void>.delayed(Duration.zero);
    f.session.releaseDetail(route);
    f.readHold!.complete();
    expect(await pending, isFalse);
    expect(f.writes, 0);
  });
  test('acknowledged lock without readback is not claimed verified', () async {
    final f = _Skills();
    addTearDown(f.session.dispose);
    await f.session.refresh();
    final route = f.session.openSkill(f.session.state.installed.single);
    await f.session.loadDetail(route);
    f.failReadback = true;
    expect(await f.session.setLocked(route, true), isFalse);
    expect(f.session.state.verified, isFalse);
    expect(f.locked, isTrue);
    await f.session.setLocked(route, true);
    expect(f.writes, 1);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Cloud keeps version and only refreshes health ${brightness.name} $scale',
        (tester) async {
          addTearDown(tester.view.reset);
          final fixture = AdministrationFixture();
          final gate = Completer<Map<String, dynamic>>();
          fixture.override = (_, path, _, _) async {
            expect(path, 'health');
            return gate.future;
          };
          final gateway = fixture.server.profile('personal').gateway;
          final versions = VersionsController(
            gateway: gateway,
            cloudManaged: true,
          );
          await _mount(
            tester,
            VersionsUpdatesScreen(controllerFactory: (_) => versions),
            brightness,
            scale,
          );
          await tester.pump();
          expect(versions.server!.versionLoading, isTrue);
          expect(find.byTooltip('Change update channel'), findsNothing);
          expect(find.byTooltip('Check for updates'), findsNothing);
          expect(find.byTooltip('Update backend'), findsNothing);
          expect(versions.server!.canStart, isFalse);
          expect(versions.server!.canOpenChannelEditor, isFalse);
          expect(
            await versions.server!.startUpdate(
              approvedChannel: BackendUpdateChannelFixture().approved,
              canDispatch: () => true,
            ),
            isFalse,
          );
          expect(
            await versions.server!.selectChannel(
              'main',
              BackendUpdateChannelFixture().approved,
              canDispatch: () => true,
            ),
            isFalse,
          );
          await versions.server!.refreshStatus();
          gate.complete({'ok': true, 'version': '0.23.0'});
          await tester.pumpAndSettle();
          expect(find.text('0.23.0'), findsOneWidget);
          expect(
            find.text('Updates are managed by Hermes Cloud.'),
            findsOneWidget,
          );
          expect(find.byTooltip('Refresh server version'), findsOneWidget);
          await _snapshot(tester, '${brightness.name}-$scale-cloud');
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'skill lock real control holds then settles ${brightness.name} $scale',
        (tester) async {
          addTearDown(tester.view.reset);
          final f = _Skills();
          addTearDown(f.session.dispose);
          await f.session.refresh();
          final route = f.session.openSkill(f.session.state.installed.single);
          await _mount(
            tester,
            AdminSkillDetail(session: f.session, route: route),
            brightness,
            scale,
          );
          await tester.pumpAndSettle();
          f.hold = Completer<void>();
          await tester.tap(find.byTooltip('Skill actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Lock against agent edits'));
          await tester.pump();
          expect(f.session.state.saving, isTrue);
          expect(find.byType(StudioLoadingRegion), findsOneWidget);
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 250));
          await _snapshot(tester, '${brightness.name}-$scale-lock-pending');
          f.hold!.complete();
          await tester.pumpAndSettle();
          expect(find.text('Locked against agent edits'), findsWidgets);
          await tester.tap(find.byTooltip('Skill actions'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Unlock agent edits'), findsOneWidget);
          expect(find.byTooltip('Edit instructions'), findsOneWidget);
          await tester.tapAt(const Offset(10, 700));
          await tester.pumpAndSettle();
          await _snapshot(tester, '${brightness.name}-$scale-locked');
          f.hold = null;
          f.failWrite = true;
          await tester.tap(find.byTooltip('Skill actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Unlock agent edits'));
          await tester.pumpAndSettle();
          expect(find.textContaining('not confirmed'), findsOneWidget);
          expect(f.session.currentSkill(route)!.locked, isTrue);
          await _snapshot(tester, '${brightness.name}-$scale-lock-failure');
          f.failWrite = false;
          f.readHold = Completer<void>();
          await tester.ensureVisible(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Retry').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          f.readHold!.complete();
          await tester.pumpAndSettle();
          expect(f.session.state.reviewRequired, isFalse);
          expect(find.textContaining('not confirmed'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'scrubbed launch facts are readable in consent ${brightness.name} $scale',
        (tester) async {
          addTearDown(tester.view.reset);
          final operation = HostedConnectionOperation.fromJson({
            'op_id': 'launch1',
            'seq': 0,
            'deadline_at': 2000000000,
            'targets': [
              {
                'name': 'Research tools',
                'kind': 'mcp',
                'state': 'pending',
                'launch': {
                  'kind': 'stdio',
                  'target':
                      'npx --yes @example/research-tools --workspace /srv/projects/research',
                  'env': ['RESEARCH_API_KEY', 'SEARCH_REGION'],
                  'cwd': '/srv/projects/research',
                },
              },
              {
                'name': 'Remote sources',
                'kind': 'mcp',
                'state': 'pending',
                'launch': {
                  'kind': 'remote',
                  'target': 'https://sources.example.test/mcp?token=[REDACTED]',
                },
              },
            ],
          });
          await _mount(
            tester,
            Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  child: HostedConnectionRequestPanel(
                    operation: operation,
                    canContinue: true,
                    canRefresh: true,
                    working: false,
                    onContinue: () async {},
                    onRefresh: () async {},
                    onOpenAccounts: () async {},
                    onAuthorize: (_) async {},
                  ),
                ),
              ),
            ),
            brightness,
            scale,
          );
          await tester.pumpAndSettle();
          expect(find.text('Runs on server'), findsOneWidget);
          expect(
            find.text(operation.targets.first.launch!.target),
            findsOneWidget,
          );
          expect(find.textContaining('RESEARCH_API_KEY'), findsOneWidget);
          await _snapshot(tester, '${brightness.name}-$scale-launch');
          await tester.ensureVisible(
            find.byTooltip('Continue connection request'),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
