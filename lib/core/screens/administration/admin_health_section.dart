import 'package:wing/core/widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

/// A section has one check time; row colors describe the individual results.
class AdminHealthSectionHeading extends StatelessWidget {
  const AdminHealthSectionHeading({
    super.key,
    required this.title,
    required this.checkedAt,
    required this.checking,
    required this.incomplete,
    required this.refresh,
    this.attempted = false,
  });

  final String title;
  final DateTime? checkedAt;
  final bool checking, incomplete, attempted;
  final Widget refresh;

  @override
  Widget build(BuildContext context) {
    final at = checkedAt?.toLocal();
    final now = DateTime.now();
    final sameDay =
        at != null &&
        at.year == now.year &&
        at.month == now.month &&
        at.day == now.day;
    final time = at == null
        ? null
        : [
            if (!sameDay) MaterialLocalizations.of(context).formatShortDate(at),
            TimeOfDay.fromDateTime(at).format(context),
          ].join(', ');
    final label = at == null && !attempted
        ? 'Not checked'
        : incomplete
        ? 'Check incomplete${time == null ? '' : ' · $time'}'
        : 'Last checked $time';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (!checking)
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          refresh,
        ],
      ),
    );
  }
}

Future<void> showHealthCheckExplanation(
  BuildContext context,
) => showDialog<void>(
  context: context,
  builder: (context) => StudioDialog(
    title: const Text('What’s checked?'),
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (title, detail) in [
          (
            'Model access',
            'Checks that the sign-in or API key needed for your selected model is available. '
                'No test message is sent, and remaining credits aren’t checked.',
          ),
          (
            'Tool setup',
            'Checks that every enabled tool group has the setup it requires. '
                'Groups include web search and image generation. We don’t run the tools to test them.',
          ),
          (
            'Connectors',
            'Connects to each enabled connector and reads what it offers. '
                'We don’t test its individual actions. Disabled connectors aren’t checked.',
          ),
          (
            'Scheduled tasks',
            'Checks the saved tasks for reported errors and actions whose outcome is unconfirmed. '
                'We don’t run the tasks. No reported errors doesn’t mean every task has completed successfully.',
          ),
        ]) ...[
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(detail),
          const SizedBox(height: 16),
        ],
      ],
    ),
    actions: [
      StudioButtonPress(
        child: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ),
    ],
  ),
);
