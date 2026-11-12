# Attribution and license

Wing is an independently developed Android companion for Hermes Agent, maintained in [`tarkilhk/Wing`](https://github.com/tarkilhk/Wing). It began with [rusty4444](https://github.com/rusty4444)'s open-source Android client and continues with its own design, features and releases. Wing is not an official Hermes Agent or Nous Research product.

The original Android client identifies its license as MIT. Wing continues under MIT and retains attribution to the original authors. See [LICENSE](LICENSE) for the full license text. Preserve applicable copyright and permission notices when redistributing.

Contributors to the original client include CarlosReyesPena, CristianGCiocoi, AI-Guru, grunjol, louquillio, sternbergm and rusty4444. The [changelog](CHANGELOG.md) and Git history retain their work and attribution.

Vendored diagram assets retain [Mermaid's license](android/app/src/main/assets/diagrams/MERMAID-LICENSE) and [DOMPurify's license](android/app/src/main/assets/diagrams/DOMPURIFY-LICENSE). These apply to their respective components.

The development-only renderer harness uses [Playwright Core](https://github.com/microsoft/playwright/blob/v1.58.2/LICENSE) under Apache-2.0. It and its test browser are not bundled in the Android app.

The vendored Flutter setup action retains [its MIT license](.github/actions/setup-flutter/LICENSE) and upstream copyright notice.

The New chat and Fork icons use Lucide's `square-pen` and `git-fork` from `lucide-static` 0.468.0, under the [ISC license](assets/fonts/LUCIDE-LICENSE). Steer uses Tabler's `steering-wheel` under the [MIT license](assets/fonts/TABLER-LICENSE). The app includes these three glyphs in its action font and the matching New chat Android shortcut vector; see [icon provenance](assets/fonts/README.md).

The website self-hosts Latin subsets of Manrope and Source Sans 3, distributed under the SIL Open Font License 1.1. Their copyright and license notices are retained in [Manrope's OFL notice](website/assets/fonts/MANROPE-OFL.txt) and [Source Sans 3's OFL notice](website/assets/fonts/SOURCE-SANS-3-OFL.txt). These web fonts are not bundled in the Android app.

Syntax highlighting uses [re_highlight](https://pub.dev/packages/re_highlight) 0.0.3, and the read-only source viewport uses [re_editor](https://pub.dev/packages/re_editor) 0.10.0. Both are by Reqable and distributed under the MIT license. Their dependency licenses are retained in Flutter's bundled notices.

Bot face motion adapts the timing formulas from [Hermes desktop's avatar renderer](https://github.com/NousResearch/hermes-agent/blob/ae3598c7cdf3a2e4a6f60d0d869602813dded97a/apps/desktop/src/plugins/hermes-bots/avatar.tsx), under the following license:

MIT License

Copyright (c) 2026 Nous Research

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Project icons and the Queue layers glyph use Microsoft’s unmodified `@vscode/codicons` 0.0.45, matching Hermes Desktop, under [CC BY 4.0](assets/fonts/CODICONS-LICENSE). Microsoft is the original author; see [font provenance](assets/fonts/README.md).

## Email draft cards

Wing's email draft integration is inspired by [arsiktech/hermes-draft-cards](https://github.com/arsiktech/hermes-draft-cards),
MIT, copyright 2026 arsiktech, reviewed at commit
`6e6ca659ece59b0ce1c28b3b188393491ee5a415`. The accompanying Wing Hermes plugin
adapts its structured card/version design and retains the original MIT notice.
Wing's Flutter renderer and Android compose handoff are implemented independently.
