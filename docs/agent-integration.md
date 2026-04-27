# Integrating pipekit — guide for agents

> Audience: an LLM agent (Claude Code, Codex, Copilot, …) tasked by a user with "set up pipekit in my repo." Read this end-to-end, then act. Self-contained — every URL referenced here is reachable without auth.

## What pipekit is, in one paragraph

Pipekit is a CI step that runs an agent task inside an isolated container *on the user's CI runner* and emits a structured verdict (`result.json`). The user picks a **recipe** — a self-contained spec defining setup, requirements, agent preference, inputs schema, and prompt — and pipekit runs it. CI pass/fail derives from `result.json.status`, optionally overridden by a `pass_when` jq expression. Same submit-task-get-verdict shape as Anthropic's Managed Agents, but the sandbox is the user's CI — secrets, code, and artifacts never leave their org.

## API surface

You integrate against the runner image. There are three wrappers; pick one based on the user's CI engine:

| User has… | Use | Reference |
|---|---|---|
| GitHub Actions | Composite action `altack/pipekit/action@main` | <https://github.com/altack/pipekit/tree/main/action> |
| GitLab CI | Include `https://raw.githubusercontent.com/altack/pipekit/main/gitlab/v1.yml` | <https://github.com/altack/pipekit/tree/main/gitlab> |
| Other / direct docker | `ghcr.io/altack/pipekit-runner:latest` | <https://github.com/altack/pipekit/blob/main/docs/contract.md> |

All three accept the same env-var contract (see "Container contract" below). The wrappers handle artifact upload and verdict mapping; direct docker, you wire it yourself.

## Mandatory flow — do not skip steps

### 1. Discover what recipes exist

Fetch the live index:

```
GET https://altack.github.io/pipekit-recipes/index.json
```

Browse: <https://altack.github.io/pipekit.dev/>. Source: <https://github.com/altack/pipekit-recipes>.

Each entry in `index.json`:

```json
{
  "id": "@pipekit/exploratory-tests",
  "description": "Drive a browser via agent-browser to pursue natural-language goals against a target URL.",
  "tags": [],
  "agents_preferred": ["claude-code"],
  "requires": { "env": ["ANTHROPIC_API_KEY"], "mounts": [] },
  "inputs_schema": { "type": "object", "required": ["target","goals"], "...": "..." },
  "links": {
    "recipe_yaml": "https://raw.githubusercontent.com/altack/pipekit-recipes/<sha>/recipes/pipekit/exploratory-tests/recipe.yaml",
    "prompt_md":   "https://raw.githubusercontent.com/altack/pipekit-recipes/<sha>/recipes/pipekit/exploratory-tests/prompt.md",
    "tree":        "https://github.com/altack/pipekit-recipes/tree/<sha>/recipes/pipekit/exploratory-tests"
  }
}
```

Find the recipe whose `description` matches the user's goal. As of this writing, four canonical `@pipekit/*` recipes exist:

- **`@pipekit/hello`** — smoke-tests the agent contract; useful for verifying CI integration.
- **`@pipekit/exploratory-tests`** — drives a browser to pursue natural-language goals against a URL. Use this for "smoke test my staging app."
- **`@pipekit/dep-migration-check`** — verifies a dependency upgrade end-to-end against a real consumer app.
- **`@pipekit/playwright-from-diff`** — generates Playwright tests for the changed files in a PR diff.

If nothing fits, tell the user and stop. Do not invent a custom recipe inside their CI YAML — that's not how pipekit composes. (For one-offs, the `recipe:` input accepts a path to a directory in the user's repo containing `recipe.yaml` + `prompt.md`.)

### 2. Read the recipe details before generating YAML

Fetch `links.recipe_yaml`. Confirm:

- **`inputs.schema`** — what runtime parameters does the recipe demand? Required fields? URI/enum constraints?
- **`requires.env`** — at least one of these must be set in the CI secret store.
- **`agents.preferred`** — which agent CLIs work; the user must have credentials for at least one.
- **`requires.mounts`** — bind-mounts the recipe needs (e.g. `/repo` for recipes that read the user's source).

Optionally fetch `links.prompt_md` to understand exactly what the agent will do. Necessary if the user asks "is this safe?" or "what does this do to my repo?".

### 3. Map secrets

Each agent driver needs its own credential. The runner picks the first agent in `agents.preferred` whose secret is set:

| Agent | Required secret |
|---|---|
| `claude-code` | `ANTHROPIC_API_KEY` |
| `codex` | `OPENAI_API_KEY` |
| `copilot` | `GH_TOKEN` (with `copilot` scope) |

Recipes that touch GitHub/GitLab also need `GH_TOKEN` / `GLAB_TOKEN`. Recipes that run a build often need `NPM_TOKEN` / similar — check `requires.env`.

In GitHub Actions: store as repo or org secrets, reference via `${{ secrets.X }}`.
In GitLab CI: store as masked CI/CD variables.

### 4. Build `inputs`

`inputs` is a JSON object validated by `ajv` against `recipe.inputs.schema` *before* the agent starts. Bad inputs fail fast at exit 2, no LLM tokens spent.

Do **not** guess values you don't have. Ask the user for any required input you can't infer from their repo. Common cases: target URLs, login fixtures, package names, file globs.

### 5. Decide the verdict gate

Default: `result.json.status == "pass"` → exit 0; `"fail"` → exit 1; missing/malformed → exit 2.

For finer control, set `pass_when` (jq expression evaluated against `result.json`):

```yaml
pass-when: '.findings | map(select(.severity == "blocker")) | length == 0'
```

Common patterns:
- Block only on blockers: `'.findings | map(select(.severity == "blocker")) | length == 0'`
- Allow some flake: `'(.findings | map(select(.severity != "minor")) | length) == 0'`
- Use a recipe-defined output: `'.outputs.passed == true'`

### 6. Generate the CI YAML

Use the templates below. Don't invent fields not in those templates. The composite action's full input list is at <https://github.com/altack/pipekit/blob/main/action/README.md>.

### 7. Tell the user how to read results

Each run produces:

| File | Purpose |
|---|---|
| `result.json` | The verdict — read `.status` and `.summary` |
| `artifacts/**` | Evidence (screenshots, logs, derived reports) |
| `agent.jsonl` | Raw agent transcript (debugging) |
| `inputs.json` | The materialized inputs (for reproducibility) |
| `recipe.yaml` | The resolved recipe (for reproducibility) |

GitHub Actions: the wrapper uploads the workspace as a job artifact named `pipekit-<job>-<run-id>`. Found at *Actions → run → Artifacts*.
GitLab CI: artifacts are auto-collected via `artifacts: paths:`. Found at *Job → Browse / Download artifacts*.

## Container contract (for reference)

```
in   PIPEKIT_RECIPE       @<org>/<name> or path to recipe dir / recipe.yaml
     PIPEKIT_INPUTS       JSON blob (default "{}"), validated against inputs.schema
     PIPEKIT_PASS_WHEN    optional jq expression against result.json
     PIPEKIT_AGENT        explicit driver override
     PIPEKIT_PREFERRED    comma-separated fallback override
     PIPEKIT_MODEL        model override
     <credentials>        ANTHROPIC_API_KEY | OPENAI_API_KEY | GH_TOKEN | …

out  $WORKSPACE/result.json    universal verdict
     $WORKSPACE/artifacts/**   evidence
     $WORKSPACE/agent.jsonl    raw agent output

exit 0 pass | 1 fail | 2 infra error
```

Full spec: <https://github.com/altack/pipekit/blob/main/docs/contract.md>

## `result.json` shape (for reading results back)

```json
{
  "status":  "pass" | "fail",
  "summary": "one-line human summary",
  "run": {
    "recipe":      "@pipekit/exploratory-tests@v0.1.0",
    "agent":       "claude-code",
    "model":       "opus",
    "started_at":  "2026-04-26T02:00:00Z",
    "finished_at": "2026-04-26T02:14:00Z",
    "overall_status": "clean | minor-findings | major-findings | blocker"
  },
  "findings": [
    { "severity": "blocker | major | minor | info",
      "title":    "...",
      "details":  "...",
      "evidence": ["artifacts/screenshot-1.png"] }
  ],
  "outputs": { "...": "recipe-defined" }
}
```

Full spec: <https://github.com/altack/pipekit/blob/main/docs/result.spec.md>

## Templates

### Template A — GitHub Actions, nightly schedule, issue-on-fail

```yaml
# .github/workflows/pipekit-nightly.yml
name: pipekit-nightly

on:
  schedule:
    - cron: "0 2 * * *"   # 02:00 UTC every night
  workflow_dispatch:        # also runnable on demand

permissions:
  contents: read
  issues:   write           # to open an issue on fail

jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/checkout@v4
        with:
          repository: altack/pipekit-recipes
          path: .pipekit-recipes

      - id: pipekit
        uses: altack/pipekit/action@main
        with:
          recipe: '@pipekit/exploratory-tests'
          recipes-source: ./.pipekit-recipes
          inputs: |
            { "target": "https://staging.example.com",
              "goals":  ["Sign-up flow completes",
                         "No console errors on /home",
                         "Pricing page loads under 3s"] }
          pass-when: '.findings | map(select(.severity == "blocker")) | length == 0'
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}

      - name: Open issue on failure
        if: failure() && steps.pipekit.outputs.summary != ''
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh issue create \
            --title "Nightly smoke failed: ${{ steps.pipekit.outputs.summary }}" \
            --body "Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
            
            See attached job artifact for screenshots, console logs, and findings.
            Status: ${{ steps.pipekit.outputs.status }}" \
            --label nightly-fail
```

The composite action sets `status` and `summary` outputs from `result.json`. The follow-up step opens a GitHub Issue on failure with a link to the run; the user sees it in their notifications the next morning.

### Template B — GitLab CI, nightly schedule

```yaml
# .gitlab-ci.yml
include:
  - remote: 'https://raw.githubusercontent.com/altack/pipekit/main/gitlab/v1.yml'

pipekit-nightly:
  extends: .pipekit
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  before_script:
    - !reference [.pipekit, before_script]
    - git clone --depth=1 https://github.com/altack/pipekit-recipes "$PIPEKIT_RECIPES_DIR"
  variables:
    PIPEKIT_RECIPE: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["Sign-up flow completes","No console errors on /home"]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
  artifacts:
    when: always
    paths: [result.json, artifacts/, agent.jsonl]
    expire_in: 30 days
```

In GitLab, set up the schedule via *CI/CD → Schedules*, cron `0 2 * * *`. Set `ANTHROPIC_API_KEY` as a masked CI/CD variable at the project level.

### Template C — Direct docker (CircleCI, Buildkite, Jenkins, etc.)

```bash
mkdir -p workspace
docker run --rm \
  -v "$(pwd)/workspace:/work" \
  -e PIPEKIT_RECIPE='@pipekit/exploratory-tests' \
  -e PIPEKIT_INPUTS='{"target":"https://staging.example.com","goals":["..."]}' \
  -e PIPEKIT_PASS_WHEN='.findings | map(select(.severity == "blocker")) | length == 0' \
  -e ANTHROPIC_API_KEY \
  -v "$(pwd)/.pipekit-recipes:/pipekit/recipes:ro" \
  ghcr.io/altack/pipekit-runner:latest

# Exit code is the verdict: 0 pass, 1 fail, 2 infra
```

You're responsible for cloning `altack/pipekit-recipes` ahead of time and bind-mounting it.

## Worked example — nightly smoke for an Angular app

> User says: "I have an Angular app deployed at https://staging.acme.test. Run a smoke test every night, check the results next morning."

### Decisions

1. **Recipe**: `@pipekit/exploratory-tests` — fits the "drive a browser at a URL" shape.
2. **Agent**: `claude-code` is the only listed preference. User must set `ANTHROPIC_API_KEY`.
3. **Inputs**:
   - `target`: `https://staging.acme.test` (from the user)
   - `goals`: ask the user for 3–5 critical user journeys. *Don't guess these — they encode the user's definition of "smoke test."* Reasonable starter goals to suggest if the user shrugs:
     - "Home page loads with no console errors"
     - "Login with the demo account succeeds"
     - "Primary CTA on /pricing navigates to /signup"
4. **Verdict gate**: `pass_when: '.findings | map(select(.severity == "blocker")) | length == 0'` — minor flake doesn't fail the night.
5. **Notification**: open a GitHub Issue on failure, labeled `nightly-fail`. User triages from their issues list each morning.
6. **Schedule**: 02:00 UTC (adjust to taste — pick a low-traffic window for the staging environment).

### What you produce

- `.github/workflows/pipekit-nightly.yml` — the file from Template A, with `target`/`goals` filled in.
- A short message to the user explaining:
  - "Add `ANTHROPIC_API_KEY` to repo secrets at *Settings → Secrets and variables → Actions*."
  - "First run: trigger manually via *Actions → pipekit-nightly → Run workflow* to confirm the wiring."
  - "On failure, an issue will be opened with label `nightly-fail`. Look there each morning."
  - "Artifacts (screenshots, console logs, full transcript) attached to each run for ~90 days by default."

### What you do **not** produce

- A `recipe.yaml` of your own — the recipe already exists.
- A bash script that runs `npm test` — that's a different workflow; pipekit is for agent-driven work.
- A custom prompt — the recipe owns the prompt.
- Browser config / Playwright setup — `@pipekit/exploratory-tests` already includes `chromium` + `agent-browser`.

## Failure modes you must handle

| Exit code | Meaning | Tell the user |
|---|---|---|
| 0 | pass / `pass_when` truthy | "Smoke passed." |
| 1 | recipe-fail / `pass_when` falsy | "Agent found problems — see findings in the run's `result.json`." |
| 2 | infra error | "Pipekit failed to run — check step logs. Most common: missing `ANTHROPIC_API_KEY`, schema-invalid inputs, or recipe not found." |

If the user reports exit 2 without context, ask them to share the step log; common causes:

- `ANTHROPIC_API_KEY is not set` → secret missing
- `inputs.json failed schema validation` → bad `inputs:` payload
- `recipe '@…' not found` → typo or `recipes-source` missing/wrong

## Don'ts

- **Don't put `setup.shell` in CI YAML.** That's a recipe-level concern, baked into the recipe — not something you wire from the consumer side.
- **Don't bind-mount secrets manually.** Pass via `env:` and the recipe declares `requires.env`.
- **Don't reimplement what a recipe already does.** If `@pipekit/exploratory-tests` exists for browser smoke, use it. Don't write a Playwright script.
- **Don't pin recipe versions yet.** v0.0.x doesn't enforce `version:` from `recipe.yaml`. Pin via `ref:` on the `actions/checkout` of the recipes repo if you need it (e.g. `ref: v0.1.0`).
- **Don't expose secrets in workflow logs.** Use `${{ secrets.X }}`, never echo them.
- **Don't add `continue-on-error: true` to silence pipekit failures.** That defeats the gate.

## Reference

| Topic | URL |
|---|---|
| Live recipe index (JSON) | <https://altack.github.io/pipekit-recipes/index.json> |
| Marketplace UI | <https://altack.github.io/pipekit.dev/> |
| Recipe spec | <https://github.com/altack/pipekit/blob/main/docs/recipe.spec.md> |
| Result spec | <https://github.com/altack/pipekit/blob/main/docs/result.spec.md> |
| Container contract | <https://github.com/altack/pipekit/blob/main/docs/contract.md> |
| GitHub Action README | <https://github.com/altack/pipekit/blob/main/action/README.md> |
| GitLab include | <https://github.com/altack/pipekit/blob/main/gitlab/v1.yml> |
| Recipes source | <https://github.com/altack/pipekit-recipes> |
