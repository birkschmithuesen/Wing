import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/backend_update.dart';
import 'profile_gateway.dart';

/// Stock dashboard checks omit channel identity. Read the producer's per-install
/// source-check record through its stock file API; never guess a channel or root.
class BackendUpdateChannels {
  BackendUpdateChannels(this.gateway, {required this.readHealth});
  final ProfileGateway gateway;
  final Future<Map<String, dynamic>> Function() readHealth;

  Future<(BackendUpdateCheck, BackendUpdateChannel?)> check() async {
    List<BackendUpdateChannel>? before;
    try {
      before = await _observe();
    } catch (_) {
      // Without the earlier observation, a retained cache cannot prove identity.
    }
    final result = BackendUpdateCheck.fromJson(
      await gateway.read('hermes/update/check', {'force': 'true'}),
    );
    if (result.canApply != true || before == null) return (result, null);
    try {
      final after = await _observe();
      final fresh = after.where(
        (row) => !before!.any(
          (old) =>
              row.installId == old.installId && row.fetchedAt == old.fetchedAt,
        ),
      );
      return (result, fresh.length == 1 ? fresh.single : null);
    } catch (_) {
      return (result, null);
    }
  }

  Future<List<BackendUpdateChannel>> _observe() async {
    final observations = await Future.wait([
      readHealth(),
      gateway.read('profiles'),
    ]);
    final commit = observations[0]['commit'];
    if (commit is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      throw const FormatException('Missing installed revision');
    }
    final profiles = observations[1]['profiles'];
    if (profiles is! List) throw const FormatException('Missing profiles');
    final homes = [
      for (final row in profiles)
        if (row is Map &&
            row['name'] == gateway.scope.profileName &&
            row['path'] is String &&
            (row['path'] as String).isNotEmpty)
          row['path'] as String,
    ];
    if (homes.length != 1) {
      throw const FormatException('Ambiguous profile home');
    }
    final home = homes.single;
    final directory = '$home/source-checks';
    final listing = await gateway.read('fs/list', {'path': directory});
    final entries = listing['entries'];
    if (listing['error'] == 'ENOENT') return [];
    if (listing['error'] != null || entries is! List) {
      throw const FormatException('Update metadata unavailable');
    }
    final candidates = <BackendUpdateChannel>[];
    for (final row in entries) {
      if (row is! Map || row['isDirectory'] != false) continue;
      final name = row['name'];
      if (name is! String || !RegExp(r'^[0-9a-f]{16}\.json$').hasMatch(name)) {
        continue;
      }
      // A broken or unrelated record cannot grant update authority.
      try {
        final response = await gateway.read('fs/read-text', {
          'path': '$directory/$name',
        });
        if (response['binary'] != false || response['truncated'] != false) {
          continue;
        }
        final raw = jsonDecode(response['text'] as String);
        if (raw is! Map) continue;
        final identity = raw['identity'];
        final status = raw['status'];
        if (identity is! Map ||
            status is! Map ||
            identity['channelProtocol'] != 3 ||
            status['supported'] != true ||
            identity['home'] != home ||
            identity['head'] != commit ||
            status['currentSha'] != commit) {
          continue;
        }
        final root = identity['root'];
        final channel = identity['channel'];
        if (root is! String ||
            root.isEmpty ||
            channel is! String ||
            !RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(channel)) {
          continue;
        }
        final id = sha256
            .convert(utf8.encode(root))
            .toString()
            .substring(0, 16);
        if (name != '$id.json' ||
            (status['channel'] != null && status['channel'] != channel)) {
          continue;
        }
        String? text(String key) =>
            status[key] is String && (status[key] as String).trim().isNotEmpty
            ? status[key] as String
            : null;
        final target = text('targetSha');
        final fetchedAt = status['fetchedAt'];
        if (fetchedAt is! int || fetchedAt <= 0) continue;
        if (target != null && !RegExp(r'^[0-9a-f]{40}$').hasMatch(target)) {
          continue;
        }
        candidates.add(
          BackendUpdateChannel(
            installId: id,
            installPath: root,
            home: home,
            name: channel,
            branch: text('branch'),
            currentSha: commit,
            targetSha: target,
            targetVersion: text('sourceVersion'),
            error: text('error'),
            aheadOfRelease: status['aheadOfRelease'] == true,
            rollback: status['rollback'] == true,
            fetchedAt: fetchedAt,
          ),
        );
      } catch (_) {
        // File retirement or malformed records leave channel identity unknown.
      }
    }
    return candidates;
  }

  Future<void> save(
    BackendUpdateChannel installation,
    String channel, {
    required bool Function() canDispatch,
  }) async {
    if (!{'stable', 'main'}.contains(channel)) {
      throw ArgumentError.value(channel);
    }
    final config = await gateway.read('config', {'include_defaults': 'false'});
    final updates = config['update'];
    final installs = updates is Map ? updates['installs'] : null;
    final existing = installs is Map ? installs[installation.installId] : null;
    if (existing != null &&
        (existing is! Map ||
            existing['path'] != installation.installPath ||
            existing['channel'] != installation.name)) {
      throw StateError('Update channel changed');
    }
    final result = await gateway.putOwned(
      'config',
      {
        'config': {
          'update': {
            'installs': {
              installation.installId: {
                'path': installation.installPath,
                'channel': channel,
              },
            },
          },
        },
      },
      canDispatch: canDispatch,
      onDispatched: () {},
    );
    if (result['ok'] != true) throw StateError('Channel save unconfirmed');
    final confirmed = await gateway.read('config', {
      'include_defaults': 'false',
    });
    final savedUpdate = confirmed['update'];
    final savedInstalls = savedUpdate is Map ? savedUpdate['installs'] : null;
    final saved = savedInstalls is Map
        ? savedInstalls[installation.installId]
        : null;
    if (saved is! Map ||
        saved['path'] != installation.installPath ||
        saved['channel'] != channel) {
      throw StateError('Channel readback unconfirmed');
    }
  }
}
