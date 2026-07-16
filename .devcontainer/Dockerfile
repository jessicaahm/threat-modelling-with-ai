FROM node:20

ARG TZ
ENV TZ="$TZ"

RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  ca-certificates \
  curl \
  wget \
  pipx \
  && rm -rf /var/lib/apt/lists/*

ARG USERNAME=node

# HashiCorp apt repo for the Vault Radar CLI (secret-scanning pre-commit hook)
# and the Vault CLI (used by init-script.sh to bootstrap KV v2 mounts/policies).
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
  . /etc/os-release && \
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $VERSION_CODENAME main" > /etc/apt/sources.list.d/hashicorp.list && \
  apt-get update && apt-get install -y --no-install-recommends vault-radar vault && \
  # The vault package sets file capability cap_ipc_lock=ep (for `vault server`
  # to mlock memory without running as root). This container's capability
  # bounding set doesn't include cap_ipc_lock, so execve() rejects the binary
  # outright with EPERM. Strip it -- irrelevant here since only the CLI
  # (client) is used against a remote HCP Vault cluster, never `vault server`.
  setcap -r /usr/bin/vault && \
  rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/share/npm-global && chown -R $USERNAME:$USERNAME /usr/local/share/npm-global

# Bash history survives container rebuilds via the /commandhistory volume.
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Claude Code reads this to know it is running in a container.
ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/$USERNAME/.claude /home/$USERNAME/.codex && \
  chown -R $USERNAME:$USERNAME /workspace /home/$USERNAME/.claude /home/$USERNAME/.codex

WORKDIR /workspace

COPY init-firewall.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/init-firewall.sh && \
  echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/$USERNAME-firewall && \
  chmod 0440 /etc/sudoers.d/$USERNAME-firewall

USER $USERNAME

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin:/home/$USERNAME/.local/bin
ENV SHELL=/bin/zsh

RUN pipx install pre-commit

# Scanner toolchain for the vulnerability-checker agent (agent/vuln_agent):
# Semgrep for SAST, Trivy for dependency/SCA scanning. Trivy ships as a
# GitHub release binary (no apt repo pinning needed); version pinned so the
# eval harness expectations stay stable.
RUN pipx install semgrep==1.170.0
ARG TRIVY_VERSION=0.72.0
RUN arch="$(dpkg --print-architecture)" && \
  case "$arch" in \
    amd64) t="Linux-64bit" ;; \
    arm64) t="Linux-ARM64" ;; \
    *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
  esac && \
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${t}.tar.gz" \
    | tar -xz -C /home/$USERNAME/.local/bin trivy && \
  # Pre-bake the vulnerability DB so scans are offline-deterministic under
  # the egress firewall; refresh happens on image rebuild (or in CI).
  /home/$USERNAME/.local/bin/trivy image --download-db-only --cache-dir /home/$USERNAME/.cache/trivy || true

# Vault Radar MCP server binary (used directly by .mcp.json's stdio transport --
# no Docker required/available in this devcontainer).
ARG VAULT_RADAR_MCP_SERVER_VERSION=1.0.0
RUN arch="$(dpkg --print-architecture)" && \
  curl -fsSL "https://releases.hashicorp.com/vault-radar-mcp-server/${VAULT_RADAR_MCP_SERVER_VERSION}/vault-radar-mcp-server_${VAULT_RADAR_MCP_SERVER_VERSION}_linux_${arch}.zip" \
    -o /tmp/vault-radar-mcp-server.zip && \
  unzip -o /tmp/vault-radar-mcp-server.zip -d /home/$USERNAME/.local/bin && \
  rm /tmp/vault-radar-mcp-server.zip && \
  chmod 0755 /home/$USERNAME/.local/bin/vault-radar-mcp-server

RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.0/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a'" \
  -a "export HISTFILE=/commandhistory/.bash_history" \
  -x

RUN npm install -g @anthropic-ai/claude-code

# OpenAI Codex CLI. Auth uses "Sign in with ChatGPT" (subscription) and caches
# tokens in $CODEX_HOME/auth.json, persisted via the .codex volume mounted in
# devcontainer.json. The sign-in flow's localhost callback rides VS Code's
# automatic port forwarding, and egress to auth.openai.com / chatgpt.com is
# opened in init-firewall.sh.
RUN npm install -g @openai/codex
