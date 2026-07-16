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

RUN mkdir -p /workspace /home/$USERNAME/.claude && \
  chown -R $USERNAME:$USERNAME /workspace /home/$USERNAME/.claude

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

RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.0/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a'" \
  -a "export HISTFILE=/commandhistory/.bash_history" \
  -x

RUN npm install -g @anthropic-ai/claude-code
