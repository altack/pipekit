# Pipekit

The orchestrator between your CI runner and an agentic CLI.

You don't write tasks in your CI YAML. You **pick a recipe** — a self-contained spec that already declares what the agent does, what tools it needs, what agent + model to prefer, and what runtime parameters it expects. Pipekit glues it all together: pulls the recipe, picks an available agent based on the secrets you've configured, sandboxes the work in an isolated container, and returns a structured verdict your CI engine reads to decide pass/fail.

Same shape as [Anthropic's Managed Agents](https://www.anthropic.com/engineering/managed-agents) — submit a task, get a verdict — except:

- The sandbox runs in *your* CI runner. Secrets, code, and artifacts never leave your org.
- The agent is whichever you have credentials for (Claude Code, Codex, Copilot, …). Pipekit is multi-vendor — recipes declare a preferred fallback, the runner picks the first whose credentials are present.
- Recipes are **content**, not harness. They live in their own repo (canonical: `altack/pipekit-recipes`), are versioned independently, and you can publish your own.

## How it composes

```
your CI YAML                  pipekit runner image            an agent CLI
─────────────────────         ────────────────────            ─────────────
recipe: @pipekit/x   ───────► resolves recipe          ┐
inputs: { url, ... } ───────► validates against schema ├─► claude / codex / ...
secrets ─────────────────────► exposes credentials     │   runs inside an
                              picks first agent ───────┘   isolated container
                              with valid creds              writes result.json
                                                                     │
                              reads result.json ◄────────────────────┘
job pass/fail   ◄──────────── exit code from .status / pass-when
artifacts/**    ◄──────────── workspace dir uploaded to CI artifact store
```

The CI YAML is **selection + parameters**. The recipe is **definition**. The runner is **glue**: secrets in, sandboxed agent loop in the middle, structured verdict out.

## Quick start — GitHub Actions

```yaml
# .github/workflows/exploratory.yml
jobs:
  exploratory:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: altack/pipekit-recipes      # the marketplace
          path: .pipekit-recipes
      - uses: altack/pipekit/action@main
        with:
          recipe: '@pipekit/exploratory-tests'      # SELECT a recipe
          recipes-source: ./.pipekit-recipes
          inputs: |                                  # PARAMETERS for this run
            { "target": "https://staging.example.com",
              "goals": ["Sign-up flow completes", "No console errors on /home"] }
          pass-when: '.findings | map(select(.severity == "blocker")) | length == 0'
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

What's actually happening:

- **`recipe:`** selects `exploratory-tests` from the recipes repo. The recipe's `prompt.md` is the task definition; its `inputs.schema` declares what runtime parameters it expects; its `agents.preferred` declares which agent CLIs it works with.
- **`inputs:`** is the per-run data the recipe needs (which URL, which goals). Validated against the recipe's schema before the agent starts — fails fast if you got the shape wrong.
- **`env:`** exposes credentials. The runner picks the first agent in `agents.preferred` whose secret is set.
- The action runs the pipekit runner image, which sandboxes the chosen agent, executes the recipe, writes `result.json` + `artifacts/**`. Exit code derives from `result.json.status` (or your `pass-when` jq expression).

## Quick start — GitLab CI

```yaml
include:
  - remote: https://altack.com/pipekit/gitlab/v1.yml

exploratory:
  extends: .pipekit
  before_script:
    - !reference [.pipekit, before_script]
    - git clone --depth=1 https://github.com/altack/pipekit-recipes "$PIPEKIT_RECIPES_DIR"
  variables:
    PIPEKIT_RECIPE: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["..."]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
  # ANTHROPIC_API_KEY set as a masked CI/CD variable at the project level
```

Same shape: `PIPEKIT_RECIPE` selects, `PIPEKIT_INPUTS` parameterizes, the runner glues. The job *runs as* the runner image — no nested `docker run`.

## Built-in recipes

Curated under `@pipekit/*` in the [recipes repo](https://github.com/altack/pipekit-recipes).

| Name | What the recipe does (you don't define this — the recipe does) |
| --- | --- |
| `@pipekit/hello` | Smoke test of the agent contract. Reads `inputs.name`, writes `Hello, <name>` — useful for verifying your CI integration end-to-end. |
| `@pipekit/exploratory-tests` | Drives a browser via agent-browser against a target URL, pursues a list of natural-language goals, emits findings with screenshots + console logs as evidence. |
| `@pipekit/dep-migration-check` | Tests a dependency upgrade against a real consumer app: catalog → upgrade → migrate → build → replay → report. Emits a structured report + `changes.patch`. |
| `@pipekit/playwright-from-diff` | Generates Playwright integration tests for the changed files in a PR/MR diff. Reads existing tests to match repo conventions, iterates per-failing-test, ships passing tests as a draft PR via `gh` or `glab`. |

## Bring your own recipe

Drop a recipe directory in your repo and pass its path:

```yaml
- uses: altack/pipekit/action@main
  with:
    recipe: ./.pipekit/recipes/my-task   # local path; no @<org>/ namespace needed
    inputs: '{"hello":"world"}'
```

A recipe is a directory with `recipe.yaml` + `prompt.md` (and optional sibling helper scripts). Three specs together describe the system end-to-end:

- [`docs/recipe.spec.md`](./docs/recipe.spec.md) — what you write (the `recipe.yaml` schema): `setup.shell`, `requires.{commands,env,mounts}`, `agents.preferred`, `inputs.schema`, prompt path.
- [`docs/result.spec.md`](./docs/result.spec.md) — what your prompt writes back: the universal `result.json` schema. One file, one shape, all recipes.
- [`docs/contract.md`](./docs/contract.md) — the runtime API of the runner image: env vars in, exit codes out.

## Multi-agent

Pipekit is not coupled to one model or vendor. Drivers ship for `claude-code` (default), with `codex` and `copilot` stubs ready for fill-in. The recipe declares its `agents.preferred` fallback list; the runner picks the first one whose credentials are present at runtime.

## Repo layout

```
runner/        the docker image — pure harness, no recipes baked in
  Dockerfile     base environment + always-on tools (gh, glab, chromium, jq, yq, …)
  pipekit-agent  Phase 1 entrypoint (root): parse recipe, run setup, validate, demote
  lib/           Phase 2 helpers (node)
  drivers/       agent drivers (claude-code, codex, copilot)
action/        the GitHub Action
gitlab/        the GitLab CI include
docs/          recipe.spec.md + result.spec.md + contract.md + marketplace.md
e2e/           local end-to-end smoke + playground integration

Recipes live in [`altack/pipekit-recipes`](https://github.com/altack/pipekit-recipes) — content, not harness. The runtime resolver supports `@<org>/<name>` against any directory mounted at `$PIPEKIT_RECIPES_DIR`. For local dev, clone the recipes repo as a sibling of this one.
```

## End-to-end test

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./e2e/smoke.sh
```

Builds the runner image locally, runs six cases that exercise the contract end-to-end (happy path, request-fail, pass-when override, agent resolution paths, setup.shell). See [`e2e/README.md`](./e2e/README.md).
