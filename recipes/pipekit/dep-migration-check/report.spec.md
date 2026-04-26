# Autotest Report — Specification (v0.1)

## Purpose

At the end of a run, the recipe writes a directory of artifacts to `${PIPEKIT_WORKSPACE}/artifacts/`. This directory is the deliverable. It serves two audiences:

- **Consumer team** — the people who own the app being tested. They need to decide "can we safely upgrade this dependency, and if not, what's blocking us?"
- **Library maintainer** — the `@org/component-library` team. They need to know "how did my latest release actually land in the apps that use it?"

Different audiences get different files. They're generated from the same structured truth (`report.json`) so the data never drifts between them.

## Artifacts written to `${PIPEKIT_WORKSPACE}/artifacts/`

```
artifacts/
├── report.json                # machine-readable truth, all findings
├── report.consumer.md         # full-narrative report for the app team
├── report.maintainer.md       # redacted report for the library team
├── changes.patch              # git diff of every edit the agent made to /repo (migrations + fixes)
├── catalog/
│   ├── primitives.json        # what was cataloged from master (the "last known good")
│   ├── routes/                # per-route breadcrumbs — ordered agent actions replay re-executes
│   │   └── <slug>.actions.json
│   └── screenshots/           # baseline screenshots from the catalog phase
├── screenshots/
│   ├── <finding-id>-before.png
│   ├── <finding-id>-after.png
│   └── <finding-id>-diff.png  # overlay when applicable
├── snapshots/
│   └── <finding-id>.html      # DOM snapshots for findings where visual alone is insufficient
└── logs/
    ├── plan.md                # the migrate-phase plan — migration commands, expected risks, verification steps, recorded deviations
    ├── install.log            # the upgrade-phase install output
    ├── build.log              # the build-phase output
    ├── migrate.log            # migration command output
    └── agent.jsonl            # raw stream-json from the Claude Code run
```

The two markdown reports link into `screenshots/`, `snapshots/`, `catalog/` using relative paths so the whole directory is portable (zip it, attach it to a CI artifact, paste it in a PR comment).

## Severity — the agent decides, scored by impact

No manifest overrides in v0.1. The agent assigns severity from this rubric, which lives in the system prompt:

- **blocker** — the upgrade is not viable. The app doesn't build, doesn't boot, or a critical journey described in the manifest fails to complete.
- **major** — the upgrade is viable, but something visibly broke that a user would notice. A dialog doesn't open, a button is invisible/unclickable, a layout is clipped, a console error fires on a journey the manifest names.
- **minor** — cosmetic or ambient. 3px padding drift, a color shift inside spec, a console warning that doesn't break behavior, a redundant network call.

**Impact fields on every finding** — these are what the agent's severity call is grounded in, and they're persisted separately so humans can validate the call:

- `affected_components: number` — count of distinct library components involved in this finding (if a broken `bui-dialog` takes down 4 dialogs on one page, `affected_components` is 1 for `bui-dialog`).
- `affected_routes: number` — count of manifest routes/flows exhibiting this finding. Bigger blast radius → higher severity.
- `user_flow_blocked: boolean` — does this finding prevent a manifest-named flow from completing? `true` correlates strongly with blocker/major.
- `console_errors_observed: number` — count of console errors/unhandled rejections during the finding.
- `severity_rationale: string` — required one-sentence justification referencing the fields above. "Critical because /checkout flow is blocked and bui-dialog fails on 3 routes" is the shape.

Humans triage by sorting: `severity` first, then `affected_routes * affected_components` as a tiebreaker.

## Confidence — every finding is probabilistic

Agentic systems are non-deterministic. Every finding carries an explicit confidence score so readers know how much to trust it:

- `confidence: 0.0–1.0` — the agent's self-reported probability that the finding is real (not flake, not a false positive from its own mis-click).
- `confidence_evidence: string[]` — the observable signals the agent used to compute it. Example for a "dialog did not open" finding:
  - `"click event fired at [data-test=open-dialog]"`
  - `"no DOM mutation observed within 2000ms of click"`
  - `"no overlay node inserted into document.body"`
  - `"no console error matched dialog-opening code path"`

**Rule of thumb for readers:** `confidence >= 0.85` is worth acting on; `0.60–0.85` worth a human glance; below `0.60` is noise unless it's a `blocker`. These thresholds are not enforced by Autotest — they're guidance for consumers reading the report.

The consumer report surfaces confidence as a badge next to the finding title. The maintainer report does the same but also highlights low-confidence findings in their own subsection so the library team can decide whether to chase them.

## Owner attribution

Recap from `autotest.spec.md` — every finding is tagged `owner: "library" | "app" | "uncertain"`. The attribution logic (DOM tag prefix, import trace, export-surface fingerprint) lives in the agent's system prompt and is not configurable from the manifest.

## `report.json` — machine-readable truth

Single JSON file. Top-level structure:

```json
{
  "run": {
    "started_at": "2026-04-15T02:04:11Z",
    "finished_at": "2026-04-15T02:21:47Z",
    "app": "fleet-console",
    "libraries": ["@org/component-library"],
    "version_from": { "@org/component-library": "2.14.3" },
    "version_to":   { "@org/component-library": "2.15.0" },
    "phases_completed": ["catalog", "upgrade", "migrate", "build", "replay"],
    "overall_status": "major-findings"
  },
  "changelog": {
    "source_url": "https://github.com/org/component-library/blob/main/CHANGELOG.md",
    "entries": [
      { "type": "breaking", "text": "<bui-option [selected]> renamed to [active]. Run `npx @org/cli migrate option-active`." },
      { "type": "fix",      "text": "improved dialog focus trap" },
      { "type": "feat",     "text": "new <bui-toast> component" }
    ]
  },
  "findings": [
    {
      "id": "finding-0001",
      "category": "migration",
      "severity": "minor",
      "severity_rationale": "Migration ran without manual intervention; no flow blocked.",
      "affected_components": 1,
      "affected_routes": 0,
      "user_flow_blocked": false,
      "console_errors_observed": 0,
      "confidence": 0.99,
      "confidence_evidence": [
        "migration command exited 0",
        "git diff reports 23 files modified cleanly"
      ],
      "owner": "library",
      "phase": "migrate",
      "library_component": "bui-option",
      "route": null,
      "summary": "Migration `option-active` ran, modified 23 files.",
      "detail": "Files touched: src/features/alerts/*.html, src/features/vehicles/*.html. See logs/migrate.log.",
      "evidence": { "logs": ["logs/migrate.log"] },
      "changelog_mentions": ["breaking: <bui-option [selected]> renamed to [active]"]
    },
    {
      "id": "finding-0002",
      "category": "visual",
      "severity": "major",
      "severity_rationale": "Close button misaligned on every dialog across 3 manifest routes; user-noticeable but does not block any flow.",
      "affected_components": 1,
      "affected_routes": 3,
      "user_flow_blocked": false,
      "console_errors_observed": 0,
      "confidence": 0.93,
      "confidence_evidence": [
        "diff pixel delta exceeds threshold on 6 of 6 bui-dialog instances captured",
        "DOM position of button shifted by 4px in layout snapshot",
        "no layout-thrash markers in console"
      ],
      "owner": "library",
      "phase": "replay",
      "library_component": "bui-dialog",
      "route": "/settings/team",
      "summary": "Dialog close button offset by ~4px from prior position.",
      "detail": "Before: button centered in 32x32 hit area. After: button shifted right, clipping at the dialog edge.",
      "evidence": {
        "screenshots": [
          "screenshots/finding-0002-before.png",
          "screenshots/finding-0002-after.png",
          "screenshots/finding-0002-diff.png"
        ],
        "dom_snapshot": "snapshots/finding-0002.html"
      },
      "changelog_mentions": []
    }
  ]
}
```

Notes on the schema:

- **Field ownership in `run`.** `started_at` and `finished_at` are written by the **runner** (the docker entrypoint), not the agent. The runner stamps `started_at` immediately before launching the agent and patches `finished_at` into `report.json` immediately after the agent exits. The agent must NEVER author or modify these two fields — leave them out, or copy-through if they were already present in a previous flush. All other `run.*` fields (`app`, `libraries`, `version_from`, `version_to`, `phases_completed`, `overall_status`) are agent-authored.
- **`libraries` (plural) is canonical.** Always an array of package names, even when there's only one. There is no singular `library` field. If a renderer wants a one-liner display, it composes `libraries.join(", ")` itself.
- **`version_from` / `version_to`** are objects keyed by package name (e.g. `{ "@angular/material": "20.2.14" }`), so multi-package upgrades are naturally representable.
- `changelog_mentions` is the crosswalk data. Empty array → the finding is **undocumented breakage** by definition. No separate category flag needed; undocumented-ness is derived.
- `severity_rationale` is required. Every severity assignment must explain itself. This is what makes an agent-decided severity auditable.
- `affected_components`, `affected_routes`, `user_flow_blocked`, `console_errors_observed` are all required on every finding (zero is a valid value). They are the impact-scoring fields that ground the severity call.
- `confidence` and `confidence_evidence` are required on every finding. `confidence` is a float in `[0.0, 1.0]`; `confidence_evidence` is an array of short observable-signal strings — not reasoning, but *what the agent saw*.
- `phase` is one of `catalog | upgrade | migrate | build | replay` — the stage of the journey the finding emerged in. Drives the chronological ordering in the narrative reports.
- `category` adds values for phase-specific and cross-cutting findings: `catalog | upgrade | migrate | build | runtime | visual | undocumented | exploration`. The `exploration` category is used only for "an exploration bound fired" findings (max_clicks_per_route hit, stop_condition triggered, etc.) so humans learn to tune the manifest. The `build` category is for post-migrate production build failures.
- `route` can be null (e.g. build errors aren't route-scoped).

## `report.consumer.md` — full narrative

Sections, in order:

### 1. TL;DR

Two or three sentences. Version from→to. Overall status (`clean | minor-findings | major-findings | blocked`). Single-sentence summary of the biggest finding.

### 2. Journey

Prose walkthrough of the full run, phase by phase. The "human tester kept a diary" voice. Example shape:

> **Catalog phase** — Booted fleet-console at `2.14.3`. Authenticated as `$AUTOTEST_USER`. Visited 4 routes and ran 1 flow. Captured 47 UI primitives owned by `@org/component-library`: 12 buttons, 6 dialogs, 8 form fields, 3 tables, 18 other. Baselines in `catalog/screenshots/`.
>
> **Upgrade phase** — Ran `pnpm add @org/component-library@latest`. Lockfile updated: `2.14.3 → 2.15.0`. Build succeeded in 31s. No TypeScript errors. One warning about `@org/component-library/legacy` being deprecated (see finding-0003).
>
> **Migration phase** — CHANGELOG advertised 1 migration: `npx @org/cli migrate option-active`. Ran it. Modified 23 files across `src/features/`. See finding-0001 and `logs/migrate.log`.
>
> **Replay phase** — Rebooted. Re-visited the same 4 routes and flow. Console errors on 1 route, visual regressions on 2 routes. See findings 0002, 0004, 0005.

### 3. Findings

One subsection per finding, sorted by severity descending then by phase. Each subsection:

```
### finding-0002 — major — library — bui-dialog

**Route:** /settings/team
**Summary:** Dialog close button offset by ~4px from prior position.
**Mentioned in CHANGELOG:** ✗ No

**Before / After / Diff**
![before](screenshots/finding-0002-before.png)
![after](screenshots/finding-0002-after.png)
![diff](screenshots/finding-0002-diff.png)

**Detail:** Before: button centered in 32x32 hit area. After: button shifted right, clipping at the dialog edge.

**Severity rationale:** Dialog close button is offset by 4px, visible in every dialog across the app; a user would notice.

**DOM snapshot:** [snapshots/finding-0002.html](snapshots/finding-0002.html)
```

The `✓/✗ Mentioned in CHANGELOG` badge is the per-finding half of the crosswalk.

### 4. Catalog reference

A short section — not full dump — summarizing what Autotest protected during catalog phase: "We cataloged 47 primitives across 4 routes. The full primitive list is in `catalog/primitives.json`; baseline screenshots are in `catalog/screenshots/`." This keeps the consumer report self-contained while not ballooning it.

### 5. What the CHANGELOG said vs what we saw

Embedded per-finding (via the badge) plus a compact summary line: "CHANGELOG mentioned 3 entries; 1 was exercised in this run; 3 undocumented findings were produced." Full crosswalk is in the maintainer report.

## `report.maintainer.md` — redacted, crosswalk-foregrounded

This is the version that can leave the consumer's network.

**Redaction applied automatically:**

- All text and selectors in the manifest's `## Redact` block are masked in screenshots and stripped from DOM snapshots before this report is generated.
- Consumer-specific identifiers (repo name, internal URLs, fixture emails) are replaced with anonymous labels: "consumer-A", "route-1", etc. Library-owned selectors and class names are kept intact — they're already public.
- Findings tagged `owner: "app"` are dropped entirely. The maintainer has no use for them and the consumer may not want to share them.

**Structure:**

### 1. TL;DR (maintainer flavor)

"Release 2.14.3 → 2.15.0, tested in 1 consumer app. 3 undocumented findings, 1 documented breaking change handled by migration, 1 major visual regression."

### 2. CHANGELOG Audit — the foregrounded crosswalk

The killer table:

| CHANGELOG entry | Exercised in this app? | Findings produced |
|---|---|---|
| breaking: `<bui-option [selected]>` → `[active]` | yes | finding-0001 (migration ran clean) |
| fix: improved dialog focus trap | no | — |
| feat: new `<bui-toast>` | no | — |
| — (undocumented) | — | finding-0002 (`bui-dialog` close button offset) |
| — (undocumented) | — | finding-0004 (`bui-tooltip` missing on hover) |
| — (undocumented) | — | finding-0003 (`/legacy` import path removed) |

The summary line under the table is the actual message to the maintainer: *"You mentioned 3 things, 1 was exercised, and we found 3 things you didn't mention."*

### 3. Undocumented findings (expanded)

Full detail on every finding with `changelog_mentions: []` and `owner: "library"`. Screenshots, DOM snapshots, severity, rationale. This is what the maintainer came to read.

### 4. Documented findings (brief)

One-liners for findings that *were* in the CHANGELOG. The maintainer already knows about these; surfacing them just confirms "migration ran / documented fix worked as expected."

### 5. App context (minimal)

A few lines so the maintainer knows what app-shape this data came from: "Framework: Angular. Library components used: 12 button, 6 dialog, 8 form-field, 3 table, 18 other." No app name, no URLs.

## Catalog phase artifacts

`catalog/primitives.json` — the structured inventory of what was protected:

```json
{
  "captured_at": "2026-04-15T02:04:11Z",
  "version": "2.14.3",
  "primitives": [
    {
      "tag": "bui-dialog",
      "count": 6,
      "routes": ["/settings/team", "/alerts", "/vehicles"],
      "variants": ["default", "with-footer", "fullscreen"]
    },
    { "tag": "bui-option", "count": 34, "routes": ["/settings/team"], "variants": ["selected", "unselected"] }
  ]
}
```

This plus `catalog/screenshots/` is what "last known good" actually means on disk.

`catalog/routes/<slug>.actions.json` — the agent's breadcrumb trail for a single route. Replay re-executes these so the post-upgrade run takes the same fair-shot path through the UI that catalog took, without being a mechanical keystroke replay.

```json
{
  "route": "/contacts",
  "slug": "contacts",
  "actions": [
    {
      "action": "click",
      "target": { "role": "button", "name": "Show details" },
      "observed": "panel revealed with 3 contact fields"
    },
    {
      "action": "type",
      "target": { "role": "textbox", "name": "Search" },
      "value": "Foo",
      "observed": "3 search results appeared"
    },
    {
      "action": "click",
      "target": { "role": "link", "name": "Foo Corp" },
      "observed": "navigated to /contact/42"
    }
  ]
}
```

**Granularity — one action per *meaningful state change*.** Navigation, form submission, dialog open/close, filter applied, expandable item opened, list item selected. Do NOT record hovers, focus events, scrolls, or intermediate keystrokes.

**Semantic targets, not DOM selectors.** `target` names what the element *is* (accessible `role` + `name`), not how to reach it (no CSS selectors, no XPath, no coordinates). Replay finds the element by matching role + name in the post-upgrade DOM so minor structural refactors don't break the replay.

**Literal values are load-bearing.** If the agent typed `"Foo"` in catalog, replay types `"Foo"` — not "something similar" and not a regenerated string. Record the exact value the agent used.

**Flows don't get breadcrumbs.** The manifest's ``flows`` section already declares the steps; flows are driven by the manifest in both phases. Breadcrumbs exist only for the exploratory ``routes`` entries.

## Migrate phase artifacts

`logs/plan.md` — the agent's plan for the migrate phase, written at the *start* of migrate and updated as execution proceeds. It is both a commitment device (no improvising mid-phase) and an audit trail (every fix attempt is logged here before it is attempted).

Shape:

```markdown
# Migrate plan — @org/component-library 2.14.3 → 2.15.0

## Migration commands (from changelog hints)
1. `npx @org/cli migrate option-active` — hint: "`[selected]` → `[active]`. Run `npx @org/cli migrate option-active`."

## Expected residual risks
- Hints mention `/legacy` barrel removed. After install, grep for `from '@org/component-library/legacy'` and remap to `@org/component-library/core`.
- Hints mention `<bui-option [value]>` type changed from `string` to `unknown`. Type errors likely in templates.

## Verification steps
- Run `npm run build` after each migration + fix.
- Replay checklist: probe `bui-dialog` focus trap, probe `bui-toast` first appearance.

## Execution log
- 15:04 — Ran `npx @org/cli migrate option-active`. Exit 0. 23 files modified under `src/features/`. → finding-0001 (minor).
- 15:05 — `npm run build` failed: `Cannot find module '@org/component-library/legacy'` in 4 files. Attempt 1: `find src -type f \( -name '*.ts' -o -name '*.html' \) -exec sed -i 's|@org/component-library/legacy|@org/component-library/core|g' {} +`. Build passes. → finding-0003 (major, owner=library, changelog_mentions=[]).
- 15:06 — `npm run build` passes cleanly. Plan complete.
```

The plan is narrative markdown, not a structured schema. Its purpose is legibility for humans reading the report (and for the agent re-reading its own plan across turns). Every `Execution log` entry corresponds to either a migration command, a fix attempt, or a verification step — and findings reference the plan line that produced them.

`changes.patch` — the cumulative `git diff` of every edit the agent made to `/repo` during migrate (migration commands + agent-applied fixes). Generated in the report phase with `git -C /repo diff > ${PIPEKIT_WORKSPACE}/artifacts/changes.patch`.

The patch is the consumer's takeaway. Autotest runs are ephemeral (the `/repo` mount is a scratch checkout in CI); the patch captures the work so the consumer can land it in their own tree if they want:

```bash
cd my-app
git apply path/to/changes.patch
# Review with `git diff`, then commit on a branch of your choosing.
```

This is deliberately **not** a PR — Autotest is not a Dependabot. The patch is an artifact the consumer can inspect, apply, reject, or cherry-pick from. Every hunk in the patch is already explained by a corresponding finding (migration output or agent fix), so the consumer can cross-reference `report.consumer.md` while reviewing.

**Fallback:** if `/repo` is not a git worktree (rare but possible), the agent skips patch generation and notes it in the report. No tarball fallback in v0.1.

**Size:** no cap. A large patch suggests a migration that touched many files, which is itself useful signal. If the patch is multi-megabyte, that's the CHANGELOG's problem, not Autotest's.

## CI exit codes

- `0` — run completed, zero `blocker` findings
- `1` — run completed, one or more `blocker` findings (app didn't build, didn't boot, or a manifest-named flow failed outright)
- `2` — Autotest itself failed (agent crashed, couldn't clone, couldn't authenticate, couldn't reach the library registry) — this is not a library-quality signal

`major` and `minor` findings do not fail the pipeline by default. A consumer who wants "fail on any major regression" opts in via a CLI flag on the runner (`--fail-on major`) — not via the manifest, since this is a CI policy choice, not an app contract.

## Redaction order of operations

Redaction is applied *before* anything is written to `${PIPEKIT_WORKSPACE}/artifacts/screenshots/` or `${PIPEKIT_WORKSPACE}/artifacts/snapshots/`. Raw un-redacted screenshots never touch disk outside the agent's in-memory workspace. This is non-negotiable — the maintainer report copies files from those directories; if un-redacted frames ever land there, they can leak.

The consumer report also reads from the redacted directory. Consumer teams who want un-redacted views can re-run locally without the `## Redact` block; we don't ship a "trust me, show me the raw frames" flag.

## What the report does NOT contain

- **No recommendations.** No "you should pin the library version" or "consider reverting." The report documents what happened; humans decide what to do.
- **No PR body snippets.** Autotest is not a Dependabot. If someone wants to paste findings into a PR, they paste them.
- **No cross-run history.** Single run, single report. Trends and aggregation across runs / across apps are out of scope for v0.1 — they live in a hypothetical future dashboard.
- **No suppression mechanism.** If a consumer team wants to ignore a finding, they fix the manifest (add to `## Ignore`) and re-run. Report files are not annotated by humans.

## Open questions for v0.2

- **Maintainer report delivery.** We generate the file; we don't ship it. Does the consumer team email it? Does the library publish a webhook? Defer.
- **Aggregation across apps.** The crosswalk gets dramatically more valuable when it's "23 apps ran against 2.15.0; here's the aggregate." Needs a hosted store. Out of scope for v0.1, explicitly interesting for v0.2.
- **Trend analytics across releases.** Once `report.json` files accumulate for a given library over time, the natural next product is a "Component Library Health" view: *"Last 30 releases: 5 safe, 2 regressions, 1 undocumented breaking release."* This is platform-engineering gold for the library team and is almost certainly the hosted-SaaS layer that sits on top of the self-hosted runner. Out of scope for v0.1; the `report.json` schema is deliberately stable enough that an aggregator can be added later without changing the runner.
- **Flake detection across retries.** Dropped; we accepted flakiness. Revisit only if noise swamps signal.
- **Severity overrides from the manifest.** Deferred per the "agent decides" decision. Revisit if the rubric proves too rigid in practice.
- **Report.md vs report.html.** Markdown is portable and pasteable; HTML with interactive diff overlays is richer. v0.1 is markdown; HTML is a v0.2 renderer over the same `report.json`.
