#!/usr/bin/env bash
# claude-code driver. Drives Anthropic's Claude Code CLI.
#
# Inputs (env, set by pipekit-agent):
#   PIPEKIT_WORKSPACE   workspace dir (cwd)
#   PIPEKIT_MODEL       model id or alias (default: opus)
#   PIPEKIT_MAX_TURNS   safety cap (default: 200)
#   ANTHROPIC_API_KEY   credential
# Args:
#   $1                  path to the system prompt .md file
#
# Writes:
#   $PIPEKIT_WORKSPACE/agent.jsonl   raw stream-json from claude
# The prompt is responsible for writing $PIPEKIT_WORKSPACE/result.json.

set -euo pipefail

PROMPT_PATH="${1:?prompt path required}"
WORKSPACE="${PIPEKIT_WORKSPACE:?required}"
MODEL="${PIPEKIT_MODEL:-opus}"
MAX_TURNS="${PIPEKIT_MAX_TURNS:-200}"

TASK="Run the pipekit task. Inputs are at ${WORKSPACE}/inputs.json. Write your verdict to ${WORKSPACE}/result.json before exiting. Drop any evidence files under ${WORKSPACE}/artifacts/."

ARGS=(
  -p
  --output-format stream-json
  --verbose
  --permission-mode bypassPermissions
  --dangerously-skip-permissions
  --tools "Bash,Read,Edit,Write,Glob,Grep,WebFetch"
  --max-turns "$MAX_TURNS"
  --append-system-prompt-file "$PROMPT_PATH"
  --model "$MODEL"
)

set +e
claude "${ARGS[@]}" "$TASK" \
  | tee "$WORKSPACE/agent.jsonl"
EXIT=${PIPESTATUS[0]}
set -e
exit $EXIT
