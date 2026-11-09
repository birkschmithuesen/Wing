# Tool activity

While a reply is streaming, one compact row shows the latest reasoning heading
and tool count. Tap it to open **Activity**. Newest work appears at the top and
oldest at the bottom. Tools appear above the reasoning that preceded them; a
late result updates its existing tool row without moving it.

Expand a reasoning row to read its full text, or an Activity run to inspect its
tools and results. Open details and your reading position remain stable as newer
work arrives. Partial saved history joins the same stack. When the reply ends,
the stack folds; saved answers retain their ordinary historical Activity tabs.

Use the compact **Subagents / Tasks / Background** bar above your draft. It remains available while Hermes waits for subagents and after
the parent response finishes. Tap a side to open its drawer, swipe left/right to
switch, and tap the selected side or outside to close. Tasks shows completed/total;
cancelled tasks do not count as completed. Empty categories stay hidden. During
streaming, current Tasks, Subagents and processes appear only in this drawer, including
completed subagents whose parent is still answering.
When their parent turn ends, completed subagents leave this drawer immediately.
Their saved results remain in that turn's Activity → Agents tab. Running and
queued background agents remain available until they finish.

Swipe up on either bar zone to open that category at its compact height. Swipe
up again on its open bar to maximize. Swipe anywhere in an open drawer upward to
expand or downward to close. Diagonal swipes follow
the larger horizontal or vertical movement. At full height, rows scroll while the
summary stays fixed; scroll back to the top and continue down to close. Tapping
the smaller top handle toggles height. Reopening by tap starts compact. Both Tasks
Subagents and Background use this behavior. At enlarged text, three tab labels scroll sideways within the same bar.

Past answers retain their received Activity and Work details. Tools and agent
results share the Timeline and Agents tabs within the same Activity. Activity shows the
available tool count. Expand a row to see what was requested and what Hermes
returned. Controls use icons with accessible labels and tooltips. Long content
can open in a fuller reader; reusable code, commands and output offer copying
and wrap controls. Raw details retains exact received inputs and results.

## Timeline and reasoning

For past answers, Timeline shows individual tool calls and reasoning in their received order.
Compact rows show an action and input summary; warnings and failures remain
visible. Expand for details, source references, received images, and available
results. Opening a received result does not rerun its tool. Completion means the
call finished; check its output and any error before assuming success.

Reasoning appears only when the model or server supplies readable text. Some
providers supply a short preview or do not save reasoning. Live reasoning and
saved history may therefore differ. Wing does not reconstruct missing text or
display encrypted reasoning.

## Memory and learning

Background **Memory and skills review** notices appear inside Activity's Timeline.
A review received directly after an answer joins that answer's tools, so you
can inspect the work and its learning in one list. Separate updates with the
same summary remain separate; replaying the same event does not duplicate it.
Received reviews survive reopening a locally cached conversation. Hermes may
not keep these notices in server history; Wing cannot recover notices it never
received or that have left its local reading cache.
They use a lightbulb icon, distinct from Hindsight's head/brain icon. Expand a
review to read and copy the changes Hermes reported; Raw details retains the
original summary. When Hermes only reports "Memory updated", Wing explains that
individual changes were not included. A summary can contain shortened previews.

Expand **Hindsight retain** to see the exact **Submitted memory** and the separate
**Result** from Hindsight. The submitted text is what Hermes asked it to store;
it does not establish which facts Hindsight extracted. Built-in memory calls
also show supplied new entries, previous or removed entries, and approval or
failure results when available. Wing displays the received evidence without
reconstructing missing facts or diffs.

File and web results retain their supplied locations. A filename can be shortened
on screen; its popup shows the full location and file actions use that original
target. A search receipt with an unreliable location remains readable in Raw
but does not gain misleading file actions. See
[Output viewers and downloads](OPENING_OUTPUT_FILES.md).

## Messages to agents

**Message agent** uses a speech-bubble icon and shows the recipient under its
title. Its **Message** section contains the sent text. **Queued** acknowledges
the handoff and shows the supplied queue time on the right. A later matching
result appends **Exchange complete** and the returned reply with its saved
receipt time; it keeps the original sections intact. Pending, unknown and failed
results are labelled accordingly. These times describe different events, not
a measured delivery duration. Expand Raw details for exact inputs, original
output and delivery notifications.

## Activity timing

While a reply streams, each Activity header shows its duration. A run followed
by Reasoning keeps the time between that reasoning block and the preceding user
message or reasoning block. The current run counts upward from the preceding
message, updating every second. Live reasoning uses the time it first arrives on
your phone; saved reasoning uses its message timestamp. The tooltip explains
this timing. Missing timestamps can leave a duration absent.


A saved reply's collapsed Activity header can show "Activity · 11 tools · 1m 24s".
This is the interval between the message that started the turn (your prompt or
an incoming bot message) and the final saved answer,
including thinking and tool work. It is not the sum of tool durations. Reopening
Wing does not change an interval available in saved history. Missing or invalid
timestamps, an unsaved reply, or an unloaded original prompt can leave it absent.

Individual tools can show approximate elapsed time while running. A measured
completion duration replaces that estimate when received. Historical timing may
be unavailable if Wing never received it and Hermes no longer retains it. Wing
keeps received measurements locally; a missing measurement is not guessed from
message timestamps. These times describe work, not a guarantee of success.

## Tasks, Agents, and Work

Tasks show the reported checklist, order, nesting, and states. Older Activity
sections retain their own reported task snapshots rather than today's list.
Agents show received delegation goals, status, and available output. Live agents
can show approximate elapsed time; saved dispatches are historical and do not
start timers or offer live controls. See [Subagent supervision](SUBAGENT_SUPERVISION.md)
for steering, interruption, and unavailable output.

Work shows the chat's goals, recurring work, and processes. Its actions are the
same controls available from the chat menu. See [Session controls](SESSION_CONTROLS.md).
Approvals and questions remain separate from tool disclosures.

## Conversation compression

"Summarizing conversation…" above the composer means Hermes is compressing the
conversation. It is a status observation, not a new message. Input requests and
recovery notices take priority. The label clears when summarization ends or
normal work resumes.

## Captured skill reading

Open a received skill to read its instructions without rerunning it. The reader
supports raw/formatted views, Contents, previous/next navigation, and available
reference documents. Formatted viewing focuses on the instructions; Raw retains
the complete received content, including declarations and any bundle context.
The reader preserves the received instructions rather than replacing them with
a newer version. Optional metadata or activity failures do not prevent reading.
When Hermes appends a recognized loop notice to a recorded skill result, Wing
still opens the received instructions. Raw details retains the complete result
and notice.

Reference documents appear when Hermes provides a valid file listing. Their
content may carry a truncation notice. Available profile activity counts and
read-request counts describe different things; missing records stay unknown.

Activity starts collapsed, including while a reply streams. New reasoning and
tool events do not open it automatically; expand it whenever you want to read
the details.

Tasks start individually collapsed with a short preview and status. Use each
task's chevron to expand its full selectable text. Live updates and reordering
retain the correct task's expansion. Hermes supplies the list order and nesting,
but no task creation timestamps for chronological sorting.

Background discovers terminal commands when the chat becomes visible and follows running processes automatically. Expand a command for its full command and recent output, then use the icon-only Stop or Dismiss action. Close and reopen the tab to refresh or retry. These are terminal processes, separate from the Tasks checklist and recurring schedules.
