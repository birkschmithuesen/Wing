# Open, save and share results

Discover generated files, open an image, document or other supported preview, then copy, save or share it; return safely after a failed or retired viewer read.

Feature ID: `outputs-and-viewers`.

## Sub-features

- `outputs-and-viewers.discover` — Find outputs belonging to the chat. Literal code paths and code examples are excluded from implicit discovery; explicit Markdown links, `MEDIA:` references and producer receipts remain available.
- `outputs-and-viewers.preview` — Open readable original content.
- `outputs-and-viewers.export` — Copy, save or share the intended result. File downloads have no fixed size cap in Wing.

## How to get to it (user POV)

Choose Outputs in the conversation menu, use a file card preview eye, or tap an inline image. Copy, save or share supported results through their icon actions.
Web-link rows in Outputs follow the destination saved under **App settings →
Open links in**. An image viewer's **Open in browser** action opens the external browser.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/chat_output_test.dart test/chat_outputs_screen_test.dart test/chat_outputs_session_test.dart test/pdf_preview_service_test.dart test/resource_preview_owner_test.dart
  flutter test --no-pub test/remote_files_client_test.dart test/remote_file_saver_test.dart test/deliverable_attachment_test.dart test/chat_inline_image_test.dart
  ```

- **Android `file-transfer`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py file-transfer --output build/feature-verification/outputs-and-viewers
  ```

- **Android `html`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py html --output build/feature-verification/outputs-and-viewers
  ```

## Gotchas

The download suites receive 33 MiB files with and without Content-Length, then
drive a file card through its download and held save picker in both themes.
The card shows progress until the picker settles and reports success only after
a destination is selected. Cancellation and errors remain separate outcomes.

Output discovery is not proof that a viewer loaded its bytes. Preview budgets
are independent of saving; an oversized HTML file can still be saved or shared.
PDF and external OS handlers have separate prerequisites. Retiring a viewer must
prevent late publication into another route.

The isolated Mermaid renderer handles line-break and nonbreaking-space labels;
`scripts/test-diagram-preview.mjs` covers those cases alongside blocked links,
configuration overrides, script execution, external assets and HTML isolation.
Inline images retain their phone-width envelope; video content opens through
explicit viewer navigation rather than eager transcript loading.

Image, diagram, SVG and HTML preview failures use the shared error appearance.
The embedded viewer also keeps that treatment when its rendering script cannot
load. Preview failure does not remove the original file or its recovery actions.
