import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_access.dart';
import 'package:wing/core/models/provider_recovery.dart';
import 'package:wing/core/services/provider_recovery.dart';
import 'support/administration_fixture.dart';

const pool = '''anthropic (3 credentials):
  #1  API key              api_key id=111aaa priority=0 env:ANTHROPIC_API_KEY
  #2  Separate login       oauth   id=222bbb priority=1 hermes_pkce
  #3  Claude work account  oauth   id=333ccc priority=2 claude_code ←
''';

Map<String, dynamic> claude({bool expired = true}) => {
  'id': 'claude-code',
  'name': 'Long Claude provider name',
  'flow': 'external',
  'disconnectable': false,
  'status': {
    'logged_in': true,
    'source': 'claude_code_cli',
    'source_label': '~/.claude/.credentials.json',
    'token_preview': '…test-only',
    'has_refresh_token': true,
    'expires_at': expired ? '2020-01-01T00:00:00Z' : '2099-01-01T00:00:00Z',
  },
};

void main() {
  test('current external-login notice does not obscure owned credentials', () {
    const notice =
        'External CLI logins (Codex CLI, Claude Code) are not adopted: '
        'auth.adopt_external_logins is false. '
        'Hermes uses only its own logins; run `hermes auth add <provider>` to add one.';
    for (final provider in ['anthropic', 'openai-codex']) {
      final listing = pool.replaceFirst('anthropic', provider);
      expect(
        ProviderCredential.parseList(
          provider,
          '$listing\n$notice\n',
        ).map((entry) => entry.id),
        ['111aaa', '222bbb', '333ccc'],
      );
      expect(ProviderCredential.parseList(provider, '$notice\n'), isEmpty);
      for (final invalid in [
        '$listing\n$notice\nUnexpected output',
        '$listing\n$notice\n$notice',
        '$notice\n$listing',
      ]) {
        expect(
          () => ProviderCredential.parseList(provider, invalid),
          throwsA(isA<ProviderRecoveryFailure>()),
        );
      }
    }
  });

  test(
    'matches the Claude source among different same-provider credentials',
    () {
      final renewal = ProviderRenewal.forAccess(ProviderAccess(claude()))!;
      final candidates = ProviderCredential.parseList(
        renewal.pool,
        pool,
      ).where(renewal.accepts).toList();
      expect(candidates.single.id, '333ccc');
      expect(candidates.single.label, 'Claude work account');
      expect(
        ProviderRenewal.forAccess(
          ProviderAccess({
            'id': 'unknown',
            'status': {'logged_in': true, 'has_refresh_token': true},
          }),
        ),
        isNull,
      );
    },
  );

  test('rejects partial and structurally ambiguous credential lists', () {
    for (final invalid in [
      pool.replaceFirst('(3 credentials)', '(4 credentials)'),
      pool.replaceFirst('333ccc', '111aaa'),
      '$pool... output truncated',
      pool.replaceFirst(
        'Claude work account',
        'Injected oauth id=444ddd priority=0 claude_code',
      ),
      pool.replaceFirst('Claude work account', 'Claude\nwork account'),
      pool.replaceFirst('anthropic', 'nous'),
    ]) {
      expect(
        () => ProviderCredential.parseList('anthropic', invalid),
        throwsA(isA<ProviderRecoveryFailure>()),
      );
    }
  });

  late AdministrationFixture fixture;
  late ProviderRecovery recovery;
  late Map<String, dynamic> observation;
  num modified = 10;
  setUp(() {
    fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    recovery = ProviderRecovery(
      fixture.server.profile('personal'),
      providerId: 'claude-code',
    );
    addTearDown(recovery.dispose);
    observation = claude();
    modified = 10;
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles/active') {
        return {'current': 'default', 'active': 'default'};
      }
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (path == 'providers/oauth') {
        return {
          'providers': [observation],
        };
      }
      if (path == 'files' && method == 'GET') {
        return {
          'path': '/home/server/.claude',
          'entries': [
            {
              'name': '.credentials.json',
              'path': '/home/server/.claude/.credentials.json',
              'size': 420,
              'mtime': modified,
              'is_directory': false,
            },
            {
              'name': 'settings.json',
              'path': '/home/server/.claude/settings.json',
              'size': 10,
              'mtime': 1,
              'is_directory': false,
            },
          ],
        };
      }
      if (path == 'files' && method == 'DELETE') {
        observation = {
          'id': 'claude-code',
          'flow': 'external',
          'status': {'logged_in': false},
        };
        return {'ok': true};
      }
      throw StateError('Unexpected request $method $path');
    };
    fixture.consoleOverride = (profile, command, {confirm = false}) async {
      if (command == 'auth list anthropic') return pool;
      expect(command, 'auth refresh anthropic 333ccc');
      expect(confirm, isTrue);
      observation = claude(expired: false);
      return 'Refreshed anthropic credential #3 (Claude work account); status: ok';
    };
  });

  test(
    'renewal revalidates selected ID and keeps explicit profile scope',
    () async {
      final access = await recovery.observe('claude-code');
      final entry = (await recovery.candidates(access)).single;
      final after = await recovery.renew(access, entry);
      expect(after.state, ProviderAccessState.connected);
      expect(fixture.consoleRequests, [
        ('personal', 'auth list anthropic', false),
        ('personal', 'auth list anthropic', false),
        ('personal', 'auth refresh anthropic 333ccc', true),
      ]);
      final reads = fixture.requests.where((r) => r.$2 == 'providers/oauth');
      expect(reads, isNotEmpty);
      expect(reads.map((r) => r.$3['profile']), everyElement('personal'));
    },
  );

  test('a new sign-in prevents mutation of the stale credential', () async {
    final before = await recovery.observe('claude-code');
    observation = claude(expired: false);
    await expectLater(
      recovery.renew(
        before,
        const ProviderCredential(
          '333ccc',
          'Claude work account',
          'oauth',
          'claude_code',
        ),
      ),
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    expect(fixture.consoleRequests, isEmpty);
  });

  test(
    'disappeared stable entry refuses renewal rather than selecting another',
    () async {
      final before = await recovery.observe('claude-code');
      fixture.consoleOverride = (_, _, {confirm = false}) async =>
          pool.replaceFirst('333ccc', '444ddd');
      await expectLater(
        recovery.renew(
          before,
          const ProviderCredential(
            '333ccc',
            'Claude work account',
            'oauth',
            'claude_code',
          ),
        ),
        throwsA(isA<ProviderRecoveryFailure>()),
      );
      expect(fixture.consoleRequests, [
        ('personal', 'auth list anthropic', false),
      ]);
    },
  );

  test(
    'file removal uses only canonical reviewed file and never profile scope',
    () async {
      final before = await recovery.observe('claude-code');
      final file = await recovery.inspectFile('~/.claude/.credentials.json');
      final after = await recovery.deleteFile(before, file);
      expect(after.hasCredential, isFalse);
      final writes = fixture.requests.where((r) => r.$1 == 'DELETE').toList();
      expect(writes.length, 1);
      expect(writes.single.$2, 'files');
      expect(writes.single.$3, isEmpty);
      expect(writes.single.$4, {
        'path': '/home/server/.claude/.credentials.json',
        'recursive': false,
      });
    },
  );

  test(
    'changed file prevents deletion, including a background token rotation',
    () async {
      final before = await recovery.observe('claude-code');
      final file = await recovery.inspectFile('~/.claude/.credentials.json');
      modified = 11;
      await expectLater(
        recovery.deleteFile(before, file),
        throwsA(isA<ProviderRecoveryFailure>()),
      );
      expect(fixture.requests.where((r) => r.$1 == 'DELETE'), isEmpty);
    },
  );

  test(
    'file adapter cannot delete a directory, arbitrary file, or traversal',
    () {
      for (final path in [
        '~/.claude',
        '/etc/passwd',
        '/home/server/../.credentials.json',
        'relative/.credentials.json',
      ]) {
        expect(
          () => ProviderCredentialFile.directory(path),
          throwsA(isA<ProviderRecoveryFailure>()),
        );
      }
      expect(
        () => ProviderCredentialFile.fromListing({
          'entries': [
            {
              'name': '.credentials.json',
              'path': '/tmp/.credentials.json',
              'is_directory': true,
              'mtime': 1,
              'size': 0,
            },
          ],
        }),
        throwsA(isA<ProviderRecoveryFailure>()),
      );
    },
  );
  test(
    'generic adapters honor current source authority and provider differences',
    () {
      for (final pair in [
        ('openai-codex', 'hermes-auth-store'),
        ('xai-oauth', 'hermes-auth-store'),
        ('nous', 'nous_portal'),
        ('anthropic', 'hermes_pkce'),
      ]) {
        final access = ProviderAccess({
          'id': pair.$1,
          'status': {
            'logged_in': true,
            'source': pair.$2,
            'has_refresh_token': pair.$1 != 'openai-codex',
          },
        });
        expect(ProviderRenewal.forAccess(access)!.pool, pair.$1);
      }
      for (final row in [
        {
          'id': 'nous',
          'status': {
            'logged_in': true,
            'source': 'nous_portal',
            'has_refresh_token': true,
            'free_tier': true,
          },
        },
        {
          'id': 'openai-codex',
          'status': {
            'logged_in': true,
            'source': 'env_var',
            'has_refresh_token': false,
          },
        },
        {
          'id': 'minimax-oauth',
          'status': {'logged_in': true, 'has_refresh_token': true},
        },
        {
          'id': 'claude-code',
          'status': {
            'logged_in': true,
            'source': 'claude_code_cli',
            'has_refresh_token': false,
          },
        },
      ]) {
        expect(ProviderRenewal.forAccess(ProviderAccess(row)), isNull);
      }
    },
  );
  test(
    'completed command with expired catalog is not healthy access',
    () async {
      final before = await recovery.observe('claude-code');
      fixture.consoleOverride = (_, command, {confirm = false}) async =>
          command.startsWith('auth list')
          ? pool
          : 'Adopted current tokens; status still: exhausted';
      final entry = (await recovery.candidates(before)).single;
      expect(
        (await recovery.renew(before, entry)).state,
        ProviderAccessState.expired,
      );
    },
  );
  test(
    'successful command with failed reread reports partial completion',
    () async {
      final before = await recovery.observe('claude-code');
      final entry = (await recovery.candidates(before)).single;
      fixture.consoleOverride = (_, command, {confirm = false}) async {
        if (command.startsWith('auth list')) return pool;
        fixture.override = (_, _, _, _) async => throw StateError('offline');
        return 'Refreshed';
      };
      await expectLater(
        recovery.renew(before, entry),
        throwsA(
          isA<ProviderRecoveryFailure>().having(
            (e) => e.message,
            'partial outcome',
            contains('completed the renewal command'),
          ),
        ),
      );
      expect(fixture.consoleRequests.where((r) => r.$3).length, 1);
    },
  );
  test('stable ID that aliases a sibling label is not a safe target', () async {
    fixture.consoleOverride = (_, _, {confirm = false}) async =>
        pool.replaceFirst('Separate login', '333ccc');
    expect(await recovery.candidates(ProviderAccess(observation)), isEmpty);
  });
  test('pool-backed Codex and xAI match reported label then use stable ID', () {
    for (final id in ['openai-codex', 'xai-oauth']) {
      final adapter = ProviderRenewal.forAccess(
        ProviderAccess({
          'id': id,
          'status': {
            'logged_in': true,
            'source': 'pool:Work account',
            'has_refresh_token': id != 'openai-codex',
          },
        }),
      )!;
      final output =
          '$id (2 credentials):\n  #1  Personal account oauth id=111aaa priority=0 device_code\n  #2  Work account oauth id=222bbb priority=1 device_code ←\n';
      expect(
        ProviderCredential.parseList(
          adapter.pool,
          output,
        ).where(adapter.accepts).single.id,
        '222bbb',
      );
    }
  });
  test('listener retirement revokes refresh before its first read', () async {
    recovery.addListener(recovery.dispose);
    await recovery.refresh();
    expect(fixture.requests, isEmpty);
    expect(fixture.consoleRequests, isEmpty);
  });

  test(
    'retained recovery facts are detached from later wire mutation',
    () async {
      await recovery.refresh();
      final retained = recovery.state.observation!;
      final expectedSource = retained.sourceLabel;
      observation['name'] = 'Changed elsewhere';
      (observation['status'] as Map)['source_label'] = 'other-source';
      expect(recovery.state.observation!.sourceLabel, expectedSource);
      expect(retained.name, 'Claude Code');
      expect(retained.reportedName, 'Long Claude provider name');
    },
  );
}
