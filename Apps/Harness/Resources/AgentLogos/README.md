# Agent logo sources

Harness bundles 23 coding-tool identities. Marks are used only to identify their
respective tools; no affiliation or endorsement is implied. Research: 2026-10-08.

Original artwork is checked in beside this file. `sources.json` records each URL,
Git revision where available, SHA-256, license, and official product page.
`uv run Scripts/generate-agent-icons.py` regenerates compiled geometry offline
(with the pinned fonttools package installed). It verifies source hashes, extracts
mark paths, removes favicon backgrounds/filters, and normalizes optical bounds.
Pi uses the coding agent's press-kit mark, not Inflection's Pi logo. Aider uses
the glyph from its official pinned-tab favicon. Crush retains its upstream PNG;
all other marks are vector geometry. No user image data is involved.

Generated geometry is embedded in the executable. Logos are cached at requested
sizes; there is no network lookup, animation, or shadow in the badge view.

| Tool | Official project | Bundled artwork | Source terms |
| --- | --- | --- | --- |
| codex | [Project](https://github.com/openai/codex) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/codex.svg) | MIT (LobeHub) |
| claude-code | [Project](https://claude.com/product/claude-code) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/claude.svg) | MIT (LobeHub) |
| cursor | [Project](https://cursor.com/cli) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/cursor.svg) | MIT (LobeHub) |
| openclaw | [Project](https://github.com/openclaw/openclaw) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/openclaw.svg) | MIT (LobeHub) |
| opencode | [Project](https://opencode.ai) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/opencode.svg) | MIT (LobeHub) |
| gemini | [Project](https://github.com/google-gemini/gemini-cli) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/gemini.svg) | MIT (LobeHub) |
| goose | [Project](https://github.com/block/goose) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/goose.svg) | MIT (LobeHub) |
| grok | [Project](https://x.ai) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/grok.svg) | MIT (LobeHub) |
| hermes | [Project](https://github.com/NousResearch/hermes-agent) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/hermesagent.svg) | MIT (LobeHub) |
| kiro | [Project](https://kiro.dev/cli/) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/kiro.svg) | MIT (LobeHub) |
| openhands | [Project](https://github.com/OpenHands/OpenHands) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/openhands.svg) | MIT (LobeHub) |
| kimi | [Project](https://github.com/MoonshotAI/kimi-code) | [Source](https://raw.githubusercontent.com/lobehub/lobe-icons/c385b2b8d1f9e19aa86e628d4e23c91ee1111a47/packages/static-svg/icons/kimi.svg) | MIT (LobeHub) |
| aider | [Project](https://aider.chat) | [Source](https://raw.githubusercontent.com/Aider-AI/aider/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/website/assets/icons/safari-pinned-tab.svg) | Apache-2.0 |
| cline | [Project](https://github.com/cline/cline) | [Source](https://raw.githubusercontent.com/cline/cline/fa840c741c3fc2eb49e7e0a4484895a99dae5cc5/apps/cline-hub/src/webview/public/cline-logo-filled.svg) | Apache-2.0 |
| kilo | [Project](https://github.com/Kilo-Org/kilocode) | [Source](https://raw.githubusercontent.com/Kilo-Org/kilocode/974723450caa7c91f140b128e2f2e3b4a932ade8/packages/ui/src/assets/icons/provider/kilo.svg) | MIT |
| qwen | [Project](https://github.com/QwenLM/qwen-code) | [Source](https://raw.githubusercontent.com/QwenLM/qwen-code/fbde5cf00e9cb5ba0fdf825e3a0e691d9b1d7423/packages/vscode-ide-companion/assets/sidebar-icon.svg) | Apache-2.0 |
| vibe | [Project](https://github.com/mistralai/mistral-vibe) | [Source](https://raw.githubusercontent.com/mistralai/mistral-vibe/7cb91894c40bb25173abcfa36e5ea2b4b81eb28c/distribution/zed/icons/mistral_vibe.svg) | Apache-2.0 |
| crush | [Project](https://github.com/charmbracelet/crush) | [Source](https://raw.githubusercontent.com/charmbracelet/crush/cd8070361f36c8370c1071a8eb34250c3033145a/internal/ui/notification/crush-icon-solo.png) | FSL-1.1-MIT; logo trademark Charm |
| copilot | [Project](https://github.com/github/copilot-cli) | [Source](https://raw.githubusercontent.com/primer/octicons/97825f832c98f817867f770d084c08e3edc6f78c/icons/copilot-24.svg) | MIT (GitHub Primer) |
| amp | [Project](https://ampcode.com) | [Source](https://ampcode.com/app-icon.svg?v=4) | Amp brand mark |
| droid | [Project](https://factory.ai) | [Source](https://factory.ai/favicon.svg) | Factory brand mark |
| auggie | [Project](https://www.augmentcode.com) | [Source](https://www.augmentcode.com/favicon.svg) | Augment brand mark |
| pi | [Project](https://pi.dev/press-kit) | [Source](https://pi.dev/logo.svg) | Pi press kit; MIT site |

Redistribution license texts are included in `licenses/`. Brand names and marks remain the property of their owners. Website press/favicon assets are included for product identification; their availability is not a grant of general trademark rights.
