# `result.json` — pipekit's universal verdict spec

Every recipe writes exactly one `result.json` to `${PIPEKIT_WORKSPACE}/result.json` before exit. This file is the **single contract** between the recipe and the world: status, summary, run metadata, structured findings, recipe-defined outputs.

- The consumer's CI reads `result.json.status` (or evaluates `PIPEKIT_PASS_WHEN` against the file) to set job pass/fail.
- The pipekit viewer renders the file directly.
- Optional evidence (screenshots, logs, snapshots, patches, derived markdown reports) lives under `${PIPEKIT_WORKSPACE}/artifacts/` and is referenced from `result.json` by paths relative to `artifacts/`.

This is the *only* JSON contract recipes need to satisfy. There is no separate "rich report" file.

## Top-level shape

```json
{
  "status":  "pass" | "fail",
  "summary": "string (one line)",
  "run":     { ... },
  "findings": [ ... ],
  "outputs":  { ... }
}
```

| Field | Required | Producer |
|---|---|---|
| `status`   | yes | recipe agent |
| `summary`  | yes | recipe agent |
| `run`      | yes | partly recipe agent, partly runner-stamped (see below) |
| `findings` | yes | recipe agent (may be `[]`) |
| `outputs`  | no  | recipe agent (recipe-defined freeform JSON) |

Status discipline:

- `pass` — recipe completed its job; CI should succeed.
- `fail` — recipe completed but the job is unsuccessful (blocker findings, explicit failure verdict); CI should fail.
- Infrastructure failures (recipe missing, agent crash, no creds, malformed `inputs.json`) do **not** write `result.json`; pipekit-agent surfaces them as exit 2 directly.

## `run` block

Universal across recipes. Mixed authorship — the runner stamps the things only the runner knows; the recipe agent fills in the things only it knows.

```json
"run": {
  "recipe":           "@pipekit/dep-migration-check@v1.0.0",                       // runner-stamped
  "agent":            "claude-code",                                                // runner-stamped
  "model":            "opus",                                                       // runner-stamped
  "started_at":       "2026-04-26T08:01:00Z",                                      // runner-stamped
  "finished_at":      "2026-04-26T08:24:00Z",                                      // runner-stamped
  "phases_completed": ["catalog","upgrade","migrate","build","replay","report"],   // agent-authored
  "overall_status":   "clean" | "minor-findings" | "major-findings" | "blocker"    // agent-authored
}
```

| Field | Producer | Notes |
|---|---|---|
| `recipe`            | runner | The recipe identifier the user requested, with version: `@<org>/<name>@<version>` for namespaced recipes, `<name>@<version>` for path-based. |
| `agent`             | runner | Which driver was picked (e.g. `claude-code`, `codex`). |
| `model`             | runner | Resolved model id (recipe default or `PIPEKIT_MODEL` override). |
| `started_at`        | runner | ISO-8601 UTC. Captured at Phase 1 entry, before setup runs. |
| `finished_at`       | runner | ISO-8601 UTC. Captured after the agent exits. |
| `phases_completed`  | agent  | Recipe-specific phase names. Empty array for recipes without phases. |
| `overall_status`    | agent  | Derived from findings (rule below). |

If the recipe authors `run.started_at` / `finished_at` itself, the runner overwrites — the runner is authoritative for those. The recipe is responsible for `phases_completed` and `overall_status`.

### `overall_status` derivation rule

```
overall_status = blocker          if any finding has severity "blocker"
              = major-findings    else if any has severity "major"
              = minor-findings    else if any has severity "minor"
              = clean             otherwise
```

Recipes can override (e.g. a recipe that produces only `info` findings might still report `clean`).

## `findings[]`

Structured observations the recipe wants to surface. May be `[]` for pass/fail recipes that don't produce findings (simple build/deploy jobs, smoke tests).

```json
{
  "id":       "F-0001",
  "category": "string (recipe-defined)",
  "severity": "blocker" | "major" | "minor" | "info",
  "summary":  "one-line headline",
  "detail":   "longer prose",

  "severity_rationale":      "one-sentence justification (recommended)",
  "affected_components":     0,
  "affected_routes":         0,
  "user_flow_blocked":       false,
  "console_errors_observed": 0,

  "owner":      "library" | "app" | "uncertain",
  "phase":      "string (recipe-specific phase name)",
  "confidence":          0.95,
  "confidence_evidence": ["..."],

  "library_component": null,
  "route":             null,

  "evidence": {
    "screenshots": ["screenshots/foo.png"],
    "logs":        ["logs/foo.log"],
    "snapshots":   ["snapshots/foo.html"]
  },

  "changelog_mentions": []
}
```

| Field | Required | Notes |
|---|---|---|
| `id`        | yes | Stable across re-renders; format suggestion `F-NNNN`. |
| `category`  | yes | Recipe-defined enum (e.g. `migrate`, `build`, `replay`, `exploration`, `iterate`, `ship`). |
| `severity`  | yes | `blocker` \| `major` \| `minor` \| `info`. |
| `summary`   | yes | One line. |
| `detail`    | yes | Prose. |
| `severity_rationale`      | recommended | Cites the impact fields. *"Major because affected_routes=3 and user_flow_blocked=false."* |
| `affected_components`     | recommended | **Number**, not array. Count of distinct components implicated. |
| `affected_routes`         | recommended | **Number**, not array. |
| `user_flow_blocked`       | recommended | Did this break a recipe-named flow? Boolean. |
| `console_errors_observed` | recommended | Number. |
| `owner`     | recommended | Who's responsible: `library`, `app`, `uncertain`. Recipes that don't have a meaningful library/app distinction can omit. |
| `phase`     | recommended | Recipe-specific phase name (matches an entry in `run.phases_completed`). |
| `confidence`          | recommended | `[0.0, 1.0]` — how sure the agent is the finding is real. |
| `confidence_evidence` | recommended | Observable signals, not reasoning. *"git diff: 3 files modified"*, not *"I think the library probably broke"*. |
| `library_component`   | optional | String or `null`. |
| `route`               | optional | String or `null`. |
| `evidence`            | optional | Paths **relative to `artifacts/`** — e.g. `screenshots/foo.png`, not `artifacts/screenshots/foo.png`. |
| `changelog_mentions`  | optional | Array of strings copied verbatim from changelog hints when applicable. |

**Recipes omit fields that don't apply.** Don't synthesize `null`/`0`/`false` for fields your recipe has no opinion on — omit them. The viewer renders only what's present.

### Severity rubric

- **blocker** — recipe's primary objective failed; CI should fail. (Build broken, flow can't complete, install errored.)
- **major** — meaningful breakage but recipe completed; user attention warranted. (Visibly broken UI, console error on a named flow, agent fix required.)
- **minor** — cosmetic / non-blocking finding worth noting. (Layout drift inside spec, console warning, clean codemod, mechanical fix.)
- **info** — observation worth recording even though nothing is wrong. (A check ran cleanly, a route walked without issues, exploration bound was hit gracefully.)

Successes are not findings. *Don't emit a "blocker: install passed" finding.* Use `outputs` for positive structured data (counts, URLs, paths).

## `outputs`

Recipe-defined freeform JSON. Use this for structured data the recipe wants to expose to:

- The CI engine (action exposes scalar fields as step outputs).
- Downstream automation in `needs:` jobs.
- Human readers / the viewer's "Outputs" panel.

Examples (drawn from current built-in recipes):

| Recipe | Notable `outputs` keys |
|---|---|
| `hello` | `greeting`, `input_name` |
| `exploratory-tests` | `target`, `goals_total`, `goals_blocked` |
| `dep-migration-check` | `version_from`, `version_to`, `libraries`, `build_passed`, `replay_passed`, `blocker_count`, `major_count`, `minor_count`, `changelog` |
| `playwright-from-diff` | `pr_url`, `tests_generated`, `tests_shipped`, `tests_dropped`, `branch`, `playwright_command` |

There is no schema for `outputs`. The recipe's prompt and `recipe.yaml` are the contract with its consumers.

## Evidence directory

`${PIPEKIT_WORKSPACE}/artifacts/` is for binary / human-readable supporting material. None of these are required:

```
artifacts/
├── catalog/              recipe inventory of "last known good" — primitives, breadcrumbs, baseline screenshots
├── screenshots/          before/after/diff visual evidence
├── snapshots/            DOM snapshots when visual alone is insufficient
├── logs/                 run logs (install.log, build.log, plan.md, ...)
├── changes.patch         git diff capturing agent edits to /repo
├── report.consumer.md    optional human narrative for the consumer team
└── report.maintainer.md  optional human narrative for the library/maintainer team
```

The viewer renders only what's present. Recipes write what makes sense for their domain — `hello` writes nothing under `artifacts/`; `dep-migration-check` writes catalog/screenshots/logs/changes.patch + both markdown reports.

## Redaction

If the recipe's `inputs` declare a `redact` block (selectors and/or text patterns), the recipe MUST apply redaction *before* writing screenshots or DOM snapshots to disk. Un-redacted frames must never land in `artifacts/`. The maintainer report (when produced) drops `owner: "app"` findings and uses redacted versions of evidence.

Recipes that don't take redaction inputs don't need to do redaction.

## Where this spec lives

Baked into the runner image at `/pipekit/docs/result.spec.md`. Recipes reference that path from their `prompt.md` so the agent can re-read the binding spec at runtime.

Recipe authors do **not** ship their own copy of this spec. The image is the source of truth; the spec evolves with the runner image version.
