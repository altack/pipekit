# Pipekit — GitLab CI include

The job runs *inside* the pipekit runner image (no nested `docker run`, no DinD). The job's `script:` is `pipekit-agent`; everything else is wrapped by `extends: .pipekit`.

## Setup

1. Add `ANTHROPIC_API_KEY` as a masked CI/CD variable at the project level (or group level if you want to share it across projects).
2. Include the template in your `.gitlab-ci.yml`:

```yaml
include:
  - remote: https://altack.com/pipekit/gitlab/v1.yml
```

## Variables read by `.pipekit`

| Variable | Required | Default | Description |
|---|---|---|---|
| `PIPEKIT_RECIPE` | yes | — | Built-in (`@pipekit/<name>`) or path inside the repo to a recipe directory / `recipe.yaml`. |
| `PIPEKIT_INPUTS` | no | `{}` | JSON blob of inputs. |
| `PIPEKIT_PASS_WHEN` | no | — | jq expression evaluated against `result.json`. |
| `PIPEKIT_AGENT` | no | — | Explicit driver (`claude-code` \| `codex` \| `copilot`). |
| `PIPEKIT_PREFERRED` | no | recipe-declared | Comma-separated fallback. |
| `PIPEKIT_MODEL` | no | recipe-declared | Model id; overrides recipe default. |
| `PIPEKIT_MAX_TURNS` | no | `200` | Safety cap. |
| `<credentials>` | yes (one of) | — | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GH_TOKEN`. |

## Examples

### Smoke test

```yaml
include:
  - remote: https://altack.com/pipekit/gitlab/v1.yml

smoke:
  extends: .pipekit
  variables:
    PIPEKIT_RECIPE: '@pipekit/hello'
    PIPEKIT_INPUTS: '{"name":"CI"}'
```

### Exploratory tests against staging

```yaml
exploratory:
  extends: .pipekit
  variables:
    PIPEKIT_RECIPE: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["Sign-up works","No console errors"]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
```

### Generate Playwright tests on demand (manual trigger)

The headline pattern for `playwright-from-diff`: a manually-triggered job that
runs after the build passes. The user clicks a button in the GitLab UI; the
recipe writes tests, iterates them, and opens a draft MR.

```yaml
generate-playwright:
  extends: .pipekit
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
      when: manual
      allow_failure: true        # skipping doesn't fail the pipeline
  needs: [build]                  # only available once build succeeds
  variables:
    PIPEKIT_RECIPE: '@pipekit/playwright-from-diff'
    PIPEKIT_INPUTS: |
      {
        "base_ref": "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME",
        "head_ref": "$CI_COMMIT_SHA",
        "test_dir": "tests/e2e",
        "max_iterations": 3,
        "pr": { "host": "gitlab", "target_branch": "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME", "draft": true }
      }
    GL_TOKEN: $PIPEKIT_GL_TOKEN   # PAT with api + write_repository scopes
```

The job sits idle in the pipeline UI as a play-button until someone clicks it.
On click: pipekit runs the recipe, opens a draft MR off your current branch,
and the job ends. `PIPEKIT_GL_TOKEN` is a project- or group-level CI/CD
variable holding a PAT (or project access token) with `api` + `write_repository`.

### Multi-step DAG

```yaml
smoke:
  extends: .pipekit
  variables: { PIPEKIT_RECIPE: '@pipekit/hello' }

exploratory:
  extends: .pipekit
  needs: [smoke]
  variables:
    PIPEKIT_RECIPE: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{...}'
```

GitLab owns the DAG via `needs:` — pipekit does not run its own scheduler.

## Outputs to downstream jobs

Each `.pipekit` job writes `.pipekit/result.env` with `PIPEKIT_STATUS` and `PIPEKIT_SUMMARY`, exposed via `artifacts.reports.dotenv`. Downstream jobs that `needs: [name: this, artifacts: true]` see those as their own variables.
