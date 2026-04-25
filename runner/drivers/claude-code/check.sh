#!/usr/bin/env bash
# Returns 0 if claude-code is usable: CLI on PATH and ANTHROPIC_API_KEY set.
set -euo pipefail
command -v claude >/dev/null || exit 1
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || exit 1
