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

## Run with Docker Compose

```bash
docker compose up -d
```

## CI/CD

GitHub Actions workflows in [.github/workflows](.github/workflows) build and publish the images to Docker Hub when the relevant files change.
