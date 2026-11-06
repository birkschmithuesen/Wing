# Scheduled tasks

Open **Hermes administration → Profile → Scheduled tasks**, or the selected bot's
settings. Tasks run on Hermes even when Wing is closed.

Create a task with instructions, a schedule and result destinations. Templates can
provide a starting point; edit the saved task to adjust its scheduling policy.

## Timing

- **Schedule timezone** accepts an IANA name such as `Asia/Singapore`. Leave it
  empty to use the Hermes profile timezone. This controls recurring wall-clock
  schedules. One-time dates chosen on the phone are sent as exact instants.
- **Missed runs beyond the window** can follow Hermes's default, run one catch-up,
  or skip missed work. Catch-up runs once, rather than replaying every missed slot.
- **Late-run window** applies to cron schedules: enter 0–1440 whole minutes or
  leave it empty for Hermes's computed window. Zero has no grace window. Choosing
  Run one catch-up still permits a catch-up beyond the window.

Run timestamps display in the phone's timezone. External schedulers control their
own delivery and retry timing. Editing a name or destination preserves unedited
policy values and the existing schedule; it does not re-anchor an interval.

## Controlling work

**Pause schedule** changes future scheduling. **Stop run** requests cancellation
of the current execution and leaves the schedule unchanged. The run stops at its
next cancellation check, so “Stop requested” can appear while it still shows
Running. Current work remains stoppable even if a newer Run now attempt was
rejected. Recent runs retain cancelled and missed outcomes.

**Run now** executes work immediately. A paused task offers **Resume and run**.
Leaving Wing does not cancel an admitted run. Deleting the task removes its
schedule and also requests cancellation of running work. If a response is lost,
refresh and review the result before issuing another request.

## Delivering results

Choose server storage, configured platform destinations, or a discovered group
chat under Results. Wing retains the group's hosting profile independently of
the task's profile. Existing targets remain selected if discovery is unavailable.

When scheduled output contains group member `@mentions`, those bots begin a round;
`@all` addresses everyone. Without a mention, the output is posted as information.
Failure notices never start a round. Include instructions about mentions in the
task only when you want its result to ask bots to continue the work.
