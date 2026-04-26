# Pipekit end-to-end tests

The smoke script builds the runner image locally and exercises the contract from [`docs/contract.md`](../docs/contract.md) end-to-end. Six cases, four code paths.

## What it asserts

| Case | Recipe | Notable | Expected exit | Expected `.status` |
|---|---|---|---|---|
| 1. happy path | `@pipekit/hello` | `inputs={"name":"smoke"}` | 0 | `pass` |
| 2. request-fail | `@pipekit/hello` | `inputs={"fail":true}` | 1 | `fail` |
| 3. pass-when override | `@pipekit/hello` | `PIPEKIT_PASS_WHEN='.status == "fail"'` | 1 | `pass` (verdict is fail) |
| 4. explicit unavailable | `@pipekit/hello` | `PIPEKIT_AGENT=codex` (stub) | 2 | — (no LLM call) |
| 5. preferred fallback | `@pipekit/hello` | `PIPEKIT_PREFERRED=codex,copilot,claude-code` | 0 | `pass` |
| 6. setup.shell | `e2e/recipes/setup-marker` | recipe sets up `/tmp/pipekit-marker` as root, agent reads it | 0 | `pass` |

If all six pass, the harness is wired correctly: recipe resolution, inputs marshalling, **`setup.shell` runs as root and is visible to the demoted agent**, `requires.*` validation, agent resolution (explicit + preferred fallback), driver dispatch, `result.json` validation, and both verdict paths (default vs. `pass_when` override).

## Run it

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./e2e/smoke.sh
```

Subsequent runs against an already-built image:

```bash
PIPEKIT_SKIP_BUILD=1 ./e2e/smoke.sh
```

## Override the image tag

```bash
PIPEKIT_IMAGE=ghcr.io/altack/pipekit-runner:dev ./e2e/smoke.sh
PIPEKIT_SKIP_BUILD=1 PIPEKIT_IMAGE=ghcr.io/altack/pipekit-runner:dev ./e2e/smoke.sh
```

## Cost

Four Claude invocations (cases 1, 2, 3, 5, 6 — case 4 makes no LLM call). Prompts cap work at <5 turns and use only Bash+Write tools — should land in the cents. If you see >$0.50 for a smoke run, something's wrong.
