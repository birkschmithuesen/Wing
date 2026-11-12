import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';

void main() {
  group('GatewaySensitivePromptRequest', () {
    test('parses an official sudo request', () {
      final request = GatewaySensitivePromptRequest.fromEventData(
        kind: GatewaySensitivePromptKind.sudo,
        data: {'request_id': 'sudo-123'},
      );

      expect(request, isNotNull);
      expect(request!.requestId, 'sudo-123');
      expect(request.kind, GatewaySensitivePromptKind.sudo);
      expect(request.fieldLabel, 'Sudo password');
    });

    test('parses the secret label and prompt without retaining a value', () {
      final request = GatewaySensitivePromptRequest.fromEventData(
        kind: GatewaySensitivePromptKind.secret,
        data: {
          'request_id': 'secret-123',
          'env_var': 'FIXTURE_API_TOKEN',
          'prompt': 'Enter a synthetic token',
        },
      );

      expect(request, isNotNull);
      expect(request!.title, 'FIXTURE_API_TOKEN');
      expect(request.description, 'Enter a synthetic token');
    });

    test('ignores a request without request_id', () {
      expect(
        GatewaySensitivePromptRequest.fromEventData(
          kind: GatewaySensitivePromptKind.secret,
          data: {'env_var': 'MISSING_ID'},
        ),
        isNull,
      );
    });

    for (final entry
        in <
              String,
              ({
                GatewaySensitivePromptKind kind,
                Map<String, dynamic> data,
                String title,
                String? field,
                String? description,
              })
            >{
              'unlock': (
                kind: GatewaySensitivePromptKind.vaultUnlock,
                data: {
                  'request_id': 'unlock-1',
                  'backend': 'onepassword',
                  'display_name': '1Password',
                },
                title: 'Unlock 1Password',
                field: 'Master password',
                description: null,
              ),
              'save login': (
                kind: GatewaySensitivePromptKind.vaultSaveLogin,
                data: {
                  'request_id': 'save-1',
                  'origin': 'https://example.test',
                  'site': 'Example',
                },
                title: 'Save login for Example',
                field: 'Identifier',
                description: null,
              ),
              'code': (
                kind: GatewaySensitivePromptKind.vaultCode,
                data: {
                  'request_id': 'code-1',
                  'site': 'Example',
                  'hint': 'Use your authenticator app.',
                },
                title: 'Enter code for Example',
                field: null,
                description: 'Use your authenticator app.',
              ),
            }
            .entries) {
      test('parses vault ${entry.key} request metadata', () {
        final request = GatewaySensitivePromptRequest.fromEventData(
          kind: entry.value.kind,
          data: entry.value.data,
        )!;
        expect(request.requestId, entry.value.data['request_id']);
        expect(request.title, entry.value.title);
        if (entry.value.field != null) {
          expect(request.fieldLabel, entry.value.field);
        }
        if (entry.value.description != null) {
          expect(request.description, entry.value.description);
        }
      });
    }

    const cases = [
      ('sudo', 'sudo-1', GatewaySensitivePromptKind.sudo),
      ('secret', 'secret-1', GatewaySensitivePromptKind.secret),
      (
        'vault.unlock_prompt',
        'unlock-1',
        GatewaySensitivePromptKind.vaultUnlock,
      ),
      ('vault.save_login', 'save-1', GatewaySensitivePromptKind.vaultSaveLogin),
      ('vault.code', 'code-1', GatewaySensitivePromptKind.vaultCode),
    ];
    for (final value in cases) {
      test('parses authoritative ${value.$1} pending-sensitive request', () {
        final request = GatewaySensitivePromptRequest.fromServerRequest({
          'id': value.$2,
          'method': value.$1,
          'params': {},
        });
        expect(request?.requestId, value.$2);
        expect(request?.kind, value.$3);
      });
    }

    for (final entry in <String, Object?>{
      'null': null,
      'empty': const {},
      'unknown method': {'id': 'id', 'method': 'unknown', 'params': {}},
      'non-object params': {
        'id': 'id',
        'method': 'sudo',
        'params': 'not-an-object',
      },
      'missing identity': {'method': 'sudo', 'params': {}},
      'non-string identity': {'id': 7, 'method': 'sudo', 'params': {}},
      'non-string prompt': {
        'id': 'id',
        'method': 'secret',
        'params': {'prompt': 7},
      },
      'supplied password': {
        'id': 'id',
        'method': 'sudo',
        'params': {'password': 'must-not-appear'},
      },
    }.entries) {
      test('rejects ${entry.key} pending-sensitive snapshot', () {
        expect(
          GatewaySensitivePromptRequest.fromServerRequest(entry.value),
          isNull,
        );
      });
    }
  });
}
