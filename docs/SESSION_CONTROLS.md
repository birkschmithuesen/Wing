# Goals and background work

Open **Activity → Work** in a conversation to inspect known goals and recurring
work. Expand Goal or Background work for their details. Terminal commands appear
separately in **Background** above the composer.
Hermes runs this work on the server; it does not depend on a phone scheduler.

## Goals and criteria

The goal view shows available status, progress, constraints, criteria, and
verification results. Use Pause, Resume, Resume now, or confirmed Clear when
available. Goal contracts and verification gates are read-only; this view does
not create goals.

Add a criterion, remove an item, or clear the criteria. Remove and Clear require
confirmation. If the list changes while confirmation is open, review the updated
list first. A failed addition keeps your text so you can review it.

Actions wait for Hermes' reply and preserve unsent text, attachments, and queued
messages. A failed or uncertain action is not automatically retried. Refresh and
check the current state before another attempt, especially if another client is
also changing the goal.

## Background work

Refresh Background work to retrieve recurring-work status. Loops offer
Pause, Resume, and Stop. Heartbeats offer Pause, Resume, and confirmed Clear.
Running processes offer targeted Stop. Finished processes retain their available
output and can be dismissed for the current app session; dismissal does not
delete server history.

The Background tab appears when processes are discovered, or when a failed read
needs attention. Wing reads the list when entering or returning to the visible
chat, refreshes after relevant tool calls and checks every five seconds while
commands are running. Polling stops when the chat is hidden, offline, finished
or a read fails. Close and reopen Background to refresh or retry; the tab shows
feedback until the read settles. Automatic reads remain quiet.

Process output is a limited recent tail, not a complete transcript. Available details
include the command, working directory, state, uptime, and exit code when
supplied. Opening the view does not start work.

`/stop` interrupts the selected chat and stops its verified running processes.
`/interrupt` interrupts only the chat. If process status or a stop cannot be
confirmed, refresh before retrying.

Profile scheduled tasks and [Bots](BOTS.md) have separate management pages.
See [Known limitations](KNOWN_LIMITATIONS.md) for server-dependent behavior.
