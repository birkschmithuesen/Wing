import 'package:shared_preferences/shared_preferences.dart';
import 'support/backend_update_channel_fixture.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/backend_update_controller.dart';
import 'package:wing/core/services/backend_update_store.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/backend_update.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/widgets/backend_version_card.dart';
import 'package:wing/core/screens/versions_updates_screen.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

const _available = <String, dynamic>{
  'current_version': '1.2.3',
  'install_method': 'git',
  'behind': 2,
  'update_available': true,
  'can_apply': true,
};

class _UpdateHost {
  final source = BackendUpdateChannelFixture();
  Map<String, dynamic> checkResponse = _available;
  Map<String, dynamic> statusResponse = {
    'running': true,
    'action_id': 'action-1',
    'pid': 41,
    'exit_code': null,
    'lines': <String>[],
  };
  Map<String, dynamic> postResponse = {
    'ok': true,
    'name': 'hermes-update',
    'pid': 41,
    'action_id': 'action-1',
  };
  Map<String, dynamic> receiptResponse = {
    'receipt': {
      'pid': 41,
      'finished_at': '2026-09-12T12:00:00Z',
      'outcome': 'success',
      'action_id': 'previous-action',
    },
    'summary': 'success',
  };
  Completer<Map<String, dynamic>>? pendingHealth;
  Completer<Map<String, dynamic>>? pendingCheck;
  Completer<Map<String, dynamic>>? pendingStatus;
  bool statusFails = false;
  bool receiptFails = false;
  final reads = <(String, Map<String, String>)>[];
  final posts = <(String, Map<String, dynamic>)>[];

  late final ProfileGateway gateway = ProfileGateway(
    scope: WorkspaceScope(connectionId: 'host', profileName: 'work'),
    get: (endpoint, query) async {
      reads.add((endpoint, query));
      final metadata = source.read(endpoint, query);
      if (metadata != null) return metadata;
      if (endpoint == 'health') {
        if (pendingHealth != null) return pendingHealth!.future;
        return {
          'ok': true,
          'version': checkResponse['current_version'],
          'commit': BackendUpdateChannelFixture.currentSha,
        };
      }
      if (endpoint == 'hermes/update/check') {
        source.fetchedAt++;
        return pendingCheck?.future ?? checkResponse;
      }
      if (endpoint == 'hermes/update/receipt') {
        if (receiptFails) {
          throw const DashboardHttpException(503, 'hermes/update/receipt');
        }
        return receiptResponse;
      }
      if (endpoint != 'actions/hermes-update/status') {
        throw StateError('Unexpected update read: $endpoint');
      }
      if (statusFails) {
        throw StateError('private disconnected detail');
      }
      return pendingStatus?.future ?? statusResponse;
    },
    ownedPut: source.put,
    ownedPost: (endpoint, body, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Retired');
      onDispatched();
      posts.add((endpoint, body));
      return postResponse;
    },
    rpc: (_, _) async => <String, dynamic>{},
    discover: () async => const ProfileDiscovery(
      profiles: [],
      currentName: null,
      activeName: null,
    ),
  );
}

// Mirrors the production Versions route's ownership when exercising a card alone.
class _UpdateCardOwner extends StatefulWidget {
  const _UpdateCardOwner({required this.controller, required this.child});
  final BackendUpdateController controller;
  final Widget child;
  @override
  State<_UpdateCardOwner> createState() => _UpdateCardOwnerState();
}

class _UpdateCardOwnerState extends State<_UpdateCardOwner> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const capture = bool.fromEnvironment('CAPTURE_BACKEND_CHANNELS');
  setUpAll(() async {
    if (!capture) return;
    for (final (family, path) in [
      ('Roboto', 'build/studio-roboto.ttf'),
      ('MaterialIcons', 'build/studio-icons.otf'),
      ('monospace', 'build/studio-mono.ttf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(path).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('channels-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/backend-channels/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settleTrackedUpdate(WidgetTester tester) async {
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
      final cards = tester.widgetList<BackendVersionCard>(
        find.byType(BackendVersionCard),
      );
      if (frame >= 15 &&
          cards.every((card) {
            final state = card.updateController;
            return !state.starting &&
                !state.checking &&
                !state.statusLoading &&
                !state.versionLoading &&
                !state.trackingLoading;
          })) {
        return;
      }
    }
    throw TestFailure(
      'Update presentation did not settle its explicit request',
    );
  }

  void expectUsableDialog(WidgetTester tester, String title, String action) {
    final dialog = tester.getRect(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    final heading = tester.getRect(find.text(title));
    final cancel = tester.getRect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Cancel'),
      ),
    );
    final commit = tester.getRect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip(action),
      ),
    );
    for (final rect in [heading, cancel, commit]) {
      expect(dialog.intersect(rect), rect);
    }
    expect(cancel.overlaps(commit), isFalse);
    for (final rect in [cancel, commit]) {
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
    }
    expect(find.byTooltip(action).hitTestable(), findsOneWidget);
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'restored update retries and settles ${brightness.name} $scale',
        (tester) async {
          final host = _UpdateHost()
            ..statusFails = true
            ..receiptFails = true;
          final store = host.source.updates;
          await store.reserve(
            BackendUpdateAttempt(
              requestId: 'saved-request',
              installId: host.source.approved.installId,
              installPath: host.source.approved.installPath,
              home: host.source.approved.home,
              targetSha: host.source.targetSha!,
              startedAt: DateTime.utc(2026, 11, 12),
            ),
          );
          await store.accept('saved-request', 'action-1', 41);
          final reopened = BackendUpdateStore(
            SharedPreferences.getInstance(),
            store.key,
          );
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('channels-capture'),
                  child: child!,
                ),
              ),
              home: VersionsUpdatesScreen(
                controllerFactory: (_) => VersionsController(
                  gateway: host.gateway,
                  updateStore: reopened,
                ),
              ),
            ),
          );
          await settleTrackedUpdate(tester);
          expect(
            find.text('Update ongoing. Waiting for the server to reconnect.'),
            findsOneWidget,
          );
          expect(find.text('Update availability unknown.'), findsNothing);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            host.reads.where((r) => r.$1 == 'hermes/update/check'),
            isEmpty,
          );
          final card = tester.widget<BackendVersionCard>(
            find.byType(BackendVersionCard),
          );
          expect(card.updateController.canStart, isFalse);
          expect(card.updateController.canOpenChannelEditor, isFalse);
          expect(host.posts, isEmpty);
          await snapshot(
            tester,
            '${brightness.name}-$scale-update-restored-outage',
          );
          final held = host.pendingStatus = Completer<Map<String, dynamic>>();
          host.statusFails = false;
          host.receiptFails = false;
          host.receiptResponse = {
            'receipt': {
              'action_id': 'action-1',
              'pid': 41,
              'outcome': 'success',
              'finished_at': '2026-11-12T09:00:00Z',
            },
          };
          host.checkResponse = {..._available, 'current_version': '1.2.4'};
          final progress = find.byTooltip('Check update progress');
          await tester.ensureVisible(progress);
          await tester.tap(progress);
          await tester.pump();
          expect(card.updateController.statusLoading, isTrue);
          expect(reopened.current, isNotNull);
          await snapshot(
            tester,
            '${brightness.name}-$scale-update-held-progress',
          );
          held.complete({
            'running': false,
            'pid': null,
            'exit_code': null,
            'lines': <String>[],
          });
          await settleTrackedUpdate(tester);
          expect(reopened.current, isNull);
          expect(
            find.text('The backend update completed successfully.'),
            findsOneWidget,
          );
          expect(find.text('1.2.4'), findsOneWidget);
          expect(find.byTooltip('Check for updates'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          expect(host.posts, isEmpty);
          expect(tester.takeException(), isNull);
          await snapshot(
            tester,
            '${brightness.name}-$scale-update-restored-success',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'changed-target warning expires after four seconds ${brightness.name} $scale',
        (tester) async {
          final host = _UpdateHost();
          host.source
            ..channel = 'stable'
            ..branch = null;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(
                  key: const ValueKey('channels-capture'),
                  child: child!,
                ),
              ),
              home: VersionsUpdatesScreen(
                controllerFactory: (_) => VersionsController(
                  updateStore: backendUpdateStoreFixture(),
                  gateway: host.gateway,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          const message =
              'The update channel or target changed. Review it before updating.';
          for (final sha in [
            '3333333333333333333333333333333333333333',
            '4444444444444444444444444444444444444444',
          ]) {
            final update = find.byTooltip('Update backend');
            await tester.ensureVisible(update);
            await tester.tap(update);
            await tester.pumpAndSettle();
            host.source.targetSha = sha;
            await tester.tap(find.byTooltip('Update backend').last);
            await tester.pumpAndSettle();
            expect(host.posts, isEmpty);
            expect(find.text(message), findsOneWidget);
            await snapshot(tester, '${brightness.name}-$scale-target-refused');
            await tester.pump(const Duration(seconds: 3));
            expect(find.text(message), findsOneWidget);
            await tester.pump(const Duration(seconds: 1));
            await tester.pumpAndSettle();
            expect(find.text(message), findsNothing);
            expect(
              find.byTooltip('Update backend').hitTestable(),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }
        },
      );

      testWidgets(
        'server version refresh fails with retained data ${brightness.name} $scale',
        (tester) async {
          final host = _UpdateHost();
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(
                  key: const ValueKey('channels-capture'),
                  child: child!,
                ),
              ),
              home: VersionsUpdatesScreen(
                controllerFactory: (_) => VersionsController(
                  updateStore: backendUpdateStoreFixture(),
                  gateway: host.gateway,
                  cloudManaged: true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('1.2.3'), findsOneWidget);
          final refresh = find.byTooltip('Refresh server version');
          final pending = Completer<Map<String, dynamic>>();
          host.pendingHealth = pending;
          await tester.tap(refresh);
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.text('1.2.3'), findsOneWidget);
          pending.completeError(StateError('Version read failed'));
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text('1.2.3'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(StudioError),
              matching: find.text('Could not refresh server version.'),
            ),
            findsOneWidget,
          );
          await snapshot(
            tester,
            '${brightness.name}-$scale-stale-server-version',
          );
          host.pendingHealth = null;
          host.checkResponse = {..._available, 'current_version': '1.2.4'};
          await tester.ensureVisible(refresh);
          await tester.pump();
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(find.text('1.2.4'), findsOneWidget);
          expect(find.byType(StudioError), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'channel editor survives failed checks ${brightness.name} $scale',
        (tester) async {
          final host = _UpdateHost();
          host.source.metadataUnavailable = true;
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
                child: RepaintBoundary(
                  key: const ValueKey('channels-capture'),
                  child: child!,
                ),
              ),
              home: VersionsUpdatesScreen(
                controllerFactory: (_) => VersionsController(
                  updateStore: backendUpdateStoreFixture(),
                  gateway: host.gateway,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining('The update channel could not be verified.'),
            findsOneWidget,
          );
          expect(find.byTooltip('Change update channel'), findsOneWidget);
          await snapshot(
            tester,
            '${brightness.name}-$scale-channel-unavailable',
          );

          final held = Completer<Map<String, dynamic>>();
          host.pendingCheck = held;
          await tester.tap(find.byTooltip('Change update channel'));
          await tester.pump();
          expect(find.text('Update channel'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 200));
          await snapshot(tester, '${brightness.name}-$scale-channel-reloading');
          held.completeError(StateError('offline'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Change update channel'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.byTooltip('Check update channel'), findsOneWidget);
          expect(find.textContaining('Check again'), findsOneWidget);
          await snapshot(
            tester,
            '${brightness.name}-$scale-channel-load-failed',
          );

          host.source.metadataUnavailable = false;
          host.pendingCheck = null;
          await tester.tap(find.byTooltip('Check update channel'));
          await tester.pumpAndSettle();
          expect(find.text('Main branch'), findsOneWidget);
          expect(find.byTooltip('Save update channel'), findsOneWidget);
          await snapshot(tester, '${brightness.name}-$scale-channel-recovered');
          expect(host.source.writes, isEmpty);
          await tester.tap(find.text('Main branch'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Stable releases').last);
          await tester.pumpAndSettle();
          final save = Completer<void>();
          host.source.pendingWrite = save;
          await tester.tap(find.byTooltip('Save update channel'));
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          save.complete();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Channel: stable'), findsOneWidget);
          expect(host.source.writes, hasLength(1));
          expect(host.posts, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'version route ${brightness.name} $scale loading, unknown, retry and success',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final health = Completer<Map<String, dynamic>>();
            final check = Completer<Map<String, dynamic>>();
            final host = _UpdateHost()
              ..pendingHealth = health
              ..pendingCheck = check;
            tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: RepaintBoundary(
                    key: const ValueKey('channels-capture'),
                    child: child!,
                  ),
                ),
                home: VersionsUpdatesScreen(
                  controllerFactory: (_) => VersionsController(
                    updateStore: backendUpdateStoreFixture(),
                    gateway: host.gateway,
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.text('Loading version…'), findsNothing);
            expect(find.text('—'), findsOneWidget);
            expect(find.text('Checking for updates…'), findsNothing);
            expect(
              find.text('Update availability unknown.').hitTestable(),
              findsNothing,
            );
            expect(
              find.bySemanticsLabel('Update availability unknown.'),
              findsNothing,
            );
            expect(find.byType(StudioLoading), findsOneWidget);
            await snapshot(tester, '${brightness.name}-$scale-initial');

            host.pendingHealth = null;
            health.complete({
              'ok': true,
              'version': '0.22.0',
              'commit': BackendUpdateChannelFixture.currentSha,
            });
            await tester.pump();
            await tester.pump();
            expect(find.text('0.22.0'), findsOneWidget);
            expect(find.text('Checking for updates…'), findsNothing);
            expect(find.byType(StudioLoading), findsOneWidget);
            await snapshot(tester, '${brightness.name}-$scale-version-ready');

            check.complete({
              'current_version': '0.22.0',
              'behind': -1,
              'can_apply': false,
            });
            await tester.pumpAndSettle();
            expect(find.text('Update availability unknown.'), findsOneWidget);
            expect(find.byType(StudioLoading), findsNothing);
            await snapshot(tester, '${brightness.name}-$scale-unknown');

            final retry = Completer<Map<String, dynamic>>();
            host.pendingCheck = retry;
            await tester.ensureVisible(find.byTooltip('Check for updates'));
            final header = tester.getRect(find.text('Versions & updates'));
            await tester.tap(find.byTooltip('Check for updates'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.text('Checking for updates…'), findsNothing);
            expect(
              find.text('Update availability unknown.').hitTestable(),
              findsNothing,
            );
            expect(
              find.bySemanticsLabel('Update availability unknown.'),
              findsNothing,
            );
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(tester.getRect(find.text('Versions & updates')), header);
            final button = tester.widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Check for updates',
              ),
            );
            expect(button.onPressed, isNull);
            retry.completeError(StateError('unreachable'));
            await tester.pumpAndSettle();
            expect(find.text('Could not check for updates.'), findsNothing);
            expect(
              find.text('Update availability could not be checked. Try again.'),
              findsOneWidget,
            );
            expect(find.byType(StudioError), findsOneWidget);
            expect(find.byType(StudioLoading), findsNothing);
            await snapshot(tester, '${brightness.name}-$scale-check-failed');

            host.pendingCheck = null;
            host.checkResponse = {
              ..._available,
              'behind': 0,
              'update_available': false,
            };
            await tester.tap(find.byTooltip('Check for updates'));
            await tester.pumpAndSettle();
            expect(find.text('Up to date on main'), findsOneWidget);
            expect(find.byType(StudioLoading), findsNothing);
            expect(tester.takeException(), isNull);
            await snapshot(tester, '${brightness.name}-$scale-current');

            host.checkResponse = {..._available, 'behind': -1};
            await tester.tap(find.byTooltip('Check for updates'));
            await tester.pumpAndSettle();
            expect(
              find.text('Update available · comparison unavailable'),
              findsOneWidget,
            );
            expect(
              find.text(
                'Hermes could not compare this installation with upstream.',
              ),
              findsOneWidget,
            );
            expect(find.textContaining('commit count unknown'), findsNothing);
            await snapshot(tester, '${brightness.name}-$scale-comparison-card');
            await tester.ensureVisible(
              find.byTooltip('Changes in this update'),
            );
            final reads = host.reads.length;
            await tester.tap(find.byTooltip('Changes in this update'));
            await tester.pumpAndSettle();
            expect(
              find.text(
                'Hermes could not compare this installation with upstream.',
              ),
              findsOneWidget,
            );
            expect(host.reads, hasLength(reads));
            await snapshot(
              tester,
              '${brightness.name}-$scale-comparison-details',
            );
            await tester.pageBack();
            await tester.pumpAndSettle();

            host.checkResponse = _available;
            await tester.tap(find.byTooltip('Check for updates'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.byTooltip('Update backend'));
            final refreshX = tester.getCenter(find.byIcon(Icons.sync)).dx;
            await tester.tap(find.byTooltip('Update backend'));
            await tester.pumpAndSettle();
            final startCheck = Completer<Map<String, dynamic>>();
            host.pendingCheck = startCheck;
            await tester.tap(find.byTooltip('Update backend').last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(find.text('Starting update…'), findsOneWidget);
            expect(find.text('Update logs'), findsOneWidget);
            expect(find.byType(SelectableText), findsNothing);
            final pendingRotation = tester
                .widget<RotationTransition>(
                  find.descendant(
                    of: find.byTooltip('Check for updates'),
                    matching: find.byType(RotationTransition),
                  ),
                )
                .turns;
            final turn = pendingRotation.value;
            await tester.pump(const Duration(milliseconds: 100));
            expect(pendingRotation.value, scale == 2 ? turn : isNot(turn));
            await tester.ensureVisible(find.text('Update logs'));
            await snapshot(tester, '${brightness.name}-$scale-update-starting');
            expect(find.text('Checking for updates…'), findsNothing);
            startCheck.complete(_available);
            await settleTrackedUpdate(tester);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(host.posts, hasLength(1));
            expect(tester.getCenter(find.byIcon(Icons.sync)).dx, refreshX);
            expect(find.byIcon(Icons.refresh), findsNothing);
            host.pendingCheck = null;
            host.statusResponse = {
              ...host.statusResponse,
              'lines': [
                'Preparing update',
                'Downloading source',
                'Applying newest changes',
              ],
            };
            await tester.pump(const Duration(seconds: 2));
            await tester.pump();
            await tester.ensureVisible(find.text('Update logs'));
            await snapshot(
              tester,
              '${brightness.name}-$scale-update-running-collapsed',
            );
            await tester.tap(find.text('Update logs'));
            await settleTrackedUpdate(tester);
            await tester.ensureVisible(find.byType(SelectableText));
            if (scale == 2) {
              await tester.drag(
                find.byType(SingleChildScrollView).first,
                const Offset(0, -520),
              );
              await settleTrackedUpdate(tester);
            }
            await snapshot(
              tester,
              '${brightness.name}-$scale-update-running-expanded',
            );
            expect(
              find.text(
                'Applying newest changes\nDownloading source\nPreparing update',
              ),
              findsOneWidget,
            );
            final logViewport = find.byKey(
              const ValueKey('backend-update-log-scroll'),
            );
            host.statusResponse = {
              ...host.statusResponse,
              'lines': ['One line'],
            };
            await tester.pump(const Duration(seconds: 2));
            await tester.pump();
            final logPosition = tester
                .widget<SingleChildScrollView>(logViewport)
                .controller!
                .position;
            expect(logPosition.maxScrollExtent, 0);
            final longLines = List.generate(
              80,
              (index) => 'Update line ${index.toString().padLeft(3, '0')}',
            );
            host.statusResponse = {...host.statusResponse, 'lines': longLines};
            await tester.pump(const Duration(seconds: 2));
            await tester.pump();
            await tester.ensureVisible(find.byTooltip('Check update progress'));
            await settleTrackedUpdate(tester);
            expect(logPosition.maxScrollExtent, greaterThan(0));
            final logText = tester.widget<SelectableText>(
              find.byType(SelectableText),
            );
            final lineHeight =
                scale * logText.style!.fontSize! * logText.style!.height!;
            expect(
              tester.getSize(logViewport).height,
              closeTo(16 * lineHeight, 0.1),
            );
            expect(
              find.byTooltip('Check update progress').hitTestable(),
              findsOneWidget,
            );
            expect(logPosition.pixels, 0);
            final output = tester.widget<SelectableText>(
              find.byType(SelectableText),
            );
            expect(output.data, longLines.reversed.join('\n'));
            await snapshot(
              tester,
              '${brightness.name}-$scale-update-bounded-newest',
            );
            final refresh = find.byTooltip('Check update progress');
            final beforeRefresh = tester.getRect(refresh);
            final heldStatus = Completer<Map<String, dynamic>>();
            host.pendingStatus = heldStatus;
            await tester.tap(refresh);
            await tester.pump();
            expect(tester.getRect(refresh), beforeRefresh);
            expect(
              tester
                  .widget<IconButton>(
                    find.ancestor(
                      of: refresh,
                      matching: find.byType(IconButton),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            final refreshTurns = tester
                .widget<RotationTransition>(
                  find.descendant(
                    of: refresh,
                    matching: find.byType(RotationTransition),
                  ),
                )
                .turns;
            final refreshTurn = refreshTurns.value;
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(
              refreshTurns.value,
              scale == 2 ? refreshTurn : isNot(refreshTurn),
            );
            await snapshot(
              tester,
              '${brightness.name}-$scale-progress-pending',
            );
            heldStatus.completeError(StateError('disconnected'));
            await settleTrackedUpdate(tester);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(
              find.text('Update ongoing. Waiting for the server to reconnect.'),
              findsOneWidget,
            );
            expect(find.byTooltip('Check update progress'), findsOneWidget);
            expect(
              tester.widget<SelectableText>(find.byType(SelectableText)).data,
              longLines.reversed.join('\n'),
            );
            host.pendingStatus = null;
            await tester.ensureVisible(refresh);
            await tester.tap(refresh);
            await settleTrackedUpdate(tester);
            expect(find.byType(StudioError), findsNothing);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(host.posts, hasLength(1));
            final footer = tester.getRect(
              find.byTooltip('Check update progress'),
            );
            final outerPosition = tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: find.byType(SingleChildScrollView).first,
                        matching: find.byType(Scrollable),
                      )
                      .first,
                )
                .position;
            final outerOffset = outerPosition.pixels;
            await tester.timedDrag(
              logViewport,
              const Offset(0, -20000),
              const Duration(seconds: 1),
            );
            await settleTrackedUpdate(tester);
            expect(
              logPosition.pixels,
              closeTo(logPosition.maxScrollExtent, 0.1),
            );
            expect(outerPosition.pixels, outerOffset);
            expect(
              tester.getRect(find.byTooltip('Check update progress')),
              footer,
            );
            await snapshot(
              tester,
              '${brightness.name}-$scale-update-bounded-oldest',
            );
            host.receiptResponse['receipt']['action_id'] = 'action-1';
            host.statusResponse = {
              ...host.statusResponse,
              'running': false,
              'exit_code': 0,
              'action_id': 'action-1',
            };
            await tester.pump(const Duration(seconds: 2));
            await settleTrackedUpdate(tester);
            expect(find.byTooltip('Check update progress'), findsNothing);
            expect(find.byTooltip('Check for updates'), findsOneWidget);
            expect(tester.getCenter(find.byIcon(Icons.sync)).dx, refreshX);
          } finally {
            semantics.dispose();
          }
        },
      );
      testWidgets(
        'channel route ${brightness.name} $scale held refresh, save failure and retry',
        (tester) async {
          final host = _UpdateHost()
            ..checkResponse = {
              ..._available,
              'behind': null,
              'update_available': false,
              'message': "Couldn't reach the update source — try again later.",
            };
          host.source
            ..channel = 'stable'
            ..branch = null
            ..error = 'release-unavailable'
            ..targetSha = null;
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('channels-capture'),
                  child: child!,
                ),
              ),
              home: VersionsUpdatesScreen(
                controllerFactory: (_) => VersionsController(
                  updateStore: backendUpdateStoreFixture(),
                  gateway: host.gateway,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Channel: stable'), findsOneWidget);
          expect(
            find.text(host.checkResponse['message'] as String),
            findsOneWidget,
          );
          expect(find.byTooltip('Update backend'), findsNothing);
          await snapshot(tester, '${brightness.name}-$scale-error');

          final refresh = Completer<Map<String, dynamic>>();
          host.pendingCheck = refresh;
          final actions = find
              .ancestor(
                of: find.byTooltip('Check for updates'),
                matching: find.byType(Wrap),
              )
              .first;
          await tester.ensureVisible(find.byTooltip('Check for updates'));
          final before = tester.getRect(actions);
          await tester.tap(find.byTooltip('Check for updates'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.getRect(actions), before);
          await snapshot(tester, '${brightness.name}-$scale-checking');
          host.pendingCheck = null;
          host.source
            ..error = null
            ..targetSha = '2222222222222222222222222222222222222222'
            ..targetVersion = '0.21.7';
          host.checkResponse = {..._available, 'behind': -1};
          refresh.complete(host.checkResponse);
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text('Release update available'), findsOneWidget);
          expect(find.text('Release: 0.21.7'), findsOneWidget);
          await snapshot(tester, '${brightness.name}-$scale-release');

          await tester.ensureVisible(find.byTooltip('Change update channel'));
          await tester.tap(find.byTooltip('Change update channel'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Stable releases'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Main branch').last);
          await tester.pumpAndSettle();
          expectUsableDialog(tester, 'Update channel', 'Save update channel');
          final saveRect = tester.getRect(
            find.byTooltip('Save update channel'),
          );
          await snapshot(tester, '${brightness.name}-$scale-editor');
          final write = Completer<void>();
          host.source
            ..pendingWrite = write
            ..saveFails = true;
          await tester.tap(find.byTooltip('Save update channel'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          // Measure the held save after the shared press feedback settles.
          await tester.pump(WingMotion.buttonPress);
          await tester.pump(WingMotion.buttonRelease);
          expectUsableDialog(tester, 'Update channel', 'Save update channel');
          expect(
            tester.getRect(find.byTooltip('Save update channel')),
            saveRect,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == 'Cancel',
                  ),
                )
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (w) =>
                        w is IconButton && w.tooltip == 'Save update channel',
                  ),
                )
                .onPressed,
            isNull,
          );
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 32));
          expect(find.text('Update channel'), findsOneWidget);
          await snapshot(tester, '${brightness.name}-$scale-saving');
          write.complete();
          await tester.pumpAndSettle();
          expect(find.text('Main branch'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.text('The channel save could not be confirmed. Try again.'),
            findsWidgets,
          );
          expectUsableDialog(tester, 'Update channel', 'Save update channel');
          await snapshot(tester, '${brightness.name}-$scale-save-error');

          host.source
            ..pendingWrite = null
            ..saveFails = false;
          host.checkResponse = _available;
          await tester.ensureVisible(find.byTooltip('Save update channel'));
          await tester.tap(find.byTooltip('Save update channel'));
          await tester.pumpAndSettle();
          expect(find.text('Update channel'), findsNothing);
          expect(find.text('Channel: main'), findsOneWidget);
          expect(
            find.text('Update available · 2 commits behind main'),
            findsOneWidget,
          );
          expect(host.source.writes, hasLength(2));
          expect(host.posts, isEmpty);
          expect(tester.takeException(), isNull);
          await snapshot(tester, '${brightness.name}-$scale-main');
          await tester.ensureVisible(find.byTooltip('Update backend'));
          await tester.tap(find.byTooltip('Update backend'));
          await tester.pumpAndSettle();
          expectUsableDialog(
            tester,
            'Update backend on this server?',
            'Update backend',
          );
          await snapshot(tester, '${brightness.name}-$scale-confirmation');
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
          host.source
            ..channel = 'stable'
            ..branch = null
            ..rollback = true
            ..targetVersion = '0.21.6';
          host.checkResponse = {
            ..._available,
            'behind': -1,
            'rollback_to': '0.21.6',
            'message':
                'Updating moves this build back to stable release 0.21.6.',
          };
          await tester.tap(find.byTooltip('Check for updates'));
          await tester.pumpAndSettle();
          expect(find.text('Switch to an older release'), findsOneWidget);
          await tester.ensureVisible(find.byTooltip('Update backend'));
          await tester.tap(find.byTooltip('Update backend'));
          await tester.pumpAndSettle();
          expectUsableDialog(
            tester,
            'Update backend on this server?',
            'Update backend',
          );
          expect(
            find.textContaining('moves the server back to release 0.21.6'),
            findsOneWidget,
          );
          await snapshot(tester, '${brightness.name}-$scale-rollback');
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
          expect(host.posts, isEmpty);
        },
      );
    }
  }
  testWidgets(
    'known update status refresh stays quiet and publishes new output',
    (tester) async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      await controller.checkForUpdate();
      await controller.refreshStatus();
      final pending = Completer<Map<String, dynamic>>();
      host.pendingStatus = pending;
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(host.statusResponse);
      });
      final card = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => Scaffold(body: child),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: BackendVersionCard(
                  key: card,
                  updateController: controller,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getRect(find.byKey(card));
      final refresh = controller.refreshStatus();
      await tester.pump(const Duration(seconds: 12));
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.getRect(find.byKey(card)), before);
      expect(find.byTooltip('Changes in this update'), findsOneWidget);
      pending.complete({
        ...host.statusResponse,
        'lines': ['Fresh update output'],
      });
      await refresh;
      await tester.pumpAndSettle();
      expect(controller.status!.lines, ['Fresh update output']);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('Fresh update output'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  Future<void> showCard(
    WidgetTester tester,
    _UpdateHost host, {
    Size size = const Size(800, 900),
    double textScale = 1,
    Brightness? brightness,
  }) async {
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _UpdateCardOwner(
        controller: controller,
        child: MaterialApp(
          theme: brightness == null ? null : wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: textScale == 2,
            ),
            child: RepaintBoundary(
              key: const ValueKey('channels-capture'),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackendVersionCard(
                updateController: controller,
                connectionLabel: 'Production host',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> check(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  Future<void> openConfirmation(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Update backend'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'channel editor opens during an availability refresh ${brightness.name} $scale',
        (tester) async {
          final host = _UpdateHost();
          await showCard(
            tester,
            host,
            size: const Size(390, 844),
            textScale: scale,
            brightness: brightness,
          );
          await tester.pumpAndSettle();
          final held = Completer<Map<String, dynamic>>();
          host.pendingCheck = held;
          await tester.tap(find.byTooltip('Check for updates'));
          await tester.pump();
          await tester.tap(find.byTooltip('Change update channel'));
          await tester.pump();
          expect(find.text('Update channel'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.byTooltip('Cancel').hitTestable(), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 200));
          await snapshot(
            tester,
            '${brightness.name}-$scale-editor-during-refresh',
          );
          held.complete(_available);
          await tester.pumpAndSettle();
          expect(find.text('Main branch'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            host.reads.where((r) => r.$1 == 'hermes/update/check'),
            hasLength(2),
          );
          expect(host.posts, isEmpty);
          expect(host.source.writes, isEmpty);
          await tester.tap(find.byTooltip('Cancel'));
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final leave in [false, true]) {
    testWidgets('channel editor held refresh failure, departure=$leave', (
      tester,
    ) async {
      final host = _UpdateHost();
      await showCard(tester, host);
      await tester.pumpAndSettle();
      final held = Completer<Map<String, dynamic>>();
      host.pendingCheck = held;
      await tester.tap(find.byTooltip('Check for updates'));
      await tester.pump();
      await tester.tap(find.byTooltip('Change update channel'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      if (leave) {
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pump(const Duration(milliseconds: 300));
      }
      held.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      if (leave) {
        expect(find.byType(AlertDialog), findsNothing);
      } else {
        expect(
          find.textContaining('Check again to enable saving'),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        host.pendingCheck = null;
        await tester.tap(find.byTooltip('Check update channel'));
        await tester.pumpAndSettle();
        expect(find.text('Main branch'), findsOneWidget);
        expect(
          find.textContaining('Check again to enable saving'),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
      }
      expect(host.posts, isEmpty);
      expect(host.source.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirmed Main update follows an advancing branch', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await tester.pumpAndSettle();
    await openConfirmation(tester);
    host.source.targetSha = '4444444444444444444444444444444444444444';
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();
    expect(host.posts, hasLength(1));
    expect(find.textContaining('Review it before updating'), findsNothing);
  });

  for (final next in ['main', 'stable']) {
    testWidgets('channel refresh reconciles a retired preview with $next', (
      tester,
    ) async {
      final host = _UpdateHost();
      host.source
        ..channel = 'pm-preview'
        ..branch = null;
      await showCard(tester, host);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Change update channel'));
      await tester.pumpAndSettle();
      expect(find.text('pm-preview').last, findsOneWidget);

      host.source
        ..channel = next
        ..branch = next == 'main' ? 'main' : null;
      await tester.tap(find.byTooltip('Check update channel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text(next == 'main' ? 'Main branch' : 'Stable releases'),
        findsOneWidget,
      );
      expect(find.text('pm-preview'), findsNothing);
      expect(host.source.writes, isEmpty);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('channel refresh preserves a supported unsaved choice', (
    tester,
  ) async {
    final host = _UpdateHost();
    host.source
      ..channel = 'pm-preview'
      ..branch = null;
    await showCard(tester, host);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change update channel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pm-preview').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stable releases').last);
    await tester.pumpAndSettle();
    host.source
      ..channel = 'main'
      ..branch = 'main';
    await tester.tap(find.byTooltip('Check update channel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Stable releases'), findsOneWidget);
    expect(host.source.writes, isEmpty);
    await tester.tap(find.byTooltip('Save update channel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Channel: stable'), findsOneWidget);
    expect(host.source.writes, hasLength(1));
  });

  testWidgets('closing an unverified channel editor retires its held read', (
    tester,
  ) async {
    final host = _UpdateHost();
    host.source.metadataUnavailable = true;
    await showCard(tester, host);
    await tester.pumpAndSettle();
    final held = Completer<Map<String, dynamic>>();
    host.pendingCheck = held;
    await tester.tap(find.byTooltip('Change update channel'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    host.source.metadataUnavailable = false;
    held.complete(_available);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(host.source.writes, isEmpty);
    expect(host.posts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'named previews are visible and custom branches stay host-owned',
    (tester) async {
      final host = _UpdateHost()..checkResponse = {..._available, 'behind': -1};
      host.source
        ..channel = 'pm-preview'
        ..branch = null;
      await showCard(tester, host);
      await tester.pumpAndSettle();
      expect(find.text('Channel: pm-preview'), findsOneWidget);
      expect(find.text('Release update available'), findsOneWidget);
      await tester.tap(find.byTooltip('Change update channel'));
      await tester.pumpAndSettle();
      expect(find.text('Keep the configured preview channel.'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      host.source
        ..channel = 'main'
        ..branch = 'feature/mobile';
      host.checkResponse = _available;
      await tester.tap(find.byTooltip('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('Branch: feature/mobile'), findsOneWidget);
      expect(find.byTooltip('Change update channel'), findsNothing);
      expect(host.source.writes, isEmpty);
      expect(host.posts, isEmpty);
    },
  );

  testWidgets('loads version and upstream status automatically on opening', (
    tester,
  ) async {
    final host = _UpdateHost()
      ..checkResponse = {..._available, 'behind': 0, 'update_available': false};
    await showCard(tester, host);
    await check(tester);

    expect(
      host.reads.where((call) => call.$1 == 'hermes/update/check'),
      hasLength(1),
    );
    expect(
      host.reads.firstWhere((call) => call.$1 == 'hermes/update/check').$2,
      {'force': 'true', 'profile': 'work'},
    );
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('Install method: git'), findsOneWidget);
    expect(find.text('Up to date on main'), findsOneWidget);
    expect(find.byTooltip('Changes in this update'), findsNothing);
    expect(find.byTooltip('Update backend'), findsNothing);
    expect(find.byTooltip('Check update progress'), findsNothing);

    await tester.tap(find.byTooltip('Check for updates'));
    await tester.pumpAndSettle();
    expect(
      host.reads.where((call) => call.$1 == 'hermes/update/check'),
      hasLength(2),
    );
  });

  testWidgets(
    'missing change details do not block updating or trigger requests',
    (tester) async {
      final host = _UpdateHost()..checkResponse = {..._available, 'behind': -1};
      await showCard(tester, host);
      await tester.pumpAndSettle();
      expect(
        find.text('Update available · comparison unavailable'),
        findsOneWidget,
      );
      expect(
        find.text('Hermes could not compare this installation with upstream.'),
        findsOneWidget,
      );
      final reads = host.reads.length;
      await tester.tap(find.byTooltip('Changes in this update'));
      await tester.pumpAndSettle();
      expect(find.text('Production host'), findsOneWidget);
      expect(
        find.text('Hermes could not compare this installation with upstream.'),
        findsOneWidget,
      );
      expect(find.text('Commit details'), findsNothing);
      expect(host.reads, hasLength(reads));
      expect(host.posts, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Update backend'), findsOneWidget);
    },
  );

  testWidgets('keeps malformed availability unknown and shows host guidance', (
    tester,
  ) async {
    final host = _UpdateHost()
      ..checkResponse = {
        'current_version': '1.2.3',
        'behind': -1,
        'update_available': 'yes',
        'can_apply': false,
      };
    await showCard(tester, host);
    await check(tester);

    expect(find.text('Update availability unknown.'), findsOneWidget);
    expect(
      find.text('Updates must be applied from the server host.'),
      findsOneWidget,
    );
    expect(find.text('Up to date on main'), findsNothing);
  });

  testWidgets('confirmation names the host and cancel does not post', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await check(tester);
    await openConfirmation(tester);

    expect(find.text('Update backend on Production host?'), findsOneWidget);
    expect(
      find.text(
        'Update the whole server using main. All profiles may disconnect while Hermes restarts.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(host.posts, isEmpty);
  });

  testWidgets('confirmed update rechecks eligibility and starts once', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await check(tester);
    await openConfirmation(tester);
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();

    expect(
      host.reads.where((call) => call.$1 == 'hermes/update/check'),
      hasLength(2),
    );
    expect(host.posts, hasLength(1));
    expect(host.posts.single.$1, 'hermes/update?profile=work');
    expect(find.text('Update ongoing'), findsOneWidget);
  });

  testWidgets(
    'update acknowledges preflight and follows newest output automatically',
    (tester) async {
      final host = _UpdateHost();
      await showCard(tester, host);
      await check(tester);
      await openConfirmation(tester);
      final preflight = Completer<Map<String, dynamic>>();
      host.pendingCheck = preflight;
      await tester.tap(find.byTooltip('Update backend').last);
      await tester.pump();
      expect(find.text('Starting update…').hitTestable(), findsOneWidget);
      expect(find.text('Update logs').hitTestable(), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      final rotation = tester
          .widget<RotationTransition>(
            find.descendant(
              of: find.byTooltip('Check for updates'),
              matching: find.byType(RotationTransition),
            ),
          )
          .turns;
      final initialTurn = rotation.value;
      await tester.pump(const Duration(milliseconds: 220));
      expect(rotation.value, isNot(initialTurn));
      expect(host.posts, isEmpty);

      final status = Completer<Map<String, dynamic>>();
      host.pendingStatus = status;
      host.pendingCheck = null;
      preflight.complete(_available);
      await tester.pump();
      await tester.pump();
      expect(find.text('Update logs'), findsOneWidget);
      // Explicit refresh joins the held automatic snapshot and acknowledges it.
      await tester.tap(find.byTooltip('Check update progress'));
      await tester.pump();
      final explicitRotation = tester
          .widget<RotationTransition>(
            find.descendant(
              of: find.byTooltip('Check update progress'),
              matching: find.byType(RotationTransition),
            ),
          )
          .turns;
      final explicitTurn = explicitRotation.value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(explicitRotation.value, isNot(explicitTurn));
      expect(
        host.reads.where((r) => r.$1 == 'actions/hermes-update/status'),
        hasLength(1),
      );
      host.pendingStatus = null;
      status.complete({
        ...host.statusResponse,
        'lines': ['First', 'Second'],
      });
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.text('Update logs'));
      await tester.pumpAndSettle();
      expect(find.text('Second\nFirst'), findsOneWidget);
      host.statusResponse = {
        ...host.statusResponse,
        'lines': ['First', 'Second', 'Third'],
      };
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Third\nSecond\nFirst'), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      host.statusFails = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        find.text('Update ongoing. Waiting for the server to reconnect.'),
        findsOneWidget,
      );
      final reads = host.reads.length;
      await tester.pump(const Duration(seconds: 6));
      expect(host.reads.length, greaterThan(reads));
      expect(find.text('Third\nSecond\nFirst'), findsOneWidget);
      host.statusFails = false;
      host.receiptResponse['receipt']['action_id'] = 'action-1';
      host.statusResponse = {
        ...host.statusResponse,
        'running': false,
        'pid': 41,
        'action_id': 'action-1',
        'exit_code': 0,
      };
      await tester.tap(find.byTooltip('Check update progress'));
      await tester.pumpAndSettle();
      expect(
        find.text('The backend update completed successfully.'),
        findsOneWidget,
      );
      final settledReads = host.reads.length;
      await tester.pump(const Duration(seconds: 6));
      expect(host.reads, hasLength(settledReads));
      await tester.tap(find.byTooltip('Check for updates'));
      await tester.pumpAndSettle();
      await openConfirmation(tester);
      host.pendingCheck = Completer<Map<String, dynamic>>();
      await tester.tap(find.byTooltip('Update backend').last);
      await tester.pump();
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Update logs'), findsOneWidget);
      // Late work after departure cannot publish another snapshot or schedule reads.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('route owner disposal retires held automatic status', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await check(tester);
    await openConfirmation(tester);
    final held = Completer<Map<String, dynamic>>();
    host.pendingStatus = held;
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();
    final controller = tester
        .widget<BackendVersionCard>(find.byType(BackendVersionCard))
        .updateController;
    var notifications = 0;
    controller.addListener(() => notifications++);
    await tester.pumpWidget(const SizedBox.shrink());
    final before = notifications;
    final reads = host.reads.length;
    held.complete({
      ...host.statusResponse,
      'lines': ['Late output'],
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(notifications, before);
    expect(host.reads, hasLength(reads));
    expect(find.text('Late output'), findsNothing);
  });

  testWidgets('fresh check can refuse a previously advertised update', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await check(tester);
    host.checkResponse = {
      ..._available,
      'update_available': false,
      'behind': 0,
    };
    await openConfirmation(tester);
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();

    expect(host.posts, isEmpty);
    expect(
      find.text('The server reports no update is available.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'manual progress check retains ongoing state through disconnection',
    (tester) async {
      final host = _UpdateHost();
      await showCard(tester, host);
      await check(tester);
      await openConfirmation(tester);
      await tester.tap(find.byTooltip('Update backend').last);
      await tester.pumpAndSettle();
      host.statusFails = true;

      await tester.tap(find.byTooltip('Check update progress'));
      await tester.pumpAndSettle();

      expect(
        find.text('Update ongoing. Waiting for the server to reconnect.'),
        findsOneWidget,
      );
      expect(host.posts, hasLength(1));
    },
  );

  testWidgets('shows terminal outcome and expandable bounded output', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host);
    await check(tester);
    await openConfirmation(tester);
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();
    host.statusResponse = {
      'running': false,
      'pid': 41,
      'exit_code': 0,
      'action_id': 'action-1',
      'lines': ['Downloading', 'Applied core', 'Skipped optional'],
    };
    host.receiptResponse = {
      'receipt': {
        'pid': 41,
        'finished_at': '2026-09-12T12:00:00Z',
        'outcome': 'partial',
        'action_id': 'action-1',
      },
      'summary': 'partial',
    };

    await tester.tap(find.byTooltip('Check update progress'));
    await tester.pumpAndSettle();

    expect(
      find.text('The backend update completed only partially.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Update logs'));
    await tester.pumpAndSettle();
    expect(
      find.text('Skipped optional\nApplied core\nDownloading'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(
        SelectableText,
        'Skipped optional\nApplied core\nDownloading',
      ),
      findsOneWidget,
    );
  });

  testWidgets('confirmation cannot cross the retained connection owner', (
    tester,
  ) async {
    final first = _UpdateHost();
    final second = _UpdateHost();
    final firstController = BackendUpdateController(
      first.gateway,
      store: first.source.updates,
    );
    final secondController = BackendUpdateController(
      second.gateway,
      store: second.source.updates,
    );
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);
    late StateSetter replace;
    var current = first;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Scaffold(body: child),
        home: StatefulBuilder(
          builder: (context, setState) {
            replace = setState;
            return BackendVersionCard(
              updateController: current == first
                  ? firstController
                  : secondController,
              connectionLabel: current == first ? 'First host' : 'Second host',
            );
          },
        ),
      ),
    );
    await check(tester);
    await openConfirmation(tester);

    replace(() => current = second);
    await tester.pump();
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();

    expect(first.posts, isEmpty);
    expect(second.posts, isEmpty);
  });

  testWidgets('external controller remains parent-owned after card disposal', (
    tester,
  ) async {
    final host = _UpdateHost();
    final external = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(external.dispose);
    await external.checkForUpdate();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Scaffold(body: child),
        home: BackendVersionCard(updateController: external),
      ),
    );
    expect(find.text('1.2.3'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    void listener() {}
    expect(() => external.addListener(listener), returnsNormally);
    external.removeListener(listener);
  });

  testWidgets('confirmation cannot start a replacement external controller', (
    tester,
  ) async {
    final first = _UpdateHost();
    final second = _UpdateHost();
    final firstController = BackendUpdateController(
      first.gateway,
      store: first.source.updates,
    );
    final secondController = BackendUpdateController(
      second.gateway,
      store: second.source.updates,
    );
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);
    late StateSetter replace;
    var currentController = firstController;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Scaffold(body: child),
        home: StatefulBuilder(
          builder: (context, setState) {
            replace = setState;
            return BackendVersionCard(updateController: currentController);
          },
        ),
      ),
    );
    await check(tester);
    await openConfirmation(tester);

    replace(() {
      currentController = secondController;
    });
    await tester.pump();
    await tester.tap(find.byTooltip('Update backend').last);
    await tester.pumpAndSettle();

    expect(first.posts, isEmpty);
    expect(second.posts, isEmpty);
  });

  testWidgets(
    'late check response cannot cross retained connection ownership',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final first = _UpdateHost()..pendingCheck = pending;
      final second = _UpdateHost()
        ..checkResponse = {..._available, 'current_version': '4.5.6'};
      final firstController = BackendUpdateController(
        first.gateway,
        store: first.source.updates,
      );
      final secondController = BackendUpdateController(
        second.gateway,
        store: second.source.updates,
      );
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => Scaffold(body: child),
          home: BackendVersionCard(updateController: firstController),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => Scaffold(body: child),
          home: BackendVersionCard(updateController: secondController),
        ),
      );
      pending.complete(_available);
      await tester.pump();

      expect(find.text('1.2.3'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('4.5.6'), findsOneWidget);
    },
  );

  testWidgets('disposed card ignores a late check response', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    final host = _UpdateHost()..pendingCheck = pending;
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Scaffold(body: child),
        home: BackendVersionCard(updateController: controller),
      ),
    );
    await tester.pump();
    expect(find.text('Checking for updates…'), findsNothing);
    expect(find.text('Checking…'), findsNothing);
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Check for updates',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Check for updates'), findsNothing);
    expect(find.byTooltip('Check for updates'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(_available);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('actions remain usable on a narrow large-text phone', (
    tester,
  ) async {
    final host = _UpdateHost();
    await showCard(tester, host, size: const Size(320, 640), textScale: 2);
    await check(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('Update backend'));
    await tester.pumpAndSettle();
    await openConfirmation(tester);
    expect(find.text('Update backend on Production host?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
