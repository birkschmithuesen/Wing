import 'package:flutter/material.dart';

import '../presentation/agent_task_presentation.dart';
import '../presentation/saved_activity.dart';
import '../presentation/tool_activity_details.dart';
import '../theme/wing_theme.dart';
import 'activity_time.dart';
import 'compact_activity_row.dart';
import 'tool_activity_details.dart';

/// Saved output is inspectable without pretending a past child is controllable.
class ProfileSavedAgents extends StatelessWidget {
  const ProfileSavedAgents({super.key, required this.agents});
  final List<SavedAgentResult> agents;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final agent in agents) _buildAgent(context, agent)],
  );

  Widget _buildAgent(BuildContext context, SavedAgentResult agent) {
    final colors = WingTokens.of(context);
    final hasSummary = agent.summary?.trim().isNotEmpty == true;
    final hasError = agent.error?.trim().isNotEmpty == true;
    final repeatedError =
        hasError && agent.summary?.trim() == agent.error?.trim();
    return CompactActivityRow(
      icon: const Icon(Icons.account_tree_outlined),
      title: Text(
        agentTaskHeading(agent.goal),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, height: 1.4),
      ),
      lines: [
        Text(
          agent.statusLabel,
          style: colors.typography.label.copyWith(
            color: agent.failed
                ? colors.danger
                : agent.warning
                ? colors.warning
                : colors.muted,
          ),
        ),
        if (agent.model != null || agent.apiCalls != null)
          Text(
            [
              ?agent.model,
              if (agent.apiCalls case final calls?) '$calls model calls',
            ].join(' · '),
            style: colors.typography.label.copyWith(color: colors.muted),
          ),
      ],
      time: ActivityTime(
        durationSeconds: agent.durationSeconds,
        subject: 'Agent',
      ),
      details: [
        ActivityDetailsCard(
          children: [
            ActivityDetailSection(
              block: ToolDetailBlock(
                label: 'Task',
                role: ToolDetailRole.task,
                text: agent.goal,
                copyable: agent.goalSupplied,
              ),
            ),
            if (hasSummary && !repeatedError)
              ActivityDetailSection(
                block: ToolDetailBlock(
                  label: 'Output',
                  role: ToolDetailRole.output,
                  text: agent.summary!,
                  markdown: true,
                  copyable: true,
                ),
                facts: agent.qualifications,
              )
            else if (agent.terminal && !hasError)
              const ActivityDetailFacts(facts: ['No result supplied']),
            if (hasError)
              ActivityDetailSection(
                leading: Icon(
                  Icons.error_outline,
                  size: 16,
                  color: colors.danger,
                ),
                block: ToolDetailBlock(
                  label: 'Error',
                  text: agent.error!,
                  copyable: false,
                ),
              ),
            if (agent.schemaNote case final note?
                when agent.schemaValid == false &&
                    note.trim().isNotEmpty &&
                    !(agent.summary?.contains(note) ?? false))
              ActivityDetailSection(
                block: ToolDetailBlock(
                  label: 'Output qualification',
                  text: note,
                ),
              ),
            for (final error in agent.schemaErrors)
              if (error.trim().isNotEmpty &&
                  !(agent.summary?.contains(error) ?? false))
                ActivityDetailSection(
                  block: ToolDetailBlock(
                    label: 'Schema finding',
                    text: error,
                    copyable: false,
                  ),
                ),
            if (!(hasSummary && !repeatedError) &&
                agent.qualifications.isNotEmpty)
              ActivityDetailFacts(facts: agent.qualifications),
            ActivityDetailSection(
              initiallyCollapsed: true,
              viewable: false,
              block: ToolDetailBlock(
                label: 'Raw details',
                text: agent.rawDetails,
                copyable: false,
                format: ToolDetailFormat.source,
                secondary: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
