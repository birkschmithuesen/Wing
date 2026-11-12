import '../models/chat_output.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../presentation/tool_call_presentation.dart';
import '../presentation/tool_activity_details.dart';
import '../theme/wing_theme.dart';
import 'activity_time.dart';
import 'compact_activity_row.dart';
import 'profile_transcript_disclosure.dart';
import 'tool_activity_details.dart';
import 'resource_filename.dart';

/// One action, shared by live receipts and passive saved transcript outputs.
class ProfileToolCall extends StatelessWidget {
  const ProfileToolCall({
    super.key,
    required this.call,
    this.initiallyExpanded = false,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  });

  final ToolCallPresentation call;
  final bool initiallyExpanded;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  /// Wing's glyph policy uses delivered tool identity, never translated titles.
  /// Both live and saved calls use this lookup. Provider namespaces can share
  /// a purpose; an unknown tool gets a neutral glyph rather than a command icon.
  static IconData iconFor(String name) {
    if (name.startsWith('hindsight_')) return Icons.psychology_outlined;
    return _icons[name] ?? Icons.extension_outlined;
  }

  static const _icons = <String, IconData>{
    'memory': Icons.psychology_outlined,
    'message_agent': Icons.forum_outlined,
    'terminal': Icons.terminal_rounded,
    'execute_code': Icons.code_rounded,
    'browser_exec': Icons.code_rounded,
    'read_file': Icons.description_outlined,
    'write_file': Icons.edit_note_outlined,
    'edit_file': Icons.edit_note_outlined,
    'patch': Icons.difference_outlined,
    'list_files': Icons.folder_open_outlined,
    'search_files': Icons.find_in_page_outlined,
    'web_search': Icons.search,
    'web_extract': Icons.language,
    'browser_navigate': Icons.language,
    'browser_snapshot': Icons.find_in_page_outlined,
    'browser_take_screenshot': Icons.photo_camera_outlined,
    'browser_click': Icons.touch_app_outlined,
    'browser_fill': Icons.edit_note_outlined,
    'browser_type': Icons.keyboard_outlined,
    'desktop_preview': Icons.desktop_windows_outlined,
    'drive_preview': Icons.cloud_outlined,
    'skill_view': Icons.menu_book_outlined,
    'skill_manage': Icons.library_books_outlined,
    'tool_get': Icons.build_outlined,
    'tool_describe': Icons.build_outlined,
    'tool_search': Icons.manage_search_outlined,
    'tool_call': Icons.extension_outlined,
    'image_generate': Icons.image_outlined,
    'vision_analyze': Icons.image_search_outlined,
    'todo_list': Icons.playlist_add_check_outlined,
    'delegate_task': Icons.account_tree_outlined,
    'cronjob': Icons.calendar_month_outlined,
    'cronjob_manage': Icons.calendar_month_outlined,
    'clarify': Icons.help_outline,
    'approval': Icons.help_outline,
    'clarification': Icons.help_outline,
    'secureInput': Icons.help_outline,
    'session_search': Icons.manage_search_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context);
    final storage = PageStorage.maybeOf(context);
    final identity = call.disclosureId ?? call.callId;
    final storageId = ('tool-call', identity);
    final remembered = identity == null
        ? null
        : storage?.readState(context, identifier: storageId) as bool?;
    final statusColor = switch (call.outcome) {
      ToolCallOutcome.error => colors.danger,
      ToolCallOutcome.warning => colors.warning,
      ToolCallOutcome.success => colors.success,
      _ => colors.muted,
    };
    return CompactActivityRow(
      icon: Icon(iconFor(call.name), color: colors.muted, size: 16),
      title: Text(
        call.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          height: 1.3,
        ),
      ),
      lines: [
        if (call.progress case final progress?)
          Text(
            progress.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.5, color: colors.muted),
          ),
        if (call.notice == null && call.filenameTarget != null)
          ResourceFilename(
            target: call.filenameTarget!,
            label: call.subtitle,
            style: TextStyle(fontSize: 12, height: 1.5, color: colors.muted),
          )
        else
          Text(
            call.notice ?? call.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: call.notice == null ? colors.muted : statusColor,
            ),
          ),
      ],
      time: ActivityTime(
        durationSeconds: call.durationSeconds,
        startedAt: call.startedAt,
        showUnavailable: call.requestId == null,
      ),
      // Backend identity survives the live-to-history handoff. Explicit
      // notification focus still opens independently of stored disclosure.
      initiallyExpanded: initiallyExpanded || remembered == true,
      onExpansionChanged: (expanded) {
        if (identity != null) {
          storage?.writeState(context, expanded, identifier: storageId);
        }
      },
      details: [
        ToolActivityDetailsView(
          call: call,
          loadImage: loadImage,
          onOpenResource: onOpenResource,
          onShareResource: onShareResource,
        ),
        ProfileTranscriptDisclosure(
          label: 'Raw details',
          icon: Icons.data_object,
          maintainState: false,
          children: [
            ActivityDetailsCard(
              children: [
                _RawToolValue(
                  label: call.requestId == null ? 'Tool' : 'Request type',
                  value: call.name,
                ),
                for (final label in call.labels.skip(1))
                  _RawToolValue(label: label.text, value: label.preview),
                if (call.callId case final id?)
                  _RawToolValue(label: 'Call ID', value: id),
                if (call.requestId case final id?)
                  _RawToolValue(label: 'Request ID', value: id),
                if (call.context case final context?)
                  _RawToolValue(label: 'Context', value: context),
                if (call.summary case final summary?)
                  _RawToolValue(label: 'Summary', value: summary),
                if (call.durationSeconds case final seconds?)
                  _RawToolValue(
                    label: 'Duration (seconds)',
                    value: seconds.toString(),
                  ),
                if (call.arguments case final args?)
                  _RawToolValue(
                    label: call.requestId == null
                        ? 'Inputs'
                        : 'Request metadata',
                    value: args,
                  ),
                if (call.result case final result?)
                  _RawToolValue(label: 'Output', value: result),
                for (final receipt in call.exchangeReceipts)
                  _RawToolValue(
                    label: 'Delivery notification',
                    value: receipt.raw,
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _RawToolValue extends StatelessWidget {
  const _RawToolValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ActivityDetailSection(
    block: ToolDetailBlock(
      label: label,
      text: value,
      format: ToolDetailFormat.source,
      copyable:
          label == 'Inputs' ||
          label == 'Output' ||
          label == 'Delivery notification',
    ),
    viewable:
        label == 'Inputs' ||
        label == 'Output' ||
        label == 'Delivery notification',
  );
}
