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
      'pid': 41,
      'finished_at': '2026-09-12T12:00:00Z',
    },
    'summary': {'outcome': 'success'},
  };
  Completer<Map<String, dynamic>>? pendingPost;
  Completer<Map<String, dynamic>>? pendingCheck;
  Completer<Map<String, dynamic>>? pendingStatus;
  bool postFails = false;
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

Future<BackendUpdateController> _started(_UpdateHost host) async {
  final controller = BackendUpdateController(host.gateway);
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
  test(
    'current stock protocol verifies the channel and exact update target',
    () async {
      final host = _UpdateHost();
      final controller = BackendUpdateController(host.gateway);
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
        final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
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
        final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
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
    final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
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
    final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
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
        final controller = BackendUpdateController(host.gateway);
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
        final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
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
    final controller = BackendUpdateController(host.gateway);
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
    final controller = BackendUpdateController(host.gateway);
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
    final controller = BackendUpdateController(host.gateway);
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
    expect(controller.message, contains('already running'));
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
    final controller = BackendUpdateController(host.gateway);
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
        },
      };
      await controller.refreshStatus();
      expect(controller.phase, phase);
      expect(controller.requestOutstanding, isFalse);
      expect(host.reads.last.$1, 'hermes/update/receipt');
      expect(host.reads.last.$2, {'profile': 'work'});
    });
  }

  test(
    'same process exit stays conservative and old receipt cannot confirm',
    () async {
      final host = _UpdateHost();
      final controller = await _started(host);
      addTearDown(controller.dispose);

      host.statusResponse = {
        'name': 'hermes-update',
        'running': true,
        'pid': 41,
        'exit_code': null,
        'lines': <String>[],
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.running);

      host.statusResponse = {
        'name': 'hermes-update',
        'running': true,
        'pid': 41,
        'exit_code': null,
        'lines': <String>[],
        'action_id': 'old-action',
        'receipt': {'outcome': 'success'},
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.unknown);

      host.statusResponse = {
        'name': 'hermes-update',
        'running': false,
        'pid': null,
        'exit_code': null,
        'lines': <String>[],
        'action_id': 'action-1',
      };
      host.receiptResponse = {
        'receipt': {
          'outcome': 'success',
          'pid': 99,
          'finished_at': '2026-09-12T11:00:00Z',
        },
        'summary': {'outcome': 'success'},
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.requestOutstanding, isFalse);

      host.statusResponse = {
        'name': 'hermes-update',
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'lines': <String>[],
        'receipt': {'outcome': 'failed'},
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.message, contains('command exited successfully'));
      expect(controller.requestOutstanding, isFalse);

      host.statusResponse = {
        'name': 'hermes-update',
        'running': false,
        'pid': 41,
        'exit_code': 0,
        'lines': <String>[],
        'action_id': 'old-action',
        'receipt': {'outcome': 'success'},
      };
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.message, contains('different update'));
    },
  );

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
      expect(controller.message, contains('started'));
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
      final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
      addTearDown(controller.dispose);

      expect(
        await controller.startUpdate(
          approvedChannel: host.source.approved,
          canDispatch: () => true,
        ),
        isFalse,
      );
      expect(controller.phase, BackendUpdatePhase.unknown);
      expect(controller.message, contains('could not be confirmed'));
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
      expect(controller.message, contains('still unconfirmed'));
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
    final controller = BackendUpdateController(host.gateway);
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
      final controller = BackendUpdateController(host.gateway);
      addTearDown(controller.dispose);

      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.running);
      expect(controller.requestOutstanding, isFalse);
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
      await controller.refreshStatus();
      expect(controller.phase, BackendUpdatePhase.succeeded);
      expect(controller.message, startsWith('Last recorded update'));

      await controller.checkForUpdate();
      expect(controller.canStart, isTrue);
    },
  );

  test('same-process completion uses a matching full receipt', () async {
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
          'pid': 41,
          'finished_at': '2026-09-12T12:00:00Z',
        },
      };

    await controller.refreshStatus();
    expect(controller.phase, BackendUpdatePhase.partial);
    expect(controller.requestOutstanding, isFalse);
  });

  test('duplicate start and disposed completion are ignored', () async {
    final host = _UpdateHost();
    final pending = host.pendingPost = Completer<Map<String, dynamic>>();
    final controller = BackendUpdateController(host.gateway);
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
