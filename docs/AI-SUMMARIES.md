# Optional AI summaries

The deterministic Overview digest works without an AI provider. Optional prose uses the same recorded totals, explicit test receipts and observed usage, with bounded extra detail only after consent. A 200-event display timeline does not limit aggregate totals. Turn completion is never treated as process exit; host profile usage is labeled shared rather than exclusively attributed to a workspace.

Open **Optional AI Summaries…** in the command palette. Add a provider, save its exact endpoint/protocol, securely enter a credential where required, discover models, and choose an explicit model ID. Saving a disabled provider does not contact it. Enabling performs model discovery; **Discover models** also permits a deliberate catalog refresh while disabled. Catalogs show their successful fetch time and refresh failures separately. Successful catalogs are complete and paginated; a failed refresh keeps the last complete catalog. Unsupported/archived models are filtered using documented metadata. Missing capabilities are unknown. Discovery never changes the selected model, and a manually entered model ID remains supported when discovery is unavailable.

The presets use native Swift networking:

| Integration | Generation | Discovery contract |
| --- | --- | --- |
| Vercel AI Gateway | Compatible chat completions | [Gateway model catalog](https://vercel.com/docs/ai-gateway/models-and-providers) |
| OpenAI | [Responses](https://developers.openai.com/api/reference/resources/responses/methods/create), with `store: false` | [Account-accessible models](https://developers.openai.com/api/reference/resources/models/methods/list) |
| Anthropic | [Messages](https://platform.claude.com/docs/en/api/messages/create) | [Paginated models](https://platform.claude.com/docs/en/api/models/list) |
| Google Gemini | [Native generateContent](https://ai.google.dev/api/generate-content), header credentials | [Supported generation methods](https://ai.google.dev/api/models) |
| OpenRouter | Compatible chat completions | [Output modalities and supported parameters](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties) |
| Grok | Compatible chat completions | [Language-model catalog](https://docs.x.ai/developers/rest-api-reference/inference/models) |
| Groq | [Compatible endpoint](https://console.groq.com/docs/openai) | Account-accessible `/models`; capability metadata may be unavailable |
| Mistral | Compatible chat completions | [Chat capability catalog](https://docs.mistral.ai/api/endpoint/models) |
| DeepSeek | [Compatible chat completions](https://api-docs.deepseek.com/api/create-chat-completion/) | [Accessible models](https://api-docs.deepseek.com/api/list-models/); capability metadata may be unavailable |
| Ollama | Compatible local endpoint | [Installed tags](https://docs.ollama.com/api/tags); tag capability metadata is unavailable |
| LM Studio | Compatible local endpoint | [Visible local models](https://lmstudio.ai/docs/developer/openai-compat/models); capability metadata may be unavailable |
| Custom | Explicit Responses / Messages / Gemini / compatible choice | The selected protocol’s model endpoint; explicit model IDs are allowed |
| Apple on-device | Available system language model, no tools | Availability check; `apple-system` ID. Requires supported hardware, macOS 26+, Apple Intelligence and an available downloaded model |

HTTPS is required except validated loopback HTTP for local endpoints. Embedded URL credentials, query strings and fragments are refused. Keys are credential references in settings, not values. macOS uses the shared signed-component Keychain boundary. Linux credentials use explicitly documented owner-only plaintext storage; this is not encryption. No JavaScript runtime is introduced.

Before enabling generation, review the exact destination and selected categories. Defaults include activity counts, observed usage counters and explicit test counts. Repository paths, captured messages and bounded excerpts of the last known completed command output each require explicit inclusion. Inputs are at most 16 KiB; detail bounds and missing observations are labeled. Unsupported larger scopes fail rather than silently truncating aggregate totals. Captured text is untrusted input, and generation exposes no tools or action executor. Results are displayed as plain text with requested and reported model provenance. A reported alias/version difference is visible and never changes the configured selection.

Use **Summarize workspace…** for a reviewed one-time request. **Automatic workspace…** is a separate opt-in for that selected workspace, defaulting to at most once per 60 minutes with recorded activity. Advanced configuration permits 30–1440 minute intervals. Disabled/removed providers cannot retain enabled automatic workspaces. Automatic occurrences commit before submission; failures do not trigger surprise retries or provider/model fallback.

Every submission commits an encrypted durable receipt with its UUID before a potentially billable request. Identical IDs return the existing receipt/result. A changed provider, workspace or range under that ID is refused. Daemon replacement cancels in-flight work, retaining an uncertain receipt; crash recovery marks interrupted submissions uncertain. There is no automatic retry after timeout, cancellation, uncertain transport or rate/budget errors. Manual retry requires a deliberately new submission ID and may incur another charge. If the history key is unavailable, no generation is submitted; live programs remain running and the deterministic digest reports history availability.

Responses have a 90-second resource deadline, bounded concurrency, a 1 MiB protocol-response limit and a 32 KiB visible-text limit in addition to the configured token budget. Catalog responses are bounded per page, with page/cursor/model/serialized-cache budgets. Redirects, persistent HTTP caches and cookies are disabled. Errors do not display provider response bodies or credential-bearing URLs. A provider/token limit may return incomplete prose, which is labeled. Closing the window leaves accepted results in history; **Cancel request** requests cancellation explicitly.

Receipts and result text use the daemon activity ledger. Closed records follow the 14-day / 500-record retention bound; submitted records are protected. Persistence opt-out removes derived prose and invalidates late result commits atomically, while retaining structural receipts so purging text cannot authorize duplicate billing. No digest input is persisted by the summary service.

CLI examples:

```sh
harness-cli summary preview --input ai-settings.json
harness-cli summary configure --input ai-settings.json --reviewed
harness-cli summary credential-set --reference UUID --stdin < private-key-input
harness-cli summary models --provider UUID
harness-cli summary catalog --provider UUID --offset 0
harness-cli summary generate --id UUID --provider UUID --workspace UUID --from UNIX_SECONDS --to UNIX_SECONDS --reviewed
harness-cli summary record --id UUID
harness-cli summary cancel --id UUID
harness-cli summary history --offset 0
```

Use secure redirected input rather than arguments for credentials, and remove any temporary key file after use. `summary.configure` accepts the typed `AISettings` JSON. An enabled provider needs `consentedDestination` exactly matching its destination and nonempty `consentedCategories`. Configuration, discovery and generation APIs stay local and are explicitly excluded from Lua, mobile and MCP exposure. The API catalog declares their capabilities/effects; an older daemon produces an actionable unsupported-capability error.

Protocol fixtures and an isolated local HTTP scenario cover current catalogs, pagination, retained refresh failures, complete totals, content filtering, actual submission deduplication, rate errors, cancellation, encrypted storage, opt-out during generation and interrupted request recovery. A live provider smoke check requires supplied credentials; fixture success is not a claim that a billable live request was made. The provisioned native configuration walkthrough verifies named presets, exact destination/model and default-off content consent; no billable generation is claimed. See [native acceptance](NATIVE-ACCEPTANCE.md).
