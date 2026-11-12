/// Explicit measurement opt-in for QA tools and tests.
///
/// Release compilation always disables instrumentation, even when the opt-in
/// flag is supplied. Keep this module Flutter-independent for worker isolates
/// and standalone parser benchmarks.
class PerformanceInstrumentation {
  static const enabled =
      bool.fromEnvironment('WING_PERF_INSTRUMENTATION') &&
      !bool.fromEnvironment('dart.vm.product');
}
