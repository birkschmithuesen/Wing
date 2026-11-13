# Shared action icons

`wing-icons.ttf` contains Lucide’s `square-pen` (U+E175), selected for every
New chat action, and `git-fork` (U+E28C), selected for answer branching.
Flutter refers to them through `WingIcons.newChat` and `WingIcons.fork`.
The same font includes Tabler's `steering-wheel` (U+E001), exposed as
`WingIcons.steer` for all composer, settings, queue and transcript Steer marks.
The Android `ic_shortcut_new_chat.xml` drawable uses the matching square-pen paths.

Source: [`lucide-static` 0.468.0](https://www.npmjs.com/package/lucide-static/v/0.468.0),
`font/lucide.ttf` and `icons/square-pen.svg` / `icons/git-fork.svg`.
The git-fork SVG geometry is identical to Lucide 0.577.0 used by upstream desktop
`GitForkIcon` at Hermes commit `dce1e9b37581dd62e480a9064dc04a709c2940d3`.
Both retain the [ISC license](LUCIDE-LICENSE).

The steering-wheel geometry matches Hermes Desktop's `IconSteeringWheel`
at commit `e017fe5ceb4dc3fb8cc09cc03cf935627aafb9a1`, using
[Tabler's outline source](https://github.com/tabler/tabler-icons/blob/main/icons/outline/steering-wheel.svg).
It retains the [MIT license](TABLER-LICENSE). The private build helper
`internal/tools/generate_steer_icon.py` expands its round 2-unit strokes into
font outlines and preserves the existing Lucide glyphs.

`WingIcons.queue` uses Codicons `layers` (U+EBD2) from `codicons.ttf` below,
matching Hermes Desktop's queue section at commit
`e017fe5ceb4dc3fb8cc09cc03cf935627aafb9a1`. The composer Queue action and
queued-message rows share this glyph.

## Project icons

`codicons.ttf` is the unmodified font from Microsoft’s [`@vscode/codicons` 0.0.45](https://www.npmjs.com/package/@vscode/codicons/v/0.0.45), used by Hermes Desktop at commit `8f817911723e3ec13e7f47fc022fdcc9e2149354`. It retains Microsoft attribution and the [CC BY 4.0 license](CODICONS-LICENSE). `ProjectIconGlyphs` maps the font’s stock names to constant Flutter glyphs. The selectable catalogue is curated separately.
