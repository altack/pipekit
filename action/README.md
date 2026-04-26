# altack/pipekit-action

GitHub Action wrapper around the [Pipekit](../README.md) runner image.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `recipe` | yes | — | `@pipekit/<name>` for a built-in, or a path inside the repo to a recipe directory / `recipe.yaml`. |
| `task` | no | `'{}'` | JSON inputs for the recipe. |
| `pass-when` | no | — | jq expression evaluated against `result.json`. If unset, verdict comes from `.status`. |
| `agent` | no | — | Explicit driver name (`claude-code` \| `codex` \| `copilot`). Bypasses recipe-declared preference. |
| `preferred` | no | recipe-declared | Comma-separated ordered fallback list. Overrides the recipe's `agents.preferred`. |
| `image` | no | `ghcr.io/altack/pipekit-runner:latest` | Runner image to pull. |
| `workspace` | no | `${{ github.workspace }}/.pipekit` | Host scratch dir bind-mounted into the container. |
| `model` | no | recipe-declared | Model id; overrides the recipe's `agents.models[<picked>]`. |
| `max-turns` | no | `200` | Safety cap. |
| `upload-artifact` | no | `true` | Upload the workspace as a job artifact. |
| `artifact-name` | no | `pipekit-<job>` | Name of the uploaded artifact. |

At least one of `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GH_TOKEN` must be exposed via the step's `env:` from a repo or org secret. The recipe's `agents.preferred` decides which is picked.

## Outputs

- `status` — `pass` | `fail` (from `result.json:.status`)
- `summary` — one-line summary from `result.json:.summary`
- `workspace` — host path to the workspace
- `result-json` — host path to `result.json`

## Usage

### Smoke test

```yaml
- uses: altack/pipekit-action@v1
  with:
    recipe: '@pipekit/hello'
    task: '{"name":"CI"}'
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Exploratory test against staging

```yaml
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

### Bring your own recipe

```yaml
- uses: actions/checkout@v4
- uses: altack/pipekit-action@v1
  with:
    recipe: ./.pipekit/recipes/release-notes
    task: '{"since":"v1.2.0","until":"HEAD"}'
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Multi-step pipeline (DAG via `needs:`)

```yaml
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: altack/pipekit-action@v1
        with: { recipe: '@pipekit/hello' }
        env: { ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} }

  exploratory:
    needs: smoke
    runs-on: ubuntu-latest
    steps:
      - uses: altack/pipekit-action@v1
        with:
          recipe: '@pipekit/exploratory-tests'
          task: '{"target":"https://staging.example.com","goals":["..."]}'
        env: { ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} }
```

The DAG is owned by GitHub Actions, not by pipekit. Use `needs:` to express dependencies.
