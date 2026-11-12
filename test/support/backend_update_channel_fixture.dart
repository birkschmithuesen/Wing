import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:wing/core/models/backend_update.dart';

/// Stock profile, source-check cache and sparse config PUT responses.
class BackendUpdateChannelFixture {
  static const root = '/opt/hermes';
  static const home = '/state/work';
  static const currentSha = '1111111111111111111111111111111111111111';
  static final installId = sha256
      .convert(utf8.encode(root))
      .toString()
      .substring(0, 16);
  String channel = 'main';
  String? branch = 'main';
  String? targetSha = '2222222222222222222222222222222222222222';
  String? error;
  String? targetVersion;
  bool rollback = false;
  bool aheadOfRelease = false;
  bool metadataUnavailable = false;
  bool saveFails = false;
  bool wrongReadback = false;
  bool refreshCache = true;
  bool ambiguous = false;
  final identityOverrides = <String, dynamic>{};
  final statusOverrides = <String, dynamic>{};
  int fetchedAt = 1;
  Completer<void>? pendingWrite;
  Map<String, dynamic>? savedRecord;
  final writes = <(String, Map<String, dynamic>)>[];

  BackendUpdateChannel get approved => BackendUpdateChannel(
    installId: installId,
    installPath: root,
    home: home,
    name: channel,
    branch: branch,
    currentSha: currentSha,
    targetSha: targetSha,
    targetVersion: targetVersion,
    error: error,
    aheadOfRelease: aheadOfRelease,
    rollback: rollback,
    fetchedAt: fetchedAt,
  );

  Map<String, dynamic>? read(
    String endpoint,
    Map<String, String> query,
  ) => switch (endpoint) {
    'profiles' => {
      'profiles': [
        {'name': 'work', 'path': home},
      ],
    },
    'fs/list' => {
      'entries': metadataUnavailable
          ? []
          : [
              {
                'name': '$installId.json',
                'isDirectory': false,
                'path': '$home/source-checks/$installId.json',
              },
              if (ambiguous)
                {
                  'name':
                      '${sha256.convert(utf8.encode('/opt/other')).toString().substring(0, 16)}.json',
                  'isDirectory': false,
                },
            ],
    },
    'fs/read-text' => {
      'binary': false,
      'truncated': false,
      'text': jsonEncode({
        'identity': {
          'root': root,
          if (query['path']?.endsWith('$installId.json') == false)
            'root': '/opt/other',
          'home': home,
          'head': currentSha,
          'channel': channel,
          'channelProtocol': 3,
          ...identityOverrides,
        },
        'status': {
          'fetchedAt': fetchedAt,
          'supported': true,
          'currentSha': currentSha,
          if (channel != 'main') 'channel': channel,
          if (channel == 'main') 'branch': branch,
          'targetSha': targetSha,
          'sourceVersion': targetVersion,
          'error': error,
          'rollback': rollback,
          'aheadOfRelease': aheadOfRelease,
          ...statusOverrides,
        },
      }),
    },
    'config' => {
      'update': {
        'installs': {
          'another-install': {'path': '/another/hermes', 'channel': 'canary'},
          if (savedRecord != null)
            installId: {...savedRecord!, if (wrongReadback) 'channel': 'other'},
        },
      },
    },
    _ => null,
  };

  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    final uri = Uri.parse(endpoint);
    if (uri.path != 'config' || uri.queryParameters['profile'] != 'work') {
      throw StateError('Unexpected channel write $endpoint');
    }
    if (!canDispatch()) throw StateError('Retired');
    onDispatched();
    writes.add((endpoint, body));
    await pendingWrite?.future;
    if (saveFails) throw StateError('Save failed');
    final record =
        body['config']['update']['installs'][installId] as Map<String, dynamic>;
    savedRecord = Map.of(record);
    channel = record['channel'] as String;
    branch = channel == 'main' ? 'main' : null;
    targetVersion = channel == 'main' ? null : '0.21.7';
    error = null;
    targetSha = '3333333333333333333333333333333333333333';
    return {'ok': true};
  }
}
