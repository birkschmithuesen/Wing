import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/gateway_endpoint.dart';

void main() {
  group('Remote file gateway URL derivation', () {
    test('derives the Desktop gateway from dashboard details by default', () {
      final connection = SavedConnection(
        id: 'miniserver',
        label: 'Miniserver',
        host: 'carlos-miniserver.taild544f6.ts.net',
        port: 8642,
        apiKey: 'test-key',
        dashboardPortOverride: 9119,
        dashboardUsername: 'carlos',
        dashboardPassword: 'secret',
      );

      expect(
        normalizedGatewayBaseUrl(connection),
        'http://carlos-miniserver.taild544f6.ts.net:9119',
      );
    });

    test(
      'ignores a redundant same-host override and derives dashboard port',
      () {
        final connection = SavedConnection(
          id: 'miniserver',
          label: 'Miniserver',
          host: 'carlos-miniserver.taild544f6.ts.net',
          port: 8642,
          apiKey: 'test-key',
          dashboardPortOverride: 9119,
          desktopGatewayUrl: 'https://carlos-miniserver.taild544f6.ts.net',
        );

        expect(
          normalizedGatewayBaseUrl(connection),
          'http://carlos-miniserver.taild544f6.ts.net:9119',
        );
      },
    );

    test('preserves an explicit Desktop gateway override', () {
      final connection = SavedConnection(
        id: 'remote',
        label: 'Remote',
        host: 'api.example.test',
        port: 8642,
        apiKey: 'test-key',
        useHttps: true,
        dashboardPortOverride: 9119,
        desktopGatewayUrl: 'https://desktop.example.test/gateway',
      );

      expect(
        normalizedGatewayBaseUrl(connection),
        'https://desktop.example.test:443/gateway',
      );
    });

    test('includes the dashboard path prefix in the derived URL', () {
      final connection = SavedConnection(
        id: 'proxied',
        label: 'Proxied',
        host: 'hermes.example.test',
        port: 443,
        apiKey: 'test-key',
        useHttps: true,
        dashboardPrefix: 'dashboard',
      );

      expect(
        normalizedGatewayBaseUrl(connection),
        'https://hermes.example.test:443/dashboard',
      );
    });
  });
}
