# Pipekit — deferred ideas

Things we've considered, decided not to build *now*, but want to remember. Each entry is dated and includes the context of why it was deferred. Not a roadmap; an idea log.

---

## LLM-driven viewer generator

**Logged:** 2026-04-26
**Status:** deferred — viewer itself deferred for now

A meta-recipe (`@pipekit/render-result` or similar) that takes any pipekit run's output — `result.json` + `artifacts/` — and produces a tailored HTML view. The generator uses an agent to:

1. Inspect the data shape (which `outputs.*` fields exist, what's under `artifacts/`, what categories of findings).
2. Infer which panels make sense (image diff grid if screenshots are present, markdown reports rendered as tabs, finding-severity grouping, etc.).
3. Emit a self-contained HTML+JS file consumers can open or share.

**Why this is interesting**

- Sidesteps the "bake-viewer-into-recipe" trap (recipe authors don't need to be web developers).
- Sidesteps the "generic viewer with conventional panels" trap (no lowest-common-denominator pressure on recipes; novel evidence shapes get novel views automatically).
- Recipes can evolve their `outputs` and `artifacts/` shape without ever coordinating with viewer code.
- Could itself be a pipekit recipe — eats its own dog food.

**Tradeoffs to wrestle with before building**

- **Cost**: every view generation is an agent call. Cache aggressively — keyed on recipe identity + schema-fingerprint of the result, not the result content itself.
- **Determinism**: same input could produce different views across runs unless caching is solid. Probably fine if the cache key includes recipe version.
- **Local-first vs hosted**: viewer generation could happen at run-time (recipe's last phase emits the HTML) or on-demand (consumer runs `@pipekit/render-result` against an existing run). Latter is more flexible but adds an LLM call to "looking at results."
- **Sandboxing**: generated HTML runs in the consumer's browser. Same trust model as any LLM-generated code in your CI artifacts.

**When this becomes obvious to build**

When pipekit has 10+ recipes with meaningfully different output shapes, and the maintenance cost of generic-panel-conventions starts exceeding the cost of just letting an agent look at the data and decide. Probably v0.3 or later.

---

## Recipe versioning at resolution time

**Logged:** 2026-04-26
**Status:** deferred — fold into v0.2's URL-fetch work

`@pipekit/<name>@v1.2.0` should resolve to a specific git tag in the recipes repo; bare `@pipekit/<name>` should default to the latest tagged release (or `main`). Today we have `version: 1.0.0` in `recipe.yaml` but no runtime pinning — whatever's in `${PIPEKIT_RECIPES_DIR}` is what runs.

Lands when v0.2's URL-based recipe fetch ships (`PIPEKIT_RECIPES_REGISTRY` → git clone with `--depth=1 --branch <ref>` + cache by ref hash). Until then, "the bind-mount is the source of truth" is the implicit version.

---

## Recipe stdlib (shared helpers)

**Logged:** 2026-04-26
**Status:** premature with 4 recipes

Common helpers across recipes: package-manager detection, dev-server boot/poll, screenshot diffing, build-output parsing. Today every recipe that needs one duplicates it (or copies our `upgrade.sh`).

Refactor when the third recipe wants the same helper. Likely lives in the runner image at `/pipekit/lib/recipes/` and recipes reference it by absolute path from their prompt. Avoid making this a separate distributable package until it actually has 5+ helpers in real use.

---

## Within-container multi-recipe orchestration

**Logged:** 2026-04-26
**Status:** CI's `needs:` is enough until proven otherwise

A way for recipe A to call recipe B in the same container without a full restart (which CI `needs:` requires). Useful when recipes share heavy state (browser session, build artifacts, large filesystem snapshots) and inter-CI-job overhead matters.

Until we have a recipe that genuinely demands this, GitHub `needs:` and GitLab `needs:` are the right primitive. Workspace upload/download is the documented pattern for state passing.

---

## Image variants

**Logged:** 2026-04-26
**Status:** nobody has asked

`pipekit-runner:slim` (no chromium / no agent-browser), `pipekit-runner:gpu`, `pipekit-runner:python` (Python pre-installed for recipes that need it). Today we have one image with kitchen-sink defaults and `setup.shell` for everything else.

Worth doing when (a) the single image gets above ~3GB and people complain, or (b) a recipe family genuinely requires GPU/specific runtime that's expensive to install per-run.

---

## Local pipekit CLI without docker

**Logged:** 2026-04-26
**Status:** rare use case, not worth building

A way to run `pipekit run @pipekit/hello` on a developer's machine without docker. Today the harness assumes containerized execution. Some recipes might be runnable directly with the dev's local agent (Claude Code, Codex, etc.) and locally-installed tools.

Probably implemented as a thin TS wrapper that mimics `pipekit-agent` but skips the container. Worth doing if/when local recipe authoring becomes a real workflow.
