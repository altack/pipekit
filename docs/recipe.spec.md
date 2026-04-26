# Recipe specification

A **recipe** is a self-contained unit of agent work. It declares what it needs, what it produces, and what it does. The runner image is a generic isolated environment; the recipe declares everything else.

## Directory layout

```
<recipe-name>/
├── recipe.yaml      # spec (this document)
├── prompt.md        # the system prompt
└── (optional) examples/, fixtures/, README.md
```

## `recipe.yaml`

```yaml
# ─── Identity ────────────────────────────────────────────────────────────
name:        dep-migration-check          # required, kebab-case
version:     1.0.0                         # required, semver
description: One-line tagline.             # required
homepage:    https://...                   # optional
prompt:      ./prompt.md                   # required, path relative to recipe.yaml

# ─── Setup (runs as root before agent starts) ────────────────────────────
setup:
  shell: |
    set -euo pipefail
    apt-get update -qq
    apt-get install -y --no-install-recommends python3 python3-pip
    pip3 install --no-cache-dir pandas==2.0
  timeout: 300                             # seconds, default 300

# ─── Requirements (validated after setup, before agent runs) ─────────────
requires:
  commands: [git, jq, python3]             # must be on PATH after setup
  env:      [ANTHROPIC_API_KEY]            # at least one must be set (any-of)
  mounts:   [/repo]                        # bind-mounts the host must provide

# ─── Agent selection ─────────────────────────────────────────────────────
agents:
  preferred: [claude-code, codex]          # ordered fallback
  models:
    claude-code: opus
    codex:       gpt-5

# ─── Inputs schema ───────────────────────────────────────────────────────
inputs:
  schema:                                  # JSON Schema; validated against inputs.json
    type: object
    required: [packages]
    properties:
      packages:
        type: array
        items: { type: string }
```

### Field reference

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | — | kebab-case identifier. Built-ins resolve as `@pipekit/<name>`. |
| `version` | yes | — | Semver. Pinned by URL refs (`...@v1.2.0`). |
| `description` | yes | — | One sentence. Shown in CI step summaries. |
| `prompt` | yes | — | Path to the `.md` system prompt, relative to `recipe.yaml`. |
| `homepage` | no | — | Discovery only. |
| `setup.shell` | no | — | Bash snippet, runs as root before agent. Failure → exit 2. |
| `setup.timeout` | no | `300` | Seconds. Hard kill on overrun → exit 2. |
| `requires.commands` | no | `[]` | Each must be on `PATH` after setup. Missing → exit 2. |
| `requires.env` | no | `[]` | At least one must be set in container env. Missing all → exit 2. |
| `requires.mounts` | no | `[]` | Each path must exist as a directory in the container. Missing → exit 2. |
| `agents.preferred` | no | `[claude-code]` | Walked left-to-right; first available wins. |
| `agents.models` | no | `{}` | Default model per agent. Overridable via `PIPEKIT_MODEL`. |
| `inputs.schema` | no | — | Standard JSON Schema. `inputs.json` is validated against it. |

## Lifecycle

`pipekit-agent` runs in two phases:

### Phase 1 — root

1. Resolve `PIPEKIT_RECIPE` to a `recipe.yaml` path (built-in `@pipekit/<name>` or filesystem path).
2. Parse `recipe.yaml`.
3. Materialize `inputs.json` from `PIPEKIT_INPUTS`. Validate against `inputs.schema` if declared.
4. If `setup.shell` is present, run it under `timeout setup.timeout`. Non-zero exit → exit 2.
5. Validate `requires.commands` (each must be on `PATH`).
6. Validate `requires.env` (at least one must be set).
7. Validate `requires.mounts` (each must exist as a directory).
8. Resolve agent (explicit `PIPEKIT_AGENT` or walk `agents.preferred`).
9. `chown -R node:node` on the workspace.
10. `exec runuser -u node` into Phase 2.

### Phase 2 — node

1. Apply `agents.models[<picked>]` as `PIPEKIT_MODEL` default if unset.
2. Invoke `/pipekit/drivers/<picked>/run.sh <prompt-path>`.
3. Validate `result.json`. Compute verdict (default or `PIPEKIT_PASS_WHEN`). Exit.

## Non-trust assumptions

- `setup.shell` runs as root. Recipe authors are trusted; consumers choosing a recipe accept that trust. Same model as `npm install` or `apt`.
- The workspace is the only writable area for the agent (Phase 2 runs as `node`). The image filesystem is owned by root and the agent cannot mutate it.
- Network is open during setup (recipe needs to install things). The image does not impose network policy; that's a CI runner / org concern.

## Backwards compatibility

None. v0.x has no users yet. Pre-spec bare-`.md`-prompt usage is removed entirely.
