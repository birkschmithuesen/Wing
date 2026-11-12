# Verification scope and stopping

Choose checks to resolve an identified risk. Before running them, identify the
changed behavior, affected callers/dependencies, required gates and the condition
that ends verification. Documentation-only edits need review of wording, links
and formatting; they do not need runtime test campaigns.

1. During implementation, run focused tests at the changed contract and the
   applicable source guards. Include affected dependencies when the property
   crosses files or owners.
2. At final integration, run a justified broad suite once for the stable tested
   inputs. Full verification is warranted by changes to checking tools, runners,
   fixtures or dependencies, substantial changes across application boundaries,
   or an explicit release/CI requirement. A local production APK build or phone
   install is not publication and does not itself trigger a full suite.
3. Record the tested revision or source fingerprint, command/scope, configuration
   and result. Reuse that evidence while its relevant inputs remain unchanged.
   A commit, push, equivalent isolated checkout or documentation edit does not
   invalidate unchanged behavior checks. Verify relevant input differences rather
   than treating every new commit hash as a reason to repeat everything.
4. After a failure, diagnose it and rerun the affected test and relevant
   dependencies. For an isolated timeout, check infrastructure/load separately
   from product behavior and rerun that test alone or with lower concurrency.
   A passing isolated rerun closes that uncertainty; it does not invalidate other
   passing checks or justify another full campaign. Preserve the original failed
   aggregate result and report the successful focused rerun separately.
5. Repeat a full suite only when substantial changes invalidate broad evidence,
   failures indicate a wider problem, or an explicit gate requires a fresh run.
   Before repeating it, state the concrete trigger and which evidence is no
   longer usable. A desire for a green aggregate command is not a trigger.
6. Stop when the planned affected checks pass and required gates are satisfied;
   report remaining limits without expanding scope automatically. If the user
   stops testing, terminate the active owned run and start no replacement campaign.
   Continue other authorized work where its prerequisites are satisfied.

When shared app composition adds ongoing I/O, include the affected data consumers
in the verification scope. Exercise nonempty success and recovery through their
production repository/transport seams while the watcher is active. Fixtures must
retain the stock response semantics involved, including exact identity versus
search/lineage resolution. Assert visible results and cleared error states;
header geometry and absence of Flutter exceptions do not establish data health.
Report fixture layout, contract/recovery, live read-only and phone installation
checks separately. A startup PID or screenshot count is not a live feature journey.

For session API changes, prove existing-chat reopening before claiming delivery
readiness. Run the [read-only saved-chat recipe](../../../../docs/features/conversation.md)
through the candidate's production gateway against the intended deployment.
Require nonempty saved history and accepted canonical session authority, including
a repeat reopen; record the app revision and the running backend's `/api/health`
commit and `session_authority == true` in the `gateway.ready` event payload. Current stock standalone
`serve` and the canonical gateway expose different session contracts at `/api/ws`;
the version or negotiated WebSocket subprotocol alone cannot distinguish them.
Login, ping, capability discovery and fixtures cannot substitute for this
check. An empty dataset, opt-in skip or unavailable deployment leaves this boundary
unverified. An API refusal fails it, even when every fixture journey passes.
Do not manufacture missing authority in fixtures to close a deployed failure.
If a breaking API change needs a different endpoint or server update, report that
dependency before phone delivery; deployment authorization remains separate. No fallback or backend
mutation is implied by verification. Reuse this evidence while the relevant app
inputs and running backend commit are unchanged.

Native journeys with ongoing animation use bounded, state-based waits. Keep live
rendering enabled across external screenshot waits when observing motion; an
explicit-pump-only frame policy can discard native timestamps and skip a short
animation after the clock catches up. Check transient notices before capture,
and allow their normal expiry during host I/O. Scroll to unique recovered data
rather than repeated action labels or headings outside a lazily built viewport.

Required published-release and CI gates remain mandatory. A failed or interrupted
full command is not a passing full run; a focused recovery does not waive a gate
that explicitly requires one. For user-requested local phone delivery, reuse
completed checks, build and verify the signed APK, then install it while GitHub
CI runs independently. GitHub CI completion is not a prerequisite for phone
installation. Report its status separately; published-release gates apply to
publication.

Production Wing phone installs use a signed APK built from an isolated clean
checkout of a commit already published on `origin/main`. Before installation,
verify the checkout matches published main and record its commit/tree, APK hash
and version. Keep development builds in the separate Wing Dev package.

