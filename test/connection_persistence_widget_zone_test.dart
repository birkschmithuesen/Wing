import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default credential store settles across independently drained zones', () {
    void completeLifecycle(int iteration) {
      final microtasks = <void Function()>[];
      var complete = false;
      Object? failure;
      runZoned(
        () async {
          try {
            FlutterSecureStorage.setMockInitialValues({});
            SharedPreferences.setMockInitialValues({});
            final prefs = await SharedPreferences.getInstance();
            final manager = await ConnectionManager.create(prefs);
            await manager.importConnections(
              [
                SavedConnection(
                  id: 'widget-$iteration',
                  label: 'Widget $iteration',
                  host: 'widget.example',
                  port: 443,
                  apiKey: 'synthetic-widget-$iteration',
                ),
              ],
              replaceExisting: true,
              canCommit: () => true,
            );
            expect(
              manager.getConnections().single.apiKey,
              'synthetic-widget-$iteration',
            );
            complete = true;
          } catch (error) {
            failure = error;
          }
        },
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, task) {
            microtasks.add(() => zone.runGuarded(task));
          },
        ),
      );
      for (var steps = 0; microtasks.isNotEmpty && steps < 10000; steps++) {
        microtasks.removeAt(0)();
      }
      expect(microtasks, isEmpty, reason: 'Storage operations must quiesce.');
      expect(failure, isNull);
      expect(
        complete,
        isTrue,
        reason:
            'A queue retained in a drained earlier zone must not strand lifecycle $iteration.',
      );
    }

    // A finished lifecycle never drains its microtasks again. Both lifecycles
    // belong to this test so selection and randomization retain the regression.
    completeLifecycle(1);
    completeLifecycle(2);
  });
}
