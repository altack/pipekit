# Pipekit marketplace — design spec

How recipes are discovered. Three repos, two contracts, one static site. GitHub is the backend.

This doc captures the shape we're committing to *before* extracting recipes from this repo, so the recipes repo and the site can land without a retrofit pass.

## The three repos

| Repo | Role | What lives here |
|---|---|---|
| `altack/pipekit` (this) | Harness | Runner image, drivers, GitHub Action, GitLab include, specs (`docs/`), e2e fixtures. |
| `altack/pipekit-recipes` | Canonical content + indexer | Recipes under `recipes/<org>/<name>/`, `publishers.yaml`, `.github/workflows/index.yml` (the indexer Action). Publishes `index.json` to GitHub Pages. |
| `altack/pipekit.dev` | Static site | Astro app. Fetches `index.json` at build time, renders cards + detail pages. Deployed to Pages or Vercel. |

The split keeps each repo's audience distinct: harness contributors, recipe authors, site contributors. Recipe contributors never need to touch site code.

## `altack/pipekit-recipes` layout

```
pipekit-recipes/
├── README.md                  # author-facing: what is this, how to contribute
├── publishers.yaml            # external publishers we crawl
├── recipes/
│   └── pipekit/               # canonical org — only this org lives here
│       ├── hello/
│       ├── exploratory-tests/
│       ├── dep-migration-check/
│       └── playwright-from-diff/
└── .github/
    └── workflows/
        ├── index.yml          # indexer Action — generates index.json
        └── validate.yml       # PR-time: each recipe.yaml must conform to recipe.spec.md
```

Only the `pipekit` org lives under `recipes/` in this repo. Other publishers host their own repos and register via `publishers.yaml`. The indexer pulls from all of them and merges.

## `publishers.yaml`

External publishers register by PR-ing one entry. The canonical pipekit org is *not* listed here (it's implicit — its recipes are in this same repo).

```yaml
publishers:
  - org: yourcompany
    repo: yourcompany/yourcompany-pipekit-recipes
    ref: main                  # branch or tag the indexer reads
    homepage: https://...      # optional
    contact: ops@yourcompany   # optional, for outage / takedown
```

Constraints enforced at PR review:
- `org` must match the directory under `recipes/` in the publisher's repo (`recipes/yourcompany/<name>/`). Cross-org publishing isn't allowed.
- `org` must not collide with an existing publisher or with `pipekit`.
- `repo` must be public.

No accounts. No publish UI. Want to be listed → open a PR. Want to be removed → open a PR.

## `index.json` (the site contract)

The indexer emits one file the site consumes. Schema:

```jsonc
{
  "generated_at": "2026-04-26T10:00:00Z",
  "indexer_version": "1",
  "publishers": [
    {
      "org": "pipekit",
      "repo": "altack/pipekit-recipes",
      "ref": "main",
      "sha": "abc123...",          // commit SHA at index time
      "canonical": true            // pipekit org only
    },
    {
      "org": "yourcompany",
      "repo": "yourcompany/yourcompany-pipekit-recipes",
      "ref": "main",
      "sha": "def456...",
      "canonical": false
    }
  ],
  "recipes": [
    {
      "id": "@pipekit/hello",
      "org": "pipekit",
      "name": "hello",
      "version": "0.1.0",
      "description": "Smoke test of the pipekit agent contract — reads name, writes greeting.",
      "tags": ["example", "smoke"],
      "agents_preferred": ["claude-code"],
      "requires": {
        "env": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GH_TOKEN"],
        "mounts": []
      },
      "inputs_schema": { "type": "object", "...": "..." },
      "source": {
        "repo": "altack/pipekit-recipes",
        "path": "recipes/pipekit/hello",
        "ref": "main",
        "sha": "abc123..."
      },
      "links": {
        "recipe_yaml": "https://raw.githubusercontent.com/.../recipe.yaml",
        "prompt_md":   "https://raw.githubusercontent.com/.../prompt.md",
        "tree":        "https://github.com/.../tree/abc123/recipes/pipekit/hello"
      }
    }
  ]
}
```

Decisions baked in:
- **`inputs_schema` is embedded.** The site needs to render it; one extra fetch per recipe is wasteful.
- **`prompt.md` is NOT embedded.** Prompts can be many KB; the site fetches lazily on the detail page via `links.prompt_md`.
- **Source SHA pins.** Every entry records the commit SHA at index time, so a stale `index.json` still resolves to deterministic content.
- **`tags` is recipe-author-controlled.** Add a top-level `tags: [...]` to `recipe.yaml`. Schema update for `recipe.spec.md` will land alongside this work.

The indexer publishes `index.json` to the `gh-pages` branch of `altack/pipekit-recipes`, served at `https://altack.github.io/pipekit-recipes/index.json` (or behind a custom domain like `recipes.pipekit.dev`).

## Indexer Action

`.github/workflows/index.yml` in `altack/pipekit-recipes`. Triggers:
- `push` to `main` (recipes changed)
- `schedule: cron: '0 */6 * * *'` (publishers changed)
- `workflow_dispatch` (manual rebuild)

Steps:
1. Walk `recipes/**/recipe.yaml`. Parse each. (These are the `pipekit` org entries.)
2. Read `publishers.yaml`. For each external publisher:
   1. `GET /repos/<repo>/commits/<ref>` — current SHA.
   2. If SHA matches the cached `index.json`'s entry, copy that publisher's recipes from cache (no re-fetch).
   3. Otherwise: `GET /repos/<repo>/git/trees/<sha>?recursive=1`, filter to `recipes/<org>/<name>/recipe.yaml`, fetch each via Contents API.
3. Validate every fetched `recipe.yaml` against `recipe.spec.md`. Skip + warn on invalid (don't fail the whole build).
4. Emit `index.json`. Commit + push to `gh-pages`.

Caching: keep the previous `index.json` checked out from `gh-pages`. Use it as the read-through cache keyed by publisher SHA. This is the only mechanism — no separate cache store. Publisher repos that haven't moved cost zero API calls.

Rate limit: authenticated runs get 5k req/h. With ~3 API calls per active publisher per index run and a 6h schedule, we sustain hundreds of publishers without strain. If we ever cross that, switch to GraphQL (one query per publisher returning the whole tree).

## Validation Action

`.github/workflows/validate.yml`. On PR:
- For each changed `recipes/**/recipe.yaml`, validate against `recipe.spec.md` (ajv).
- For each changed `publishers.yaml` entry, fetch the publisher's repo tree and confirm at least one `recipes/<their-org>/<name>/recipe.yaml` exists.
- Block merge on failure.

This is what makes "PR-as-publish" trustworthy: publisher claims are verified at merge time, not at runtime.

## Site (`altack/pipekit.dev`)

Astro static site. Build-time fetch of `index.json`; one detail page generated per recipe.

Routes:
- `/` — search + tag filter over all recipes
- `/r/@<org>/<name>` — detail page (renders `recipe.yaml` fields + lazy-loads `prompt.md`)
- `/publishers` — list of publishers with link counts

Per-recipe page must include copy-paste blocks:

```yaml
# GitHub Action
- uses: altack/pipekit/action@main
  with:
    recipe: '@pipekit/hello'
    inputs: |
      { "name": "World" }
```

```yaml
# GitLab CI
include:
  - remote: 'https://raw.githubusercontent.com/altack/pipekit/main/gitlab/v1.yml'
pipekit:
  variables:
    PIPEKIT_RECIPE: '@pipekit/hello'
    PIPEKIT_INPUTS: '{"name":"World"}'
```

Search is client-side fuzzy (Fuse.js or similar) over the embedded `index.json`. Filters: tag, agent, publisher, has-setup-shell.

No analytics that phone home. No accounts. No comments. The site is a directory.

## What this unblocks (and what it doesn't)

**Unblocks:** v0.2 URL-based recipe fetch (`PIPEKIT_RECIPES_REGISTRY`) — the resolver can clone any publisher's repo at the SHA pinned in `index.json`. Recipe versioning falls out for free: pinned to `<ref>` resolves to a tag.

**Does not unblock:** Private recipes. If a publisher's repo is private, the indexer can't see it. That's fine — private recipes don't need a public marketplace; consumers bind-mount or clone with their own credentials.

## Open questions parked

- **Featured / curated lists.** Initially everything indexed = listed. If quality becomes a problem, add a `featured: true` field to `publishers.yaml` for pipekit-blessed entries and let the site default-filter on it.
- **Deprecation.** No mechanism yet for marking a recipe as deprecated. Probably a `deprecated: true` in `recipe.yaml` + UI badge. Defer until the first deprecation comes up.
- **Custom domain.** `recipes.pipekit.dev` (Pages on the recipes repo) vs `pipekit.dev/r/...` (everything under one domain). Lean toward the second for SEO and to keep the surface area small, but it requires the site to proxy or rebuild on indexer changes. Decide when wiring up DNS.
