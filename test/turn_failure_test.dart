import 'dart:async';
import 'support/form_family_capture.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/turn_failure.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/turn_failure_view.dart';

Map<String, dynamic> limitedTurn() => {
  'status': 'error',
  'error': 'Provider diagnostic with a private endpoint',
  'error_surface': {
    'layer': 'billing',
    'code': 'usage_limit',
    'retryable': false,
    'provider': 'nous',
    'model': 'large',
    'usage_limit': {
      'limit_name': 'Daily',
      'message': 'Daily allowance exhausted',
      'scope': 'all',
      'resets_at_ms': 1793203200000,
      'suggestions': [
        {
          'provider': 'nous',
          'model': 'free',
          'label': 'Free model',
          'note': 'free',
        },
      ],
      'credits': {'action': 'use_credits'},
    },
  },
};

void main() {
  setUpAll(loadFormFamilyFonts);
  test('local endpoint recovery never offers provider sign-in', () {
    final failure = TurnFailure.fromCompletion({
      'status': 'error',
      'error_surface': {
        'code': 'local_runtime_unavailable',
        'layer': 'endpoint',
      },
    })!;
    expect(failure.canReviewProvider, isFalse);
    expect(failure.canChooseModel, isTrue);
    expect(failure.recovery, contains('Start the local model server'));
    expect(failure.blocking, isTrue);
  });
  test('cut-off replies expose explicit Continue as degraded recovery', () {
    final failure = TurnFailure.fromCompletion({
      'status': 'error',
      'error_surface': {'code': 'truncated', 'layer': 'streaming'},
    })!;
    expect(failure.canContinue, isTrue);
    expect(failure.blocking, isFalse);
  });
  test(
    'launch credential refusal requires a new chat and keeps supplied explanation',
    () {
      final failure = TurnFailure.fromCompletion({
        'status': 'error',
        'error_surface': {
          'code': 'launch_credentials_unavailable',
          'layer': 'auth',
          'message': 'The original launch key is no longer available.',
          'provider': 'nous',
          'provider_label': 'Nous Portal',
        },
      })!;
      expect(failure.recovery, contains('start a new chat'));
      expect(
        failure.description,
        'The original launch key is no longer available.',
      );
      expect(failure.providerLabel, 'Nous Portal');
    },
  );
  test(
    'structured failure retains exact identity without leaking diagnostics to notifications',
    () {
      final failure = TurnFailure.fromCompletion(limitedTurn())!;
      expect(failure.retryable, isFalse);
      expect(failure.provider, 'nous');
      expect(failure.model, 'large');
      expect(
        failure.usageLimit!.resetsAt!.millisecondsSinceEpoch,
        1793203200000,
      );
      expect(failure.usageLimit!.suggestions.single.model, 'free');
      final notification = ChatNotificationContent.failure(failure);
      expect(notification.status, 'Plan allowance reached');
      expect(notification.preview, isNot(contains('private endpoint')));
      expect(
        TurnFailure.fromCompletion({
          'status': 'complete',
          'error_surface': limitedTurn()['error_surface'],
        }),
        isNull,
      );
    },
  );

  test(
    'unknown descriptors do not invent retry or recovery, bad epochs stay absent',
    () {
      final failure = TurnFailure.fromCompletion({
        'status': 'error',
        'error_surface': {
          'code': 'future_failure',
          'resets_at': double.infinity,
        },
      })!;
      expect(failure.retryable, isNull);
      expect(failure.resetsAt, isNull);
      expect(failure.recovery, isNull);
      expect(failure.canChooseModel, isFalse);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Continue failure holds feedback $brightness $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final held = Completer<void>();
        var calls = 0;
        final failure = TurnFailure.fromCompletion({
          'status': 'error',
          'error': 'Response ended early',
          'error_surface': {'code': 'truncated', 'layer': 'streaming'},
        })!;
        await tester.pumpWidget(
          RepaintBoundary(
            key: formFamilyCapture,
            child: MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: TurnFailureView(
                    failure: failure,
                    onContinue: () {
                      calls++;
                      return held.future;
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await captureFormFamily(
          tester,
          'failure-continue-${brightness.name}-$scale',
        );
        await tester.ensureVisible(find.byTooltip('Continue'));
        await tester.pump();
        expect(find.byTooltip('Continue').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Continue'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await captureFormFamily(
          tester,
          'failure-continue-pending-${brightness.name}-$scale',
        );
        await tester.ensureVisible(find.byTooltip('Continue'));
        await tester.pump();
        expect(find.byTooltip('Continue').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Continue'));
        expect(calls, 1);
        held.completeError(StateError('Connection unavailable'));
        await tester.pump();
        await tester.pump();
        final feedback = find.textContaining('Connection unavailable');
        await tester.ensureVisible(feedback);
        await tester.pump();
        expect(feedback.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
      testWidgets(
        'limit recovery acknowledges held action and preserves failure $brightness $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final held = Completer<bool>();
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: TurnFailureView(
                      failure: TurnFailure.fromCompletion(limitedTurn())!,
                      onSelectModel: (suggestion) {
                        calls++;
                        expect(suggestion.provider, 'nous');
                        return held.future;
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byTooltip('Use Free model'));
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.text('Daily allowance exhausted'), findsOneWidget);
          await tester.tap(find.byTooltip('Use Free model'));
          expect(calls, 1);
          held.completeError(StateError('Provider is unavailable'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.textContaining('Provider is unavailable'),
            findsOneWidget,
          );
          expect(find.text('Daily allowance exhausted'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
