---
name: verify-wing
description: Drive Wing's user-facing Android features through the existing disposable-emulator and Flutter harnesses. Use for feature verification, UI bug proof, native journeys, and maintaining the feature map when code adds, changes or removes a feature.
---

# Verify Wing

Read the [feature-map index](../../../docs/FEATURE_MAP.md), then the affected
feature files and connected journeys. These define user paths and expected
outcomes. Use existing drivers; their `--help` output is the command contract.
Commands below run from the app checkout root. Before choosing checks, retrying
a failure or preparing delivery, follow [verification scope and stopping](references/verification-policy.md).

## Launch

Match the toolchain in [CI](../../../.github/workflows/pr-quality.yml): Flutter 3.47.9
with bundled Dart 3.13.7, Java 17, Android SDK platform/build-tools 36 and the tracked
Gradle wrapper. Install command-line tools, accept SDK licenses, run `flutter doctor`
and resolve packages with `flutter pub get` while retaining `pubspec.lock`.
Native recipes also need the API36 Google APIs x86_64 image and working KVM acceleration.

```sh
python3 scripts/test_nightly_native.py --matrix
python3 scripts/test_nightly_native.py scheduled-tasks --output build/feature-verification/recipe-smoke
```

The first command lists existing families without launching or mutating an app.
The second is one complete launch/drive/teardown: it creates a unique AVD, builds
and installs the native fixture target, drives production controls, writes a
strict named verdict and retires the AVD. A mapped feature chooses its own family;
`scheduled-tasks` is the small baseline demonstration, not a general smoke verdict.

Run families serially in this checkout: Gradle build output and packages are
shared. Each family owns its emulator. Existing physical phones, deployed
backends and their data are outside the default recipe.

## Doctor

Read-only preflight:

```sh
git rev-parse HEAD
flutter --version
adb version
adb devices -l
python3 scripts/test_nightly_native.py --matrix
```

Confirm the intended checkout/toolchain and inspect attached devices without
touching them. These checks establish prerequisites, not a usable app. The runner
then checks its owned serial is an emulator, waits for Android boot, builds the
selected entry point and requires the target's actual controls and named outcomes.
Its receipt binds the source before/after and records build/install/test steps.
An HTTP-ready fixture is required by drivers that use its control endpoint.

After an unexpected failure, inspect the receipt, step log and failure capture.
Do not keep driving a stale or unknown instance. Let cleanup finish and relaunch
through the same owned runner after resolving the prerequisite or failure.

## Drive

Read the selected feature's four sections: sub-features, user entry points,
exact harness commands and gotchas. Use named labels, tooltips and semantics;
wait for observable states. Each command's supplied gateway/native responses
limit what it proves. Host suites are useful focused checks; they do not replace
a listed Android entry or a real-provider proof.

For connected Android journeys:

```sh
python3 scripts/test_journeys.py --output build/feature-verification/journeys
```

For stock-backend operations use the explicit command and prerequisites in
[connected journeys](../../../docs/features/multi-surface-journeys.md).
Stock means current upstream unmodified Hermes. Deployed-server mutations,
provider calls and real-account authorization require the operator's approval;
saved diagnostic credentials grant authentication/read-only access only.

## Evidence

Keep artifacts in the supplied ignored `build/feature-verification/` directory.
Require exit zero, `passed: true`, nonempty named completed outcomes, no hidden
failures/skips, and unchanged source fingerprints. For direct suites, read the
completed names and their action/result assertions; a broad family label does
not establish every entry point in the map.

Show the trigger and result. Include persistence/side-effect readback where it
is the contract. For visual changes capture the actual rendered before/after
states; a host semantics flag alone is insufficient. Label fixture Android,
stock API, live provider and physical-phone evidence separately. Report an
unreachable entry with its attempted route and missing prerequisite.

## Cleanup

The drivers own their AVD/process group and temporary state. Let their `finally`
cleanup run on success, failure or interruption. Never kill a process by name,
reset another device or clear a production package. Inspect driver cleanup errors
and owned resources before the next run. Preserve the output directory: verify
its receipt/logs still exist after the emulator is removed.

## Maintain the map

For code that adds, changes or removes a feature, follow the map’s
[maintenance contract](../../../docs/FEATURE_MAP.md#maintain-a-feature) in the same PR.
At final diff review, account for each affected feature ID and connected journey;
update entries to describe delivered behaviour and executable verification. If
existing entries remain accurate, state the checked IDs and why no edit is needed.
Keep implementation ownership in the architecture workflow reached through
[AGENTS.md](../../../AGENTS.md).

For a broad maintenance pass, reconcile the index with its feature files, source-check every feature,
merge overlapping recipes and drive each reachable feature through the existing
harnesses. Run each shared native family once at unchanged inputs and attribute
its actual named scenarios to the relevant feature IDs; combine overlapping host
suites rather than rerunning the same command for each feature file. Finish with connected journeys. Classify doc drift, harness gaps and
product defects separately; broken supported behaviour keeps its expected result.
Keep run notes/results with the task's evidence, separate from the product map.
Reuse unchanged evidence under the verification policy and state unexecuted
boundaries explicitly. Do not claim a complete sweep from this skill's single
baseline demonstration.
