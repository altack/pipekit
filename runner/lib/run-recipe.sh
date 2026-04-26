#!/usr/bin/env bash
# pipekit Phase 2 (node). Invoked by /usr/local/bin/pipekit-agent after the
# root phase has parsed the recipe, run setup, validated requires, and resolved
# the agent. This phase invokes the driver, validates result.json, and computes
# the verdict.
#
# Args:
#   $1   path to the system prompt .md file
#
# Inputs (env):
#   PIPEKIT_WORKSPACE    workspace dir (cwd at entry)
#   PIPEKIT_AGENT        picked driver name
#   PIPEKIT_MODEL        model id (already defaulted by Phase 1 if recipe-set)
#   PIPEKIT_MAX_TURNS    (default 200)
#   PIPEKIT_PASS_WHEN    optional jq expression
#   <agent credentials>  forwarded by Phase 1 via --preserve-environment
#
# Exit codes match docs/contract.md: 0 pass, 1 fail, 2 infra fail.

set -euo pipefail

log()  { echo "[pipekit] $*" >&2; }
fail() { log "ERROR: $*"; exit 2; }

PROMPT_PATH="${1:?prompt path required}"
WORKSPACE="${PIPEKIT_WORKSPACE:?required}"
PICK="${PIPEKIT_AGENT:?required}"

DRIVER="/pipekit/drivers/$PICK/run.sh"
[[ -x "$DRIVER" ]] || fail "driver not executable: $DRIVER"

cd "$WORKSPACE"

set +e
"$DRIVER" "$PROMPT_PATH"
DRIVER_EXIT=$?
set -e

if [[ $DRIVER_EXIT -ne 0 ]]; then
  log "driver $PICK exited non-zero ($DRIVER_EXIT)"
  if [[ ! -f "$WORKSPACE/result.json" ]]; then
    printf '{"status":"fail","summary":"driver %s exited %d without writing result.json"}' \
      "$PICK" "$DRIVER_EXIT" > "$WORKSPACE/result.json"
  fi
  exit 2
fi

if [[ ! -f "$WORKSPACE/result.json" ]]; then
  log "ERROR: agent did not write result.json"
  echo '{"status":"fail","summary":"agent did not write result.json"}' > "$WORKSPACE/result.json"
  exit 2
fi

jq empty "$WORKSPACE/result.json" 2>/dev/null \
  || fail "result.json is not valid JSON"

# ─── Stamp runner-known fields into result.json.run ────────────────────────
# Authoritative for recipe/agent/model/started_at/finished_at — overwrites any
# values the agent wrote. Agent retains authorship of phases_completed and
# overall_status (and any other run.* keys it wants to set).
PIPEKIT_FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP_RESULT="$(mktemp "$WORKSPACE/result.json.XXXXXX")"
if jq --arg recipe   "${PIPEKIT_RECIPE_ID:-}" \
      --arg agent    "${PICK}" \
      --arg model    "${PIPEKIT_MODEL:-}" \
      --arg started  "${PIPEKIT_STARTED_AT:-}" \
      --arg finished "$PIPEKIT_FINISHED_AT" \
      '.run = (.run // {})
       | .run.recipe      = $recipe
       | .run.agent       = $agent
       | .run.model       = $model
       | .run.started_at  = $started
       | .run.finished_at = $finished' \
      "$WORKSPACE/result.json" > "$TMP_RESULT"; then
  mv "$TMP_RESULT" "$WORKSPACE/result.json"
else
  rm -f "$TMP_RESULT"
  log "WARNING: failed to stamp run.* into result.json (kept agent values)"
fi

if [[ -n "${PIPEKIT_PASS_WHEN:-}" ]]; then
  log "evaluating pass-when: $PIPEKIT_PASS_WHEN"
  if jq -e "$PIPEKIT_PASS_WHEN" "$WORKSPACE/result.json" >/dev/null 2>&1; then
    log "verdict: pass (pass-when truthy)"
    exit 0
  else
    log "verdict: fail (pass-when falsy)"
    exit 1
  fi
fi

STATUS=$(jq -r '.status // "fail"' "$WORKSPACE/result.json")
log "verdict: $STATUS (from result.json:.status)"
[[ "$STATUS" == "pass" ]] && exit 0 || exit 1
