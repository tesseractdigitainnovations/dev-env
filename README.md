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

## Claude skills

A curated skill set (agent workflow, TypeScript/Node/NestJS, Python, Postgres/TypeORM, Docker/Kubernetes/CI, OpenTelemetry, API security, testing, React/Next/Vercel, Expo, browser automation, research) is baked into `/home/agent/.claude/skills` at build time by [scripts/install-skills.sh](scripts/install-skills.sh), driven by [skills.lock.yaml](skills.lock.yaml).

Two reasons it works this way rather than calling `skills add` at sandbox launch:

- **No launch-time hang.** The `skills` CLI prompts for install scope and target agent when it cannot detect an agent, which blocks a non-interactive startup indefinitely.
- **Pinned and reviewed.** Every entry carries the exact commit it was reviewed at. `skills add` has no way to pin a revision — it always takes upstream HEAD, so a rebuild could pull in unreviewed changes. The script fetches each locked SHA, verifies it, and copies the reviewed tree in.

### Lockfile

Each entry records `repo`, `skill`, `ref` (commit) and `reviewed` (the date that skill's SKILL.md, references and bundled scripts were audited at that ref). The audit checks for reads of sensitive files and config (`~/.aws`, `~/.ssh`, `.npmrc`, kubeconfig, `.claude.json`, token env vars, shell history), outbound network calls or data exfiltration, and recommendations to install non-official tooling. **Bumping a `ref` invalidates its review** — re-audit and update `reviewed`.

Skills installed but no longer named in the lockfile are unreviewed by definition, so they are pruned. To add a skill: review it, add an entry with the commit you reviewed, rebuild.

```bash
install-skills.sh                  # skips anything already at its locked ref
SKILLS_PRUNE=0 install-skills.sh   # keep hand-added skills that aren't locked
SKILLS_STRICT=1 install-skills.sh  # fail the build if any skill fails
```

Installed refs are tracked in `/home/agent/.claude/skills/.skills-installed.tsv`, so a ref bump is detected and replaced rather than skipped.

### Finding candidates

`skills.sh` is allowlisted in the sandbox spec. Note that `npx skills find <query>` currently returns no results for any query even with the registry reachable; listing a repo works:

```bash
npx skills add <repo-url> --list
```

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
