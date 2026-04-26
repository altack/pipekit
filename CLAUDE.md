# CLAUDE.md — Pipekit

You are working on **Pipekit**: a self-hosted "cousin of Anthropic's Managed Agents" that drops into a consumer's existing GitHub Actions or GitLab CI pipeline. The user picks a **recipe** — a self-contained spec declaring setup, requirements, agent preferences, inputs schema, and prompt — and pipekit runs it inside an isolated docker container on the user's CI runner. The agent emits `result.json` + an artifacts directory; the CI job's pass/fail is derived from that result.

The product wedge: **same submit-task-get-verdict shape as Managed Agents, but the sandbox is the user's CI runner — secrets, code, and artifacts never leave their org. The image is a generic isolated environment; recipes own their dependencies.**

## Mental model

- **One container, one recipe, one structured result.** That's the unit of work.
- **The CI engine owns the DAG.** GitHub `needs:` and GitLab `needs:` already do step orchestration. Pipekit does not compete with them.
- **The image is an isolated environment, not a curated toolchain.** Always-on tools: shell utils, gh, glab, chromium, agent-browser, JS runtime (node/bun/pnpm/yarn), agent CLIs. Anything else (Python, Go, Ruby, language deps) is installed at runtime via the recipe's `setup.shell`.
- **Recipes are first-class — and they are NOT baked into the image.** A recipe is a directory with `recipe.yaml` + `prompt.md`. Recipes live in their own repos (the canonical one being `pipekit/pipekit-recipes`), and the runner resolves `@<org>/<name>` against `${PIPEKIT_RECIPES_DIR:-/pipekit/recipes}` at runtime. v0.0.x: bind-mount the recipes dir from the host. v0.2: fetch on demand from `PIPEKIT_RECIPES_REGISTRY` (URL pattern; not yet implemented).
- **Multi-agent at the runtime layer.** Drivers: `claude-code`, `codex`, `copilot`. Recipes declare `agents.preferred`; the runner picks the first available at runtime.
- **One JSON contract: `result.json`.** Every recipe writes a single `result.json` to the workspace root, conformant to `docs/result.spec.md`. There is **no separate "rich report" file**. Status, summary, run metadata, structured findings, recipe-defined outputs — all in one schema. The runner stamps `run.recipe`, `run.agent`, `run.model`, `run.started_at`, `run.finished_at`; the recipe authors the rest.
- **`recipe.yaml` in, `result.json` out** — see `docs/recipe.spec.md` (input contract) and `docs/result.spec.md` (output contract); `docs/contract.md` describes the runtime API the runner image exposes.

## Architecture

### Runner image (`runner/`)

A docker image baked with: agent CLIs (Claude Code, agent-browser), chromium, gh, glab, bun/pnpm/yarn, jq, yq, and a single entrypoint at `/usr/local/bin/pipekit-agent`. **No recipes are baked in** — the image is pure harness. The image runs as **root by default** so Phase 1 can run `setup.shell`; Phase 2 demotes to `node` before invoking the agent.

### Recipes (`recipes/` — separate from the image)

Recipes live alongside the harness in this repo (`recipes/<org>/<name>/`) for development, but they are **content, not harness**. They will be extracted to `pipekit/pipekit-recipes` (the canonical marketplace) and any number of community publishers (`@yourcompany/<name>`, etc.). The runtime resolver supports `@<org>/<name>` against any directory tree mounted at `$PIPEKIT_RECIPES_DIR`.

### Two-phase entrypoint

```
Phase 1 (root) — pipekit-agent:
  capture STARTED_AT (ISO-8601 UTC)
  parse recipe.yaml; compute RECIPE_ID (@<org>/<name>@<version> or <name>@<version>)
  materialize inputs.json from PIPEKIT_INPUTS
  validate inputs.json against recipe.inputs.schema (ajv)
  run setup.shell under timeout
  validate requires.{commands, env, mounts}
  resolve agent driver (PIPEKIT_AGENT explicit || agents.preferred walk)
  chown -R node:node $WORKSPACE
  exec runuser -u node -- /pipekit/lib/run-recipe.sh
                         (passes STARTED_AT, RECIPE_ID, AGENT, MODEL forward)

Phase 2 (node) — run-recipe.sh:
  invoke /pipekit/drivers/$AGENT/run.sh
  validate result.json (exists + valid JSON)
  stamp run.{recipe, agent, model, started_at, finished_at} into result.json
  compute verdict (PIPEKIT_PASS_WHEN || result.status)
  exit
```

The agent never runs as root. setup.shell needs root for apt/curl/etc.; the demotion happens before the driver is invoked.

### Container contract

```
in   PIPEKIT_RECIPE       @<org>/<name> (resolved against PIPEKIT_RECIPES_DIR)
                          or path to recipe dir / recipe.yaml
     PIPEKIT_RECIPES_DIR  where namespaced recipes live (default /pipekit/recipes;
                          typically a bind-mount of pipekit/pipekit-recipes)
     PIPEKIT_INPUTS       JSON blob (default "{}"); validated against recipe.inputs.schema
     PIPEKIT_PASS_WHEN    optional jq expression evaluated against result.json
     PIPEKIT_WORKSPACE    scratch dir (default /work)
     PIPEKIT_AGENT        explicit driver (claude-code | codex | copilot)
     PIPEKIT_PREFERRED    comma-separated fallback (overrides recipe default)
     PIPEKIT_MODEL        model id (overrides recipe default)
     PIPEKIT_MAX_TURNS    safety cap (default 200)
     <credentials>        ANTHROPIC_API_KEY | OPENAI_API_KEY | GH_TOKEN

out  $PIPEKIT_WORKSPACE/result.json     universal verdict (docs/result.spec.md)
                                          { status, summary, run, findings, outputs }
     $PIPEKIT_WORKSPACE/artifacts/**    optional evidence — screenshots, logs,
                                          snapshots, patches, derived markdown reports
     $PIPEKIT_WORKSPACE/agent.jsonl     raw agent output (driver-specific format)
     $PIPEKIT_WORKSPACE/inputs.json     materialized recipe inputs
     $PIPEKIT_WORKSPACE/recipe.yaml     copy of the resolved recipe

exit 0  pass        (status="pass" or pass_when truthy)
     1  agent fail  (status="fail" or pass_when falsy)
     2  infra fail  (recipe missing/invalid, inputs failed schema validation,
                     setup failed, requires unsatisfied, no agent available,
                     result.json missing, etc.)
```

### CI integrations

- **GitHub Action** (`action/action.yml`) — composite action wrapping `docker run`. Uploads `$PIPEKIT_WORKSPACE` as a job artifact via `actions/upload-artifact`. Sets `status` and `summary` outputs from `result.json`.
- **GitLab include** (`gitlab/v1.yml`) — job template using `image: ghcr.io/altack/pipekit-runner` directly. The job runs *as* the agent (no nested docker). Artifacts are auto-collected via `artifacts: paths:`.

Both shells delegate exclusively to `pipekit-agent`. They contain zero agent logic.

## Decisions already locked — do not relitigate

- **No DAG runner is the headline.** CI engines have DAGs. We use them.
- **The image is an isolated environment, not a curated toolchain.** Recipes install their own deps via `setup.shell` (runs as root in Phase 1). Don't grow the image's always-on tool list without a strong reason.
- **Recipes are NOT baked into the image.** They are content, distributed via git repos (the marketplace pattern, similar to Claude Code skills). Image bake-in was an early mistake; recipes now live under `recipes/` separate from `runner/` and will be extracted to `pipekit/pipekit-recipes` for canonical distribution. v0.0.x resolves recipes via bind-mount; v0.2 adds URL-based on-demand fetch.
- **One JSON output: `result.json`.** Every recipe writes a single `result.json` to the workspace root. There is no separate `artifacts/report.json`. The schema is universal — `docs/result.spec.md` is owned by pipekit, baked into the image at `/pipekit/docs/result.spec.md`, and recipes reference it by absolute path. We tried the small-pipekit-contract / rich-recipe-report split early on; it leaked schema duplication everywhere and coupled the viewer to autotest. Don't undo this.
- **The runner stamps `run.{recipe, agent, model, started_at, finished_at}`.** Authoritative — overwrites whatever the agent wrote. The recipe authors `run.phases_completed` and `run.overall_status`.
- **`inputs.schema` is enforced.** Recipes declare a JSON Schema; pipekit-agent validates `inputs.json` against it via `ajv` before invoking the agent. Bad inputs fail fast at exit 2 — no agent tokens spent on malformed data.
- **No canvas in v0.x.** YAML in `.github/workflows/*.yml` and `.gitlab-ci.yml` is the canvas.
- **No backwards compat with autotest.** Pipekit is a new product. Autotest is now a built-in pipekit recipe (`@pipekit/dep-migration-check`); the two systems are otherwise unrelated.
- **`pass_when` is a jq expression**, not a custom DSL. It's evaluated against `result.json`. Inventing an expression language is yak-shaving.
- **One image for all prompts** in v0.x. Per-step custom images are an escape hatch for later.
- **Local-only** — no hosted state, no SaaS, no shared canvas. The user's CI is the runtime; the user's git is the storage.

## Non-goals

- A scheduler. Use cron in your CI.
- A UI/canvas/dashboard for authoring pipelines. Use the YAML you already have.
- Cross-run aggregation, trend analysis, flake detection. Out of scope.
- Replacing CI. Pipekit is a step *inside* a CI job, not a CI replacement.
- A "rich report" file separate from `result.json`. We tried; it caused more problems than it solved.

## Glossary

- **Recipe** — a directory containing `recipe.yaml` + `prompt.md` (and optional helpers like `upgrade.sh`). The unit of work definition. Lives in a recipes repo, not the runner image.
- **Recipe agent** — the agent CLI (Claude Code, Codex, …) executing a recipe's prompt inside the runner container during Phase 2.
- **Driver** — the `/pipekit/drivers/<name>/{check.sh, run.sh}` shim that knows how to invoke a specific agent CLI. Drivers live in the image; recipes pick from them via `agents.preferred`.
- **Workspace** — the per-task scratch directory mounted into the container at `/work`. Inputs go in (`inputs.json`, `recipe.yaml`), results + artifacts come out (`result.json`, `artifacts/**`, `agent.jsonl`).
- **Contract** — the runtime API the runner image exposes. See `docs/contract.md`. Distinct from the recipe spec (`docs/recipe.spec.md`) and the result spec (`docs/result.spec.md`).
- **Verdict** — pass/fail decision. Default: `result.json.status`. Overridable via `PIPEKIT_PASS_WHEN` (jq expression).

## Conventions when writing code

- TypeScript for any future helpers; bash for the entrypoint.
- No comments explaining *what* code does. Names should suffice.
- No backwards-compat shims. Nothing has shipped externally.
- No abstractions for hypothetical second use cases. Four concrete recipes (hello, exploratory-tests, dep-migration-check, playwright-from-diff) — abstract when there's a 5th case asking for it.

## What to read next

- `README.md` — quick start and CI snippets.
- `docs/recipe.spec.md` — what recipe authors write.
- `docs/result.spec.md` — what recipes write back.
- `docs/contract.md` — runtime API of the runner image.
- `runner/pipekit-agent` — Phase 1 implementation.
- `runner/lib/run-recipe.sh` — Phase 2 implementation.
- `recipes/pipekit/hello/` — smallest possible example recipe.
- `recipes/pipekit/dep-migration-check/` — most realistic example (autotest's lift).
- `e2e/smoke.sh` — local end-to-end test.
