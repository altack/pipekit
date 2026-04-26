#!/usr/bin/env bash
# Pipekit playground integration test.
#
# Runs @pipekit/dep-migration-check against the autotest playground (Angular +
# Material) using the published GHCR image. This is NOT a smoke test — it
# performs a real upgrade journey, takes ~15-30 min, and costs real Claude API
# spend (~$5-15 per run).
#
# Requires:
#   ANTHROPIC_API_KEY  — Claude credential
#   AUTOTEST_USER      — playground login (e.g. demo@autotest.com)
#   AUTOTEST_PASSWORD  — playground login password
#
# Optional:
#   PIPEKIT_IMAGE      — override image (default: ghcr.io/wall-street-dev/pipekit-runner:latest)
#   PLAYGROUND_REPO    — path to consumer repo (default: /Users/guzmanoj/Projects/autotest/playground)
#   PIPEKIT_OUT        — host output dir (default: ./e2e/playground/out-<timestamp>)
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export AUTOTEST_USER=demo@autotest.com
#   export AUTOTEST_PASSWORD=...
#   ./e2e/playground/run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${PIPEKIT_IMAGE:-ghcr.io/wall-street-dev/pipekit-runner:latest}"
PLAYGROUND="${PLAYGROUND_REPO:-/Users/guzmanoj/Projects/autotest/playground}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${PIPEKIT_OUT:-$REPO_ROOT/e2e/playground/out-$TS}"

log() { echo "[playground] $*"; }
fail() { echo "[playground] FAIL: $*" >&2; exit 1; }

[[ -n "${ANTHROPIC_API_KEY:-}" ]] || fail "ANTHROPIC_API_KEY is not set"
[[ -n "${AUTOTEST_USER:-}" ]]     || fail "AUTOTEST_USER is not set (login for the playground)"
[[ -n "${AUTOTEST_PASSWORD:-}" ]] || fail "AUTOTEST_PASSWORD is not set (login for the playground)"
[[ -d "$PLAYGROUND" ]]            || fail "PLAYGROUND_REPO not a directory: $PLAYGROUND"
[[ -f "$PLAYGROUND/autotest.yml" ]] || fail "no autotest.yml at $PLAYGROUND"

mkdir -p "$OUT"
log "image:      $IMAGE"
log "playground: $PLAYGROUND"
log "out:        $OUT"

# ─── Convert autotest.yml → JSON inputs (using the image's yq) ──────────
log "converting playground/autotest.yml to JSON inputs"
INPUTS_JSON=$(docker run --rm --entrypoint yq \
  -v "$PLAYGROUND/autotest.yml:/in.yml:ro" \
  "$IMAGE" \
  -o=json '.' /in.yml)

# Save a copy alongside the run output for traceability
echo "$INPUTS_JSON" > "$OUT/inputs.input.json"
log "inputs saved to: $OUT/inputs.input.json"

# ─── Pull image (no-op if already local) ────────────────────────────────
log "pulling $IMAGE"
docker pull "$IMAGE" >/dev/null

# ─── Run dep-migration-check ────────────────────────────────────────────
log "starting dep-migration-check (this takes 15-30 min and costs real API tokens)"
log "stream the run via:  tail -f $OUT/agent.jsonl"

set +e
docker run --rm \
  -v "$PLAYGROUND:/repo" \
  -v "$OUT:/work" \
  -e PIPEKIT_RECIPE='@pipekit/dep-migration-check' \
  -e PIPEKIT_INPUTS="$INPUTS_JSON" \
  -e PIPEKIT_MAX_TURNS="${PIPEKIT_MAX_TURNS:-500}" \
  -e ANTHROPIC_API_KEY \
  -e AUTOTEST_USER \
  -e AUTOTEST_PASSWORD \
  "$IMAGE"
EXIT=$?
set -e

# ─── Summarize ──────────────────────────────────────────────────────────
echo ""
log "exit code: $EXIT"
if [[ -f "$OUT/result.json" ]]; then
  STATUS=$(jq -r '.status'  "$OUT/result.json")
  SUMMARY=$(jq -r '.summary' "$OUT/result.json")
  BLOCKERS=$(jq -r '.outputs.blocker_count // 0' "$OUT/result.json")
  MAJORS=$(jq -r '.outputs.major_count // 0' "$OUT/result.json")
  MINORS=$(jq -r '.outputs.minor_count // 0' "$OUT/result.json")
  log "status: $STATUS"
  log "summary: $SUMMARY"
  log "findings: blocker=$BLOCKERS major=$MAJORS minor=$MINORS"
else
  log "no result.json produced"
fi

log ""
log "artifacts: $OUT/artifacts/"
[[ -f "$OUT/artifacts/report.consumer.md" ]] && log "consumer report: $OUT/artifacts/report.consumer.md"
[[ -f "$OUT/artifacts/changes.patch"      ]] && log "changes patch:   $OUT/artifacts/changes.patch"
exit "$EXIT"
