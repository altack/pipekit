# Pipekit end-to-end tests

The smoke script builds the runner image locally and exercises the contract from `docs/contract.md` end-to-end against the `@pipekit/hello` prompt.

## What it asserts

| Case | Inputs | Expected exit | Expected `.status` |
|---|---|---|---|
| 1. happy path | `{"name":"smoke"}` | 0 | `pass` |
| 2. request-fail | `{"fail":true}` | 1 | `fail` |
| 3. pass-when override | `{"name":"smoke"}` + `PIPEKIT_PASS_WHEN='.status == "fail"'` | 1 | `pass` (but verdict is fail) |

If all three pass, the contract is wired correctly: prompt resolution, inputs marshalling, agent launch, result.json validation, and the two verdict paths (default vs. `pass_when` override) all work.

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

Three Claude invocations against `@pipekit/hello`. The prompt explicitly caps work at <5 turns and tells the agent to use only Bash + Write — should land in the cents. If you see >$0.50 for a smoke run, something's wrong.
