FROM ubuntu:24.04 AS claude-installer

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash

# Main image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV NVM_DIR=/usr/local/nvm
ENV BUN_INSTALL=/usr/local/bun

# Install system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essentials
    bash \
    ca-certificates \
    curl \
    wget \
    git \
    sudo \
    # Build tools
    build-essential \
    make \
    cmake \
    pkg-config \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Common utilities
    jq \
    ripgrep \
    fd-find \
    fzf \
    tree \
    htop \
    vim \
    nano \
    less \
    openssh-client \
    gnupg \
    unzip \
    zip \
    # For native node modules
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv (latest)
# Installs via Astral's installer, then places binaries in /usr/local/bin for all users.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && for b in uv uvx; do \
         if [ -f "/root/.local/bin/$b" ]; then install -m 0755 "/root/.local/bin/$b" "/usr/local/bin/$b"; fi; \
       done \
    && rm -rf /root/.local/share/uv /root/.local/bin/uv /root/.local/bin/uvx

# Install bun (latest)
RUN mkdir -p "$BUN_INSTALL" \
    && curl -fsSL https://bun.sh/install | bash \
    && chmod -R a+rX "$BUN_INSTALL" \
    && ln -sf "$BUN_INSTALL/bin/bun" /usr/local/bin/bun \
    && ln -sf "$BUN_INSTALL/bin/bunx" /usr/local/bin/bunx
ENV PATH="$BUN_INSTALL/bin:$PATH"

# Install nvm, then use it to install the latest Node.js LTS and set it as default
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash \
    && bash -lc 'source "$NVM_DIR/nvm.sh" \
      && nvm install --lts \
      && nvm alias default "lts/*" \
      && nvm use default \
      && DEFAULT_NODE="$(nvm version default)" \
      && ln -sf "$NVM_DIR/versions/node/$DEFAULT_NODE/bin/node" /usr/local/bin/node \
      && ln -sf "$NVM_DIR/versions/node/$DEFAULT_NODE/bin/npm" /usr/local/bin/npm \
      && ln -sf "$NVM_DIR/versions/node/$DEFAULT_NODE/bin/npx" /usr/local/bin/npx \
      && if [ -f "$NVM_DIR/versions/node/$DEFAULT_NODE/bin/corepack" ]; then ln -sf "$NVM_DIR/versions/node/$DEFAULT_NODE/bin/corepack" /usr/local/bin/corepack; fi \
      && node -v \
      && npm -v' \
    && chmod -R a+rX "$NVM_DIR" \
    && printf '%s\n' \
      "export NVM_DIR=\"$NVM_DIR\"" \
      '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
      '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"' \
      > /etc/profile.d/nvm.sh

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install global npm packages and AI CLIs
RUN npm install -g \
    typescript \
    ts-node \
    yarn \
    pnpm \
    @google/gemini-cli \
    @openai/codex

# Create yolo user with passwordless sudo
RUN useradd -m -s /bin/bash yolo \
    && echo "yolo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/yolo \
    && chmod 0440 /etc/sudoers.d/yolo

# Set up directories
RUN mkdir -p /workspace /output /secrets \
    && chown yolo:yolo /workspace /output

# Copy Claude Code from installer stage
COPY --from=claude-installer /root/.local/bin/claude /usr/local/bin/claude

USER yolo

# Create symlink for Claude at ~/.local/bin (host config expects it there)
RUN mkdir -p /home/yolo/.local/bin && \
    ln -s /usr/local/bin/claude /home/yolo/.local/bin/claude
WORKDIR /home/yolo

# Set up a fun prompt and aliases
RUN echo 'PS1="\\[\\033[35m\\]yolo\\[\\033[0m\\]:\\[\\033[36m\\]\\w\\[\\033[0m\\] 🎲 "' >> ~/.bashrc \
    && echo 'alias ll="ls -la"' >> ~/.bashrc \
    && echo 'alias la="ls -A"' >> ~/.bashrc \
    && echo 'alias l="ls -CF"' >> ~/.bashrc \
    && echo 'alias yeet="rm -rf"' >> ~/.bashrc

# AI CLI wrappers in yolo mode - these find the real binary dynamically,
# so they survive updates (npm update -g, claude upgrade, etc.)
USER root
RUN mkdir -p /opt/yolobox/bin

# Generic wrapper template that finds real binary by excluding wrapper dir from PATH
RUN echo '#!/bin/bash' > /opt/yolobox/wrapper-template \
    && echo 'WRAPPER_DIR=/opt/yolobox/bin' >> /opt/yolobox/wrapper-template \
    && echo 'CMD=$(basename "$0")' >> /opt/yolobox/wrapper-template \
    && echo 'CLEAN_PATH=$(echo "$PATH" | tr ":" "\n" | grep -v "^$WRAPPER_DIR$" | tr "\n" ":" | sed "s/:$//" )' >> /opt/yolobox/wrapper-template \
    && echo 'REAL_BIN=$(PATH="$CLEAN_PATH" which "$CMD" 2>/dev/null)' >> /opt/yolobox/wrapper-template \
    && echo 'if [ -z "$REAL_BIN" ]; then echo "Error: $CMD not found" >&2; exit 1; fi' >> /opt/yolobox/wrapper-template

# Claude wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/claude \
    && echo 'exec "$REAL_BIN" --dangerously-skip-permissions "$@"' >> /opt/yolobox/bin/claude \
    && chmod +x /opt/yolobox/bin/claude

# Codex wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/codex \
    && echo 'exec "$REAL_BIN" --dangerously-bypass-approvals-and-sandbox "$@"' >> /opt/yolobox/bin/codex \
    && chmod +x /opt/yolobox/bin/codex

# Gemini wrapper
RUN cp /opt/yolobox/wrapper-template /opt/yolobox/bin/gemini \
    && echo 'exec "$REAL_BIN" --yolo "$@"' >> /opt/yolobox/bin/gemini \
    && chmod +x /opt/yolobox/bin/gemini

# Add wrapper dir and ~/.local/bin to PATH (wrappers take priority)
ENV PATH="/opt/yolobox/bin:/home/yolo/.local/bin:$PATH"

USER yolo

# Welcome message
RUN echo 'echo ""' >> ~/.bashrc \
    && echo 'echo -e "\\033[1;35m  Welcome to yolobox!\\033[0m"' >> ~/.bashrc \
    && echo 'echo -e "\\033[33m  Your home directory is safe. Go wild.\\033[0m"' >> ~/.bashrc \
    && echo 'echo ""' >> ~/.bashrc

# Create entrypoint script
USER root
RUN mkdir -p /host-claude && \
    printf '%s\n' \
    '#!/bin/bash' \
    '' \
    '# Copy Claude config from host staging area if present' \
    'if [ -d /host-claude/.claude ] || [ -f /host-claude/.claude.json ]; then' \
    '    echo -e "\033[33m→ Copying host Claude config to container\033[0m" >&2' \
    'fi' \
    'if [ -d /host-claude/.claude ]; then' \
    '    sudo rm -rf /home/yolo/.claude' \
    '    sudo cp -a /host-claude/.claude /home/yolo/.claude' \
    '    sudo chown -R yolo:yolo /home/yolo/.claude' \
    'fi' \
    'if [ -f /host-claude/.claude.json ]; then' \
    '    sudo rm -f /home/yolo/.claude.json' \
    '    sudo cp -a /host-claude/.claude.json /home/yolo/.claude.json' \
    '    sudo chown yolo:yolo /home/yolo/.claude.json' \
    'fi' \
    '' \
    '# Auto-trust /workspace for Claude Code (this is yolobox after all)' \
    'CLAUDE_JSON="/home/yolo/.claude.json"' \
    'if [ ! -f "$CLAUDE_JSON" ]; then' \
    '    echo '"'"'{"projects":{}}'"'"' > "$CLAUDE_JSON"' \
    'fi' \
    '# Add /workspace as trusted project' \
    'if command -v jq &> /dev/null; then' \
    '    TMP=$(mktemp)' \
    '    jq '"'"'.projects["/workspace"] = (.projects["/workspace"] // {}) + {"hasTrustDialogAccepted": true}'"'"' "$CLAUDE_JSON" > "$TMP" && mv "$TMP" "$CLAUDE_JSON"' \
    '    chown yolo:yolo "$CLAUDE_JSON"' \
    'fi' \
    '' \
    'exec "$@"' \
    > /usr/local/bin/yolobox-entrypoint.sh && \
    chmod +x /usr/local/bin/yolobox-entrypoint.sh
USER yolo

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/yolobox-entrypoint.sh"]
CMD ["bash"]
