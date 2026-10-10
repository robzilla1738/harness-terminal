# Coding CLI support

Harness recognizes 37 named terminal tools and bundles a sourced logo for each.
Install and authenticate the vendor CLI separately, then run its normal command in
any Harness terminal. Recognition does not install software, change the provider’s
approval settings, or execute startup commands. Terminal compatibility also applies
to other CLI programs; the catalog adds identity and activity presentation.

The same catalog supplies monochrome marks on transparent backgrounds in tabs, pane headers, sidebar, Overview/Board,
menus, and the main Settings → Agents page. Settings lists executable aliases and
shows Install Hooks only when Harness has an installer for that tool. An existing
custom `agents.json` remains an explicit replacement of the default detection table.

| Coding tool | Commands / aliases | Vendor documentation |
| --- | --- | --- |
| Codex | `codex` | [Vendor](https://github.com/openai/codex) |
| Claude Code | `claude` | [Vendor](https://claude.com/product/claude-code) |
| Cursor Agent | `cursor-agent` | [Vendor](https://cursor.com/cli) |
| Grok | `grok / grok-build` | [Vendor](https://x.ai) |
| Pi | `pi` | [Vendor](https://pi.dev/press-kit) |
| Hermes | `hermes` | [Vendor](https://github.com/NousResearch/hermes-agent) |
| OpenClaw | `openclaw` | [Vendor](https://github.com/openclaw/openclaw) |
| OpenCode | `opencode` | [Vendor](https://opencode.ai) |
| Aider | `aider` | [Vendor](https://aider.chat) |
| Gemini | `gemini` | [Vendor](https://github.com/google-gemini/gemini-cli) |
| Goose | `goose` | [Vendor](https://github.com/block/goose) |
| GitHub Copilot | `copilot` | [Vendor](https://github.com/github/copilot-cli) |
| Cline | `cline` | [Vendor](https://github.com/cline/cline) |
| Kilo Code | `kilo / kilocode` | [Vendor](https://github.com/Kilo-Org/kilocode) |
| Qwen Code | `qwen` | [Vendor](https://github.com/QwenLM/qwen-code) |
| Amp | `amp` | [Vendor](https://ampcode.com) |
| Droid | `droid` | [Vendor](https://factory.ai) |
| Crush | `crush` | [Vendor](https://github.com/charmbracelet/crush) |
| Kiro | `kiro-cli / kiro-cli-chat / kiro` | [Vendor](https://kiro.dev/cli/) |
| Mistral Vibe | `vibe` | [Vendor](https://github.com/mistralai/mistral-vibe) |
| OpenHands | `openhands` | [Vendor](https://github.com/OpenHands/OpenHands) |
| Auggie | `auggie` | [Vendor](https://www.augmentcode.com) |
| Kimi Code | `kimi / kimi-cli / kimi-code` | [Vendor](https://github.com/MoonshotAI/kimi-code) |
| Devin | `devin` | [Vendor](https://devin.ai/cli) |
| Codebuff | `codebuff / cb` | [Vendor](https://www.codebuff.com/docs/help/quick-start) |
| Command Code | `command-code / commandcode / cmd / cmdc` | [Vendor](https://commandcode.ai/docs/quickstart) |
| Qoder | `qoder / qodercli` | [Vendor](https://docs.qoder.com/cli/commands) |
| CodeRabbit | `coderabbit / cr` | [Vendor](https://docs.coderabbit.ai/cli) |
| IBM Bob | `bob chat / bob run` | [Vendor](https://bob.ibm.com/docs/shell/getting-started/start-bobshell-interactive) |
| Muse Code | `muse` | [Vendor](https://dev.meta.ai/docs/muse-code) |
| Antigravity CLI | `agy` | [Vendor](https://antigravity.google/docs/getting-started?tab=cli) |
| JetBrains Junie | `junie` | [Vendor](https://junie.jetbrains.com/docs/junie-cli.html) |
| CodeBuddy Code | `codebuddy / codebuddy-code / cbc / codebuddy-lowmem` | [Vendor](https://www.codebuddy.ai/docs/cli/quickstart) |
| Warp Oz | `oz / oz-preview / warp-cli` | [Vendor](https://docs.warp.dev/agents/cli/oz-cli/) |
| Abacus AI | `abacusai` | [Vendor](https://abacus.ai/help/abacusai-desktop/cli-installation) |
| MiniMax Code | `mcode` | [Vendor](https://github.com/MiniMax-AI/minimax-code) |
| Trae Code | `traecli` | [Vendor](https://docs.trae.cn/cli_get-started-with-trae-code-cli-2) |

Detection follows real process identities, runtime launch targets, and known npm
entry points. It does not scan arbitrary command arguments for product names.
Muse’s official launcher replaces itself with `muse-bin-<version>`; the documented
release-version grammar is recognized as well as `muse`. Antigravity’s coding CLI
is `agy`; launching the desktop IDE alone does not identify a terminal agent.
CodeRabbit is a review CLI. Warp Oz records the local CLI execution; exiting a
cloud-submission command is not evidence that its cloud workload completed.

## Advanced integration boundaries

All recognized tools can use ordinary terminal I/O, process/output observations,
attention presentation, resource sampling, and durable execution history. Inferred
activity is best effort, not an authoritative report of a completed conversational
turn or successful task. Missing token usage remains unavailable.

Existing hook installers cover Claude Code, Codex, Cursor, Grok, OpenCode, Pi,
Hermes, and OpenClaw. Versioned rich turn/tool adapters and transcript accounting
cover the implemented Claude/Codex/Cursor contracts. Provider conversation resume
and managed fan-out use their existing verified provider adapters. Adding an identity
does not silently enable hooks, transcript reads, automatic resume, or fan-out.
Use the tool’s own supported commands for capabilities without a Harness adapter.

The response capability `agent-identities-v1` announces the expanded vocabulary.
Clients without it receive generic identities for new tools in snapshots, attention,
agent lists, and run-history responses. Canonical stored identities remain unchanged.
`list-agents` retains its command name and JSON fields; current clients request the
expanded identities with an optional request capability field. Previous daemons
can ignore this field. There is no forced daemon restart to activate new detection:
existing owners preserve shells and show a pending compatible update.

## Products in the supplied screenshots

Coding tools already covered include Codex, Claude, Cursor, OpenCode, Droid,
Gemini, Copilot, Kimi Code, Kilo, Kiro, Augment/Auggie, Amp, Grok, Pi, and Mistral’s
Vibe. The added identities cover Devin, Codebuff, Command Code, Qoder, CodeRabbit,
IBM Bob, Muse Code, Antigravity CLI, Junie, CodeBuddy Code, Warp Oz, Abacus AI,
MiniMax Code, and ByteDance’s Trae Code. Doubao itself is a model service; Trae is
the separately documented terminal coding tool from that ecosystem.

Several labels identify plans or services for these tools: OpenCode Go belongs to
OpenCode, ClinePass to Cline, Charm Hyper to Crush, and Qwen Cloud to the Qwen
provider ecosystem. JetBrains AI is represented here by its terminal coding agent
Junie; WorkBuddy’s desktop ecosystem has the separately documented CodeBuddy Code
CLI. Muse Code is Meta’s coding agent; `muse.ai` is a different product and does
not share the `muse` identity. xKiro is distinct from Kiro CLI.

Model APIs, hosting plans, routers, speech services, and desktop/web applications
in the screenshots do not get invented terminal executables. The user clarified
that the Windsurf entry should be represented by Devin from devin.ai; Harness
shows Devin with its official current symbol and the `devin` command. Their logos are not
added to the CLI catalog merely because another agent can use them as a provider.
This includes the OpenAI/Azure/Vertex/Bedrock model services, AI Gateway, OpenRouter,
LiteLLM, Bifrost, speech APIs, and editor/app entries such as Zed.
The user selected coding CLIs and logos; optional AI-summary provider expansion is
outside this change.

## Artwork

The [logo catalog](../Apps/Harness/Resources/AgentLogos/README.md) records source
URLs, pinned revisions when available, SHA-256 hashes, and attribution. Original
licensed artwork and official website brand assets are bundled locally. SVG marks
use normalized original geometry; Codebuff, Crush, and Abacus AI retain their original raster
assets for provenance; the native renderer extracts their white foreground into a
transparent template, trims empty margins, and fits all marks consistently. App
chrome uses its foreground color and native menus adapt for light/dark contrast.
Rendering uses the existing cached native renderer without network lookups.
