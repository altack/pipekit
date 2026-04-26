# Pipekit container contract

The runtime API the runner image exposes — env vars in, structured `result.json` out, exit codes derived from the verdict. Three docs together fully describe the system:

- **`recipe.spec.md`** — what a recipe author writes (the `recipe.yaml` schema + lifecycle).
- **`result.spec.md`** — what the recipe writes back (the universal `result.json` schema).
- **This file** — how CI integrations talk to the runner image (env vars, mounts, exit codes, two-phase execution).

CI integrations (`action/`, `gitlab/`) read this and nothing else.

## Inputs (set by the caller, read by `pipekit-agent`)

| Env var | Required | Default | Meaning |
|---|---|---|---|
| `PIPEKIT_RECIPE` | yes | — | Recipe to load. `@<org>/<name>` resolves to `${PIPEKIT_RECIPES_DIR}/<org>/<name>/recipe.yaml`. A path to a directory is treated as a recipe directory; a path to a file is treated as a `recipe.yaml`. |
| `PIPEKIT_RECIPES_DIR` | no | `/pipekit/recipes` | Where namespaced recipes are resolved. v0.0.x: bind-mount your recipes repo here. v0.2: URL-based fetch via `PIPEKIT_RECIPES_REGISTRY`. |
| `PIPEKIT_INPUTS` | no | `{}` | JSON blob. Materialized to `$PIPEKIT_WORKSPACE/inputs.json`. **Validated against `recipe.inputs.schema`** (JSON Schema) before the agent starts; bad inputs fail fast at exit 2. |
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

1. Captures `PIPEKIT_STARTED_AT` (UTC, ISO-8601) — pre-setup, pre-agent.
2. Resolves `PIPEKIT_RECIPE` to a `recipe.yaml`.
3. Parses the recipe; computes `RECIPE_ID` (`@<org>/<name>@<version>` for namespaced; `<name>@<version>` for path-based).
4. Materializes `inputs.json` from `PIPEKIT_INPUTS` (validates as JSON).
5. **Validates `inputs.json` against `recipe.inputs.schema`** (JSON Schema, via `ajv`). Failure → exit 2 with the validation error.
6. Runs `recipe.setup.shell` under `timeout setup.timeout` if present. Non-zero exit → exit 2.
7. Validates `recipe.requires.commands` are on `PATH` after setup.
8. Validates `recipe.requires.env` (at least one must be set).
9. Validates `recipe.requires.mounts` are bind-mounted directories.
10. Resolves the agent driver: explicit `PIPEKIT_AGENT` or walk `PIPEKIT_PREFERRED || recipe.agents.preferred`.
11. Applies `recipe.agents.models[<picked>]` as `PIPEKIT_MODEL` default if unset.
12. `chown -R node:node` on the workspace.
13. `exec runuser -u node` into Phase 2 with `STARTED_AT`, `RECIPE_ID`, `AGENT`, `MODEL` exported.

### Phase 2 — node (unprivileged)

`run-recipe.sh` runs as `node`. It:

1. Invokes `/pipekit/drivers/<picked>/run.sh <prompt-path>`. The driver hands the prompt + task to its agent and exits with the agent's status.
2. Validates `result.json` exists and is valid JSON.
3. **Stamps `run.recipe`, `run.agent`, `run.model`, `run.started_at`, `run.finished_at`** into `result.json` — overwriting whatever the agent wrote for those keys (the runner is authoritative for that metadata).
4. Computes the verdict (default: `result.status`; override: `PIPEKIT_PASS_WHEN`) and exits.

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
| `inputs.json`   | pipekit-agent (pre-flight) | yes | Mirror of `PIPEKIT_INPUTS`. Validated against `recipe.inputs.schema`. Agent reads this. |
| `recipe.yaml`   | pipekit-agent (pre-flight) | yes | Copy of the resolved recipe, for debugging. |
| `result.json`   | recipe agent + runner stamping | yes | **The single contract.** Schema: [`result.spec.md`](./result.spec.md). Status, summary, run metadata, findings, outputs. |
| `agent.jsonl`   | the driver | yes | Raw agent output (driver-specific format). |
| `artifacts/**`  | the recipe agent | no | Optional evidence — screenshots, logs, snapshots, patches, derived markdown reports. Referenced from `result.json` via paths relative to `artifacts/`. |

CI integrations upload **the entire workspace directory** as a job artifact. Everything-or-nothing.

## `result.json`

`result.json` is the **single machine-readable verdict** every recipe writes. There is no separate "rich report" file; the schema is universal across all recipes. See [`result.spec.md`](./result.spec.md) for full field-by-field documentation.

```json
{
  "status":  "pass" | "fail",
  "summary": "string",
  "run": {
    "recipe":      "...",   // runner-stamped
    "agent":       "...",   // runner-stamped
    "model":       "...",   // runner-stamped
    "started_at":  "...",   // runner-stamped
    "finished_at": "...",   // runner-stamped
    "phases_completed": ["..."],          // recipe-authored
    "overall_status":   "clean | minor-findings | major-findings | blocker"
  },
  "findings": [ /* universal finding shape — see result.spec.md */ ],
  "outputs":  { /* recipe-defined freeform JSON */ }
}
```

The recipe agent is responsible for `status`, `summary`, `run.phases_completed`, `run.overall_status`, `findings`, and `outputs`. The runner is responsible for the five `run.*` metadata fields above (overwrites whatever the agent wrote there).

## Verdict rules

```
exit 0 (pass)   →  PIPEKIT_PASS_WHEN truthy, OR (unset and result.status == "pass")
exit 1 (fail)   →  PIPEKIT_PASS_WHEN falsy,  OR (unset and result.status == "fail")
exit 2 (infra)  →  any of:
                     - recipe not found / unparseable
                     - PIPEKIT_INPUTS not valid JSON
                     - inputs.json fails inputs.schema validation
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

See [`recipe.spec.md`](./recipe.spec.md). The smallest example is `recipes/pipekit/hello/`; the most realistic is `recipes/pipekit/dep-migration-check/`.
