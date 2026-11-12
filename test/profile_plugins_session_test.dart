import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_plugins.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/screens/administration/admin_plugins_page.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_plugins_session.dart';
import 'helpers/journey_controls.dart';
import 'support/administration_fixture.dart';
import 'support/form_family_capture.dart';

class _PluginsFixture {
  final http = AdministrationFixture();
  final calls = <Map<String, dynamic>>[];
  final row = <String, dynamic>{
    'key': 'tools/review',
    'name': 'Review',
    'source': 'user',
    'description': 'Review tools',
    'status': 'disabled',
    'version': '1.0.0',
  };
  bool loseReadback = false, unknownReceipt = false, invalid = false;
  Completer<void>? connected, release, updating, readback;
  Map<String, dynamic> outcome = {
    'results': [
      {'name': 'review', 'status': 'updated', 'detail': ''},
      {'name': 'wider', 'status': 'needs_review', 'detail': 'Adds tools'},
      {'name': 'broken', 'status': 'failed', 'detail': 'Update check failed'},
      {'name': 'raced', 'status': 'current', 'detail': ''},
    ],
    'skipped': [
      {'name': 'held', 'reason': 'Held with --ref'},
    ],
    'current': 2,
  };
  late final AdministrationRepository server = AdministrationRepository(
    connectionId: http.id,
    connectionIdentity: '${http.id}-endpoint',
    connectionLabel: http.id,
    request: http.send,
    settingsWrite: (_, _, _, _) async =>
        throw StateError('Unexpected config write'),
    ownedMutation: (_, _, _, _, _, _) async =>
        throw StateError('Unexpected HTTP write'),
    gateway: (_) => gateway,
  );
  late final ProfileGateway gateway = ProfileGateway(
    scope: WorkspaceScope(connectionId: http.id, profileName: 'work'),
    get: (_, _) async => throw StateError('Unexpected gateway HTTP read'),
    discover: () => server.discover(),
    connect: () async {
      if (release != null && !connected!.isCompleted) {
        connected!.complete();
        await release!.future;
      }
    },
    rpc: (method, params) async {
      expect(method, 'plugins.manage');
      calls.add({...params});
      if (params['action'] == 'list') {
        if (loseReadback &&
            calls.any(
              (call) => {'toggle', 'update_all'}.contains(call['action']),
            )) {
          throw StateError('Readback unavailable');
        }
        if (readback != null &&
            calls.any((call) => call['action'] == 'update_all')) {
          await readback!.future;
        }
        return {
          'plugins': [
            invalid ? {...row, 'status': 7} : row,
          ],
        };
      }
      if (params['action'] == 'update_all') {
        expect(params, {'profile': 'work', 'action': 'update_all'});
        await updating?.future;
        return outcome;
      }
      expect(params, {
        'profile': 'work',
        'action': 'toggle',
        'key': 'tools/review',
        'enable': true,
      });
      row['status'] = 'enabled';
      if (unknownReceipt) {
        return {'name': 'tools/review'};
      }
      return {
        'ok': true,
        'name': 'tools/review',
        'unchanged': false,
        'restart_required': false,
        'gateway_reloaded': true,
        'plugin': row,
      };
    },
  );
}

void main() {
  setUpAll(loadFormFamilyFonts);
  test(
    'immutable captured inventory and ACK survive unavailable readback without replay',
    () async {
      final fixture = _PluginsFixture();
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      final original = session.state;
      expect(() => original.rows.clear(), throwsUnsupportedError);
      fixture.row['description'] = 'Changed outside the snapshot';
      expect(original.rows.single.description, 'Review tools');
      fixture.loseReadback = true;
      await session.toggle(original.rows.single, true);
      expect(fixture.row['status'], 'enabled');
      expect(session.state.acknowledgement!.key, 'tools/review');
      expect(session.state.acknowledgement!.enabled, isTrue);
      expect(session.state.error, contains('saved'));
      expect(session.state.verified, isFalse);
      final count = fixture.calls.length;
      await session.toggle(session.state.rows.single, true);
      expect(fixture.calls, hasLength(count));
      fixture.loseReadback = false;
      await session.refresh();
      expect(session.state.rows.single.enabled, isTrue);
      expect(session.state.error, isNull);
      expect(original.rows.single.enabled, isFalse);
      expect(
        fixture.calls.where((call) => call['action'] == 'toggle'),
        hasLength(1),
      );
      expect(fixture.calls.every((call) => call['profile'] == 'work'), isTrue);
    },
  );

  test(
    'malformed observation and an unknown dispatched result require a fresh read',
    () async {
      final fixture = _PluginsFixture()..invalid = true;
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.state.verified, isFalse);
      expect(session.state.rows, isEmpty);
      expect(session.state.error, contains('invalid response'));
      fixture.invalid = false;
      await session.refresh();
      fixture.unknownReceipt = true;
      await session.toggle(session.state.rows.single, true);
      expect(fixture.row['status'], 'enabled');
      expect(session.state.acknowledgement, isNull);
      expect(session.state.error, contains('could not be confirmed'));
      expect(session.state.canToggle, isFalse);
      await session.toggle(session.state.rows.single, true);
      expect(
        fixture.calls.where((call) => call['action'] == 'toggle'),
        hasLength(1),
      );
      await session.refresh();
      expect(session.state.verified, isTrue);
      expect(session.state.rows.single.enabled, isTrue);
      expect(session.state.acknowledgement, isNull);
    },
  );

  test(
    'retirement during connection admission prevents physical plugin mutation',
    () async {
      final fixture = _PluginsFixture();
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      await session.refresh();
      fixture.connected = Completer<void>();
      fixture.release = Completer<void>();
      final pending = session.toggle(session.state.rows.single, true);
      await fixture.connected!.future;
      final published = session.state;
      session.dispose();
      fixture.server.close();
      fixture.release!.complete();
      await pending;
      expect(
        fixture.calls.where((call) => call['action'] == 'toggle'),
        isEmpty,
      );
      expect(fixture.row['status'], 'disabled');
      expect(identical(session.state, published), isTrue);
    },
  );

  testWidgets(
    'plugin route mounts, toggles and refreshes its captured profile',
    (tester) async {
      final fixture = _PluginsFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => AdminPluginsPage(
                      createSession: () =>
                          ProfilePluginsSession(fixture.server.profile('work')),
                    ),
                  ),
                ),
                child: const Text('Open plugins'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open plugins'));
      await tester.pumpAndSettle();
      expect(find.text('Review'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byTooltip('Refresh plugins'));
      await tester.pumpAndSettle();
      expect(
        fixture.calls.where((call) => call['action'] == 'toggle'),
        hasLength(1),
      );
      expect(fixture.calls.every((call) => call['profile'] == 'work'), isTrue);
      expect(
        fixture.http.requests.where((request) => request.$1 != 'GET'),
        isEmpty,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      final before = fixture.calls.length;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(fixture.calls, hasLength(before));
      expect(tester.takeException(), isNull);
      fixture.server.close();
    },
  );

  test(
    'maintenance keeps mixed receipts through failed readback without replay',
    () async {
      final fixture = _PluginsFixture()..loseReadback = true;
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      await session.updateInstalled();
      final result = session.state.maintenance!;
      expect(result.updated, 1);
      expect(result.alreadyCurrent, 3);
      expect(result.needsReview, isTrue);
      expect(result.skipped.single.reason, 'Held with --ref');
      expect(result.results.map((row) => row.status), [
        PluginUpdateStatus.updated,
        PluginUpdateStatus.needsReview,
        PluginUpdateStatus.failed,
        PluginUpdateStatus.current,
      ]);
      expect(() => result.results.clear(), throwsUnsupportedError);
      expect(session.state.error, startsWith('Update results received'));
      expect(session.state.canUpdate, isFalse);
      await session.updateInstalled();
      expect(
        fixture.calls.where((row) => row['action'] == 'update_all'),
        hasLength(1),
      );
      fixture.loseReadback = false;
      await session.refresh();
      expect(session.state.canUpdate, isTrue);
      expect(identical(session.state.maintenance, result), isTrue);
      expect(
        fixture.calls.where((row) => row['action'] == 'update_all'),
        hasLength(1),
      );
    },
  );

  test(
    'unknown maintenance receipt blocks repeated mutation until refresh',
    () async {
      final fixture = _PluginsFixture()..outcome = {'ok': true};
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      await session.updateInstalled();
      expect(session.state.maintenance, isNull);
      expect(session.state.error, contains('could not be confirmed'));
      await session.updateInstalled();
      expect(
        fixture.calls.where((row) => row['action'] == 'update_all'),
        hasLength(1),
      );
    },
  );

  test(
    'retired maintenance cannot dispatch after connection admission',
    () async {
      final fixture = _PluginsFixture();
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      await session.refresh();
      fixture.connected = Completer<void>();
      fixture.release = Completer<void>();
      final pending = session.updateInstalled();
      await fixture.connected!.future;
      session.dispose();
      fixture.release!.complete();
      await pending;
      expect(
        fixture.calls.where((row) => row['action'] == 'update_all'),
        isEmpty,
      );
    },
  );

  test(
    'plugin metadata remains supplied and malformed batch identities fail',
    () async {
      final fixture = _PluginsFixture();
      fixture.row.addAll({
        'installed_sha': 'old',
        'catalog_sha': 'new',
        'catalog_version': '2.0.0',
        'update_available': true,
        'pinned_sha': 'held',
      });
      final session = ProfilePluginsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      final row = session.state.rows.single;
      expect(row.version, '1.0.0');
      expect(row.catalogVersion, '2.0.0');
      expect(row.installedSha, 'old');
      expect(row.updateAvailable, isTrue);
      expect(row.pinnedSha, 'held');
      expect(
        () => PluginMaintenanceResult.decode({
          'results': [
            {'name': 'same', 'status': 'updated', 'detail': ''},
          ],
          'skipped': [
            {'name': 'same', 'reason': 'held'},
          ],
          'current': 0,
        }),
        throwsFormatException,
      );
    },
  );

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('maintenance pending and results $dark $scale', (
        tester,
      ) async {
        final width = scale == 2 ? 320.0 : 390.0;
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _PluginsFixture()
          ..updating = Completer<void>()
          ..readback = Completer<void>();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: formFamilyCapture, child: child!),
            ),
            home: AdminPluginsPage(
              createSession: () =>
                  ProfilePluginsSession(fixture.server.profile('work')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(ListView))).width,
          width,
        );
        await tester.tap(find.byTooltip('Update installed plugins'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        await captureFormFamily(
          tester,
          'plugins-maintenance-pending-$dark-$scale',
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Update installed plugins',
                ),
              )
              .onPressed,
          isNull,
        );
        fixture.updating!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        fixture.readback!.complete();
        await tester.pumpAndSettle();
        expect(find.text('1 updated · 3 already current'), findsOneWidget);
        await captureFormFamily(
          tester,
          'plugins-maintenance-results-$dark-$scale',
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.text('Skipped · Held with --ref'),
        );
        expect(
          find.text('Skipped · Held with --ref').hitTestable(),
          findsOneWidget,
        );
        await captureFormFamily(
          tester,
          'plugins-maintenance-skipped-$dark-$scale',
        );
        await tester.scrollUntilVisible(
          find.byTooltip('Update installed plugins'),
          -300,
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.byTooltip('Update installed plugins'),
        );
        fixture.updating = Completer<void>();
        fixture.readback = null;
        fixture.loseReadback = true;
        await tester.tap(find.byTooltip('Update installed plugins'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        fixture.updating!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Update results received. Current inventory is unavailable; refresh to check it.',
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('1 updated · 3 already current'),
          150,
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.text('1 updated · 3 already current'),
        );
        expect(
          find.text('1 updated · 3 already current').hitTestable(),
          findsOneWidget,
        );
        await captureFormFamily(
          tester,
          'plugins-maintenance-failed-$dark-$scale',
        );
        fixture.loseReadback = false;
        fixture.readback = Completer<void>();
        await tester.scrollUntilVisible(
          find.byTooltip('Refresh plugins'),
          -150,
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.byTooltip('Refresh plugins'),
        );
        await tester.tap(find.byTooltip('Refresh plugins'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        fixture.readback!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Update results received. Current inventory is unavailable; refresh to check it.',
          ),
          findsNothing,
        );
        expect(
          fixture.calls.where((call) => call['action'] == 'update_all'),
          hasLength(2),
        );
        await captureFormFamily(
          tester,
          'plugins-maintenance-recovered-$dark-$scale',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
