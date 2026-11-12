# Output viewers and downloads

Explicit Markdown file links and `MEDIA:` references in an answer appear as
cards with separate Download and Open preview icons. Inline code remains literal,
even when it looks like a file path: API request paths and code examples are not
file attachments. To offer a file, use a Markdown link such as
`[Read the report](/srv/report.md)` or `MEDIA:/srv/report.md`. The chat's
**Outputs** list also collects references, including older history. Download opens Android's destination picker; cancelling saves
nothing. Open preview opens the reader, and Back returns to the conversation.

Files are fetched from their original connection and profile. Old paths can
become unavailable. Relative paths in chat resolve against the saved chat's
directory; a missing directory shows an error. Leaving while a download is
pending prevents a late viewer or save picker from opening.

## Supported reading

| Content | In-app behavior | Limits |
| --- | --- | --- |
| Markdown and code | Formatted or raw Markdown, selectable code, copying, tables, and supported diagrams | A truncated preview is labelled; download for the full file. |
| Images and SVG | Loading, zoom, and restricted SVG preview | Unsupported content can be saved or opened elsewhere. |
| PDF | Page controls and pinch zoom | No editing, forms, text search, or selection; encrypted files may need another app. |
| Audio and video | Explicit Play, pause, and seek | Device codecs determine support; no background playback. |
| Web links | Browser preview or external browser | Uses the browser's login state. |
| Self-contained HTML | Rendered page, inline interaction, and optional Show source | External-resource pages may need another app; see the sandbox below. |

PDF, audio, and video also offer Open in app. Save or share remains available if
an in-app format fails or a compatible viewer is unavailable. Returning to a
media preview resumes at the last position, paused.

Markdown's toolbar offers raw/formatted switching, Copy content, Share file,
and Download. Relative document links and images resolve from the open file's
directory. Heading links scroll within that file; Back returns from a linked
document. Missing headings are reported, including those outside a truncated
preview. Web links open in the browser.

Code preserves its original text when wrapped, selected, or copied. Chat code
fences wrap by default and offer a horizontal-scrolling toggle. Activity source
viewers have their own wrap controls. Copying a chat message retains the original
message, including its file paths.

## Download limits and temporary files

Downloads have no fixed size limit in Wing. In-app previews retain a 32 MiB
budget for downloaded files. Embedded images have a 32 MiB decoded limit;
oversized images cannot be previewed or shared. Other outputs remain available.
Authenticated reads time out after 45 seconds and show a retryable error.

In-app viewing uses temporary cached files, not an offline library. Save a copy
to retain it. Wing does not pass Hermes credentials to external viewers or web
browsers. For shared-copy retention, see
[Sharing from Wing](SHARING_AND_CAPTURE.md#sharing-from-wing).

## HTML and diagram sandbox

HTML opens from the complete downloaded file, up to 32 MiB, rather than a
truncated text preview. Show source displays the same full document. A loading
failure offers retry; invalid text encoding still allows saving the original.

The HTML viewer supports inline scripts, styles, and embedded images. It blocks
external resources, page navigation, forms, workers, and nested frames, and does
not supply Hermes credentials or access to Wing's storage. It is not complete
network isolation: WebRTC networking is not reliably blocked. Open trusted
self-contained files; pages relying on external resources may need another app.

Mermaid and SVG use a separate restricted viewer. See
[Diagram previews](DIAGRAM_PREVIEWS.md).
