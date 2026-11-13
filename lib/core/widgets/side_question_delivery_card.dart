import 'studio_error.dart';
import 'selection_viewport.dart';
import 'package:flutter/material.dart';

import '../models/side_question_delivery.dart';

class SideQuestionDeliveryCard extends StatelessWidget {
  final SideQuestionDelivery delivery;

  const SideQuestionDeliveryCard({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final pending = delivery.state == SideQuestionDeliveryState.pending;
    final failed = delivery.state == SideQuestionDeliveryState.failed;
    final background = delivery.kind == SideQuestionDeliveryKind.backgroundTask;
    final label = switch ((background, pending, failed)) {
      (false, true, _) => 'Side question running',
      (false, false, true) => 'Side question failed',
      (false, false, false) => 'Side question answer',
      (true, true, _) => 'Background task running',
      (true, false, true) => 'Background task failed',
      (true, false, false) => 'Background task result',
    };
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (failed)
              StudioError(label, icon: Icons.call_split, announce: false)
            else
              Row(
                children: [
                  Icon(
                    pending ? Icons.schedule : Icons.call_split,
                    size: 18,
                    color: colors.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            if (delivery.question.isNotEmpty) ...[
              const SizedBox(height: 8),
              viewportSelection(SelectableText(delivery.question)),
              if (delivery.questionTruncated)
                const Text('Prompt shortened by Hermes.'),
            ],
            const SizedBox(height: 8),
            viewportSelection(
              SelectableText(
                pending ? 'Waiting for the Hermes host.' : delivery.result,
              ),
            ),
            if (!pending && delivery.resultTruncated)
              const Text('Result shortened by Hermes.'),
          ],
        ),
      ),
    );
  }
}
