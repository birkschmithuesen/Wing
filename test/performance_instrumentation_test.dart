import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/completion_diagnostics.dart';
import 'package:wing/core/services/performance_instrumentation.dart';

void main() {
  tearDown(CompletionDiagnostics.reset);

  test('completion measurements require explicit opt-in', () {
    CompletionDiagnostics.reset();
    final started = CompletionDiagnostics.start();
    CompletionDiagnostics.event('qa.event');
    CompletionDiagnostics.finish('qa.duration', started);
    final report = CompletionDiagnostics.snapshot();
    if (PerformanceInstrumentation.enabled) {
      expect(started, greaterThan(0));
      expect(report['enabled'], true);
      expect(report['written'], 2);
      expect((report['events'] as List).length, 2);
      expect(
        (report['totals'] as Map).keys,
        containsAll(['qa.event', 'qa.duration']),
      );
    } else {
      expect(started, 0);
      expect(report, {'enabled': false});
    }
  });
}
