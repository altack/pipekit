# CLAUDE.md — Pipekit

You are working on **Pipekit**: a self-hosted "cousin of Anthropic's Managed Agents" that drops into a consumer's existing GitHub Actions or GitLab CI pipeline. The user picks a **recipe** — a self-contained spec declaring setup, requirements, agent preferences, inputs schema, and prompt — and pipekit runs it inside an isolated docker container on the user's CI runner. The agent emits `result.json` + an artifacts directory; the CI job's pass/fail is derived from that result.

The product wedge: **same submit-task-get-verdict shape as Managed Agents, but the sandbox is the user's CI runner — secrets, code, and artifacts never leave their org. The image is a generic isolated environment; recipes own their dependencies.**

## Mental model

- **One container, one recipe, one structured result.** That's the unit of work.
- **The CI engine owns the DAG.** GitHub `needs:` and GitLab `needs:` already do step orchestration. Pipekit does not compete with them.
- **The image is an isolated environment, not a curated toolchain.** Always-on tools: shell utils, gh, glab, chromium, agent-browser, JS runtime (node/bun/pnpm/yarn), agent CLIs. Anything else (Python, Go, Ruby, language deps) is installed at runtime via the recipe's `setup.shell`.
- **Recipes are first-class.** A recipe is a directory with `recipe.yaml` + `prompt.md`. Built-in (`@pipekit/<name>`, baked into the image) or user-provided (path to a directory). No registry, no template engine, no remote resolution yet — that's a v0.2+ concern.
- **Multi-agent at the runtime layer.** Drivers: `claude-code`, `codex`, `copilot`. Recipes declare `agents.preferred`; the runner picks the first available at runtime.
- **The contract is `recipe.yaml` in, `result.json` out** — see `docs/recipe.spec.md` and `docs/contract.md`.

## Architecture

### Runner image (`runner/`)

A docker image baked with: agent CLIs (Claude Code, agent-browser), chromium, gh, glab, bun/pnpm/yarn, jq, yq, and a single entrypoint at `/usr/local/bin/pipekit-agent`. The image runs as **root by default** so Phase 1 can run `setup.shell`; Phase 2 demotes to `node` before invoking the agent.

### Two-phase entrypoint

```
Phase 1 (root) — pipekit-agent:
  parse recipe.yaml
  materialize inputs.json from PIPEKIT_INPUTS
  run setup.shell under timeout
  validate requires.{commands, env, mounts}
  resolve agent driver (PIPEKIT_AGENT explicit || agents.preferred walk)
  chown -R node:node $WORKSPACE
  exec runuser -u node -- /pipekit/lib/run-recipe.sh

Phase 2 (node) — run-recipe.sh:
  invoke /pipekit/drivers/$AGENT/run.sh
  validate result.json
  compute verdict (PIPEKIT_PASS_WHEN || result.status)
  exit
```

### Container contract

```
in   PIPEKIT_RECIPE       @pipekit/<name> or path to recipe dir / recipe.yaml
     PIPEKIT_INPUTS       JSON blob (default "{}")
     PIPEKIT_PASS_WHEN    optional jq expression evaluated against result.json
     PIPEKIT_WORKSPACE    scratch dir (default /work)
     PIPEKIT_AGENT        explicit driver (claude-code | codex | copilot)
     PIPEKIT_PREFERRED    comma-separated fallback (overrides recipe default)
     PIPEKIT_MODEL        model id (overrides recipe default)
     PIPEKIT_MAX_TURNS    safety cap (default 200)
     <credentials>        ANTHROPIC_API_KEY | OPENAI_API_KEY | GH_TOKEN

out  $PIPEKIT_WORKSPACE/result.json     { status, summary, findings[], outputs{} }
     $PIPEKIT_WORKSPACE/artifacts/**    recipe-defined evidence
     $PIPEKIT_WORKSPACE/agent.jsonl     raw agent output
     $PIPEKIT_WORKSPACE/recipe.yaml     copy of the resolved recipe

exit 0  pass        (status="pass" or pass_when truthy)
     1  agent fail  (status="fail" or pass_when falsy)
     2  infra fail  (recipe missing/invalid, setup failed, requires unsatisfied,
                     no agent available, result.json missing, etc.)
```

### CI integrations

- **GitHub Action** (`action/action.yml`) — composite action wrapping `docker run`. Uploads `$PIPEKIT_WORKSPACE` as a job artifact via `actions/upload-artifact`. Sets `status` and `summary` outputs from `result.json`.
- **GitLab include** (`gitlab/v1.yml`) — job template using `image: ghcr.io/altack/pipekit-runner` directly. The job runs *as* the agent (no nested docker). Artifacts are auto-collected via `artifacts: paths:`.

Both shells delegate exclusively to `pipekit-agent`. They contain zero agent logic.

## Decisions already locked — do not relitigate

- **No DAG runner is the headline.** CI engines have DAGs. We use them.
- **The image is an isolated environment, not a curated toolchain.** Recipes install their own deps via `setup.shell` (runs as root in Phase 1). Don't grow the image's always-on tool list without a strong reason.
- **No registry.** Recipes are directories baked into the image (`@pipekit/...`) or paths supplied by the user. v0.2 may add URL-based recipe resolution (e.g., `github://altack/pipekit-recipes/<name>@<tag>`); not now.
- **No canvas in v0.x.** YAML in `.github/workflows/*.yml` and `.gitlab-ci.yml` is the canvas.
- **No backwards compat with autotest.** Pipekit is a new product. Autotest will eventually become a built-in pipekit prompt (`@pipekit/upgrade-journey`), but until then the two systems are unrelated.
- **`pass_when` is a jq expression**, not a custom DSL. It's evaluated against `result.json`. Inventing an expression language is yak-shaving.
- **One image for all prompts** in v0.x. Per-step custom images are an escape hatch for later.
- **Local-only** — no hosted state, no SaaS, no shared canvas. The user's CI is the runtime; the user's git is the storage.

## Non-goals

- A scheduler. Use cron in your CI.
- A UI/canvas/dashboard. Use the YAML you already have.
- A template marketplace. Maybe v1.
- Cross-run aggregation, trend analysis, flake detection. Out of scope.
- Replacing CI. Pipekit is a step *inside* a CI job, not a CI replacement.

## Glossary

- **Task** — one invocation of `pipekit-agent`. Has one prompt, one inputs JSON, one result.
- **Prompt** — the system prompt file that defines what the agent does. Built-in or user-supplied.
- **Workspace** — the per-task scratch directory mounted into the container. Inputs go in, results + artifacts come out.
- **Contract** — the input/output shape every prompt must satisfy. See `docs/contract.md`.
- **Verdict** — pass/fail decision. Default: `result.json.status`. Overridable via `PIPEKIT_PASS_WHEN`.

## Conventions when writing code

- TypeScript for any future helpers; bash for the entrypoint (matches autotest precedent).
- No comments explaining *what* code does. Names should suffice.
- No backwards-compat shims. Nothing has shipped.
- No abstractions for hypothetical second use cases. We have two concrete prompts (hello, exploratory-tests). That's it.

## What to read next

- `README.md` — quick start and CI snippets.
- `docs/contract.md` — the input/output contract.
- `runner/pipekit-agent` — the contract implementation.
- `runner/prompts/hello.md` — smoke test prompt; the smallest possible example.
- `runner/prompts/exploratory-tests.md` — the second template; agent-browser-driven.
- `e2e/smoke.sh` — end-to-end test you run locally to validate a build.
