# Read and copy formatted content

Read partial and completed replies, code and tool output; select or copy exact content while asynchronous rendering keeps newer content authoritative.

Feature ID: `markdown`.

## Sub-features

- `markdown.render` — Read partial and completed formatted content.
- `markdown.tables` — Tables open as a wrapped grid, with horizontal scrolling when too wide; use the icon controls to choose stacked header/value rows or the table. The latest explicit choice stays with the table through message updates, completion and rotation. Full screen enters the containing conversation’s reading mode.
- `markdown.links` — Open web links, explicitly linked Hermes files and email drafts. Inline code preserves its full text without file actions, including API routes ending in `.md`. Email addresses open Android’s email app chooser, preserving recipients and any subject/body supplied by the link.
- Completed `wing-email-draft` fences render the exact plugin artifact in the originating conversation; see [`conversation.email-draft`](conversation.md#structured-email-draft-verification). Partial or malformed references remain readable source.
- `markdown.copy` — Select or copy exact code and output.
- `markdown.reuse` — Retain current content through asynchronous rendering.

## How to get to it (user POV)

Read a streamed reply, saved answer, Activity result or supported file preview. Open code actions to copy exact text, wrap lines or inspect a full view. Tap an email address or email link to choose an email app and compose a draft. Back dismisses the chooser and returns to the content.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/markdown_inline_parser_test.dart test/markdown_segment_correctness_test.dart test/markdown_parse_worker_test.dart test/markdown_phone_content_test.dart test/phone_reading_test.dart test/profile_conversation_ui_test.dart test/web_preview_test.dart test/profile_markdown_style_test.dart test/growing_markdown_text_test.dart test/block_reusing_markdown_body_test.dart
  ```

  The file-reference regression is also covered by:

  ```sh
  flutter test --no-pub test/deliverable_attachment_test.dart test/chat_inline_image_test.dart test/chat_output_test.dart test/markdown_inline_parser_test.dart test/markdown_parse_worker_test.dart
  ```

  These checks preserve literal API request suffixes in messages, exact message
  copying, cached/worker parsing and Outputs discovery. Image paths in inline
  code stay readable without loading image bytes; explicit image references
  still render previews. The message test also
  opens an explicit Markdown file link through the production HTTP client,
  holds the read to check visible progress and then verifies rendered content.

  Growing paragraphs, headings, list items and quotes retain native text
  controls without repeating clipboard/text-action queries. Selection survives
  append-only updates; links use current callbacks, syntax changes retire old
  controls, and custom builders keep their own widgets and interactions.

  Document assertions distinguish whole prose segments from the table cells'
  nested renderers. Growing tables must retain exact cell content and selection
  bounds and match a fresh adaptive-table render.
  Wide tables must open as horizontally scrolling grids at normal and enlarged
  text sizes. Table controls must retain the latest manual choice when arriving
  content changes whether the table fits, when the reply completes and when
  another reply appears. Phone-reading cases also exercise history updates and
  rotation through the production conversation screen.

- **Android `recents-code`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py recents-code --output build/feature-verification/markdown
  ```

- **Android `html`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py html --output build/feature-verification/markdown
  ```

## Gotchas

Partial streams can be plain until completion. Unsupported syntax must remain readable. A parser test alone does not prove Android selection or a WebView render.

The Android `transcript-expansion` family also exercises the table-owned reading toggle, rotation, draft retention and compact composer through the production chat screen, in both themes and at normal/enlarged text. Run `python3 scripts/test_nightly_native.py transcript-expansion --output build/feature-verification/phone-reading`.

The conversation UI suite taps email links, checks exact mailto handoff, held-launch feedback, repeat taps, failure, retry and departure. These platform-channel fixtures do not prove the Android chooser or an installed email app. On Android, tap an email link, select an installed email app and check the draft recipient; a link with subject/body must retain those fields. Back must return without sending. With no email app, Wing explains that one must be installed or enabled.
