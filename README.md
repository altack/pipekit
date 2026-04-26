# Pipekit

Self-hosted Managed Agents for your CI.

Pipekit runs an agentic CLI (Claude Code, Codex, Copilot, …) inside an isolated docker container on your CI runner. You give it a **recipe** — a self-contained spec that declares its setup, requirements, agent preferences, inputs schema, and prompt. It hands back a structured `result.json` + an artifacts directory. The CI job passes or fails based on the result.

Same shape as [Anthropic's Managed Agents](https://www.anthropic.com/engineering/managed-agents), except the sandbox runs in *your* GitHub/GitLab runner — secrets, code, and artifacts never leave your org. The image is a generic isolated environment; recipes own their own dependencies.

## Quick start — GitHub Actions

```yaml
# .github/workflows/exploratory.yml
jobs:
  exploratory:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: altack/pipekit-action@v1
        with:
          recipe: '@pipekit/exploratory-tests'
          task: |
            { "target": "https://staging.example.com",
              "goals": ["Sign-up flow completes", "No console errors on /home"] }
          pass-when: '.findings | map(select(.severity == "blocker")) | length == 0'
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Quick start — GitLab CI

```yaml
include:
  - remote: https://altack.com/pipekit/gitlab/v1.yml

exploratory:
  extends: .pipekit
  variables:
    PIPEKIT_RECIPE: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["..."]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
  # ANTHROPIC_API_KEY set as a masked CI/CD variable at the project level
```

## Built-in recipes

| Name | What it does |
| --- | --- |
| `@pipekit/hello` | Smoke test. Reads `inputs.name`, writes `Hello, <name>` to result.json. Use this to verify your CI integration works end-to-end. |
| `@pipekit/exploratory-tests` | Drives a browser via agent-browser against a target URL, pursues a list of natural-language goals, emits findings with screenshots + console logs as evidence. |
| `@pipekit/dep-migration-check` | Tests a dependency upgrade against the consumer app end-to-end. Boots the app, walks routes, applies the upgrade, plans + executes migrations (incl. fixes for undocumented breakage), verifies build, replays the catalog. Emits a structured report + `changes.patch` you can `git apply`. |

## Bring your own recipe

Drop a recipe directory in your repo and pass its path:

```yaml
- uses: altack/pipekit-action@v1
  with:
    recipe: ./.pipekit/recipes/my-task
    task: '{"hello":"world"}'
```

Your `recipe.yaml` declares its setup, requirements, agent preferences, and prompt. See [`docs/recipe.spec.md`](./docs/recipe.spec.md).

## Multi-agent

Pipekit isn't tied to one model or vendor. Drivers ship for `claude-code` (default), with `codex` and `copilot` stubs ready for fill-in. Recipes declare a preferred fallback list; the runner picks the first one whose credentials are present at runtime.

## Repo layout

```
runner/        the docker image
  Dockerfile     base environment + always-on tools (gh, glab, chromium, jq, …)
  pipekit-agent  Phase 1 entrypoint (root): parse recipe, run setup, validate, demote
  lib/           Phase 2 helpers (node)
  recipes/       built-in recipes (hello, exploratory-tests)
  drivers/       agent drivers (claude-code, codex, copilot)
action/        the GitHub Action
gitlab/        the GitLab CI include
docs/          recipe.spec.md + contract.md
e2e/           local end-to-end smoke test
```

## End-to-end test

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./e2e/smoke.sh
```

Builds the runner image locally, runs six cases that exercise the contract end-to-end (happy path, request-fail, pass-when override, agent resolution paths, setup.shell). See [`e2e/README.md`](./e2e/README.md).
