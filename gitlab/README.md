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
| `PIPEKIT_PROMPT` | yes | — | Built-in or path inside the repo. |
| `PIPEKIT_INPUTS` | no | `{}` | JSON blob of inputs. |
| `PIPEKIT_PASS_WHEN` | no | — | jq expression evaluated against `result.json`. |
| `PIPEKIT_MODEL` | no | `opus` | Claude model. |
| `PIPEKIT_MAX_TURNS` | no | `200` | Safety cap. |
| `ANTHROPIC_API_KEY` | yes | — | CI/CD variable. |

## Examples

### Smoke test

```yaml
include:
  - remote: https://altack.com/pipekit/gitlab/v1.yml

smoke:
  extends: .pipekit
  variables:
    PIPEKIT_PROMPT: '@pipekit/hello'
    PIPEKIT_INPUTS: '{"name":"CI"}'
```

### Exploratory tests against staging

```yaml
exploratory:
  extends: .pipekit
  variables:
    PIPEKIT_PROMPT: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["Sign-up works","No console errors"]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
```

### Multi-step DAG

```yaml
smoke:
  extends: .pipekit
  variables: { PIPEKIT_PROMPT: '@pipekit/hello' }

exploratory:
  extends: .pipekit
  needs: [smoke]
  variables:
    PIPEKIT_PROMPT: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{...}'
```

GitLab owns the DAG via `needs:` — pipekit does not run its own scheduler.

## Outputs to downstream jobs

Each `.pipekit` job writes `.pipekit/result.env` with `PIPEKIT_STATUS` and `PIPEKIT_SUMMARY`, exposed via `artifacts.reports.dotenv`. Downstream jobs that `needs: [name: this, artifacts: true]` see those as their own variables.
