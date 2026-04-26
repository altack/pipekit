# Pipekit playground integration

Runs `@pipekit/dep-migration-check` against the autotest playground (Angular + Material) using the **published GHCR image**. This validates the full upgrade journey end-to-end: catalog → upgrade → migrate → build → replay → report.

This is **not** a smoke test. It's an integration test:

- Takes 15–30 minutes.
- Costs roughly $5–15 in Claude API spend per run.
- Requires the playground app at `/Users/guzmanoj/Projects/autotest/playground` (or override via `PLAYGROUND_REPO`).
- Pulls `ghcr.io/altack/pipekit-runner:latest` from GHCR.

## Run it

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export AUTOTEST_USER=demo@autotest.com
export AUTOTEST_PASSWORD=...
./e2e/playground/run.sh
```

## What lands on disk

A timestamped directory at `e2e/playground/out-YYYYmmdd-HHMMSS/` (or `$PIPEKIT_OUT`) containing:

- `inputs.input.json` — the autotest.yml translated to JSON (for traceability).
- `inputs.json` — copy materialized inside the container.
- `recipe.yaml` — copy of the resolved recipe.
- `result.json` — the pipekit verdict.
- `agent.jsonl` — raw stream-json from the agent (tail this during the run).
- `artifacts/`:
  - `report.json` — rich machine-readable report.
  - `report.consumer.md` / `report.maintainer.md` — markdown reports.
  - `changes.patch` — `git diff` of agent edits; `git apply` to land them.
  - `catalog/` — primitives, breadcrumbs, baseline screenshots.
  - `screenshots/` — replay before/after/diff images.
  - `logs/` — `plan.md`, `install.log`, `migrate.log`, `build.log`.

## Streaming progress

While the run is going:

```bash
tail -f e2e/playground/out-*/agent.jsonl | jq -r 'select(.type=="assistant") | .message.content[0].text' 2>/dev/null
```

That filters to assistant turns only.

## Override the image

For testing changes locally before publishing:

```bash
PIPEKIT_IMAGE=pipekit-runner:e2e ./e2e/playground/run.sh
```
