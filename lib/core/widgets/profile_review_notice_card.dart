import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

import '../models/review_notice.dart';
import '../presentation/tool_activity_details.dart';
import 'activity_time.dart';
import 'compact_activity_row.dart';
import 'profile_transcript_disclosure.dart';
import 'tool_activity_details.dart';

/// A received background-review summary, inside the same timeline as tools.
class ProfileReviewNoticeRow extends StatelessWidget {
  final String text;
  final bool initiallyExpanded;

  const ProfileReviewNoticeRow({
    super.key,
    required this.text,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context);
    final summary = normalizeReviewText(
      text,
    ).replaceFirst(RegExp(r'^Self-improvement review:\s*'), '').trim();
    final generic = summary
        .split(' · ')
        .every(
          (part) =>
              const {'Memory updated', 'User profile updated'}.contains(part),
        );
    return CompactActivityRow(
      icon: Icon(Icons.lightbulb_outline, color: colors.muted, size: 16),
      title: const Text(
        'Memory and skills review',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          height: 1.3,
        ),
      ),
      lines: [
        Text(
          summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, height: 1.5, color: colors.muted),
        ),
      ],
      time: const ActivityTime(),
      initiallyExpanded: initiallyExpanded,
      details: [
        ActivityDetailsCard(
          children: [
            ActivityDetailSection(
              block: ToolDetailBlock(
                label: 'Reported changes',
                text: summary,
                copyable: true,
              ),
            ),
            if (generic)
              const ActivityDetailFacts(
                facts: [
                  'Individual changes were not included in this summary.',
                ],
              ),
          ],
        ),
        ProfileTranscriptDisclosure(
          label: 'Raw details',
          icon: Icons.data_object,
          maintainState: false,
          children: [
            ActivityDetailsCard(
              children: [
                ActivityDetailSection(
                  block: ToolDetailBlock(
                    label: 'Review summary',
                    text: text,
                    copyable: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
