import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/side_question_delivery.dart';
import 'package:wing/core/widgets/side_question_delivery_card.dart';

void main() {
  testWidgets(
    'pending dispatch keeps its semantic glyph without claiming execution',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SideQuestionDeliveryCard(
              delivery: SideQuestionDelivery(
                taskId: 'retained',
                question: 'What changed?',
                state: SideQuestionDeliveryState.pending,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Side question running'), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
  testWidgets('renders pending side questions as selectable delivery cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SideQuestionDeliveryCard(
            delivery: SideQuestionDelivery(
              taskId: 'task-1',
              question: 'What changed?',
              state: SideQuestionDeliveryState.pending,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Card), findsOneWidget);
    expect(find.text('Side question running'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
    expect(
      find.widgetWithText(SelectableText, 'What changed?'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SelectableText, 'Waiting for the Hermes host.'),
      findsOneWidget,
    );
  });

  testWidgets('renders completed side-question result as selectable text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SideQuestionDeliveryCard(
            delivery: SideQuestionDelivery(
              taskId: 'task-1',
              question: 'What changed?',
              state: SideQuestionDeliveryState.completed,
              result: 'The server changed.',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Side question answer'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(SelectableText, 'The server changed.'),
      findsOneWidget,
    );
  });

  testWidgets('labels background work as running and result', (tester) async {
    Future<void> pump(SideQuestionDeliveryState state) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SideQuestionDeliveryCard(
            delivery: SideQuestionDelivery(
              kind: SideQuestionDeliveryKind.backgroundTask,
              taskId: 'background-1',
              question: 'Check the deployment',
              state: state,
              result: 'The deployment failed.',
            ),
          ),
        ),
      ),
    );

    await pump(SideQuestionDeliveryState.pending);
    expect(find.text('Background task running'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.text('Background task result'), findsNothing);

    await pump(SideQuestionDeliveryState.completed);
    expect(find.text('Background task result'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
    expect(
      find.widgetWithText(SelectableText, 'The deployment failed.'),
      findsOneWidget,
    );
  });

  testWidgets('labels failed and shortened recovered work', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SideQuestionDeliveryCard(
            delivery: SideQuestionDelivery(
              kind: SideQuestionDeliveryKind.backgroundTask,
              taskId: 'failed',
              question: 'Long prompt',
              state: SideQuestionDeliveryState.failed,
              result: 'Task failed.',
              questionTruncated: true,
              resultTruncated: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Background task failed'), findsOneWidget);
    expect(find.text('Prompt shortened by Hermes.'), findsOneWidget);
    expect(find.text('Result shortened by Hermes.'), findsOneWidget);
  });
}
