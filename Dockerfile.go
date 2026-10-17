# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

LABEL maintainer="DevOps Admin <devops.admin@tdi.solutions>"
LABEL description="dev-env: Go / Golang development sandbox environment"

ENV DEBIAN_FRONTEND=noninteractive

# Core system tools and C compilation tools (required for CGO)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    wget \
    jq \
    unzip \
    ca-certificates \
    gnupg \
    sudo \
    nano \
    vim \
    less \
    && rm -rf /var/lib/apt/lists/*

ARG GO_VERSION=1.23.2
ARG TARGETARCH

# Install official Go distribution (arch-aware)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then GO_ARCH="amd64"; elif [ "$ARCH" = "arm64" ]; then GO_ARCH="arm64"; else GO_ARCH="${TARGETARCH:-amd64}"; fi && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" | tar -C /usr/local -xz

# Install Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    ARCH=$(dpkg --print-architecture) && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then AWS_ARCH="x86_64"; else AWS_ARCH="aarch64"; fi && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# Configure agent user (UID 1000)
RUN userdel -r ubuntu 2>/dev/null || true
RUN groupadd -f docker && \
    useradd -m -u 1000 -s /bin/bash -G docker agent && \
    mkdir -p /home/agent/.claude/agents \
             /home/agent/.claude/skills \
             /home/agent/.local/bin \
             /home/agent/.aws \
             /home/agent/go/bin \
             /home/agent/go/src \
             /home/agent/go/pkg \
             /opt/tools \
             /workspace && \
    chown -R agent:agent /home/agent /opt/tools /workspace

RUN echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent

# Install Claude Code CLI
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    CLAUDE_SRC="/root/.local/bin/claude" && \
    if [ -e "$CLAUDE_SRC" ]; then \
        CLAUDE_REAL="$(readlink -f "$CLAUDE_SRC")" && \
        mkdir -p /opt/claude-code && \
        cp -a "$(dirname "$CLAUDE_REAL")/." /opt/claude-code/ && \
        ln -sf "/opt/claude-code/$(basename "$CLAUDE_REAL")" /usr/local/bin/claude && \
        chmod -R a+rX /opt/claude-code; \
    fi

# Copy configuration and helper scripts
COPY config /home/agent/.aws/config
COPY scripts/fetch-temp-token.sh /home/agent/.local/bin/fetch-temp-token.sh
COPY scripts/git-auto-commit-pr-merge.sh /home/agent/.local/bin/git-auto-commit-pr-merge.sh
COPY scripts/install-skills.sh /home/agent/.local/bin/install-skills.sh
COPY skills.lock.yaml /home/agent/.claude/skills.lock.yaml
COPY .claude/settings.json /home/agent/.claude/settings.json

RUN chown -R agent:agent /home/agent/.aws /home/agent/.local /home/agent/.claude && \
    chmod 600 /home/agent/.aws/* && \
    chmod 700 /home/agent/.aws && \
    chmod +x /home/agent/.local/bin/*.sh

USER agent
WORKDIR /workspace

ENV GOPATH=/home/agent/go \
    GOBIN=/home/agent/go/bin \
    CGO_ENABLED=1 \
    PATH=/usr/local/go/bin:/home/agent/go/bin:/home/agent/.local/bin:$PATH \
    CLAUDE_HARNESS_DIR=/home/agent/.claude \
    CLAUDE_HARNESS_AGENTS_DIR=/home/agent/.claude/agents \
    CLAUDE_HARNESS_SKILLS_DIR=/home/agent/.claude/skills \
    CLAUDE_HARNESS_AGENT_NAME=x-dev-go \
    CLAUDE_HARNESS_AGENT_DESCRIPTION="dev-env: Go/Golang sandbox"

# Install essential Go developer tools
RUN go install golang.org/x/tools/gopls@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest && \
    go install github.com/air-verse/air@latest && \
    go install gotest.tools/gotestsum@latest && \
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin

# Bootstrap skills (best-effort at build time)
RUN /home/agent/.local/bin/install-skills.sh || true

CMD ["/bin/bash"]
