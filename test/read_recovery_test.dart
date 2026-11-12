import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/network_availability.dart';
import 'package:wing/core/widgets/read_recovery.dart';

Future<void> resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

Future<void> networkReturn(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'com.tarkilhk.wing/network',
    const StandardMethodCodec().encodeMethodCall(const MethodCall('available')),
    (_) {},
  );
  await tester.pump();
}

void main() {
  late GlobalKey<NavigatorState> navigator;
  late int calls;
  late bool failed;
  Completer<void>? pending;

  setUp(() {
    navigator = GlobalKey<NavigatorState>();
    calls = 0;
    failed = true;
    pending = null;
  });

  Future<void> render(
    WidgetTester tester, {
    bool recoverOnEntry = false,
  }) async {
    final network = NetworkAvailability()..start(() {}, () {});
    addTearDown(network.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ReadRecovery(
          shouldRetry: () => failed,
          retry: () async {
            calls++;
            await pending?.future;
          },
          recoverOnEntry: recoverOnEntry,
          child: const Scaffold(body: Text('Read')),
        ),
      ),
    );
  }

  for (final recoverOnEntry in [false, true]) {
    testWidgets('entry recovery is opt-in: $recoverOnEntry', (tester) async {
      await render(tester, recoverOnEntry: recoverOnEntry);
      expect(calls, recoverOnEntry ? 1 : 0);
    });
  }

  testWidgets('elapsed time alone never retries a failed read', (tester) async {
    await render(tester);
    await resume(tester);
    expect(calls, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1);
  });

  for (final trigger in ['resume', 'network']) {
    testWidgets('$trigger retries a visible failed read', (tester) async {
      await render(tester);
      expect(calls, 0);
      if (trigger == 'resume') {
        await resume(tester);
      } else {
        await networkReturn(tester);
      }
      expect(calls, 1);
    });
  }

  testWidgets('overlapping recovery signals share the pending read', (
    tester,
  ) async {
    await render(tester);
    pending = Completer<void>();
    await networkReturn(tester);
    await resume(tester);
    await networkReturn(tester);
    expect(calls, 1);
    pending!.complete();
    await tester.pump();
    pending = null;
    await networkReturn(tester);
    expect(calls, 2);
  });

  testWidgets('a covered route retries only when revealed again', (
    tester,
  ) async {
    await render(tester);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await resume(tester);
    await networkReturn(tester);
    expect(calls, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('network restoration waits until the app is foregrounded', (
    tester,
  ) async {
    await render(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await networkReturn(tester);
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('a successful read no longer responds to recovery signals', (
    tester,
  ) async {
    await render(tester);
    await resume(tester);
    expect(calls, 1);
    failed = false;
    await resume(tester);
    await networkReturn(tester);
    expect(calls, 1);
  });

  testWidgets('departure removes lifecycle and network recovery listeners', (
    tester,
  ) async {
    await render(tester);
    await tester.pumpWidget(const SizedBox());
    await resume(tester);
    await networkReturn(tester);
    expect(calls, 0);
  });
}
