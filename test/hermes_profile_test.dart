import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';

void main() {
  group('HermesProfile', () {
    test('keeps canonical routing identity separate from its label', () {
      final profile = HermesProfile.fromJson({
        'name': 'client-work',
        'display_name': 'Client Work',
        'is_default': false,
        'provider': 'openai-codex',
        'model': 'gpt-5.6-luna',
      });

      expect(profile.name, 'client-work');
      expect(profile.label, 'Client Work');
      expect(profile.provider, 'openai-codex');
    });

    test('falls back to the canonical name for an empty display name', () {
      final profile = HermesProfile.fromJson({
        'name': 'default',
        'display_name': '',
      });

      expect(profile.label, 'default');
    });

    test('rejects a name the server cannot route safely', () {
      expect(
        () => HermesProfile.fromJson({'name': '../default'}),
        throwsFormatException,
      );
    });

    test('accepts canonical letters digits underscores and hyphens', () {
      expect(HermesProfile.isCanonicalName('qa_profile-2'), isTrue);
    });
  });

  group('WorkspaceScope', () {
    test('is typed and produces an opaque stable storage namespace', () {
      final first = WorkspaceScope(
        connectionId: 'host/with separators',
        profileName: 'client-work',
      );
      final second = WorkspaceScope(
        connectionId: 'host/with separators',
        profileName: 'client-work',
      );

      expect(first, second);
      expect(first.storageNamespace, second.storageNamespace);
      expect(first.storageNamespace, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(first.storageNamespace, isNot(contains('host')));
      expect(first.storageNamespace, isNot(contains('client-work')));
    });

    for (final changed in ['connection', 'profile', 'authentication']) {
      test('storage ownership is isolated by $changed', () {
        final original = WorkspaceScope(
          connectionId: 'connection-a',
          profileName: 'default',
          connectionIdentity: 'authentication-a',
        );
        final other = WorkspaceScope(
          connectionId: changed == 'connection'
              ? 'connection-b'
              : 'connection-a',
          profileName: changed == 'profile' ? 'work' : 'default',
          connectionIdentity: changed == 'authentication'
              ? 'authentication-b'
              : 'authentication-a',
        );
        expect(other, isNot(original));
        expect(other.storageNamespace, isNot(original.storageNamespace));
      });
    }

    test('refuses an empty connection identity', () {
      expect(
        () => WorkspaceScope(connectionId: '', profileName: 'default'),
        throwsArgumentError,
      );
    });

    test('refuses a non-canonical profile', () {
      expect(
        () => WorkspaceScope(connectionId: 'conn', profileName: 'Client Work'),
        throwsArgumentError,
      );
    });
  });
}
