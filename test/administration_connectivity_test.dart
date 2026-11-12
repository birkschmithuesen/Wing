import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/administration_fixture.dart';

void main() {
  testWidgets(
    'diagnostic retries a refused connection and returns the started operation',
    (tester) async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var attempts = 0;
      fixture.override = (method, path, query, body) async {
        if (++attempts == 1) {
          throw const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 111),
          );
        }
        return {'ok': true, 'name': 'security-audit', 'pid': 7};
      };
      final starting = fixture.server.startDiagnostic(
        'ops/security-audit',
        isActive: () => true,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final action = await starting;
      expect(action.pid, 7);
      expect(attempts, 2);
    },
  );
}
