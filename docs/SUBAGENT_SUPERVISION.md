# Subagent supervision

While Hermes works, tap **Subagents** above your draft to inspect known children.
Only populated categories appear; swipe between Subagents and Tasks when both
are available. The drawer keeps its summary visible while longer lists scroll.
Swipe up on the Subagents bar to open it at its compact height, then swipe up
again to maximize. Swipe anywhere in the drawer up to expand or down to close;
at full height, scroll rows back to their
top before continuing downward to close. Diagonal swipes follow their larger
component, switching categories when mostly sideways. The smaller top handle
toggles height on tap. Reopening by tap starts compact. Tap the selected tab,
outside or Back to close it without leaving the conversation.

The header shows completed out of total, then running and queued counts. Failed,
interrupted and unconfirmed agents are counted separately when present. Zero
status counts are omitted; unconfirmed agents are not also counted as running
or queued.

Received events update progress automatically. Close and reopen Subagents to
fetch a fresh snapshot or retry a failed read. Past answers retain
**Activity → Agents** with received goals, status, output and available timings.
Historical results do not offer live controls.
Completed agents leave the drawer when their parent turn ends. Their saved
results stay under that answer's Activity, while unfinished background
agents remain in the drawer until they finish.

Open a child's details to read its own conversation when Hermes supplies its
session identity. It uses the same message and Activity timeline as the main
chat, including saved tool results, available reasoning and live tool previews.
Expand **Task** for its goal and metadata. Eligible guidance and Send controls
stay below the conversation, with Interrupt in the status row. Nested read-only viewers do not offer those controls.

Use Refresh in the header to reread the child. Updates continue while the viewer is open and
Wing is active. After three consecutive failures, automatic refresh stops; use
Retry. Closing the sheet stops its reads. The parent chat and draft stay selected.

**Steer** appears when the child accepts guidance. Accepted guidance is queued,
so delivery can still be missed if the child finishes first. Failed or rejected
steering keeps your text. **Interrupt** confirms the interruption request, then
waits for the child to report its final state.

## Refresh and unavailable output

If a known child disappears from a refresh without a confirmed final state,
Wing marks it unconfirmed and disables controls. Later activity or another
refresh can confirm it again. Absence does not mean completion.

Received content remains visible when a later refresh fails. Live tool previews
may omit full arguments and results; saved receipts can provide those details.
Live tool completion can be inferred by Hermes when the next tool starts, so
Wing does not show an exact duration from that boundary.

If Hermes supplies no child session, the details show received activity and any
available live-output excerpt. That excerpt is limited to the latest 16 KiB and
may become unavailable after completion. Recent activity remains inspectable
without live-output access. Hermes' live list contains active children only;
Wing does not provide a complete cross-session agent tree or transcript archive.

See [Tool activity](TOOL_ACTIVITY.md) for saved and live activity views.
