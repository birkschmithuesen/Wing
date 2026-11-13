import 'support/form_family_capture.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/screens/administration/admin_profiles_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/models/profiles_management.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profiles_management_session.dart';

typedef _Read = Future<Map<String, dynamic>> Function(String path);

class _Rig {
  final names = <String, String>{
    'default': 'Shared root',
    'work': 'Work',
    'personal': 'Personal',
  };
  final flags = <String, bool>{};
  final writes = <(String, String, Map<String, dynamic>)>[];
  final opens = <String>[];
  int closes = 0, reads = 0;
  _Read? read;
  AdministrationMutation? mutation;
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>)?
  response;
  Future<bool> Function(String)? open;

  Map<String, dynamic> roster() => {
    'profiles': [
      for (final entry in names.entries)
        {
          'name': entry.key,
          'display_name': entry.value,
          'is_default': flags[entry.key] ?? entry.key == 'default',
        },
    ],
  };

  late final server = AdministrationRepository(
    connectionId: 'captured-connection',
    connectionIdentity: 'captured-endpoint',
    connectionLabel: 'Captured server',
    request: (method, path, query, body) async {
      expect(method, 'GET');
      expect(query, isEmpty);
      expect(body, isNull);
      reads++;
      if (read case final override?) return override(path);
      if (path == 'profiles') return roster();
      if (path == 'profiles/active') {
        return {'current': 'default', 'active': 'work'};
      }
      throw StateError('Unexpected read');
    },
    ownedMutation:
        (method, path, query, body, canDispatch, onDispatched) async {
          expect(query, isEmpty);
          if (mutation case final override?) {
            return override(
              method,
              path,
              query,
              body,
              canDispatch,
              onDispatched,
            );
          }
          if (!canDispatch()) {
            throw DashboardRequestNotSentException(
              StateError('Retired fixture'),
            );
          }
          onDispatched();
          writes.add((method, path, Map.of(body)));
          if (response case final override?) {
            return override(method, path, body);
          }
          return acknowledge(method, path, body);
        },
    settingsWrite: (_, _, _, _) =>
        throw StateError('Unexpected settings write'),
    gateway: (_) => throw StateError('Unexpected gateway'),
    close: () => closes++,
  );

  ProfilesManagementSession session() => ProfilesManagementSession(
    server: server,
    openProfile: (name) async {
      opens.add(name);
      return open == null ? true : open!(name);
    },
  );

  Map<String, dynamic> acknowledge(
    String method,
    String path,
    Map<String, dynamic> body,
  ) {
    if (method == 'POST') {
      final name = body['name'] as String;
      names[name] = name;
      return {'ok': true, 'name': name, 'path': '/fixture/$name'};
    }
    final original = path.substring('profiles/'.length);
    if (method == 'DELETE') {
      names.remove(original);
      return {'ok': true, 'path': '/fixture/$original'};
    }
    expect(method, 'PATCH');
    final name = body['new_name'] as String;
    if (original == 'default') {
      names['default'] = name;
      return {
        'ok': true,
        'name': 'default',
        'display_name': name,
        'path': '/fixture/default',
      };
    }
    names.remove(original);
    names[name] = name;
    return {'ok': true, 'name': name, 'path': '/fixture/$name'};
  }
}

void main() {
  setUpAll(loadFormFamilyFonts);
  late _Rig rig;
  late ProfilesManagementSession session;
  setUp(() {
    rig = _Rig();
    session = rig.session();
  });
  tearDown(() => session.dispose());

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'profile form retains failed name and held save ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
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
                home: AdminProfilesPage(createSession: () => session),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Create profile'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'studio');
          await tester.pump();
          await captureFormFamily(
            tester,
            'profile-${brightness.name}-$scale-normal',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pumpAndSettle();
          await captureFormFamily(
            tester,
            'profile-${brightness.name}-$scale-keyboard',
          );
          final save = find.byKey(const ValueKey('profile-name-save'));
          final gate = Completer<Map<String, dynamic>>();
          var attempts = 0;
          rig.mutation =
              (method, path, query, body, canDispatch, onDispatched) async {
                attempts++;
                return gate.future;
              };
          await tester.tap(save);
          await tester.pump();
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.getSize(save), const Size(48, 48));
          expect(tester.getRect(save).bottom, lessThanOrEqualTo(584));
          expect(find.bySemanticsLabel('Saving profile'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 200));
          await captureFormFamily(
            tester,
            'profile-${brightness.name}-$scale-saving',
          );
          expect(tester.widget<IconButton>(save).onPressed, isNull);
          await tester.binding.handlePopRoute();
          await tester.pump();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(attempts, 1);
          gate.completeError(
            DashboardRequestNotSentException(StateError('Held write not sent')),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'studio',
          );
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('Your profile name is kept'),
            ),
            findsOneWidget,
          );
          expect(tester.widget<IconButton>(save).onPressed, isNotNull);
          await captureFormFamily(
            tester,
            'profile-${brightness.name}-$scale-failure',
          );
          rig.mutation = null;
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(rig.writes, hasLength(1));
          expect(rig.writes.single.$3['name'], 'studio');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'uncertain profile write keeps owner admission and can close editor for recovery',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AdminProfilesPage(createSession: () => session)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Create profile'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'studio');
      rig.mutation =
          (method, path, query, body, canDispatch, onDispatched) async {
            onDispatched();
            rig.writes.add((method, path, Map.of(body)));
            throw StateError('Unconfirmed response');
          };
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile-name-save')));
      await tester.pumpAndSettle();
      expect(session.state.draft!.canSubmit, isFalse);
      expect(session.state.draft!.canCancel, isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'studio',
      );
      expect(find.textContaining('Refresh the list'), findsWidgets);
      await tester.tap(find.byTooltip('Close editor'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(session.pendingIntent, isNotNull);
      await session.reload();
      await tester.pumpAndSettle();
      expect(rig.writes, hasLength(1));
      expect(session.state.draft!.canSubmit, isFalse);
    },
  );
  test(
    'borrowed connection closes only after its one route lease releases',
    () async {
      await session.reload();
      rig.server.close();
      expect(rig.closes, 0);
      session.dispose();
      expect(rig.closes, 1);
    },
  );

  test(
    'admitted write keeps its own lease after route retirement until settlement',
    () async {
      await session.reload();
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      late bool Function() authority;
      rig.mutation = (method, path, query, body, active, dispatched) {
        authority = active;
        expect(active(), isTrue);
        dispatched();
        rig.writes.add((method, path, Map.of(body)));
        entered.complete();
        return held.future;
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final pending = session.submit(intent);
      await entered.future;
      expect(rig.writes, hasLength(1));
      var changes = 0;
      session.addListener(() => changes++);
      rig.server.close();
      session.dispose();
      expect(rig.closes, 0);
      expect(authority(), isFalse);
      held.complete({'ok': true, 'name': 'studio', 'path': '/fixture/studio'});
      expect((await pending)!.kind, ProfilesManagementOutcomeKind.confirmed);
      expect(rig.closes, 1);
      expect(rig.writes, hasLength(1));
      expect(changes, 0);
    },
  );

  test('reentrant reservation cannot start a second command or open', () async {
    await session.reload();
    var callbacks = 0;
    session.addListener(() {
      callbacks++;
      expect(session.beginClone('work'), isNull);
      expect(session.beginDelete('work'), isNull);
    });
    final intent = session.beginCreate();
    expect(intent, isNotNull);
    expect(callbacks, 1);
    expect(session.pendingIntent, same(intent));
    expect(session.state.busy, isFalse);
    expect(session.state.canCreate, isFalse);
    expect(session.state.canOpen, isFalse);
    expect(rig.writes, isEmpty);
  });

  test(
    'reentrant submission retirement revokes authority and still releases the lease',
    () async {
      await session.reload();
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      rig.server.close();
      session.addListener(() {
        session.dispose();
        expect(rig.closes, 0);
      });
      await session.submit(intent);
      expect(rig.writes, isEmpty);
      expect(rig.closes, 1);
    },
  );

  for (final operation in [
    'create',
    'clone',
    'rename',
    'default rename',
    'delete',
  ]) {
    test(
      '$operation captures the exact stock request and acknowledgement',
      () async {
        await session.reload();
        final intent = switch (operation) {
          'create' => session.beginCreate(),
          'clone' => session.beginClone('work'),
          'rename' => session.beginRename('work'),
          'default rename' => session.beginRename('default'),
          _ => session.beginDelete('work'),
        };
        expect(intent, isNotNull);
        if (operation != 'delete') {
          session.updateName(
            intent!,
            operation == 'default rename' ? 'My shared account' : 'studio',
          );
        }
        final outcome = await session.submit(intent!);
        expect(rig.writes, hasLength(1));
        final write = rig.writes.single;
        expect(
          write.$1,
          operation == 'delete'
              ? 'DELETE'
              : operation.contains('rename')
              ? 'PATCH'
              : 'POST',
        );
        expect(
          write.$2,
          operation == 'create' || operation == 'clone'
              ? 'profiles'
              : operation == 'default rename'
              ? 'profiles/default'
              : 'profiles/work',
        );
        expect(
          write.$3,
          operation == 'delete'
              ? {}
              : operation.contains('rename')
              ? {
                  'new_name': operation == 'default rename'
                      ? 'My shared account'
                      : 'studio',
                }
              : {
                  'name': 'studio',
                  if (operation == 'clone') 'clone_from': 'work',
                  'clone_all': false,
                  'clone_channels': false,
                },
        );
        expect(outcome!.kind, ProfilesManagementOutcomeKind.confirmed);
        expect(session.pendingIntent, isNull);
        expect(session.state.canCreate, isTrue);
        expect(
          session.state.rows.any((row) => row.name == outcome.target),
          operation != 'delete',
        );
      },
    );
  }

  test(
    'canonical default identity protects deletion despite contradictory flags',
    () async {
      rig.flags.addAll({'default': false, 'work': true});
      await session.reload();
      expect(session.beginDelete('default'), isNull);
      expect(
        session.state.rows
            .singleWhere((row) => row.name == 'default')
            .canDelete,
        isFalse,
      );
      expect(
        session.state.rows.singleWhere((row) => row.name == 'work').canDelete,
        isTrue,
      );
      final intent = session.beginRename('default')!;
      session.updateName(intent, 'Uppercase display name with spaces');
      expect(session.state.draft!.canContinue, isTrue);
      expect(
        (await session.submit(intent))!.kind,
        ProfilesManagementOutcomeKind.confirmed,
      );
      expect(rig.writes.single.$2, 'profiles/default');
    },
  );

  test(
    'opaque draft occupancy is reserved before any dialog and cancelled explicitly',
    () async {
      await session.reload();
      final intent = session.beginCreate()!;
      expect(session.beginClone('work'), isNull);
      expect(session.beginRename('work'), isNull);
      expect(session.beginDelete('work'), isNull);
      expect(await session.open('work'), isFalse);
      expect(rig.writes, isEmpty);
      session.cancel(intent);
      final successor = session.beginClone('work')!;
      session.updateName(intent, 'stale');
      expect(await session.submit(intent), isNull);
      expect(session.pendingIntent, same(successor));
      expect(session.state.draft!.initialName, '');
    },
  );

  for (final invalid in ['', 'current', 'Has spaces', '-bad', 'x' * 65]) {
    test(
      'invalid canonical create name is never sent: ${invalid.length}',
      () async {
        await session.reload();
        final intent = session.beginCreate()!;
        session.updateName(intent, invalid);
        expect(session.state.draft!.canContinue, isFalse);
        expect(await session.submit(intent), isNull);
        expect(rig.writes, isEmpty);
      },
    );
  }

  for (final cloneDefault in [false, true]) {
    test(
      'fresh duplicate target refuses ${cloneDefault ? 'default clone' : 'create'}',
      () async {
        await session.reload();
        final intent = cloneDefault
            ? session.beginClone('default')!
            : session.beginCreate()!;
        session.updateName(intent, 'studio');
        rig.names['studio'] = 'Another client created this';
        final outcome = await session.submit(intent);
        expect(rig.writes, isEmpty);
        expect(outcome!.kind, ProfilesManagementOutcomeKind.rejected);
        expect(session.state.draft!.initialName, 'studio');
      },
    );
  }

  test(
    'clone source disappearance before dispatch cannot retarget default',
    () async {
      await session.reload();
      final intent = session.beginClone('work')!;
      session.updateName(intent, 'studio');
      rig.names.remove('work');
      final outcome = await session.submit(intent);
      expect(rig.writes, isEmpty);
      expect(outcome!.kind, ProfilesManagementOutcomeKind.rejected);
    },
  );

  test('refresh never rebases a default display-name intent', () async {
    await session.reload();
    final intent = session.beginRename('default')!;
    session.updateName(intent, 'My intended name');
    rig.names['default'] = 'Other client changed this';
    await session.reload();
    expect(session.state.draft!.initialName, 'My intended name');
    final outcome = await session.submit(intent);
    expect(rig.writes, isEmpty);
    expect(outcome!.kind, ProfilesManagementOutcomeKind.rejected);
  });

  test(
    'held preflight retired by route closure makes zero mutation calls',
    () async {
      await session.reload();
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      rig.read = (path) async {
        if (path == 'profiles') {
          entered.complete();
          return held.future;
        }
        return {'current': 'default'};
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final pending = session.submit(intent);
      await entered.future;
      expect(rig.writes, isEmpty);
      session.dispose();
      held.complete(rig.roster());
      await pending;
      expect(rig.writes, isEmpty);
    },
  );

  for (final renew in [false, true]) {
    test(
      'real ${renew ? '401 renewal' : 'initial auth'} rejects retired physical write',
      () async {
        await session.reload();
        final entered = Completer<void>();
        final held = Completer<http.Response>();
        var logins = 0, writes = 0, dispatches = 0;
        final client = DashboardClient(
          host: 'fixture.invalid',
          httpClient: MockClient((request) async {
            if (request.url.path == '/') {
              if (++logins == (renew ? 2 : 1)) {
                entered.complete();
                return held.future;
              }
              return http.Response(
                'window.__HERMES_SESSION_TOKEN__="fixture-token";',
                200,
              );
            }
            expect(request.method, 'POST');
            expect(request.url.path, '/api/profiles');
            writes++;
            return http.Response('{}', 401);
          }),
        );
        addTearDown(client.close);
        rig.mutation = (method, path, query, body, active, dispatched) =>
            client.apiWriteOwned(
              method,
              path,
              body: body,
              canDispatch: active,
              onDispatched: () {
                dispatches++;
                dispatched();
              },
            );
        final intent = session.beginCreate()!;
        session.updateName(intent, 'studio');
        final pending = session.submit(intent);
        await entered.future;
        expect(writes, renew ? 1 : 0);
        session.dispose();
        held.complete(
          http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            200,
          ),
        );
        final outcome = await pending;
        expect(writes, renew ? 1 : 0);
        expect(dispatches, renew ? 1 : 0);
        expect(
          outcome!.kind,
          renew
              ? ProfilesManagementOutcomeKind.uncertain
              : ProfilesManagementOutcomeKind.notSent,
        );
      },
    );
  }

  test(
    'settled pre-dispatch failure revokes old callback even when retry uses same intent',
    () async {
      await session.reload();
      final held = Completer<Map<String, dynamic>>();
      final entered = Completer<void>();
      late bool Function() oldAuthority;
      rig.mutation = (_, _, _, _, active, _) {
        oldAuthority = active;
        entered.complete();
        return held.future;
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final pending = session.submit(intent);
      await entered.future;
      held.completeError(
        TimeoutException('Held fixture rejected before dispatch'),
      );
      expect((await pending)!.kind, ProfilesManagementOutcomeKind.notSent);
      expect(oldAuthority(), isFalse);
      expect(session.state.draft!.canSubmit, isTrue);
      rig.mutation = null;
      expect(
        (await session.submit(intent))!.kind,
        ProfilesManagementOutcomeKind.confirmed,
      );
      expect(rig.writes, hasLength(1));
      expect(oldAuthority(), isFalse);
    },
  );

  test(
    'ACK after disposal settles honestly without readback or publication',
    () async {
      await session.reload();
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      rig.response = (_, _, _) {
        entered.complete();
        return held.future;
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final pending = session.submit(intent);
      await entered.future;
      expect(rig.writes, hasLength(1));
      final reads = rig.reads;
      var changes = 0;
      session.addListener(() => changes++);
      session.dispose();
      held.complete({'ok': true, 'name': 'studio', 'path': '/fixture/studio'});
      expect((await pending)!.kind, ProfilesManagementOutcomeKind.confirmed);
      expect(rig.reads, reads);
      expect(changes, 0);
    },
  );

  for (final (index, ack) in [
    {'ok': true, 'name': 'personal', 'path': '/fixture/personal'},
    {'name': 'studio', 'path': '/fixture/studio'},
    {'ok': true, 'name': 'studio'},
    {'ok': true, 'name': 'studio', 'path': 42},
    {'ok': true, 'name': 'studio', 'path': ''},
  ].indexed) {
    test('malformed create ACK $index cannot confirm or resend', () async {
      await session.reload();
      rig.response = (_, _, _) async => ack;
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      expect(
        (await session.submit(intent))!.kind,
        ProfilesManagementOutcomeKind.uncertain,
      );
      expect(rig.writes, hasLength(1));
      expect(await session.submit(intent), isNull);
      await session.reload();
      expect(rig.writes, hasLength(1));
      expect(session.state.error, contains('could not be confirmed'));
      expect(session.state.draft!.initialName, 'studio');
      expect(session.state.draft!.canSubmit, isFalse);
      expect(session.state.draft!.canCancel, isFalse);
    });
  }

  test(
    'default rename ACK must identify default and the captured display name',
    () async {
      await session.reload();
      rig.response = (_, _, _) async => {
        'ok': true,
        'name': 'default',
        'display_name': 'Another name',
        'path': '/fixture/default',
      };
      final intent = session.beginRename('default')!;
      session.updateName(intent, 'My name');
      expect(
        (await session.submit(intent))!.kind,
        ProfilesManagementOutcomeKind.uncertain,
      );
      expect(rig.writes.single.$2, 'profiles/default');
    },
  );

  test(
    'confirmed create and retained roster survive a failed refresh without replay',
    () async {
      await session.reload();
      rig.read = (path) async {
        if (path == 'profiles') return rig.roster();
        if (rig.writes.isNotEmpty) throw StateError('Fixture unavailable');
        return {'current': 'default'};
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final outcome = await session.submit(intent);
      expect(rig.writes, hasLength(1));
      expect(outcome!.kind, ProfilesManagementOutcomeKind.confirmed);
      expect(
        session.state.outcome!.kind,
        ProfilesManagementOutcomeKind.confirmedRefreshFailed,
      );
      expect(session.state.outcome!.announcesSuccess, isTrue);
      expect(session.state.rows.map((row) => row.name), [
        'default',
        'personal',
        'work',
      ]);
      expect(session.state.canCreate, isTrue);
      rig.read = null;
      await session.reload();
      expect(rig.writes, hasLength(1));
      expect(session.state.rows.any((row) => row.name == 'studio'), isTrue);
      expect(session.state.error, isNull);
    },
  );

  test(
    'superseded failed post-ACK read cannot replace a newer healthy roster',
    () async {
      await session.reload();
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      var intercepted = false;
      rig.read = (path) async {
        if (path == 'profiles') {
          if (rig.writes.isNotEmpty && !intercepted) {
            intercepted = true;
            entered.complete();
            return held.future;
          }
          return rig.roster();
        }
        return {'current': 'default'};
      };
      final intent = session.beginCreate()!;
      session.updateName(intent, 'studio');
      final pending = session.submit(intent);
      await entered.future;
      expect(
        session.state.outcome!.kind,
        ProfilesManagementOutcomeKind.confirmed,
      );
      rig.names['external'] = 'Concurrent profile';
      await session.reload();
      held.completeError(const FormatException('Older read failed'));
      await pending;
      expect(rig.writes, hasLength(1));
      expect(session.state.rows.any((row) => row.name == 'external'), isTrue);
      expect(session.state.error, isNull);
      expect(
        session.state.outcome!.kind,
        ProfilesManagementOutcomeKind.confirmed,
      );
    },
  );

  test(
    'pending deletion settlement persists through Reload and unrelated commands',
    () async {
      await session.reload();
      rig.response = (method, path, body) async {
        if (method != 'DELETE') return rig.acknowledge(method, path, body);
        rig.names.remove('work');
        return {
          'ok': true,
          'path': '/fixture/work',
          'identity_settled': false,
          'settlement_pending': true,
          'retry_command': 'hermes profile delete work --yes',
        };
      };
      final outcome = await session.submit(session.beginDelete('work')!);
      expect(
        outcome!.kind,
        ProfilesManagementOutcomeKind.deletedSettlementPending,
      );
      expect(session.state.settlements.single.target, 'work');
      await session.reload();
      expect(rig.writes.where((write) => write.$1 == 'DELETE'), hasLength(1));
      expect(session.state.rows.any((row) => row.name == 'work'), isFalse);
      final create = session.beginCreate()!;
      session.updateName(create, 'work');
      expect(session.state.draft!.canContinue, isFalse);
      expect(await session.submit(create), isNull);
      session.updateName(create, 'studio');
      expect(
        (await session.submit(create))!.kind,
        ProfilesManagementOutcomeKind.confirmed,
      );
      await session.reload();
      expect(
        session.state.settlements.single.manualGuidance,
        'hermes profile delete work --yes',
      );
      expect(rig.writes.where((write) => write.$1 == 'DELETE'), hasLength(1));
    },
  );

  for (final (index, fields) in [
    {'settlement_pending': true},
    {
      'settlement_pending': true,
      'identity_settled': true,
      'retry_command': 'manual',
    },
    {
      'settlement_pending': true,
      'identity_settled': false,
      'retry_command': '',
    },
    {
      'settlement_pending': false,
      'identity_settled': false,
      'retry_command': 'manual',
    },
    {'identity_settled': false},
  ].indexed) {
    test('malformed pending settlement $index stays uncertain', () async {
      await session.reload();
      rig.response = (_, _, _) async => {
        'ok': true,
        'path': '/fixture/work',
        ...fields,
      };
      final intent = session.beginDelete('work')!;
      expect(
        (await session.submit(intent))!.kind,
        ProfilesManagementOutcomeKind.uncertain,
      );
      expect(session.state.settlements, isEmpty);
      expect(await session.submit(intent), isNull);
      expect(rig.writes, hasLength(1));
    });
  }

  test(
    'open delegates only a freshly present captured canonical identity',
    () async {
      await session.reload();
      expect(await session.open('work'), isTrue);
      expect(rig.opens, ['work']);
      rig.names.remove('personal');
      expect(await session.open('personal'), isFalse);
      expect(rig.opens, ['work']);
    },
  );

  test(
    'retired held open discovery never invokes the workspace callback',
    () async {
      await session.reload();
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      rig.read = (path) async {
        if (path == 'profiles') {
          entered.complete();
          return held.future;
        }
        return {'current': 'default'};
      };
      final pending = session.open('work');
      await entered.future;
      session.dispose();
      held.complete(rig.roster());
      expect(await pending, isFalse);
      expect(rig.opens, isEmpty);
    },
  );
}
