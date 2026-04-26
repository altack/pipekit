# syntax=docker/dockerfile:1.7
#
# Pipekit runner image.
#
# An isolated environment, not a curated toolchain. The image bakes in a small
# fixed set of always-on tools (shell utils, CI clients, browser, JS runtime,
# agent CLIs). Anything else a recipe needs (Python, Go, Ruby, language deps)
# is installed at runtime via the recipe's `setup.shell` block.
#
# Two-phase entrypoint:
#   Phase 1 — root  : parse recipe.yaml, run setup.shell, validate requires.*,
#                     resolve agent driver, exec into Phase 2 as `node`.
#   Phase 2 — node  : invoke driver, validate result.json, compute verdict.

FROM oven/bun:1 AS bun-stage

FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/home/node/.local/bin:/home/node/.claude/local:${PATH}" \
    IS_DEMO=1 \
    DISABLE_AUTOUPDATER=1 \
    AGENT_BROWSER_SESSION=pipekit \
    AGENT_BROWSER_DEFAULT_TIMEOUT=45000 \
    AGENT_BROWSER_IDLE_TIMEOUT_MS=600000 \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium

# NODE_ENV is deliberately NOT set — recipes may want devDependencies.

# ─── Always-on tools ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg jq openssh-client unzip \
      util-linux \
      chromium \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libgbm1 libasound2 libpango-1.0-0 libcairo2 \
    && rm -rf /var/lib/apt/lists/*

# yq for parsing recipe.yaml in pipekit-agent
RUN ARCH=$(dpkg --print-architecture) \
  && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
       -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

COPY --from=gitlab/glab:latest /usr/bin/glab /usr/local/bin/glab

COPY --from=bun-stage /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx

RUN corepack enable \
  && corepack prepare pnpm@latest --activate \
  && corepack prepare yarn@stable --activate

RUN mkdir -p /home/node/.ssh \
  && chmod 700 /home/node/.ssh \
  && ssh-keyscan github.com gitlab.com >> /home/node/.ssh/known_hosts 2>/dev/null \
  && chmod 644 /home/node/.ssh/known_hosts

# ─── Pipekit layout ────────────────────────────────────────────────────────
RUN mkdir -p /work /pipekit/recipes /pipekit/drivers /pipekit/lib \
  && mkdir -p /home/node/.cache /home/node/.claude /home/node/.local/bin \
  && chown -R node:node /work /pipekit /home/node

RUN npm install -g agent-browser

COPY --chown=node:node runner/pipekit-agent /usr/local/bin/pipekit-agent
COPY --chown=node:node runner/lib/          /pipekit/lib/
COPY --chown=node:node runner/recipes/      /pipekit/recipes/
COPY --chown=node:node runner/drivers/      /pipekit/drivers/
RUN chmod +x /usr/local/bin/pipekit-agent \
  && find /pipekit/drivers /pipekit/lib -name '*.sh' -exec chmod +x {} +

# ─── Bake the agent-browser skill (must run as node so it lands in node's home) ─
USER node
RUN mkdir -p /home/node/.claude/skills/agent-browser \
  && agent-browser skills get agent-browser --full \
       > /home/node/.claude/skills/agent-browser/SKILL.md

# Claude Code CLI via the native installer (writes under /home/node)
RUN curl -fsSL https://claude.ai/install.sh | bash

# ─── Switch back to root for the entrypoint ───────────────────────────────
# pipekit-agent's Phase 1 needs root to run setup.shell (apt-get, etc.) and to
# chown the workspace. It demotes to `node` via runuser before invoking the
# driver. The agent itself NEVER runs as root.
USER root
RUN chown -R node:node /home/node

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/pipekit-agent"]
