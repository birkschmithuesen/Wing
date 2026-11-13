import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/backend_update_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/backend_update_channel_fixture.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/backend_update.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/backend_update_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';

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
    'name': 'hermes-update',
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
      'outcome': 'success',
      'action_id': 'previous-action',
      'pid': 41,
      'finished_at': '2026-09-12T12:00:00Z',
    },
    'summary': {'outcome': 'success'},
  };
  Completer<Map<String, dynamic>>? pendingPost;
  Completer<Map<String, dynamic>>? pendingCheck;
  Completer<Map<String, dynamic>>? pendingStatus;
  bool postFails = false;
  bool statusFails = false;
  final reads = <(String, Map<String, String>)>[];
  final posts = <(String, Map<String, dynamic>)>[];

  late final gateway = ProfileGateway(
    scope: WorkspaceScope(connectionId: 'host', profileName: 'work'),
    get: (endpoint, query) async {
      reads.add((endpoint, query));
      if (endpoint == 'hermes/update/check' && source.refreshCache) {
        source.fetchedAt++;
      }
      final metadata = source.read(endpoint, query);
      if (metadata != null) return metadata;
      if (endpoint == 'actions/hermes-update/status' && statusFails) {
        throw TimeoutException('gateway restarting');
      }
      return switch (endpoint) {
        'health' => {
          'ok': true,
          'version': checkResponse['current_version'],
          'commit': BackendUpdateChannelFixture.currentSha,
        },
        'hermes/update/check' => pendingCheck?.future ?? checkResponse,
        'hermes/update/receipt' => receiptResponse,
        'actions/hermes-update/status' =>
          pendingStatus?.future ?? statusResponse,
        _ => throw StateError('Unexpected update read: $endpoint'),
      };
    },
    ownedPut: source.put,
    ownedPost: (endpoint, body, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Retired');
      onDispatched();
      posts.add((endpoint, body));
      if (postFails) throw TimeoutException('lost acknowledgement');
      return pendingPost?.future ?? postResponse;
    },
    rpc: (_, _) async => <String, dynamic>{},
    discover: () async => const ProfileDiscovery(
      profiles: [],
      currentName: null,
      activeName: null,
    ),
  );
}

class _AcceptanceWriteFailure extends InMemorySharedPreferencesStore {
  _AcceptanceWriteFailure() : super.empty();
  int writes = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (++writes == 2) return false;
    return super.setValue(type, key, value);
  }
}

Future<BackendUpdateController> _started(_UpdateHost host) async {
  final controller = BackendUpdateController(
    host.gateway,
    store: host.source.updates,
  );
  expect(
    await controller.startUpdate(
      approvedChannel: host.source.approved,
      canDispatch: () => true,
    ),
    isTrue,
  );
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('accepted update keeps following progress through an outage', (
    tester,
  ) async {
    final host = _UpdateHost()
      ..receiptResponse = {
        'receipt': {
          'action_id': 'action-1',
          'outcome': 'running',
          'pid': 41,
          'finished_at': null,
        },
      };
    final controller = await _started(host);
    addTearDown(controller.dispose);
    await tester.pump();
    host.statusFails = true;

    await controller.refreshStatus();

    expect(controller.requestOutstanding, isTrue);
    expect(controller.phase, BackendUpdatePhase.running);
    expect(
      controller.message,
      'Update ongoing. Waiting for the server to reconnect.',
    );
    final reads = host.reads.length;
    await tester.pump(const Duration(seconds: 3));
    expect(host.reads.length, greaterThan(reads));
    expect(host.posts, hasLength(1));
    controller.dispose();
  });

  test(
    'reopening restores accepted tracking and only its receipt clears it',
    () async {
      final host = _UpdateHost();
      final first = await _started(host);
      first.dispose();
      host.statusResponse = {
        'running': false,
        'pid': null,
        'exit_code': null,
        'lines': <String>[],
      };
      host.receiptResponse = {
        'receipt': {
          'action_id': 'action-1',
          'outcome': 'running',
          'pid': 41,
          'finished_at': null,
        },
      };
      final restoredStore = BackendUpdateStore(
        SharedPreferences.getInstance(),
        host.source.updates.key,
      );
      final restored = BackendUpdateController(
        host.gateway,
        store: restoredStore,
      );
      addTearDown(restored.dispose);
      final checks = host.reads
          .where((r) => r.$1 == 'hermes/update/check')
          .length;
      await restored.checkForUpdate();
      expect(restored.phase, BackendUpdatePhase.running);
      expect(restored.requestOutstanding, isTrue);
      expect(restored.canOpenChannelEditor, isFalse);
      expect(
        host.reads.where((r) => r.$1 == 'hermes/update/check'),
        hasLength(checks),
      );
      expect(restoredStore.current?.targetSha, host.source.targetSha);
      expect(
        await restored.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      host.receiptResponse = {
        'receipt': {
          'action_id': 'action-1',
          'outcome': 'success',
          'pid': 99,
          'finished_at': '2026-11-12T09:00:00Z',
        },
      };
      await restored.refreshStatus();
      expect(restored.phase, BackendUpdatePhase.succeeded);
      expect(restored.requestOutstanding, isFalse);
      expect(
        (await SharedPreferences.getInstance()).containsKey(restoredStore.key),
        isFalse,
      );
      await restored.checkForUpdate();
      expect(restored.canStart, isTrue);
      expect(host.posts, hasLength(1));
    },
  );

  test(
    'late acceptance is saved after its route controller is disposed',
    () async {
      final host = _UpdateHost();
      final pending = host.pendingPost = Completer<Map<String, dynamic>>();
      final first = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      final start = first.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(host.posts, hasLength(1));
      expect(host.source.updates.current, isNotNull);
      first.dispose();
      pending.complete(host.postResponse);
      expect(await start, isFalse);
      final disk = BackendUpdateStore(
        SharedPreferences.getInstance(),
        host.source.updates.key,
      );
      await disk.load();
      expect(disk.current?.actionId, 'action-1');
      expect(disk.current?.pid, 41);
    },
  );

  test(
    'shared connection tracking blocks a second owner during dispatch',
    () async {
      final host = _UpdateHost();
      final pending = host.pendingPost = Completer<Map<String, dynamic>>();
      final first = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      final second = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final start = first.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(second.requestOutstanding, isTrue);
      expect(second.canSelectChannel, isFalse);
      expect(
        await second.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      await second.checkForUpdate();
      expect(
        host.reads.where((r) => r.$1 == 'hermes/update/check'),
        hasLength(1),
      );
      expect(host.posts, hasLength(1));
      pending.complete(host.postResponse);
      await start;
      expect(second.message, 'Update ongoing');
    },
  );

  test(
    'lost acceptance survives restart and cannot match an arbitrary receipt',
    () async {
      final host = _UpdateHost()..postFails = true;
      final first = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      await first.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      );
      first.dispose();
      final disk = BackendUpdateStore(
        SharedPreferences.getInstance(),
        host.source.updates.key,
      );
      final restored = BackendUpdateController(host.gateway, store: disk);
      addTearDown(restored.dispose);
      host.statusResponse = {
        'running': false,
        'pid': null,
        'exit_code': 0,
        'lines': <String>[],
      };
      host.receiptResponse = {
        'receipt': {
          'action_id': 'action-1',
          'outcome': 'success',
          'pid': 41,
          'finished_at': '2026-11-12T09:00:00Z',
        },
      };
      await restored.checkForUpdate();
      expect(restored.phase, BackendUpdatePhase.unknown);
      expect(restored.requestOutstanding, isTrue);
      expect(disk.current?.actionId, isNull);
      expect(host.posts, hasLength(1));
    },
  );

  test(
    'current stock protocol verifies the channel and exact update target',
    () async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);

      await controller.checkForUpdate();

      expect(controller.phase, BackendUpdatePhase.ready);
      expect(controller.message, isNull);
      expect(controller.channel?.name, 'main');
      expect(controller.channel?.targetSha, host.source.targetSha);
      expect(controller.canStart, isTrue);
      expect(controller.canSelectChannel, isTrue);
      expect(host.posts, isEmpty);
      expect(host.source.writes, isEmpty);
    },
  );

  for (final protocol in [1, 2, 99]) {
    test(
      'unsupported channel protocol $protocol cannot authorize writes',
      () async {
        final host = _UpdateHost();
        host.source.identityOverrides['channelProtocol'] = protocol;
        final controller = BackendUpdateController(
          host.gateway,
          store: host.source.updates,
        );
        addTearDown(controller.dispose);

        await controller.checkForUpdate();

        expect(controller.channel, isNull);
        expect(controller.canStart, isFalse);
        expect(controller.canSelectChannel, isFalse);
        expect(controller.canOpenChannelEditor, isTrue);
        expect(host.posts, isEmpty);
        expect(host.source.writes, isEmpty);
      },
    );
  }

  test(
    'multiple refreshed installations with the same revision remain ambiguous',
    () async {
      final host = _UpdateHost();
      host.source.ambiguous = true;
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      await controller.checkForUpdate();
      expect(controller.channel, isNull);
      expect(controller.canStart, isFalse);
      expect(controller.canSelectChannel, isFalse);
      expect(host.posts, isEmpty);
    },
  );

  for (final operation in ['save', 'update']) {
    test(
      'retired $operation authority prevents dispatch after a held check',
      () async {
        final host = _UpdateHost();
        final controller = BackendUpdateController(
          host.gateway,
          store: host.source.updates,
        );
        addTearDown(controller.dispose);
        await controller.checkForUpdate();
        final approved = controller.channel!;
        final held = Completer<Map<String, dynamic>>();
        host.pendingCheck = held;
        var current = true;
        final action = operation == 'save'
            ? controller.selectChannel(
                'stable',
                approved,
                canDispatch: () => current,
              )
            : controller.startUpdate(
                approvedChannel: approved,
                canDispatch: () => current,
              );
        await Future<void>.delayed(Duration.zero);
        current = false;
        held.complete(_available);
        expect(await action, isFalse);
        expect(host.source.writes, isEmpty);
        expect(host.posts, isEmpty);
      },
    );
  }
  test(
    'stable errors retain verified channel selection without offering an update',
    () async {
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
        ..targetSha = null
        ..error = 'release-unavailable';
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      await controller.checkForUpdate();
      expect(controller.channel?.name, 'stable');
      expect(controller.canSelectChannel, isTrue);
      expect(controller.canStart, isFalse);
      expect(controller.message, host.checkResponse['message']);
    },
  );

  test('release updates do not require a commit count', () async {
    final host = _UpdateHost()..checkResponse = {..._available, 'behind': -1};
    host.source
      ..channel = 'stable'
      ..branch = null
      ..targetVersion = '0.21.7';
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);
    await controller.checkForUpdate();
    expect(controller.check?.failed, isFalse);
    expect(controller.canStart, isTrue);
    expect(controller.channel?.targetVersion, '0.21.7');
  });

  test(
    'channel save is sparse, confirmed, rechecked and never installs an update',
    () async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      await controller.checkForUpdate();
      final approved = controller.channel!;
      final held = Completer<void>();
      host.source.pendingWrite = held;
      final save = controller.selectChannel(
        'stable',
        approved,
        canDispatch: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.channelSaving, isTrue);
      expect(controller.canStart, isFalse);
      expect(controller.canSelectChannel, isFalse);
      expect(
        await controller.selectChannel(
          'stable',
          approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(host.source.writes, hasLength(1));
      expect(host.source.writes.single.$1, 'config?profile=work');
      expect(host.source.writes.single.$2, {
        'config': {
          'update': {
            'installs': {
              BackendUpdateChannelFixture.installId: {
                'path': BackendUpdateChannelFixture.root,
                'channel': 'stable',
              },
            },
          },
        },
      });
      held.complete();
      expect(await save, isTrue);
      expect(controller.channelSaving, isFalse);
      expect(controller.channel?.name, 'stable');
      expect(host.posts, isEmpty);
      expect(
        host.reads.where((read) => read.$1 == 'hermes/update/check'),
        hasLength(3),
      );
    },
  );

  test('unconfirmed channel readback clears eligibility', () async {
    final host = _UpdateHost();
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);
    await controller.checkForUpdate();
    host.source.wrongReadback = true;
    expect(
      await controller.selectChannel(
        'stable',
        controller.channel!,
        canDispatch: () => true,
      ),
      isFalse,
    );
    expect(controller.channelSaving, isFalse);
    expect(controller.canStart, isFalse);
    expect(controller.message, contains('could not be confirmed'));
    expect(host.posts, isEmpty);
  });

  test(
    'main advancement after confirmation starts the approved branch update',
    () async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      await controller.checkForUpdate();
      final approved = controller.channel!;
      host.source.targetSha = '4444444444444444444444444444444444444444';
      expect(
        await controller.startUpdate(
          approvedChannel: approved,
          canDispatch: () => true,
        ),
        isTrue,
      );
      expect(host.posts, hasLength(1));
    },
  );

  for (final changed in ['channel', 'branch', 'release target', 'rollback']) {
    test(
      'a changed $changed after confirmation cannot start an update',
      () async {
        final host = _UpdateHost();
        if (changed == 'release target') {
          host.source
            ..channel = 'stable'
            ..branch = null;
        }
        final controller = BackendUpdateController(
          host.gateway,
          store: host.source.updates,
        );
        addTearDown(controller.dispose);
        await controller.checkForUpdate();
        final approved = controller.channel!;
        if (changed == 'channel') {
          host.source.channel = 'stable';
        } else if (changed == 'branch') {
          host.source.branch = 'another-branch';
        } else if (changed == 'rollback') {
          host.source.rollback = true;
        } else {
          host.source.targetSha = '4444444444444444444444444444444444444444';
        }
        expect(
          await controller.startUpdate(
            approvedChannel: approved,
            canDispatch: () => true,
          ),
          isFalse,
        );
        expect(controller.message, contains('changed'));
        expect(host.posts, isEmpty);
      },
    );
  }

  for (final malformed in ['stale', 'root', 'home', 'head', 'protocol']) {
    test(
      '$malformed metadata cannot identify an update installation',
      () async {
        final host = _UpdateHost();
        switch (malformed) {
          case 'stale':
            host.source.refreshCache = false;
          case 'root':
            host.source.identityOverrides['root'] = '/another/install';
          case 'home':
            host.source.identityOverrides['home'] = '/another/home';
          case 'head':
            host.source.statusOverrides['currentSha'] = 'bad';
          case 'protocol':
            host.source.identityOverrides['channelProtocol'] = 99;
        }
        final controller = BackendUpdateController(
          host.gateway,
          store: host.source.updates,
        );
        addTearDown(controller.dispose);
        await controller.checkForUpdate();
        expect(controller.channel, isNull);
        expect(controller.canStart, isFalse);
        expect(controller.canSelectChannel, isFalse);
        expect(host.source.writes, isEmpty);
        expect(host.posts, isEmpty);
      },
    );
  }

  test(
    'a failed stock check exposes its explanation and cannot start',
    () async {
      final host = _UpdateHost()
        ..checkResponse = {
          ..._available,
          'behind': null,
          'update_available': false,
          'message': "Couldn't reach the update source — try again later.",
        };
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      await controller.checkForUpdate();
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.message, host.checkResponse['message']);
      expect(controller.canStart, isFalse);
      expect(host.posts, isEmpty);
    },
  );

  test('start rechecks eligibility and targets the captured profile', () async {
    final host = _UpdateHost();
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);

    await controller.checkForUpdate();
    expect(controller.check!.canStart, isTrue);
    expect(
      await controller.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      ),
      isTrue,
    );
    expect(controller.phase, BackendUpdatePhase.running);
    expect(
      host.reads.where((call) => call.$1 == 'hermes/update/check'),
      hasLength(2),
    );
    for (final call in host.reads.where(
      (call) => {'health', 'hermes/update/check'}.contains(call.$1),
    )) {
      expect(call.$2, {
        if (call.$1 == 'hermes/update/check') 'force': 'true',
        'profile': 'work',
      });
    }
    expect(host.posts, hasLength(1));
    expect(host.posts.single.$1, 'hermes/update?profile=work');
    expect(host.posts.single.$2, isEmpty);
  });

  test('fresh eligibility can refuse a previously advertised update', () async {
    final host = _UpdateHost();
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);
    await controller.checkForUpdate();
    host.checkResponse = {..._available, 'update_available': false};

    expect(
      await controller.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      ),
      isFalse,
    );
    expect(controller.phase, BackendUpdatePhase.refused);
    expect(host.posts, isEmpty);
  });

  test('already running acknowledgement is tracked', () async {
    final host = _UpdateHost()
      ..postResponse = {
        'ok': true,
        'name': 'hermes-update',
        'pid': 41,
        'action_id': 'existing-action',
        'already_running': true,
      };
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);

    expect(
      await controller.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      ),
      isTrue,
    );
    expect(controller.phase, BackendUpdatePhase.running);
    expect(controller.requestOutstanding, isTrue);
    expect(controller.message, contains('Update ongoing'));
    host.statusResponse['action_id'] = 'existing-action';
    await controller.checkForUpdate();
    expect(
      host.reads.where((call) => call.$1 == 'hermes/update/check'),
      hasLength(1),
    );
    expect(controller.phase, BackendUpdatePhase.running);
  });

  test('explicit refusal is not presented as success', () async {
    final host = _UpdateHost()
      ..postResponse = {'ok': false, 'message': 'private backend detail'};
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);

    expect(
      await controller.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      ),
      isFalse,
    );
    expect(controller.phase, BackendUpdatePhase.refused);
    expect(controller.requestOutstanding, isFalse);
    expect(controller.message, isNot(contains('private backend detail')));
  });

  for (final (outcome, phase, exitCode) in [
    ('partial', BackendUpdatePhase.partial, 0),
    ('refused', BackendUpdatePhase.refused, 0),
    ('failed', BackendUpdatePhase.failed, 1),
    ('success', BackendUpdatePhase.succeeded, 0),
  ]) {
    test('correlated $outcome receipt proves its terminal outcome', () async {
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);
      host.statusResponse = {
        'name': 'hermes-update',
        'running': false,
        'pid': 41,
        'exit_code': exitCode,
        'lines': <String>[],
        'action_id': 'action-1',
      };
      host.receiptResponse = {
        ...host.receiptResponse,
        'receipt': {
          ...host.receiptResponse['receipt'] as Map,
          'outcome': outcome,
          'action_id': 'action-1',
        },
      };
      await controller.refreshStatus();
      expect(controller.phase, phase);
      expect(controller.requestOutstanding, isFalse);
      expect(host.reads.where((r) => r.$1 == 'hermes/update/receipt').last.$2, {
        'profile': 'work',
      });
      expect(host.reads.any((r) => r.$1 == 'health'), isTrue);
    });
  }

  test(
    'action-scoped receipt settles even after a newer update owns latest',
    () async {
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);
      host.statusResponse = {
        'running': false,
        'pid': null,
        'exit_code': null,
        'lines': <String>[],
        'receipt': {
          'action_id': 'action-1',
          'outcome': 'success',
          'finished_at': '2026-11-12T09:00:00Z',
        },
      };
      host.receiptResponse = {
        'receipt': {
          'action_id': 'newer-action',
          'pid': 88,
          'outcome': 'failed',
          'finished_at': '2026-11-12T09:05:00Z',
        },
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.succeeded);
      expect(controller.requestOutstanding, isFalse);
    },
  );

  test(
    'received acceptance survives a failed local save without replay',
    () async {
      final previous = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      SharedPreferencesStorePlatform.instance = _AcceptanceWriteFailure();
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);
      expect(host.source.updates.current?.actionId, 'action-1');
      expect(controller.requestOutstanding, isTrue);
      host.receiptResponse = {
        'receipt': {
          'action_id': 'action-1',
          'pid': 41,
          'outcome': 'success',
          'finished_at': '2026-11-12T09:00:00Z',
        },
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.succeeded);
      expect(host.source.updates.current, isNull);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          host.source.updates.key,
        ),
        isFalse,
      );
      expect(host.posts, hasLength(1));
    },
  );

  test(
    'shared completion retires another owner’s held running snapshot',
    () async {
      final host = _UpdateHost();
      final first = await _started(host);
      addTearDown(first.dispose);
      final other = _UpdateHost();
      final held = other.pendingStatus = Completer<Map<String, dynamic>>();
      final second = BackendUpdateController(
        other.gateway,
        store: host.source.updates,
      );
      addTearDown(second.dispose);
      final reading = second.refreshStatus();
      await Future<void>.delayed(Duration.zero);
      host.statusResponse = {
        'running': false,
        'pid': null,
        'exit_code': null,
        'lines': <String>[],
      };
      final finished = {
        'receipt': {
          'action_id': 'action-1',
          'pid': 41,
          'outcome': 'success',
          'finished_at': '2026-11-12T09:00:00Z',
        },
      };
      host.receiptResponse = finished;
      await first.refreshStatus();
      expect(host.source.updates.current, isNull);
      expect(second.statusLoading, isFalse);
      other.receiptResponse = finished;
      held.complete(other.statusResponse);
      await reading;
      expect(host.source.updates.current, isNull);
      expect(second.phase, BackendUpdatePhase.succeeded);
      other.pendingStatus = null;
      await second.refreshStatus();
      expect(host.source.updates.current, isNull);
      expect(second.phase, BackendUpdatePhase.succeeded);
      expect(other.posts, isEmpty);
    },
  );

  test(
    'late availability errors cannot replace shared ongoing feedback',
    () async {
      final host = _UpdateHost();
      final other = _UpdateHost();
      final held = other.pendingCheck = Completer<Map<String, dynamic>>();
      final second = BackendUpdateController(
        other.gateway,
        store: host.source.updates,
      );
      addTearDown(second.dispose);
      final check = second.checkForUpdate();
      await Future<void>.delayed(Duration.zero);
      final first = await _started(host);
      addTearDown(first.dispose);
      held.completeError(TimeoutException('old availability read'));
      await check;
      expect(second.requestOutstanding, isTrue);
      expect(second.phase, BackendUpdatePhase.running);
      expect(second.message, 'Update ongoing');
      expect(host.posts, hasLength(1));
    },
  );

  for (final fails in [false, true]) {
    test(
      'pre-update availability cannot overwrite a completed result, fails=$fails',
      () async {
        final host = _UpdateHost();
        final other = _UpdateHost();
        final held = other.pendingCheck = Completer<Map<String, dynamic>>();
        final second = BackendUpdateController(
          other.gateway,
          store: host.source.updates,
        );
        addTearDown(second.dispose);
        final checking = second.checkForUpdate();
        await Future<void>.delayed(Duration.zero);
        final first = await _started(host);
        addTearDown(first.dispose);
        host.statusResponse = {
          'running': false,
          'pid': null,
          'exit_code': null,
          'lines': <String>[],
        };
        host.receiptResponse = {
          'receipt': {
            'action_id': 'action-1',
            'pid': 41,
            'outcome': 'success',
            'finished_at': '2026-11-12T09:00:00Z',
          },
        };
        await first.refreshStatus();
        expect(second.phase, BackendUpdatePhase.succeeded);
        if (fails) {
          held.completeError(TimeoutException('old availability read'));
        } else {
          held.complete(_available);
        }
        await checking;
        expect(second.phase, BackendUpdatePhase.succeeded);
        expect(second.message, 'The backend update completed successfully.');
        expect(other.posts, isEmpty);
      },
    );
  }

  test('only the accepted action ID can clear a tracked update', () async {
    final host = _UpdateHost();
    final controller = await _started(host);
    addTearDown(controller.dispose);
    for (final receipt in [
      {'outcome': 'success', 'pid': 41, 'finished_at': '2026-09-12T12:00:00Z'},
      {
        'outcome': 'success',
        'pid': 41,
        'action_id': 'old-action',
        'finished_at': '2026-09-12T12:00:00Z',
      },
      {
        'outcome': 'running',
        'pid': 41,
        'action_id': 'action-1',
        'finished_at': null,
      },
      {
        'outcome': 'unknown',
        'pid': 41,
        'action_id': 'action-1',
        'finished_at': '2026-09-12T12:00:00Z',
      },
    ]) {
      host.statusResponse = {
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'action_id': 'action-1',
        'lines': <String>[],
      };
      host.receiptResponse = {'receipt': receipt};
      await controller.refreshStatus();
      expect(controller.requestOutstanding, isTrue);
      expect(controller.canStart, isFalse);
      expect(controller.canOpenChannelEditor, isFalse);
      expect(host.source.updates.current?.actionId, 'action-1');
    }
  });

  test(
    'a status read started before a new request cannot overwrite it',
    () async {
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);

      host.statusResponse = {
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'lines': <String>[],
        'action_id': 'action-1',
      };
      host.receiptResponse['receipt']['action_id'] = 'action-1';
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.succeeded);

      final oldStatus = host.pendingStatus = Completer<Map<String, dynamic>>();
      final pendingRefresh = controller.refreshStatus();
      await Future<void>.delayed(Duration.zero);
      expect(controller.statusLoading, isTrue);

      host
        ..postResponse = {
          'ok': true,
          'name': 'hermes-update',
          'pid': 42,
          'action_id': 'action-2',
        }
        ..pendingStatus = null;
      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isTrue,
      );
      expect(controller.phase, BackendUpdatePhase.running);
      expect(controller.statusLoading, isFalse);

      oldStatus.complete({
        'running': false,
        'pid': 41,
        'exit_code': 1,
        'lines': <String>[],
        'action_id': 'action-1',
      });
      await pendingRefresh;
      expect(controller.phase, BackendUpdatePhase.running);
      expect(controller.message, 'Update ongoing');
      expect(controller.requestOutstanding, isTrue);
    },
  );

  for (final (defect, acknowledgement) in <(String, Map<String, dynamic>)>[
    (
      'missing acceptance',
      {'name': 'hermes-update', 'pid': 41, 'action_id': 'action-1'},
    ),
    (
      'wrong action name',
      {'ok': true, 'name': 'update', 'pid': 41, 'action_id': 'action-1'},
    ),
    (
      'missing action identity',
      {'ok': true, 'name': 'hermes-update', 'pid': 41},
    ),
  ]) {
    test('$defect acknowledgement stays unknown and prevents replay', () async {
      final host = _UpdateHost()..postResponse = acknowledgement;
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.requestOutstanding, isTrue);
      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(host.posts, hasLength(1));
    });
  }

  test(
    'lost acknowledgement is unknown and is not retried automatically',
    () async {
      final host = _UpdateHost()..postFails = true;
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);

      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.message, contains('not yet confirmed'));
      expect(host.posts, hasLength(1));

      host.statusResponse = {
        'running': false,
        'pid': null,
        'exit_code': null,
        'lines': <String>[],
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.requestOutstanding, isTrue);
      expect(controller.message, contains('not yet confirmed'));
    },
  );

  test('fresh controller reports the last completed server update', () async {
    final host = _UpdateHost()
      ..statusResponse = {
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'lines': <String>[],
        'action_id': 'old-action',
      }
      ..receiptResponse = {
        'receipt': {
          'outcome': 'partial',
          'pid': 41,
          'finished_at': '2026-09-12T12:00:00Z',
        },
        'summary': {'outcome': 'partial'},
      };
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    addTearDown(controller.dispose);

    await controller.refreshStatus();
    expect(controller.phase, BackendUpdatePhase.partial);
    expect(
      controller.message,
      'Last recorded update completed only partially.',
    );
    expect(host.reads.last.$1, 'hermes/update/receipt');
  });

  test(
    'observed host update blocks starts until it becomes terminal',
    () async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(
        host.gateway,
        store: host.source.updates,
      );
      addTearDown(controller.dispose);

      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.running);
      expect(controller.requestOutstanding, isTrue);
      expect(controller.canStart, isFalse);
      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      await controller.checkForUpdate();
      expect(host.posts, isEmpty);
      expect(
        host.reads.where((call) => call.$1 == 'hermes/update/check'),
        isEmpty,
      );

      host.statusResponse = {
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'lines': <String>[],
        'action_id': 'old-action',
      };
      host.receiptResponse['receipt']['action_id'] = 'action-1';
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.succeeded);
      expect(controller.message, 'The backend update completed successfully.');

      await controller.checkForUpdate();
      expect(controller.canStart, isTrue);
    },
  );

  test(
    'matching action receipt settles after the process table is lost',
    () async {
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);
      host
        ..statusResponse = {
          'running': false,
          'pid': 41,
          'exit_code': 1,
          'lines': <String>[],
        }
        ..receiptResponse = {
          'receipt': {
            'outcome': 'partial',
            'action_id': 'action-1',
            'pid': 41,
            'finished_at': '2026-09-12T12:00:00Z',
          },
        };

      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.partial);
      expect(controller.requestOutstanding, isFalse);
    },
  );

  test('duplicate start and disposed completion are ignored', () async {
    final host = _UpdateHost();
    final pending = host.pendingPost = Completer<Map<String, dynamic>>();
    final controller = BackendUpdateController(
      host.gateway,
      store: host.source.updates,
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final first = controller.startUpdate(
      approvedChannel: host.source.approved,
      canDispatch: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      await controller.startUpdate(
        approvedChannel: host.source.approved,
        canDispatch: () => true,
      ),
      isFalse,
    );
    expect(host.posts, hasLength(1));
    controller.dispose();
    final before = notifications;
    pending.complete(host.postResponse);
    expect(await first, isFalse);
    expect(notifications, before);
  });
}
