# dev-env

This repository builds a feature-rich development sandbox image for full-stack and AI-assisted engineering work. It includes two variants:

- Dockerfile: a container based on the sandbox template with a broad toolchain
- Dockerfile.ubuntu: an Ubuntu 24.04-based variant with the same core tooling

## Included tools

The image is intended for modern web and backend development and includes:

- Runtime and language support: Python, Node.js, Go, Ruby, Java 21, PHP, Rust
- Build tools: Maven, Gradle, npm, pnpm
- Databases and utilities: PostgreSQL client, MariaDB client, SQLite, Redis CLI
- Cloud and infrastructure: AWS CLI, kubectl, Helm, Ollama CLI
- Security and automation: Trufflehog, Claude Code CLI, git, curl, jq, ffmpeg, adb, fastboot

## Build locally

Build the default image:

```bash
docker build -t dev-env .
```

Build the Ubuntu variant:

```bash
docker build -f Dockerfile.ubuntu -t dev-env:ubuntu .
```

## AWS Secrets Injection

```bash
sbx secret set-custom -g --host '*.amazonaws.com' --env AWS_ACCESS_KEY_ID
```

```bash
sbx secret set-custom -g --host '*.amazonaws.com' --env AWS_SECRET_ACCESS_KEY
```

```bash
sbx secret ls
```

```bash
sbx secret rm -g --placeholder sb -f
```

## Run with Docker Sandbox (sbx)

Docker Sandbox (`sbx`) lets you run AI coding agents (such as Claude Code) in a secure, isolated microVM mapped to your workspace. This repository provides a complete **Docker Sandbox Kit** inside the `dev-env` directory.

### 1. Validate the Kit
Ensure you have the `sbx` CLI installed, then validate the kit:
```bash
sbx kit validate ./dev-env
```

### 2. Launch the Sandbox with the Kit
You can use the provided helper script to create and launch the sandbox. The script automatically configures persistent AWS Bedrock environment variables, injects necessary credentials, and launches Claude Code inside the sandbox with robust execution timeouts:
```bash
./scripts/claude-sbx.sh ~/path/to/my/project my-claude-sandbox
```

Alternatively, you can launch a sandbox using the `sbx` CLI directly with the `--kit` flag:
```bash
sbx run --kit ./dev-env claude
```

### Why Use the Sandbox Kit?
- **Isolation & Protection:** AI agents run inside a secure container boundary, protecting your host system from destructive operations.
- **Credential Safety:** Uses `sbx` host-side proxy credential injection. Raw API keys (AWS, Anthropic, OpenAI, GitHub) stay on your host and are never exposed inside the container environment.
- **Network Egress Control:** The agent's network traffic is restricted to trusted package managers (npm, pip, cargo, crates.io), code repositories (GitHub), and LLM endpoints.

## Run with Docker Compose

```bash
docker compose up -d
```

## CI/CD

GitHub Actions workflows in [.github/workflows](.github/workflows) build and publish the images to Docker Hub when the relevant files change.
