# Pipekit contract

Pipekit's runtime contract has two layers:

- **Recipe spec** — what a recipe author writes. Declares inputs, requirements, agents, prompt. Documented in [`recipe.spec.md`](./recipe.spec.md).
- **Container contract** — the runtime API the runner image exposes. Documented here. The CI integrations (`action/`, `gitlab/`) read this and nothing else.

## Inputs (set by the caller, read by `pipekit-agent`)

| Env var | Required | Default | Meaning |
|---|---|---|---|
| `PIPEKIT_RECIPE` | yes | — | Recipe to load. `@pipekit/<name>` resolves to `/pipekit/recipes/<name>/recipe.yaml` (built-in). A path to a directory is treated as a recipe directory (`recipe.yaml` expected inside). A path to a file is treated as a `recipe.yaml` directly. |
| `PIPEKIT_INPUTS` | no | `{}` | JSON blob. Materialized to `$PIPEKIT_WORKSPACE/inputs.json` before the agent starts. The recipe's `inputs.schema` (if declared) is the source of truth for what's expected. Must be valid JSON. |
| `PIPEKIT_PASS_WHEN` | no | — | jq expression evaluated against `result.json` at the end of the run. Truthy → exit 0, falsy → exit 1. If unset, exit code derives from `result.json:.status`. |
| `PIPEKIT_WORKSPACE` | no | `/work` | Per-task scratch directory. The CI integrations bind-mount the host's per-job temp dir here. |
| `PIPEKIT_AGENT` | no | — | Explicit driver name (`claude-code`, `codex`, `copilot`, …). Bypasses preference resolution. If the named driver is unavailable, exits 2. |
| `PIPEKIT_PREFERRED` | no | recipe-declared | Comma-separated ordered fallback list. Overrides the recipe's `agents.preferred`. Walks left-to-right, picks the first driver whose `check.sh` passes. |
| `PIPEKIT_MODEL` | no | recipe-declared | Model id. Overrides `agents.models[<picked>]` from the recipe. |
| `PIPEKIT_MAX_TURNS` | no | `200` | Safety cap on agent turns. |
| `<agent credentials>` | yes (one of) | — | Whichever credentials the chosen driver requires: `ANTHROPIC_API_KEY` (claude-code), `OPENAI_API_KEY` (codex), `GH_TOKEN` (copilot). |

## Two-phase execution

### Phase 1 — root

`pipekit-agent` runs as `root` until handoff. It:

1. Resolves `PIPEKIT_RECIPE` to a `recipe.yaml`.
2. Parses the recipe.
3. Materializes `inputs.json` from `PIPEKIT_INPUTS` (validates as JSON).
4. Runs `recipe.setup.shell` under `timeout setup.timeout` if present. Non-zero exit → exit 2.
5. Validates `recipe.requires.commands` are on `PATH` after setup.
6. Validates `recipe.requires.env` (at least one must be set).
7. Validates `recipe.requires.mounts` are bind-mounted directories.
8. Resolves the agent driver: explicit `PIPEKIT_AGENT` or walk `PIPEKIT_PREFERRED || recipe.agents.preferred`.
9. Applies `recipe.agents.models[<picked>]` as `PIPEKIT_MODEL` default if unset.
10. `chown -R node:node` on the workspace.
11. `exec runuser -u node` into Phase 2.

### Phase 2 — node (unprivileged)

`run-recipe.sh` runs as `node`. It:

1. Invokes `/pipekit/drivers/<picked>/run.sh <prompt-path>`. The driver hands the prompt + task to its agent and exits with the agent's status.
2. Validates `result.json` exists and is valid JSON.
3. Computes the verdict (default: `result.status`; override: `PIPEKIT_PASS_WHEN`) and exits.

The agent itself **never runs as root**.

## Driver contract

A driver is a directory `/pipekit/drivers/<name>/` containing:

- `check.sh` — exits 0 if the driver is usable (CLI on PATH, credentials present), non-zero otherwise. Run during agent resolution.
- `run.sh` — receives the prompt path as `$1`. Drives its agent's loop. Reads `PIPEKIT_INPUTS`, `PIPEKIT_WORKSPACE`, `PIPEKIT_MODEL`, `PIPEKIT_MAX_TURNS` from env. The driver does **not** write `result.json` — the prompt instructs the agent to. Exit code is bubbled up.

Built-in drivers in v0.x: `claude-code` (real), `codex` (stub), `copilot` (stub).

## Outputs (written by the agent, consumed by the caller)

Everything lives under `$PIPEKIT_WORKSPACE`:

| Path | Producer | Required | Purpose |
|---|---|---|---|
| `inputs.json` | `pipekit-agent` (pre-flight) | yes | Mirror of `PIPEKIT_INPUTS`. Agent reads this. |
| `recipe.yaml` | `pipekit-agent` (pre-flight) | yes | Copy of the resolved recipe, for debugging. |
| `result.json` | the prompt (via the agent) | yes | The verdict. Schema below. |
| `agent.jsonl` | the driver | yes | Raw agent output (driver-specific format). |
| `artifacts/**` | the prompt | no | Evidence files (screenshots, logs, patches, snapshots). Referenced from `result.json` by relative path. |

CI integrations upload **the entire workspace directory** as a job artifact. Everything-or-nothing.

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
    "<key>": "<any recipe-defined value>"
  }
}
```

- `status` and `summary` are **required**. Everything else is optional.
- `findings` is for recipes that produce N observations (audits, exploratory tests). For pass/fail recipes (build, deploy), it can be `[]` or omitted.
- `outputs` is for recipe-specific structured data the consumer wants to surface as CI step outputs (e.g. a deploy URL, a branch name, a count).
- Evidence paths are **relative to `$PIPEKIT_WORKSPACE`**.

## Verdict rules

```
exit 0 (pass)   →  PIPEKIT_PASS_WHEN truthy, OR (unset and result.status == "pass")
exit 1 (fail)   →  PIPEKIT_PASS_WHEN falsy,  OR (unset and result.status == "fail")
exit 2 (infra)  →  any of:
                     - recipe not found / unparseable
                     - PIPEKIT_INPUTS not valid JSON
                     - setup.shell failed or timed out
                     - requires.* not satisfied
                     - no agent available
                     - driver crashed
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

## Authoring a recipe

See [`recipe.spec.md`](./recipe.spec.md).

`runner/recipes/hello/` is the smallest possible example. `runner/recipes/exploratory-tests/` is a real one.
