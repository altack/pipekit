# Pipekit contract

The single contract every prompt — built-in or user-provided — must satisfy. The CI integrations (`action/`, `gitlab/`) read this and nothing else.

## Inputs (set by the caller, read by the agent)

| Env var | Required | Default | Meaning |
|---|---|---|---|
| `PIPEKIT_PROMPT` | yes | — | Prompt to load. `@pipekit/<name>` resolves to `/pipekit/prompts/<name>.md` (built-in). Anything else is treated as a path inside the container. |
| `PIPEKIT_INPUTS` | no | `{}` | JSON blob. Materialized to `$PIPEKIT_WORKSPACE/inputs.json` before the agent starts. The agent reads task-specific params from here. Must be valid JSON. |
| `PIPEKIT_PASS_WHEN` | no | — | jq expression evaluated against `result.json` at the end of the run. Truthy → exit 0, falsy → exit 1. If unset, exit code derives from `result.json:.status`. |
| `PIPEKIT_WORKSPACE` | no | `/work` | Per-task scratch directory. The CI integrations bind-mount the host's per-job temp dir here. |
| `PIPEKIT_AGENT` | no | — | Explicit driver name (`claude-code`, `codex`, `copilot`, …). Bypasses preference resolution. If the named driver is unavailable, exits 2. |
| `PIPEKIT_PREFERRED` | no | `claude-code` | Comma-separated ordered fallback list. Walks left-to-right and picks the first driver whose `check.sh` passes (CLI installed + credentials present). |
| `PIPEKIT_MODEL` | no | driver default | Agent-specific model id. Each driver decides its default. |
| `PIPEKIT_MAX_TURNS` | no | `200` | Safety cap on agent turns. |
| `<agent credentials>` | yes (one of) | — | Whichever credentials the chosen driver requires: `ANTHROPIC_API_KEY` (claude-code), `OPENAI_API_KEY` (codex), `GH_TOKEN` (copilot). Read at process start; never written to disk. |

## Agent resolution

```
if PIPEKIT_AGENT is set:
    run /pipekit/drivers/$PIPEKIT_AGENT/check.sh
    if check fails → exit 2 ("agent X is not available")
    else use $PIPEKIT_AGENT
else:
    for each name in PIPEKIT_PREFERRED.split(","):
        if /pipekit/drivers/$name/check.sh succeeds → use $name, stop
    if none matched → exit 2 ("no preferred agent available")
```

A driver is a directory `/pipekit/drivers/<name>/` containing:

- `check.sh` — exits 0 if the driver is usable (CLI on PATH, credentials present), non-zero otherwise.
- `run.sh` — receives the prompt path as `$1`, drives its agent's loop. Reads `PIPEKIT_INPUTS`, `PIPEKIT_WORKSPACE`, `PIPEKIT_MODEL`, `PIPEKIT_MAX_TURNS` from env. The driver does **not** write `result.json` — the prompt instructs the agent to. Exit code is bubbled up.

Built-in drivers in v0.x: `claude-code` (real), `codex` (stub), `copilot` (stub).

## Outputs (written by the agent, consumed by the caller)

Everything lives under `$PIPEKIT_WORKSPACE`:

| Path | Producer | Required | Purpose |
|---|---|---|---|
| `inputs.json` | `pipekit-agent` (pre-flight) | yes | Mirror of `PIPEKIT_INPUTS`. Agent reads this. |
| `result.json` | the prompt | yes | The verdict. Schema below. |
| `agent.jsonl` | `pipekit-agent` (during run) | yes | Raw stream-json from `claude` for debugging. |
| `artifacts/**` | the prompt | no | Evidence files (screenshots, logs, patches, snapshots). Referenced from `result.json` by relative path. |

CI integrations upload **the entire workspace directory** as a job artifact. No separate "artifacts only" path; everything-or-nothing.

## `result.json` schema

```json
{
  "status":  "pass" | "fail",
  "summary": "string",
  "findings": [
    {
      "id":       "string (optional, auto-stable if omitted)",
      "severity": "blocker | major | minor | info",
      "summary":  "string",
      "detail":   "string (optional)",
      "evidence": {
        "screenshots": ["artifacts/foo.png"],
        "logs":        ["artifacts/foo.log"],
        "snapshots":   ["artifacts/foo.html"]
      }
    }
  ],
  "outputs": {
    "<key>": "<any prompt-defined value>"
  }
}
```

- `status` and `summary` are **required**. Everything else is optional.
- `findings` is for prompts that produce N observations (audits, exploratory tests). For pass/fail prompts (build, deploy), it can be `[]` or omitted.
- `outputs` is for prompt-specific structured data the consumer wants to surface as CI step outputs (e.g. a deploy URL, a branch name, a count).
- Evidence paths are **relative to `$PIPEKIT_WORKSPACE`**. The contract's reference frame is the workspace, not the container root.

## Verdict rules

```
exit 0 (pass)  →  PIPEKIT_PASS_WHEN truthy, OR (unset and result.status == "pass")
exit 1 (fail)  →  PIPEKIT_PASS_WHEN falsy,  OR (unset and result.status == "fail")
exit 2 (infra) →  any of:
                    - PIPEKIT_PROMPT not readable
                    - PIPEKIT_INPUTS not valid JSON
                    - claude CLI exited non-zero
                    - result.json missing
                    - result.json not valid JSON
```

`pass_when` examples:

```jq
.status == "pass"                                              # equivalent to default
.findings | map(select(.severity == "blocker")) | length == 0  # no blockers
.outputs.tests_passed == .outputs.tests_total                  # all green
(.outputs.coverage // 0) >= 0.8                                # coverage gate
```

## Authoring a prompt

A prompt is a single markdown file appended to Claude Code's system prompt. It should:

1. State the task in one sentence.
2. Document the `inputs.json` schema it reads.
3. Describe the procedure.
4. Define the `result.json` shape it writes (must conform to the schema above).
5. Declare constraints (timeouts, scope, what tools to use).

Keep prompts to one page. If you need two pages, split into multiple prompts and chain them at the CI layer with `needs:`.

See `runner/prompts/hello.md` for the smallest possible example, and `runner/prompts/exploratory-tests.md` for a real one.
