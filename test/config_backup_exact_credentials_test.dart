import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/config_backup.dart';

void main() {
  for (final encrypted in [false, true]) {
    test(
      '${encrypted ? 'Encrypted' : 'Plain'} backup preserves exact password bytes',
      () async {
        // Synthetic credentials; surrounding whitespace is part of the password.
        const password = '  fixture-password\t ';
        final backup = ConfigBackup(
          createdAt: DateTime.utc(2026, 10, 4),
          appVersion: 'fixture',
          connections: [
            SavedConnection(
              id: 'exact-password-fixture',
              label: 'Fixture',
              icon: ConnectionIcon.server,
              host: '127.0.0.1',
              port: 8642,
              apiKey: '',
              useHttps: false,
              dashboardUsername: 'fixture-user',
              dashboardPassword: password,
            ),
          ],
          preferences: const {},
        );
        final passphrase = encrypted ? 'fixture-encryption' : '';
        final contents = await ConfigBackupCodec.encode(
          backup,
          passphrase: passphrase,
          iterations: 1000,
        );
        final restored = await ConfigBackupCodec.decode(
          contents,
          passphrase: passphrase,
        );

        expect(restored.connections.single.dashboardPassword, password);
      },
    );
  }
}
