# Third-party notices

## Agent platform icons

Harness renders agent brand marks from vector geometry embedded in
`Apps/Harness/Sources/HarnessApp/UI/AgentIconArt.swift` (parsed to `CGPath`s by
`SVGPathParser` and tinted at draw time — no bundled raster assets). All marks are
[**Lobe Icons**](https://github.com/lobehub/lobe-icons) (MIT, see below) — the
`@lobehub/icons-static-svg` monochrome (`currentColor`) variants: `codex`, `claude`,
`cursor`, `inflection` (Pi), `gemini`, and `goose`. Agents without a Lobe Icons mark
(e.g. Hermes, Aider, OpenClaw) fall back to a text name pill.

Platform names and logos are trademarks of their respective owners. They are used
here solely to identify the corresponding coding agent in the UI.

### Lobe Icons — MIT License

```
MIT License

Copyright (c) 2023 LobeHub

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
```
