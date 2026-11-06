# Slash commands and skills

Type `/` at the start of the composer to browse the connected server's commands,
plugins, and installed skills. Type `/` after a space or on a new line within a
message to browse skills. Search matches names, aliases, and descriptions.
Selecting a result replaces the slash token at the cursor and keeps surrounding
text. Skill references remain editable and copy as ordinary text. URLs and paths
stay literal. Refresh the workspace after changing installed skills.

On Send, Wing loads referenced skills before submitting the message. The chat
shows your original wording. Repeated references to one skill load it once;
different skills can be combined. If loading fails, the queued message is
retained rather than sent without its instructions.

Some commands start a response; others return output or place text in the
composer for editing. Display-only command output is not saved in model history
and leaves composer attachments in place. A failed or timed-out command is not
automatically sent through another handler: check its result before retrying.

`/yolo` changes the current chat's setting and shows the confirmed state; it does
not change global defaults. `/steer`, interruption, status, and side questions
can address active work. Commands that start a normal turn wait until idle.
Built-in commands mentioned within ordinary prose remain text.

`/compress` and `/compact` use the current conversation's compression operation.
Add `--preview` to inspect its plan without changing history; `here N` selects
the newest messages to keep and `focus TOPIC` supplies a focus. The conversation
must be idle and writable. Wing shows the server's preview, no-change result or
applied summary, and refreshes history after a confirmed change. It preserves a
newer draft while waiting. A checkpoint or runtime-coordination refusal remains
a refusal; Wing does not send it through a generic command or prompt instead.

A command's presence in the catalog does not guarantee it works on mobile.
Wing checks the server's availability restrictions before running a command.
Commands reserved for management controls, settings, the terminal or messaging
explain their requirement and keep your draft. A server microphone command does
not use your phone's microphone. You can still type a command by name when the
catalog is stale; known restrictions still apply.

Skill receipts open the [instruction reader](TOOL_ACTIVITY.md#captured-skill-reading)
without rerunning the command. See [Queues and pending input](SUPERVISION_AND_QUEUES.md)
for side-question recovery limits.
