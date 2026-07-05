# CLAUDE instructions

## Repository overview

This repository maintains a Docker-based development environment for agentic and full-stack engineering work.

## Maintenance guidance

- Keep the toolchain in both Dockerfiles in sync whenever possible.
- Prefer adding broadly useful developer tools that support web, backend, cloud, and AI workflows.
- Update the documentation when adding major capabilities.
- Ensure workflow paths and Dockerfile references match the repository layout.

## Common validation

When changing the container setup:

1. Review both Dockerfiles for parity.
2. Update the relevant GitHub Actions workflow if build context or file paths change.
3. Refresh the README and this file if the supported toolchain changes significantly.
