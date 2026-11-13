import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/testing/test_batches.dart';

void main() {
  for (final control in [
    "if (configureGlobalState()) { test('case', () {}); }",
    "for (final item in installGlobalFixture()) { test('case', () {}); }",
    "for (var i = initializeGlobalState(); i < 1; i++) { test('case', () {}); }",
    "for (var i = 0; shouldRegisterNext(); i++) { test('case', () {}); }",
    "for (var i = 0; i < 1; resetGlobalState()) { test('case', () {}); }",
  ]) {
    test('registration control effects remain isolated: $control', () {
      expect(
        canBatch('test/example_test.dart', 'void main() { $control }'),
        isFalse,
      );
    });
  }

  test('literal case matrices remain eligible for batching', () {
    expect(
      canBatch('test/example_test.dart', '''
void main() {
  for (final enabled in [true, false]) {
    if (enabled) { test('enabled case', () {}); }
  }
}
'''),
      isTrue,
    );
  });

  test(
    'dispatcher discovers every proof main and rejects unknown signatures',
    () {
      final root = Directory.systemTemp.createTempSync('wing-proof-plan-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final proofs = Directory('${root.path}/tools/architecture/tests')
        ..createSync(recursive: true);
      File('${proofs.path}/sync_test.dart').writeAsStringSync('void main() {}');
      File(
        '${proofs.path}/async_test.dart',
      ).writeAsStringSync('Future<void> main(List<String> args) async {}');
      final output = Directory('${root.path}/output')..createSync();
      final commands = createProofDispatcher(root, output);
      expect(commands, hasLength(2));
      final generated = File('${output.path}/proofs.dart').readAsStringSync();
      for (final command in commands) {
        expect(generated, contains(command));
      }
      expect(generated, contains('Future<void>.sync'));
      expect(generated, contains('Unregistered proof'));
      File(
        '${proofs.path}/unsupported_test.dart',
      ).writeAsStringSync('void main(int unexpected) {}');
      expect(() => createProofDispatcher(root, output), throwsFormatException);
    },
  );

  test(
    'ordinary registration preserves per-group setup and test callbacks',
    () {
      expect(
        canBatch('test/example_test.dart', '''
void main() {
  late Object owner;
  setUp(() { owner = Object(); });
  tearDown(() { owner = Object(); });
  for (var index = 0; index < 3; index++) {
    test('case', () { expect(owner, isNotNull); });
  }
}
'''),
        isTrue,
      );
    },
  );

  test('special bindings, fonts, startup state and unscoped effects isolate', () {
    for (final source in [
      "import 'dart:io'; void main() { test('network', () { HttpServer.bind('localhost', 0); }); }",
      "void main() { test('socket', () { connectWebSocket(); }); }",
      "void main() { FontLoader('Roboto'); test('x', () {}); }",
      "void main() { final owner = ProfileWorkspaceController(); test('x', () {}); }",
      "void main() { SharedPreferences.setMockInitialValues({}); test('x', () {}); }",
      "void main() { debugDefaultTargetPlatformOverride = null; test('x', () {}); }",
      "Future<void> main() async { test('x', () {}); }",
      "void main() { configureUnknownState(); test('x', () {}); }",
    ]) {
      expect(
        canBatch('test/example_test.dart', source),
        isFalse,
        reason: source,
      );
    }
    expect(canBatch('test/work_budget_test.dart', 'void main() {}'), isFalse);
    expect(canBatch('test/service_live_test.dart', 'void main() {}'), isFalse);
    expect(canBatch('test/live_service_test.dart', 'void main() {}'), isFalse);
    expect(
      canBatch('test/message_delivery_test.dart', 'void main() {}'),
      isTrue,
    );
    const perCasePreferences = '''
void main() {
  testWidgets('case', (tester) async {
    SharedPreferences.setMockInitialValues({});
  });
}
''';
    expect(
      canBatch(
        'test/unknown_test.dart',
        perCasePreferences,
        reviewedWidget: true,
      ),
      isFalse,
    );
    expect(
      canBatch(
        'test/doctor_chat_test.dart',
        perCasePreferences,
        reviewedWidget: true,
      ),
      isTrue,
    );
  });

  test(
    'pure lanes admit transport values and keep bindings and real I/O isolated',
    () {
      expect(
        canBatch('test/value_snapshot_test.dart', '''
void main() {
  test('captured HTTP failure', () {
    final owner = fixture.server.profile('work');
    expect(owner, isNotNull);
    throw DashboardHttpException(403, 'fixture');
  });
}
''', pure: true),
        isTrue,
      );
      for (final source in [
        "void main() { testWidgets('x', (tester) async {}); }",
        "void main() { TestWidgetsFlutterBinding.ensureInitialized(); test('x', () {}); }",
        "void main() { test('x', () { HttpServer.bind('localhost', 0); }); }",
        "void main() { test('x', () { File.fromUri(uri); }); }",
        "void main() { test('x', () { Socket.connect('localhost', 0); }); }",
      ]) {
        expect(canBatch('test/value_test.dart', source, pure: true), isFalse);
      }
    },
  );

  test(
    'proofs, pure tests and widget bindings use separate batch lifetimes',
    () {
      final root = Directory.systemTemp.createTempSync('wing-lane-plan-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/test').createSync();
      final sources = {
        'test/browser_row_work_guard_test.dart':
            "void main() { test('proof', () { Process.run('dart', []); }); }",
        'test/ordinary_test.dart': "void main() { test('value', () {}); }",
        'test/widget_test.dart':
            "void main() { testWidgets('view', (tester) async {}); }",
      };
      for (final entry in sources.entries) {
        File('${root.path}/${entry.key}').writeAsStringSync(entry.value);
      }
      final plan = createTestPlan(
        root,
        Directory('${root.path}/build'),
        count: 2,
        full: true,
      );
      expect(plan.isolated, isEmpty);
      expect(
        plan.batches.expand((batch) => batch).toSet(),
        sources.keys.toSet(),
      );
      expect(plan.batches.where((batch) => batch.isNotEmpty), hasLength(3));
      expect(plan.batches[0], ['test/ordinary_test.dart']);
      expect(plan.batches[2], ['test/widget_test.dart']);
      expect(plan.batches[4], ['test/browser_row_work_guard_test.dart']);
    },
  );

  test('routine schedules checker proofs and retains every product suite', () {
    final root = Directory.systemTemp.createTempSync('wing-cadence-plan-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/test').createSync();
    final names = [
      'test/browser_row_work_guard_test.dart',
      'test/required_quality_gates_test.dart',
      'test/scheduled_tasks_blueprint_contract_test.dart',
      'test/scheduled_tasks_schedule_projection_test.dart',
      'test/new_security_guard_test.dart',
    ];
    for (final name in names) {
      File(
        '${root.path}/$name',
      ).writeAsStringSync("void main() { test('case', () {}); }");
    }
    final routine = createTestPlan(root, Directory('${root.path}/routine'));
    expect(routine.scheduled, [names[0], names[1]]);
    final selected = [
      ...routine.isolated,
      ...routine.batches.expand((batch) => batch),
    ];
    expect(selected.toSet(), names.skip(2).toSet());
    expect({...selected, ...routine.scheduled}, names.toSet());
    final full = createTestPlan(
      root,
      Directory('${root.path}/full'),
      full: true,
    );
    expect(full.scheduled, isEmpty);
    expect({
      ...full.isolated,
      ...full.batches.expand((batch) => batch),
    }, names.toSet());
  });

  test(
    'every original main is represented exactly once, including isolation',
    () {
      final root = Directory.systemTemp.createTempSync('wing-batch-plan-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/test').createSync();
      File(
        '${root.path}/test/ordinary_test.dart',
      ).writeAsStringSync("void main() { test('x', () {}); }");
      File(
        '${root.path}/test/live_test.dart',
      ).writeAsStringSync("void main() { test('y', () {}); }");
      final plan = createTestPlan(
        root,
        Directory('${root.path}/build'),
        count: 2,
      );
      expect(plan.files, ['test/live_test.dart', 'test/ordinary_test.dart']);
      expect(plan.isolated, ['test/live_test.dart']);
      expect(plan.batches.expand((batch) => batch), [
        'test/ordinary_test.dart',
      ]);
      expect(plan.targets, hasLength(2));
      final generated = File(
        plan.targets.singleWhere((name) => name.endsWith('batch_0_test.dart')),
      ).readAsStringSync();
      expect(generated, contains('suite0.main'));
      expect(generated, contains('test/ordinary_test.dart'));
      expect(generated, isNot(contains('live_test.dart')));
    },
  );
}
