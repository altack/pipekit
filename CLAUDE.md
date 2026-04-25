# CLAUDE.md — Pipekit

You are working on **Pipekit**: a self-hosted "cousin of Anthropic's Managed Agents" that drops into a consumer's existing GitHub Actions or GitLab CI pipeline. The user defines a task as a prompt + JSON inputs; pipekit runs it inside an isolated docker container on the user's CI runner; the agent emits `result.json` + an artifacts directory; the CI job's pass/fail is derived from that result.

The product wedge: **same submit-task-get-verdict shape as Managed Agents, but the sandbox is the user's CI runner — secrets, code, and artifacts never leave their org.**

## Mental model

- **One container, one prompt, one structured result.** That's the unit of work.
- **The CI engine owns the DAG.** GitHub `needs:` and GitLab `needs:` already do step orchestration. Pipekit does not compete with them. (A multi-step `pipekit run` harness exists as an escape hatch for cases where steps share heavy state, but it is not the headline.)
- **Templates are just prompt files** — built-in (`@pipekit/<name>`, baked into the image) or user-provided (a path to a markdown file). No registry, no template engine, no version pinning yet.
- **Every prompt obeys one contract** (see `docs/contract.md`): read inputs from `$PIPEKIT_WORKSPACE/inputs.json`, write `$PIPEKIT_WORKSPACE/result.json` before exit, drop arbitrary evidence under `$PIPEKIT_WORKSPACE/artifacts/`.

## Architecture

### Runner image (`runner/`)

A docker image baked with: Claude Code CLI, agent-browser + chromium, gh, glab, bun/pnpm/yarn, and a single entrypoint at `/usr/local/bin/pipekit-agent`. The entrypoint is the *only* thing CI integrations talk to.

### `pipekit-agent` — the container contract

```
in   PIPEKIT_PROMPT       @pipekit/<name> or path to .md
     PIPEKIT_INPUTS       JSON blob (default "{}")
     PIPEKIT_PASS_WHEN    optional jq expression evaluated against result.json
     PIPEKIT_WORKSPACE    scratch dir (default /work)
     PIPEKIT_MODEL        opus | sonnet | haiku (default opus)
     PIPEKIT_MAX_TURNS    safety cap (default 200)
     ANTHROPIC_API_KEY    required

out  $PIPEKIT_WORKSPACE/result.json     { status, summary, findings[], outputs{} }
     $PIPEKIT_WORKSPACE/artifacts/**    user-defined evidence
     $PIPEKIT_WORKSPACE/agent.jsonl     raw stream-json from claude

exit 0  pass        (status="pass" or pass_when truthy)
     1  agent fail  (status="fail" or pass_when falsy)
     2  infra fail  (no result.json, prompt missing, invalid inputs, etc.)
```

### CI integrations

- **GitHub Action** (`action/action.yml`) — composite action wrapping `docker run`. Uploads `$PIPEKIT_WORKSPACE` as a job artifact via `actions/upload-artifact`. Sets `status` and `summary` outputs from `result.json`.
- **GitLab include** (`gitlab/v1.yml`) — job template using `image: ghcr.io/altack/pipekit-runner` directly. The job runs *as* the agent (no nested docker). Artifacts are auto-collected via `artifacts: paths:`.

Both shells delegate exclusively to `pipekit-agent`. They contain zero agent logic.

## Decisions already locked — do not relitigate

- **No DAG runner is the headline.** CI engines have DAGs. We use them.
- **No registry.** Templates are files in the image (`@pipekit/...`) or paths supplied by the user. v0.2 may add an OCI artifact registry; not now.
- **No canvas in v0.x.** YAML in `.github/workflows/*.yml` and `.gitlab-ci.yml` is the canvas.
- **No backwards compat with autotest.** Pipekit is a new product. Autotest will eventually become a built-in pipekit prompt (`@pipekit/upgrade-journey`), but until then the two systems are unrelated.
- **`pass_when` is a jq expression**, not a custom DSL. It's evaluated against `result.json`. Inventing an expression language is yak-shaving.
- **One image for all prompts** in v0.x. Per-step custom images are an escape hatch for later.
- **Local-only** — no hosted state, no SaaS, no shared canvas. The user's CI is the runtime; the user's git is the storage.

## Non-goals

- A scheduler. Use cron in your CI.
- A UI/canvas/dashboard. Use the YAML you already have.
- A template marketplace. Maybe v1.
- Cross-run aggregation, trend analysis, flake detection. Out of scope.
- Replacing CI. Pipekit is a step *inside* a CI job, not a CI replacement.

## Glossary

- **Task** — one invocation of `pipekit-agent`. Has one prompt, one inputs JSON, one result.
- **Prompt** — the system prompt file that defines what the agent does. Built-in or user-supplied.
- **Workspace** — the per-task scratch directory mounted into the container. Inputs go in, results + artifacts come out.
- **Contract** — the input/output shape every prompt must satisfy. See `docs/contract.md`.
- **Verdict** — pass/fail decision. Default: `result.json.status`. Overridable via `PIPEKIT_PASS_WHEN`.

## Conventions when writing code

- TypeScript for any future helpers; bash for the entrypoint (matches autotest precedent).
- No comments explaining *what* code does. Names should suffice.
- No backwards-compat shims. Nothing has shipped.
- No abstractions for hypothetical second use cases. We have two concrete prompts (hello, exploratory-tests). That's it.

## What to read next

- `README.md` — quick start and CI snippets.
- `docs/contract.md` — the input/output contract.
- `runner/pipekit-agent` — the contract implementation.
- `runner/prompts/hello.md` — smoke test prompt; the smallest possible example.
- `runner/prompts/exploratory-tests.md` — the second template; agent-browser-driven.
- `e2e/smoke.sh` — end-to-end test you run locally to validate a build.
