# Pipekit

Self-hosted Managed Agents for your CI.

Pipekit runs a Claude Code agent inside an isolated docker container on your CI runner. You give it a prompt + JSON inputs; it gives you a structured `result.json` + an artifacts directory. The CI job passes or fails based on the result.

Same shape as [Anthropic's Managed Agents](https://www.anthropic.com/engineering/managed-agents), except the sandbox runs in *your* GitHub/GitLab runner so secrets, code, and artifacts never leave your org.

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
          prompt: '@pipekit/exploratory-tests'
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
    PIPEKIT_PROMPT: '@pipekit/exploratory-tests'
    PIPEKIT_INPUTS: '{"target":"https://staging.example.com","goals":["..."]}'
    PIPEKIT_PASS_WHEN: '.findings | map(select(.severity == "blocker")) | length == 0'
  # ANTHROPIC_API_KEY set as a masked CI/CD variable at the project level
```

## Built-in prompts

| Name | What it does |
| --- | --- |
| `@pipekit/hello` | Smoke test. Reads `inputs.name`, writes `Hello, <name>` to result.json. Use this to verify your CI integration works end-to-end. |
| `@pipekit/exploratory-tests` | Drives a browser via agent-browser against a target URL, pursues a list of natural-language goals, emits findings with screenshots + console logs as evidence. |

## Bring your own prompt

Drop a markdown file in your repo and pass its path:

```yaml
- uses: altack/pipekit-action@v1
  with:
    prompt: ./.pipekit/prompts/my-task.md
    task: '{"hello":"world"}'
```

Your prompt must obey the contract in [`docs/contract.md`](./docs/contract.md): read `inputs.json`, write `result.json`, optionally drop evidence in `artifacts/`.

## Repo layout

```
runner/        the docker image — Dockerfile, pipekit-agent entrypoint, baked-in prompts
action/        the GitHub Action
gitlab/        the GitLab CI include
docs/          the input/output contract spec
e2e/           local end-to-end smoke test
```

## End-to-end test

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./e2e/smoke.sh
```

Builds the runner image locally, runs the `@pipekit/hello` prompt against it, asserts `result.json.status == "pass"`. See [`e2e/README.md`](./e2e/README.md) for details.
