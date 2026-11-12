import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/profile_connection_identity.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'singleton identity resolves across independently drained lifecycle zones',
    () {
      FlutterSecureStorage.setMockInitialValues({});
      final identity = ProfileConnectionIdentity();

      // Each lifecycle owns its own microtask queue. After it ends that queue
      // stops being drained, as happens between independent widget test clocks.
      // Keeping both lifecycles in one test makes the regression safe to filter
      // or randomize without depending on another test's side effects.
      String? resolveInLifecycle() {
        final microtasks = <void Function()>[];
        String? result;
        runZoned(
          () => identity.resolve(identityTestConnection()).then((value) {
            result = value;
          }),
          zoneSpecification: ZoneSpecification(
            scheduleMicrotask: (self, parent, zone, task) {
              microtasks.add(() => zone.runGuarded(task));
            },
          ),
        );
        for (var steps = 0; microtasks.isNotEmpty && steps < 10000; steps++) {
          microtasks.removeAt(0)();
        }
        expect(
          microtasks,
          isEmpty,
          reason: 'Identity resolution must quiesce.',
        );
        return result;
      }

      final first = resolveInLifecycle();
      expect(first, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(resolveInLifecycle(), first);
    },
  );
}
