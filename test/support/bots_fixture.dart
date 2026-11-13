import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'package:flutter/foundation.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'dart:convert';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/administration_repository.dart';

/// Modern stock shapes, with explicit authority and per-key revisions.
class BotsFixture {
  BotsFixture({this.server, this.now});
  final AdministrationRepository? server;
  final DateTime Function()? now;
  final profiles = <Map<String, dynamic>>[
    profile(
      'atlas',
      'Atlas',
      pinned: true,
      preview:
          'I found three useful approaches. The first keeps the existing boundary and makes the workflow easier to maintain.',
    ),
    profile(
      'mira',
      'Mira',
      preview:
          'The review is ready. Would you like me to apply the suggested changes?',
    ),
    profile(
      'forge',
      'Forge',
      preview: 'Building the Android release and checking the final output.',
    ),
  ];
  final commands = <(String, String, Map<String, dynamic>)>[];
  final events = <Map<String, dynamic>>[];
  final room = <String, dynamic>{
    'room_id': 'room-1',
    'name': 'Research team',
    'authority_gateway_id': 'gateway-1',
    'authority_epoch': 1,
    'revision': 1,
    'latest_seq': 0,
    'members': [
      {
        'member_id': 'atlas',
        'profile': 'atlas',
        'handle': 'bot_atlas',
        'display_name': 'Atlas',
      },
      {
        'member_id': 'mira',
        'profile': 'mira',
        'handle': 'bot_mira',
        'display_name': 'Mira',
      },
    ],
  };
  final pending = <Map<String, dynamic>>[];
  bool conflict = false, sendLost = false;
  Future<void> Function()? beforeCommand;
  Future<Map<String, dynamic>?> Function(String, String, Map<String, dynamic>)?
  readHook;
  Future<Map<String, dynamic>?> Function(String, String, Map<String, dynamic>)?
  commandHook;
  int _newSession = 0;
  late final repository = BotsRepository(
    groupObservations: GroupObservations(
      WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'default',
      ),
    ),
    scope: WorkspaceScope(
      connectionId: 'host',
      connectionIdentity: 'instance-1',
      profileName: 'default',
    ),
    instance: 'Home server',
    server: server,
    read: read,

    command: command,
    ownership: ownership,
    now: now,
  );
  void observeGroupMessages({int since = 0}) {
    final latest = events.isEmpty ? 0 : events.last['seq'] as int;
    final page = BotsRepository.decodeGroupLog(room['room_id'] as String, {
      'events': [
        for (final event in events.where((event) => event['seq'] > since))
          {'event_id': 'fixture-${event['seq']}', ...event},
      ],
      'cursor': latest,
      'latest_seq': latest,
      'has_more': false,
      'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
    }, since: since);
    repository.groupObservations.record(
      BotsRepository.decodeGroup(repository.scope, repository.instance, room),
      page,
      since: since,
    );
  }

  static Map<String, dynamic> profile(
    String name,
    String title, {
    bool pinned = false,
    String preview = '',
  }) => {
    'name': name,
    'display_name': name,
    'description': 'Research & development',
    'is_default': false,
    'model': 'model-1',
    'provider': 'provider-1',
    'has_avatar': false,
    'ui_meta': {
      'hermes-bots': {
        'title': title,
        'shape': 'squircle',
        'color': '#65c7bc',
        'pinned': pinned,
        'custom': true,
        'unrelated': {
          'nested': ['kept'],
        },
      },
    },
    'ui_meta_revisions': {'hermes-bots': 2},
    'canonical_session': {
      'id': '$name-chat',
      'resolved_id': '$name-tip',
      'preview': preview,
    },
    'last_session': {
      'id': '$name-cron',
      'preview': 'Private scheduled-task message',
    },
  };
  Future<Set<String>> ownership(String profile, Iterable<String> keys) async {
    final row = profiles.firstWhere((p) => p['name'] == profile);
    final ids = {
      row['canonical_session']?['id'],
      row['canonical_session']?['resolved_id'],
      row['last_session']?['id'],
    };
    return keys.where(ids.contains).toSet();
  }

  Future<Map<String, dynamic>> read(
    String profile,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'session.events.since' &&
        (params.length != 3 ||
            params['replay_epoch'] is! String ||
            params['last_sequence'] is! int ||
            params['session_id'] is! String)) {
      throw const FormatException('Invalid canonical passive replay payload');
    }
    final custom = await readHook?.call(profile, method, params);
    Map<String, dynamic> stockLog(Map<String, dynamic> result) => {
      ...result,
      'events': [
        for (final raw in result['events'] as List)
          {
            'event_id': 'fixture-${raw['seq']}',
            ...Map<String, dynamic>.from(raw as Map),
          },
      ],
    };
    if (custom != null) {
      if (method == 'session.events.since' &&
          custom['replay_epoch'] != params['replay_epoch']) {
        return {
          ...custom,
          'events': <Map<String, dynamic>>[],
          'truncated': true,
          'snapshot_required': true,
        };
      }
      return method == 'groups.log' ? stockLog(custom) : custom;
    }
    if (method == 'groups.log') {
      final since = params['since_seq'] as int;
      final page = <Map<String, dynamic>>[];
      final latest = events.isEmpty ? 0 : events.last['seq'] as int;
      Map<String, dynamic> response() {
        final cursor = page.isEmpty ? since : page.last['seq'] as int;
        return {
          'events': page,
          'cursor': cursor,
          'latest_seq': latest,
          'has_more': cursor < latest,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      }

      for (final event
          in events
              .where((event) => event['seq'] > since)
              .take(params['limit'] as int)) {
        page.add(event);
        if (utf8.encode(jsonEncode(response())).length > 2 * 1024 * 1024) {
          page.removeLast();
          break;
        }
      }
      return stockLog(response());
    }
    return switch (method) {
      'session.resume' => passiveSnapshot(params),
      'session.list' => {'sessions': <Map<String, dynamic>>[]},
      'profiles.list' => {
        'profiles': jsonDecode(jsonEncode(profiles)),
        'bot_mode_protocol': true,
        'install_id': 'install-1',
      },
      'session.active_list' => {
        'sessions': [
          {
            'id': 'runtime-forge',
            'session_key': 'forge-chat',

            'status': 'working',
          },
          {
            'id': 'runtime-mira',
            'session_key': 'mira-chat',

            'status': 'waiting',
          },
        ],
      },
      'groups.capabilities' => {
        'driver': true,
        'seatable_profiles': profiles.map((row) => row['name']).toList(),
        'methods': [
          'groups.create',
          'groups.send',
          'groups.stop',
          'groups.retry',
          'groups.discard',
          'groups.approve',
          'groups.context',
          'groups.continue',
        ],
      },
      'groups.list' => {
        'rooms': [room],
        'next_offset': null,
      },
      'groups.state' => {
        'context': {
          'purpose': '',
          'notes': '',
          'routing': 'everyone',
          'lead_member_id': '',
        },
        'room': {
          ...room,
          'latest_seq': events.isEmpty ? 0 : events.last['seq'] as int,
        },
        'driver_status': {
          'working': false,
          'blocked': pending.isNotEmpty,
          'pending_actions': pending,
          'routing_modes': ['everyone', 'lead', 'auto'],
          'max_rounds': 3,
          'max_continues': 5,
        },
      },
      'display.status' => {
        'supported': true,
        'installed': true,
        'running': false,
        'lease': {'holder': 'agent', 'viewer_hash': null, 'epoch': 0},
      },
      _ => throw StateError('Unexpected read $method'),
    };
  }

  static Map<String, dynamic> passiveSnapshot(
    Map<String, dynamic> params, {
    String epoch = 'test',
    int sequence = 0,
    bool running = true,
  }) {
    if (params.length != 2 ||
        params['display_projection'] != true ||
        params['session_id'] is! String) {
      throw const FormatException('Invalid canonical passive mount payload');
    }
    return {
      'session_id': params['session_id'],
      'stored_session_id': params['session_id'],
      'replay_epoch': epoch,
      'last_sequence': sequence,
      'running': running,
    };
  }

  Future<Map<String, dynamic>> command(
    String profile,
    String method,
    Map<String, dynamic> params,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    await beforeCommand?.call();
    if (!canDispatch()) throw StateError('Not dispatched');
    onDispatched();
    commands.add((
      profile,
      method,
      Map<String, dynamic>.from(jsonDecode(jsonEncode(params))),
    ));
    if (method == 'session.create' &&
        !mapEquals(params, {
          'title': 'Bot Chat',
          'hidden': true,
          'follow_profile_config': true,
          'source': 'gui',
        })) {
      throw const FormatException('Invalid canonical Bot Chat create payload');
    }
    final custom = await commandHook?.call(profile, method, params);
    if (custom != null) return custom;
    switch (method) {
      case 'profiles.configure':
        final row = profiles.firstWhere((p) => p['name'] == params['name']);
        final revision = row['ui_meta_revisions']['hermes-bots'] as int;
        if (conflict ||
            params['ui_meta_expected_revisions']['hermes-bots'] != revision) {
          return {
            'ok': false,
            'applied': {
              'ui_meta': false,
              'ui_meta_conflicts': {
                'hermes-bots': {'actual': revision},
              },
            },
          };
        }
        row['ui_meta'] = params['ui_meta'];
        row['ui_meta_revisions'] = {'hermes-bots': revision + 1};
        return {
          'ok': true,
          'applied': {
            'ui_meta': true,
            'ui_meta_revisions': {'hermes-bots': revision + 1},
          },
        };
      case 'session.create':
        final id = 'new-bot-chat-${++_newSession}';
        profiles.firstWhere((p) => p['name'] == profile)['canonical_session'] =
            {'id': id, 'resolved_id': id, 'preview': ''};
        return {'session_id': id, 'stored_session_id': id};
      case 'profiles.create':
        profiles.add(
          BotsFixture.profile(
            params['name'] as String,
            params['name'] as String,
          ),
        );
        return {'ok': true};
      case 'groups.send':
        final wireId = BotsRepository.groupUserEventId(
          params['event_id'] as String,
        );
        if (!events.any((event) => event['event_id'] == wireId)) {
          events.add({
            'room_id': params['room_id'],
            'seq': (events.isEmpty ? 0 : events.last['seq'] as int) + 1,
            'event_id': wireId,
            'kind': 'message.user',
            'created_at': 1791756000.0 + events.length,
            'actor': {'kind': 'user', 'id': 'you'},
            'payload': params['payload'],
          });
        }
        if (sendLost) {
          sendLost = false;
          throw StateError('Acknowledgement lost');
        }
        return {
          'accepted': true,
          'client_event_id': params['event_id'],
          'driver_started': true,
          'event': events.singleWhere((event) => event['event_id'] == wireId),
        };
      case 'groups.create':
        return {
          'room': {...room, 'room_id': params['room_id']},
        };
      case 'groups.retry':
        pending.removeWhere(
          (action) =>
              action['task_id'] == params['task_id'] &&
              action['member_id'] == params['member_id'] &&
              action['execution_generation'] == params['execution_generation'],
        );
        return {
          'retried': true,
          'task': {
            'room_id': params['room_id'],
            'task_id': params['task_id'],
            'execution_generation': (params['execution_generation'] as int) + 1,
          },
        };
      case 'groups.approve':
        pending.clear();
        return {'approved': true};
      case 'groups.rename':
        room['name'] = params['name'];
        return {'room': room};
      case 'groups.stop':
        final cancelled = pending.length;
        pending.clear();
        events.add({
          'room_id': params['room_id'],
          'seq': events.isEmpty ? 1 : (events.last['seq'] as int) + 1,
          'event_id': 'stop-${params['cancel_id']}',
          'kind': 'room.stop_requested',
          'actor': {'kind': 'gateway', 'id': 'gateway-1'},
          'payload': {'cancel_id': params['cancel_id']},
          'created_at': 1791756000.0,
        });
        return {'cancelled': cancelled};
      case 'groups.disband':
        return {'ok': true};
      case 'profiles.set_asset':
        return {'ok': true};
      default:
        throw StateError('Unexpected command $method');
    }
  }
}

/// Explicit fixed appearance observations for standalone group-session tests.
class FixedGroupAppearances extends ChangeNotifier
    implements BotGroupAppearanceSource {
  FixedGroupAppearances(Iterable<BotRecord> bots)
    : _bots = List.unmodifiable(bots);
  final List<BotRecord> _bots;
  @override
  BotGroupAppearance appearanceForGroup(BotGroup group) =>
      BotGroupAppearance.forGroup(group, _bots);
}

/// Full discovery for standalone route fixtures; production schedules each read.
Future<List<BotGroup>> readFixtureGroups(
  BotsRepository repository, {
  required RecentGroupMessages? groupMessages,
}) async {
  final rooms = <BotGroup>[];
  for (final room in await repository.groupCatalog()) {
    rooms.add(
      await repository.groupPreview(
        room,
        groupMessages: groupMessages,
        canPublish: () => true,
      ),
    );
  }
  return rooms;
}

int _replyFixtureSequence = 0;
final _replyFixtureState = Expando<Map<String, Object>>();

/// Current stock reply identity for passive-worker fixture emitters.
Map<String, dynamic> stockWorkerReply(
  List<Map<String, dynamic>> events,
  String type,
  Map<String, dynamic> payload,
) {
  if (!{'message.start', 'message.delta', 'message.interim'}.contains(type)) {
    return payload;
  }
  var state = _replyFixtureState[events];
  if (state == null || type == 'message.start') {
    state = {
      'turn': 'worker-fixture-${++_replyFixtureSequence}',
      'segment': 0,
      'offset': 0,
    };
    _replyFixtureState[events] = state;
  }
  final stamped = <String, dynamic>{
    'turn_id': state['turn'],
    if (type != 'message.start') 'segment': state['segment'],
    if (type == 'message.delta') 'offset': state['offset'],
    ...payload,
  };
  if (type == 'message.delta') {
    state['offset'] =
        (state['offset'] as int) + (payload['text']?.toString().length ?? 0);
  }
  if (type == 'message.interim') {
    state['segment'] = (state['segment'] as int) + 1;
    state['offset'] = 0;
  }
  return stamped;
}
