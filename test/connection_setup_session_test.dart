import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/connection_setup.dart';
import 'package:wing/core/models/dashboard_oauth_grant.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/connection_setup_probe.dart';
import 'package:wing/core/services/dashboard_oauth_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';

import 'support/connection_probe_fixture.dart';

const _instance = CloudInstance(
  id: 'one',
  name: 'Cloud one',
  state: 'running',
  dashboardUrl: 'https://cloud.example',
);
DashboardOAuthSession _owner() => DashboardOAuthSession(
  DashboardOAuthGrant(
    id: 'synthetic',
    baseUrl: _instance.dashboardUrl!,
    accessToken: 'synthetic-access',
    refreshToken: 'synthetic-refresh',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  ),
);

class _Cloud extends HermesCloud {
  CloudDiscovery result = const CloudDiscovery(instances: [_instance]);
  Completer<CloudDiscovery?>? discovery;
  Completer<DashboardOAuthSession?>? authorization;
  Completer<void>? cancellation;
  int signIns = 0;
  @override
  Future<CloudDiscovery?> discover({
    String? organization,
    bool switchAccount = false,
  }) async => discovery?.future ?? result;
  @override
  Future<DashboardOAuthSession?> signIn(CloudInstance instance) async {
    signIns++;
    return authorization?.future ?? _owner();
  }

  @override
  Future<void> cancel() async {
    await cancellation?.future;
  }

  @override
  void close() {}
}

void main() {
  late _Cloud cloud;
  late ConnectionProbeFixture probe;
  late ConnectionSetupSession session;
  late DateTime now;
  final writes = <SavedConnection>[];
  ConnectionAccess? checked;
  ConnectionSetupSession create({
    ConnectionAccess? initial,
    Future<SavedConnection> Function(SavedConnection)? save,
  }) => ConnectionSetupSession(
    initialAccess: initial,
    now: () => now,
    savedConnections: () => const [],
    cloud: cloud,
    createProbe: (access) {
      checked = access;
      return probe;
    },
    onSave:
        save ??
        (candidate) async {
          writes.add(candidate);
          return candidate;
        },
    onSaveIcon: initial == null ? null : (_) async {},
  );
  final disposedSessions = <ConnectionSetupSession>{};
  void disposeSession() {
    if (disposedSessions.add(session)) session.dispose();
  }

  setUp(() {
    disposedSessions.clear();
    now = DateTime.utc(2026, 11, 7, 12);
    cloud = _Cloud();
    probe = ConnectionProbeFixture();
    writes.clear();
    checked = null;
    session = create();
  });
  tearDown(() {
    if (!disposedSessions.contains(session)) disposeSession();
  });
  void local() {
    session.chooseSource(cloud: false);
    session.editAddress('https://hermes.example/agent/');
    expect(session.continueAddress(), isTrue);
    session.editUsername(' alex ');
    session.editPassword(' exact synthetic password ');
  }

  Future<void> cloudReady() async {
    session.chooseSource(cloud: true);
    await session.continueCloud();
    session.selectInstance(_instance.id);
  }

  test(
    'swipe cards use validation and verified transitions without bypassing save',
    () async {
      session.chooseSource(cloud: false);
      expect(session.value.cards, [ConnectionSetupStep.address]);
      session.selectCard(ConnectionSetupStep.signIn);
      expect(session.value.step, ConnectionSetupStep.address);
      session.editAddress('https://hermes.example');
      expect(session.value.cards, [
        ConnectionSetupStep.address,
        ConnectionSetupStep.signIn,
      ]);
      session.selectCard(ConnectionSetupStep.review);
      expect(session.value.step, ConnectionSetupStep.address);
      session.selectCard(ConnectionSetupStep.signIn);
      session.editUsername('alex');
      session.editPassword('password');
      session.selectCard(ConnectionSetupStep.review);
      expect(session.value.step, ConnectionSetupStep.signIn);
      await session.check();
      session.selectCard(ConnectionSetupStep.review);
      expect(session.value.step, ConnectionSetupStep.review);
      expect(writes, isEmpty);
      session.selectCard(ConnectionSetupStep.signIn);
      expect(session.value.check.verified, isTrue);
      session.editPassword('replacement');
      expect(session.value.cards, isNot(contains(ConnectionSetupStep.review)));
    },
  );

  test('a swipe can return from review directly to the address', () async {
    local();
    await session.check();
    session.continueVerified();
    expect(session.value.step, ConnectionSetupStep.review);
    session.selectCard(ConnectionSetupStep.address);
    expect(session.value.step, ConnectionSetupStep.address);
    expect(session.value.check.verified, isTrue);
    expect(session.value.draft.username, ' alex ');
    expect(writes, isEmpty);
  });

  test(
    'recent checks survive repeated card navigation without new probes',
    () async {
      local();
      await session.check();
      now = now.add(const Duration(minutes: 4, seconds: 59));
      session.selectCard(ConnectionSetupStep.address);
      expect(session.value.check.verified, isTrue);
      session.selectCard(ConnectionSetupStep.signIn);
      session.selectCard(ConnectionSetupStep.review);
      session.selectCard(ConnectionSetupStep.address);
      session.selectCard(ConnectionSetupStep.review);
      expect(session.value.step, ConnectionSetupStep.review);
      expect(session.value.check.verified, isTrue);
      expect(probe.calls, ConnectionCheck.values);
      // Navigation must not extend the original result's age.
      now = now.add(const Duration(seconds: 1));
      await session.back();
      expect(session.value.step, ConnectionSetupStep.signIn);
      expect(session.value.check.verified, isFalse);
      expect(session.value.canAdvance, isFalse);
      expect(
        session.value.check.statuses.values,
        everyElement(ConnectionCheckStatus.waiting),
      );
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.signIn);
    },
  );

  test(
    'expired results cannot advance or save and a new check renews them',
    () async {
      local();
      await session.check();
      now = now.add(const Duration(minutes: 5));
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.signIn);
      expect(session.value.check.verified, isFalse);
      await session.check();
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.review);
      now = now.add(const Duration(minutes: 5));
      await session.save();
      expect(writes, isEmpty);
      expect(session.value.step, ConnectionSetupStep.signIn);
      expect(session.value.check.verified, isFalse);
      await session.check();
      session.continueVerified();
      await session.save();
      expect(writes, hasLength(1));
    },
  );

  test(
    'failed results survive navigation but connection edits retire them',
    () async {
      local();
      probe.failAt = ConnectionCheck.chat;
      await session.check();
      final error = session.value.check.error;
      session.selectCard(ConnectionSetupStep.address);
      now = now.add(const Duration(minutes: 4));
      session.selectCard(ConnectionSetupStep.signIn);
      expect(session.value.check.error, error);
      expect(
        session.value.check.statuses[ConnectionCheck.chat],
        ConnectionCheckStatus.failed,
      );
      expect(session.value.canAdvance, isFalse);
      expect(probe.calls, [ConnectionCheck.profiles, ConnectionCheck.chat]);
      session.editPassword('replacement');
      expect(session.value.check.error, isNull);
      expect(
        session.value.check.statuses.values,
        everyElement(ConnectionCheckStatus.waiting),
      );
    },
  );

  test(
    'raw draft validation prevents probes and preserves exact password',
    () async {
      session.chooseSource(cloud: false);
      session.editAddress('http://localhost:8080');
      expect(session.continueAddress(), isFalse);
      await session.check();
      expect(probe.calls, isEmpty);
      local();
      await session.check();
      expect(
        checked!.connection.dashboardPassword,
        ' exact synthetic password ',
      );
      expect(checked!.connection.dashboardUsername, 'alex');
      expect(session.value.step, ConnectionSetupStep.signIn);
      expect(session.value.check.verified, isTrue);
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.review);
      expect(writes, isEmpty);
      await session.save();
      expect(writes.single.dashboardPassword, ' exact synthetic password ');
      expect(writes.single.dashboardPrefix, '/agent');
    },
  );

  test('held probe completion cannot verify a changed draft', () async {
    local();
    probe.discoveryGate = Completer();
    final check = session.check();
    session.editAddress('https://other.example');
    probe.discoveryGate!.complete(connectionDiscovery);
    await check;
    expect(session.value.check.verified, isFalse);
    session.continueVerified();
    await session.save();
    expect(writes, isEmpty);
  });

  test(
    'storage failure retains verified draft and retry does not repeat checks',
    () async {
      disposeSession();
      var attempts = 0;
      session = create(
        save: (candidate) async {
          if (++attempts == 1) throw StateError('private detail');
          writes.add(candidate);
          return candidate;
        },
      );
      local();
      await session.check();
      final calls = probe.calls.length;
      session.continueVerified();
      await session.save();
      expect(writes, isEmpty);
      expect(session.value.saveError, isNotNull);
      expect(session.value.saveError, isNot(contains('private detail')));
      await session.save();
      expect(writes.length, 1);
      expect(probe.calls.length, calls);
    },
  );

  test(
    'late authorization after back cannot adopt an owner or probe',
    () async {
      await cloudReady();
      cloud.authorization = Completer();
      final authorization = session.continueCloud();
      expect(await session.back(), ConnectionSetupBack.stay);
      final owner = _owner();
      cloud.authorization!.complete(owner);
      await authorization;
      expect(owner.isActive, isFalse);
      expect(probe.calls, isEmpty);
    },
  );

  test('dispose retires late authorization without notification', () async {
    await cloudReady();
    cloud.authorization = Completer();
    final authorization = session.continueCloud();
    disposeSession();
    final owner = _owner();
    cloud.authorization!.complete(owner);
    await authorization;
    expect(owner.isActive, isFalse);
    expect(probe.calls, isEmpty);
  });

  test(
    'saved registry owner is borrowed through check and never retired by route',
    () async {
      disposeSession();
      final owner = _owner();
      final saved = SavedConnection(
        id: 'saved',
        label: 'Saved',
        host: 'cloud.example',
        port: 443,
        useHttps: true,
        apiKey: '',
        cloudInstanceId: _instance.id,
        dashboardGrant: owner.currentGrant,
      );
      session = create(
        initial: ConnectionAccess(connection: saved, dashboardOAuth: owner),
      );
      await session.check();
      expect(identical(checked!.dashboardOAuth, owner), isTrue);
      disposeSession();
      expect(owner.isActive, isTrue);
      owner.retire();
    },
  );

  test(
    'changing provisional destination retires owner and invalidates verification',
    () async {
      await cloudReady();
      await session.continueCloud();
      final owner = checked!.dashboardOAuth!;
      session.chooseSource(cloud: false);
      expect(owner.isActive, isFalse);
      expect(session.value.check.verified, isFalse);
    },
  );

  test('late discovery after close cannot publish', () async {
    session.chooseSource(cloud: true);
    cloud.discovery = Completer();
    final read = session.continueCloud();
    disposeSession();
    cloud.discovery!.complete(const CloudDiscovery(instances: [_instance]));
    await read;
    expect(session.value.discovery, isNull);
  });

  test(
    'custom access resolution preserves existing secret rows and rejects stale modal',
    () {
      local();
      final edit = session.beginAccessEdit();
      expect(
        session.applyAccess(
          ConnectionSetupAccessInput(
            proxied: true,
            separateChat: true,
            chatAddress: 'https://chat.example/path/',
            headerEdits: GatewayHeaderEdit([
              const GatewayHeaderDraft(
                savedName: null,
                name: 'X-Access',
                value: 'synthetic-header',
              ),
            ]),
          ),
          edit: edit,
        ),
        isTrue,
      );
      expect(session.value.draft.access.chatUrl, 'https://chat.example/path');
      final input = ConnectionSetupAccessInput(
        proxied: false,
        separateChat: false,
        chatAddress: '',
        headerEdits: GatewayHeaderEdit(const []),
      );
      expect(session.applyAccess(input, edit: edit), isFalse);
      expect(session.value.draft.access.proxied, isTrue);
    },
  );

  test('late durable save after close cannot request navigation', () async {
    disposeSession();
    final committed = Completer<SavedConnection>();
    session = create(save: (_) => committed.future);
    local();
    await session.check();
    session.continueVerified();
    final save = session.save();
    final candidate = checked!.connection;
    disposeSession();
    committed.complete(candidate);
    await save;
    expect(session.value.leaving, isFalse);
  });
  test(
    'check entry closes synchronously before any provisional probe opens',
    () async {
      local();
      session.addListener(() {
        if (session.value.step == ConnectionSetupStep.signIn &&
            !disposedSessions.contains(session)) {
          disposeSession();
        }
      });
      await session.check();
      expect(probe.calls, isEmpty);
      expect(checked, isNull);
    },
  );

  test('save entry closes synchronously before storage is invoked', () async {
    local();
    await session.check();
    session.addListener(() {
      if (session.value.saving && !disposedSessions.contains(session)) {
        disposeSession();
      }
    });
    session.continueVerified();
    await session.save();
    expect(writes, isEmpty);
  });

  test(
    'saved cloud Continue checks the captured shared owner without sign-in',
    () async {
      disposeSession();
      final owner = _owner();
      final saved = SavedConnection(
        id: 'saved',
        label: 'Saved',
        host: 'cloud.example',
        port: 443,
        useHttps: true,
        apiKey: '',
        cloudInstanceId: _instance.id,
        dashboardGrant: owner.currentGrant,
      );
      session = create(
        initial: ConnectionAccess(connection: saved, dashboardOAuth: owner),
      );
      await session.continueCloud();
      expect(cloud.signIns, 0);
      expect(identical(checked!.dashboardOAuth, owner), isTrue);
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.review);
      disposeSession();
      expect(owner.isActive, isTrue);
      owner.retire();
    },
  );

  test(
    'held cancellation keeps admission closed until browser cancellation settles',
    () async {
      await cloudReady();
      cloud.authorization = Completer();
      cloud.cancellation = Completer();
      final signIn = session.continueCloud();
      final cancel = session.back();
      await session.continueCloud();
      expect(cloud.signIns, 1);
      expect(session.value.cloudBusy, isTrue);
      cloud.cancellation!.complete();
      await cancel;
      final oldOwner = _owner();
      cloud.authorization!.complete(oldOwner);
      await signIn;
      expect(oldOwner.isActive, isFalse);
      expect(probe.calls, isEmpty);
    },
  );

  test(
    'published check and discovery collections cannot be mutated by views',
    () async {
      await cloudReady();
      expect(
        () => session.value.discovery!.instances.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => session.value.check.statuses.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => session.value.organizations.add(
          const CloudOrganization('other', 'Other'),
        ),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'successful save retires the provisional owner at durable handoff',
    () async {
      await cloudReady();
      await session.continueCloud();
      final owner = checked!.dashboardOAuth!;
      expect(owner.isActive, isTrue);
      session.continueVerified();
      await session.save();
      expect(writes.length, 1);
      expect(owner.isActive, isFalse);
      expect(session.value.leaving, isTrue);
    },
  );

  test(
    'registry retirement after verification refuses save without exception or write',
    () async {
      disposeSession();
      final owner = _owner();
      final saved = SavedConnection(
        id: 'saved',
        label: 'Saved',
        host: 'cloud.example',
        port: 443,
        useHttps: true,
        apiKey: '',
        cloudInstanceId: _instance.id,
        dashboardGrant: owner.currentGrant,
      );
      session = create(
        initial: ConnectionAccess(connection: saved, dashboardOAuth: owner),
      );
      await session.check();
      owner.retire();
      session.continueVerified();
      await session.save();
      expect(writes, isEmpty);
      expect(session.value.step, ConnectionSetupStep.cloud);
      expect(session.value.cloudError, isNotNull);
    },
  );
  test(
    'held discovery cannot offer Open after saved destination is removed',
    () async {
      disposeSession();
      final saved = <SavedConnection>[
        SavedConnection(
          id: 'saved',
          label: 'Saved',
          host: 'cloud.example',
          port: 443,
          useHttps: true,
          apiKey: '',
          cloudInstanceId: _instance.id,
        ),
      ];
      session = ConnectionSetupSession(
        initialAccess: null,
        savedConnections: () => saved,
        cloud: cloud,
        createProbe: (access) {
          checked = access;
          return probe;
        },
        onSave: (candidate) async {
          writes.add(candidate);
          return candidate;
        },
        onSaveIcon: null,
      );
      session.chooseSource(cloud: true);
      cloud.discovery = Completer();
      final discovery = session.continueCloud();
      saved.clear();
      cloud.discovery!.complete(cloud.result);
      await discovery;
      session.selectInstance(_instance.id);
      expect(session.value.alreadySaved, isNull);
      await session.continueCloud();
      expect(session.value.leaving, isFalse);
      expect(cloud.signIns, 1);
      expect(session.value.check.verified, isTrue);
      session.continueVerified();
      expect(session.value.step, ConnectionSetupStep.review);
      expect(probe.connectedProfile?.name, 'work');
      expect(writes, isEmpty);
    },
  );

  test(
    'Open command rechecks membership after already-saved presentation',
    () async {
      disposeSession();
      final saved = <SavedConnection>[
        SavedConnection(
          id: 'saved',
          label: 'Saved',
          host: 'cloud.example',
          port: 443,
          useHttps: true,
          apiKey: '',
          cloudInstanceId: _instance.id,
        ),
      ];
      session = ConnectionSetupSession(
        initialAccess: null,
        savedConnections: () => saved,
        cloud: cloud,
        createProbe: (access) {
          checked = access;
          return probe;
        },
        onSave: (candidate) async {
          writes.add(candidate);
          return candidate;
        },
        onSaveIcon: null,
      );
      await cloudReady();
      expect(session.value.alreadySaved, isNotNull);
      saved.clear();
      await session.continueCloud();
      expect(session.value.leaving, isFalse);
      expect(cloud.signIns, 1);
      expect(writes, isEmpty);
    },
  );

  test(
    'failed saved Cloud check requests new sign-in without retiring saved owner',
    () async {
      disposeSession();
      final owner = _owner();
      final saved = SavedConnection(
        id: 'saved',
        label: 'Saved',
        host: 'cloud.example',
        port: 443,
        useHttps: true,
        apiKey: '',
        cloudInstanceId: _instance.id,
        dashboardGrant: owner.currentGrant,
      );
      session = create(
        initial: ConnectionAccess(connection: saved, dashboardOAuth: owner),
      );
      probe.failAt = ConnectionCheck.profiles;
      await session.check();
      session.editSignIn();
      probe.failAt = null;
      await session.continueCloud();
      expect(owner.isActive, isTrue);
      expect(cloud.signIns, 1);
      expect(identical(checked!.dashboardOAuth, owner), isFalse);
      disposeSession();
      expect(owner.isActive, isTrue);
      owner.retire();
    },
  );

  test('custom access ticket from another owner is rejected', () {
    local();
    final edit = session.beginAccessEdit();
    final other = create();
    expect(
      other.applyAccess(
        ConnectionSetupAccessInput(
          proxied: true,
          separateChat: false,
          chatAddress: '',
          headerEdits: GatewayHeaderEdit(const []),
        ),
        edit: edit,
      ),
      isFalse,
    );
    expect(other.value.draft.access.proxied, isFalse);
    other.dispose();
  });
}
