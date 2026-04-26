#!/usr/bin/env bash
# pipekit end-to-end smoke test.
#
# Builds the runner image locally and exercises the recipe contract end-to-end.
# Each case validates a different code path; the first three do real LLM calls
# (against @pipekit/hello), case 4 exercises agent resolution without any LLM
# spend, and case 5 verifies the recipe-supplied agent-preferred fallback works.
# Case 6 verifies setup.shell runs before the agent and is visible at runtime.
#
# Requires:
#   - docker (or podman aliased to docker)
#   - ANTHROPIC_API_KEY in env
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   ./e2e/smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PIPEKIT_IMAGE:-pipekit-runner:e2e}"
WORK_BASE="$(mktemp -d -t pipekit-smoke.XXXXXX)"
trap 'rm -rf "$WORK_BASE"' EXIT

log() { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY is not set"
fi

# ─── Build ───────────────────────────────────────────────────────────────
if [[ "${PIPEKIT_SKIP_BUILD:-}" != "1" ]]; then
  log "building $IMAGE from $REPO_ROOT"
  docker build \
    -f "$REPO_ROOT/runner/Dockerfile" \
    -t "$IMAGE" \
    "$REPO_ROOT"
else
  log "PIPEKIT_SKIP_BUILD=1 — assuming $IMAGE already exists"
fi

# ─── Case 1: happy path ─────────────────────────────────────────────────
WORK_PASS="$WORK_BASE/pass"
mkdir -p "$WORK_PASS"
log "case 1: happy path (expect status=pass, exit 0)"

set +e
docker run --rm \
  -v "$WORK_PASS:/work" \
  -e PIPEKIT_RECIPE='@pipekit/hello' \
  -e PIPEKIT_INPUTS='{"name":"smoke"}' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT1=$?
set -e

[[ -f "$WORK_PASS/result.json" ]] || fail "case 1: result.json was not produced"
[[ $EXIT1 -eq 0 ]] || fail "case 1: expected exit 0, got $EXIT1"
STATUS1=$(jq -r '.status'  "$WORK_PASS/result.json")
SUMMARY1=$(jq -r '.summary' "$WORK_PASS/result.json")
[[ "$STATUS1" == "pass" ]] || fail "case 1: expected status=pass, got '$STATUS1'"
echo "$SUMMARY1" | grep -qi "smoke" || fail "case 1: expected summary to mention 'smoke', got '$SUMMARY1'"
log "case 1 OK: $SUMMARY1"

# ─── Case 2: request-fail path ──────────────────────────────────────────
WORK_FAIL="$WORK_BASE/fail"
mkdir -p "$WORK_FAIL"
log "case 2: request-fail (expect status=fail, exit 1)"

set +e
docker run --rm \
  -v "$WORK_FAIL:/work" \
  -e PIPEKIT_RECIPE='@pipekit/hello' \
  -e PIPEKIT_INPUTS='{"fail":true}' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT2=$?
set -e

[[ -f "$WORK_FAIL/result.json" ]] || fail "case 2: result.json was not produced"
[[ $EXIT2 -eq 1 ]] || fail "case 2: expected exit 1, got $EXIT2"
STATUS2=$(jq -r '.status' "$WORK_FAIL/result.json")
[[ "$STATUS2" == "fail" ]] || fail "case 2: expected status=fail, got '$STATUS2'"
log "case 2 OK"

# ─── Case 3: pass-when override ─────────────────────────────────────────
WORK_PW="$WORK_BASE/passwhen"
mkdir -p "$WORK_PW"
log "case 3: pass-when inverts the verdict (expect exit 1 even though status=pass)"

set +e
docker run --rm \
  -v "$WORK_PW:/work" \
  -e PIPEKIT_RECIPE='@pipekit/hello' \
  -e PIPEKIT_INPUTS='{"name":"smoke"}' \
  -e PIPEKIT_PASS_WHEN='.status == "fail"' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT3=$?
set -e

[[ $EXIT3 -eq 1 ]] || fail "case 3: expected exit 1 (pass-when falsy), got $EXIT3"
log "case 3 OK"

# ─── Case 4: explicit codex (stub) → exit 2, no LLM call ───────────────
WORK_CODEX="$WORK_BASE/codex"
mkdir -p "$WORK_CODEX"
log "case 4: explicit PIPEKIT_AGENT=codex (stub) → expect exit 2 with no API spend"

set +e
docker run --rm \
  -v "$WORK_CODEX:/work" \
  -e PIPEKIT_RECIPE='@pipekit/hello' \
  -e PIPEKIT_AGENT='codex' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT4=$?
set -e

[[ $EXIT4 -eq 2 ]] || fail "case 4: expected exit 2 (codex stub unavailable), got $EXIT4"
log "case 4 OK"

# ─── Case 5: preferred fallback (codex,copilot,claude-code) → uses claude-code ──
WORK_FB="$WORK_BASE/fallback"
mkdir -p "$WORK_FB"
log "case 5: PIPEKIT_PREFERRED=codex,copilot,claude-code → falls back to claude-code"

set +e
docker run --rm \
  -v "$WORK_FB:/work" \
  -e PIPEKIT_RECIPE='@pipekit/hello' \
  -e PIPEKIT_INPUTS='{"name":"fallback"}' \
  -e PIPEKIT_PREFERRED='codex,copilot,claude-code' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT5=$?
set -e

[[ -f "$WORK_FB/result.json" ]] || fail "case 5: result.json was not produced"
[[ $EXIT5 -eq 0 ]] || fail "case 5: expected exit 0, got $EXIT5"
STATUS5=$(jq -r '.status' "$WORK_FB/result.json")
[[ "$STATUS5" == "pass" ]] || fail "case 5: expected status=pass, got '$STATUS5'"
log "case 5 OK"

# ─── Case 6: setup.shell runs before agent and is visible to it ────────
WORK_SETUP="$WORK_BASE/setup"
mkdir -p "$WORK_SETUP"
log "case 6: custom recipe with setup.shell → marker file readable by agent"

set +e
docker run --rm \
  -v "$WORK_SETUP:/work" \
  -v "$REPO_ROOT/e2e/recipes/setup-marker:/recipes/setup-marker:ro" \
  -e PIPEKIT_RECIPE='/recipes/setup-marker' \
  -e ANTHROPIC_API_KEY \
  "$IMAGE"
EXIT6=$?
set -e

[[ -f "$WORK_SETUP/result.json" ]] || fail "case 6: result.json was not produced"
[[ $EXIT6 -eq 0 ]] || fail "case 6: expected exit 0, got $EXIT6"
STATUS6=$(jq -r '.status' "$WORK_SETUP/result.json")
[[ "$STATUS6" == "pass" ]] || fail "case 6: expected status=pass, got '$STATUS6'"
MARKER=$(jq -r '.outputs.marker // ""' "$WORK_SETUP/result.json")
[[ "$MARKER" == "marker-from-setup" ]] \
  || fail "case 6: expected outputs.marker='marker-from-setup', got '$MARKER'"
log "case 6 OK: setup.shell visible to agent"

log "ALL CASES PASSED"
