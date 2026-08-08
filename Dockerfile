FROM docker/sandbox-templates:shell-docker

# Switch to root to perform system-level installations
USER root

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install core system tools and dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    jq \
    unzip \
    zstd \
    python3-pip \
    python3-venv \
    ruby-full \
    ffmpeg \
    adb \
    fastboot \
    golang-go \
    build-essential \
    openjdk-21-jdk \
    maven \
    gradle \
    php-cli \
    php-curl \
    php-xml \
    php-mbstring \
    php-zip \
    php-mysql \
    postgresql-client \
    mariadb-client \
    sqlite3 \
    redis-tools \
    rustc \
    cargo \
    fish \ 
    nano \
    vim \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

ENV CGO_ENABLED=0

# Create directory structure for tools and ensure they are owned by agent
RUN mkdir -p /opt/tools /opt/dev-env-venv

# create venv for the agent user
RUN python3 -m venv /opt/dev-env-venv && \
    /opt/dev-env-venv/bin/pip install --upgrade pip setuptools wheel

# Install Trufflehog for Linux
RUN echo "Installing Trufflehog..." && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        ARCH="arm64"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/trufflesecurity/trufflehog/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/') && \
    wget "https://github.com/trufflesecurity/trufflehog/releases/download/v${LATEST_VERSION}/trufflehog_${LATEST_VERSION}_linux_${ARCH}.tar.gz" -O /tmp/trufflehog.tar.gz && \
    tar -xzf /tmp/trufflehog.tar.gz -C /usr/local/bin/ trufflehog && \
    chmod +x /usr/local/bin/trufflehog && \
    rm /tmp/trufflehog.tar.gz

# Install AWS CLI v2
RUN echo "Installing AWS CLI v2..." && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# Install Ollama CLI client
RUN echo "Installing Ollama CLI client..." && \
    curl -fsSL https://ollama.com/install.sh | sh

# Install Kubernetes tooling
RUN echo "Installing kubectl and Helm..." && \
    curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install GitHub CLI
RUN echo "Installing GitHub CLI..." && \
    mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh

# Configure Node/NPM via NVM for agent user
ENV NVM_DIR=/home/agent/.nvm
RUN mkdir -p $NVM_DIR && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash && \
    . "$NVM_DIR/nvm.sh" && \
    unset NPM_CONFIG_PREFIX && \
    nvm install 24 && \
    nvm use 24 && \
    nvm alias default 24 && \
    npm install -g npm@latest && \
    npm install -g pnpm@latest

# Create and configure Claude harness directory
RUN mkdir -p /home/agent/.claude/agents \
             /home/agent/.claude/skills 

# Ensure proper user/group permissions for the entire filesystem including copied files
RUN chown -R agent:agent /home/agent && \
    chown -R agent:agent /opt/tools && \
    chown -R agent:agent /opt/dev-env-venv

# Switch to the non-root agent user (UID 1000)
USER agent

# Configure Go, Node (NVM), and user bin paths
ENV GOPATH=/home/agent/go
ENV PATH=$PATH:/usr/local/go/bin:/home/agent/go/bin:/opt/dev-env-venv/bin:/home/agent/.nvm/versions/node/v24.18.0/bin:/home/agent/.local/bin:/home/agent/.local/share/pnpm/bin

# Install Claude Code CLI as the agent user to avoid permission/broken path warnings
RUN echo "Installing Claude Code CLI..." && \
    curl -fsSL https://claude.ai/install.sh | bash

# Bootstrap requested global skills and marketplace plugins
RUN echo "Installing Claude skills and plugins..." && \
    mkdir -p /home/agent/.claude/skills && \
    (npx skills add jeffallan/claude-skills --global || true) && \
    (npx skills add Kadajett/agent-nestjs-skills || true) && \
    (npx skills add Kadajett/agent-nestjs-skills --global || true) && \
    (npx skills add https://github.com/vercel-labs/skills --skill find-skills || true) && \
    (claude plugin marketplace add jeffallan/claude-skills || true) && \
    (claude plugin install fullstack-dev-skills@jeffallan || true) && \
    (claude plugin marketplace add fallow-rs/fallow-skills || true) && \
    (claude plugin install fallow-skills@fallow-rs/fallow-skills || true)

COPY .claude/settings.json /home/agent/.claude/settings.json

# Automatically activate virtual environment and load NVM in any bash/sh session
RUN echo "source /opt/dev-env-venv/bin/activate" >> /home/agent/.bashrc && \
    echo "source /opt/dev-env-venv/bin/activate" >> /home/agent/.profile && \
    echo 'export NVM_DIR="$HOME/.nvm"' >> /home/agent/.bashrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /home/agent/.bashrc && \
    echo 'export NVM_DIR="$HOME/.nvm"' >> /home/agent/.profile && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /home/agent/.profile

ENV CLAUDE_HARNESS_DIR=/home/agent/.claude
ENV CLAUDE_HARNESS_AGENTS_DIR=/home/agent/.claude/agents
ENV CLAUDE_HARNESS_SKILLS_DIR=/home/agent/.claude/skills
ENV CLAUDE_HARNESS_AGENT_NAME=x-dev
ENV CLAUDE_HARNESS_AGENT_DESCRIPTION="dev-env: A secure, isolated, and fully-featured sandbox environment for executing doing yolo agentic fullstack development."
ENV CLAUDE_HARNESS_AGENT_VERSION=1.0.0
ENV CLAUDE_HARNESS_AGENT_AUTHOR="DevOps Admin <devops.admin@tdi.solutions>"

ENV NPM_CONFIG_PREFIX=

# Default working directory inside the sandbox
WORKDIR /workspace