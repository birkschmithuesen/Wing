import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Uses real HTTP clients for tests that own loopback HTTP/WebSocket servers.
/// Flutter's widget binding otherwise replaces them with empty 400 responses.
void useRealHttpClientsForLoopbackFixtures() {
  HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
  });
  tearDown(() {
    HttpOverrides.global = previousOverrides;
  });
}

// HttpOverrides' base implementation constructs the actual dart:io client.
class _RealHttpOverrides extends HttpOverrides {}
