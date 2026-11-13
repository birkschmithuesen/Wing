import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_access.dart';

void main() {
  final now = DateTime.utc(2026, 9, 14);
  ProviderAccess access(Map<String, dynamic> status, {bool external = false}) =>
      ProviderAccess({
        'status': status,
        'flow': external ? 'external' : 'device_code',
      }, now: now);

  test(
    'expiry overrides a positive login snapshot without claiming renewal failed',
    () {
      final value = access({
        'logged_in': true,
        'expires_at': '2026-09-13T00:00:00Z',
        'has_refresh_token': true,
      });
      expect(value.state, ProviderAccessState.expired);
      expect(value.detail, contains('has not been checked'));
      expect(value.signInLabel, 'Sign in again');
      expect(value.needsAttention, isTrue);
    },
  );

  for (final entry in <String, Object>{
    'milliseconds': now.millisecondsSinceEpoch,
    'seconds': now.millisecondsSinceEpoch / 1000,
    'numeric text': '${now.millisecondsSinceEpoch}',
    'zoned ISO': '2026-09-14T08:00:00+08:00',
  }.entries) {
    test('${entry.key} expiry is parsed and expires at the boundary', () {
      expect(providerStatusDate(entry.value), now);
      expect(
        access({'logged_in': true, 'expires_at': entry.value}).state,
        ProviderAccessState.expired,
      );
    });
  }
  for (final entry in <String, Object?>{
    'missing': null,
    'empty': '',
    'unrecognized': 'invalid',
    'unzoned ISO': '2026-09-14T00:00:00',
    'infinity': double.infinity,
    'negative': -1,
    'out of range': 1e30,
  }.entries) {
    test('${entry.key} expiry remains unknown', () {
      expect(providerStatusDate(entry.value), isNull);
    });
  }
  for (final entry
      in <
            String,
            ({
              Map<String, dynamic> status,
              bool external,
              ProviderAccessState expected,
            })
          >{
            'missing metadata': (
              status: {},
              external: false,
              expected: ProviderAccessState.unknown,
            ),
            'failed check': (
              status: {'logged_in': false, 'error': 'failed'},
              external: false,
              expected: ProviderAccessState.unknown,
            ),
            'external credentials': (
              status: {'logged_in': false},
              external: true,
              expected: ProviderAccessState.external,
            ),
            'signed out': (
              status: {'logged_in': false},
              external: false,
              expected: ProviderAccessState.signedOut,
            ),
          }
          .entries) {
    test('${entry.key} has its own access state', () {
      expect(
        access(entry.value.status, external: entry.value.external).state,
        entry.value.expected,
      );
    });
  }
  test('connected credentials can have no supplied expiry', () {
    final connected = access({'logged_in': true, 'expires_at': null});
    expect(connected.state, ProviderAccessState.connected);
    expect(connected.expiresAt, isNull);
  });
}
