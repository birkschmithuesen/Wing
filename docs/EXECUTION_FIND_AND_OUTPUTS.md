# Execution details, Find and Outputs

## Live execution

Activity's Timeline preserves individual tool calls and supplied reasoning in order. Tasks, Agents and Work show their related progress. Expand a detail to read received content, or open a full reader for longer output. Progress reported by Hermes is read-only.

Tap anywhere on a task row's header to expand or collapse it. Expanded task text
remains selectable and scrollable.

Completed timing uses supplied durations. An active call can show a labelled estimate; missing timing remains unavailable. Saved conversation content stays readable even when optional timing recovery fails. Source, commands and literal output have wrap controls.

Temporary review notices can appear in Activity. Open one to read its full text; it is not an approval request or saved memory entry. See [Tool activity](TOOL_ACTIVITY.md) for more.

## Find in chat

Find starts with the most recent 500 loaded messages. **Search older** loads more history while retaining existing results. A failed load offers retry. Results cover the loaded history, rather than the entire archive until all needed pages are searched.

**View in chat** opens a highlighted result with up to four nearby messages on either side. This view is read-only. **Back to latest** returns to the live conversation and its draft.

## Per-chat Outputs

Outputs lists file references in recent history, initially 500 messages, with older batches available. It is a conversation index, rather than a complete server filesystem inventory. A failed refresh retains loaded results. Old references may be unavailable if Hermes no longer exposes the file.

Supported file links use the original conversation's connection and profile. Missing content and temporary failures have distinct errors, with Retry where useful. See [Output viewers](OPENING_OUTPUT_FILES.md) for formats, download limits and preview restrictions.

Wing does not offer a general remote filesystem browser or global artifact library.
