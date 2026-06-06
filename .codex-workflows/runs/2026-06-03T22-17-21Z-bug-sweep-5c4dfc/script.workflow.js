export default workflow({
  name: "bug-sweep",
  version: "1",
  description:
    "Codebase-wide adversarial bug sweep with independent finding, verification, repro planning, and synthesis.",
  maxConcurrency: 16,
  maxAgents: 64,
  phases: [
    {
      id: "find",
      title: "Find",
      agents: [
        {
          id: "runtime-correctness",
          title: "runtime-correctness",
          prompt:
            "Audit runtime correctness bugs: state transitions, async races, lifecycle gaps, stale caches, and edge cases. Return strict JSON findings only."
        },
        {
          id: "data-contracts",
          title: "data-contracts",
          prompt:
            "Audit schemas, parsing, serialization, migrations, and compatibility contracts for bugs. Return strict JSON findings only."
        },
        {
          id: "cli-mcp-surfaces",
          title: "cli-mcp-surfaces",
          prompt:
            "Audit CLI and MCP public interfaces for broken flags, invalid defaults, missing validation, and workflow control bugs. Return strict JSON findings only."
        },
        {
          id: "ui-tui",
          title: "ui-tui",
          prompt:
            "Audit terminal UI behavior for broken navigation, unreadable states, overflow, stale status, and control mismatches. Return strict JSON findings only."
        },
        {
          id: "adapter-streaming",
          title: "adapter-streaming",
          prompt:
            "Audit Codex SDK and exec adapter streaming behavior, token/tool accounting, cancellation, and error handling. Return strict JSON findings only."
        },
        {
          id: "persistence-resume",
          title: "persistence-resume",
          prompt:
            "Audit run persistence, checkpoint/resume, restart-agent, event logs, and artifact durability. Return strict JSON findings only."
        }
      ]
    },
    {
      id: "verify",
      title: "Verify",
      agents: Array.from({ length: 12 }, (_, index) => ({
        id: `claim-${String(index + 1).padStart(2, "0")}`,
        title: `claim-${String(index + 1).padStart(2, "0")}`,
        prompt:
          "Adversarially verify one candidate bug from the find phase. Try to disprove it first. Return confirmed, false-positive, or needs-human-review as strict JSON findings only.",
        expectedTokens: 64000 + index * 1200,
        expectedTools: 34 + (index % 13),
        durationMs: 430 + index * 20
      }))
    },
    {
      id: "probe",
      title: "Probe",
      agents: [
        {
          id: "minimal-repros",
          title: "minimal-repros",
          prompt:
            "For confirmed or plausible bugs, design minimal repro commands/tests. Mark anything unproven as needs-human-review. Return strict JSON findings only."
        },
        {
          id: "regression-tests",
          title: "regression-tests",
          prompt:
            "Map confirmed bugs to exact regression test files, test names, and acceptance criteria. Return strict JSON findings only."
        }
      ]
    },
    {
      id: "synthesize",
      title: "Synthesize",
      agents: [
        {
          id: "bug-report",
          title: "bug-report",
          prompt:
            "Synthesize confirmed bugs, false positives, and needs-human-review items into a prioritized bug report. Return strict JSON findings only."
        }
      ]
    }
  ]
});
