# syntax=docker/dockerfile:1.7
#
# Pipekit runner image.
#
# Self-hosted "Managed Agents" sandbox: ships a Claude Code agent + agent-browser +
# common CI tooling. The container's only entrypoint is /usr/local/bin/pipekit-agent,
# which implements the contract documented in docs/contract.md.

FROM oven/bun:1 AS bun-stage

FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/node \
    PATH="/home/node/.local/bin:/home/node/.claude/local:${PATH}" \
    IS_DEMO=1 \
    DISABLE_AUTOUPDATER=1 \
    AGENT_BROWSER_SESSION=pipekit \
    AGENT_BROWSER_DEFAULT_TIMEOUT=45000 \
    AGENT_BROWSER_IDLE_TIMEOUT_MS=600000 \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium

# NODE_ENV is deliberately NOT set — consumer prompts may want devDependencies.

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq openssh-client unzip \
      chromium \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libgbm1 libasound2 libpango-1.0-0 libcairo2 \
    && rm -rf /var/lib/apt/lists/*

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

RUN mkdir -p /work /pipekit/prompts \
  && mkdir -p /home/node/.cache /home/node/.claude /home/node/.local/bin \
  && chown -R node:node /work /pipekit /home/node

RUN npm install -g agent-browser

COPY --chown=node:node runner/pipekit-agent /usr/local/bin/pipekit-agent
COPY --chown=node:node runner/prompts/      /pipekit/prompts/
RUN chmod +x /usr/local/bin/pipekit-agent

RUN chown -R node:node /home/node

USER node

# Bake the agent-browser skill so Claude Code auto-discovers it at session start.
RUN mkdir -p /home/node/.claude/skills/agent-browser \
  && agent-browser skills get agent-browser --full \
       > /home/node/.claude/skills/agent-browser/SKILL.md

RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/pipekit-agent"]
