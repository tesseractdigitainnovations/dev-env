#!/usr/bin/env bash

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/../dev-env" && pwd)"

show_help() {
  echo "Usage: $0 <project_dir> <sandbox_name>"
  echo
  echo "Creates and configures a Docker sandbox for Claude with Bedrock integration."
  echo
  echo "Arguments:"
  echo "  <project_dir>   Directory to use for the sandbox context"
  echo "  <sandbox_name>  Name for the sandbox"
  echo
  echo "Options:"
  echo "  --help          Show this help message and exit"
}

# Check for --help or insufficient arguments
if [[ "$1" == "--help" ]]; then
  show_help
  exit 0
fi

if [[ $# -lt 2 ]]; then
  echo "Error: Missing required arguments."
  show_help
  exit 1
fi

PROJECT_DIR="$1"
SANDBOX_NAME="$2"

echo "Using project directory: $PROJECT_DIR"
echo "Sandbox name: $SANDBOX_NAME"
echo "Using kit directory: $KIT_DIR"

# Create the sandbox with custom kit
cd "$PROJECT_DIR" || { echo "Failed to navigate to $PROJECT_DIR"; exit 1; }

echo "Creating the sandbox with kit..."
if ! timeout 300s sbx create claude --name "$SANDBOX_NAME" --kit "$KIT_DIR" .; then
  echo "Error: Failed to create sandbox or command timed out."
  exit 1
fi

# Set persistent environment variables inside the sandbox
echo "Configuring persistent environment variables inside the sandbox..."
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export CLAUDE_CODE_USE_BEDROCK=1' >> /etc/sandbox-persistent.sh"
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export AWS_REGION=us-east-1' >> /etc/sandbox-persistent.sh"
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export AWS_PROFILE=claude-bedrock' >> /etc/sandbox-persistent.sh"
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-opus-4-5-20251101-v1:0' >> /etc/sandbox-persistent.sh"
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0' >> /etc/sandbox-persistent.sh"
timeout 30s sbx exec -d "$SANDBOX_NAME" bash -c "echo 'export ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-5' >> /etc/sandbox-persistent.sh"

# Copy AWS credentials/config and credential_process script into the sandbox if they exist on the host
echo "Setting up AWS credential access inside the sandbox..."
timeout 30s sbx exec -d "$SANDBOX_NAME" mkdir -p /home/agent/.aws

if [ -f "$HOME/.aws/config" ]; then
  timeout 30s sbx cp "$HOME/.aws/config" "$SANDBOX_NAME:/home/agent/.aws/config"
fi

if [ -f "$HOME/.aws/credentials" ]; then
  timeout 30s sbx cp "$HOME/.aws/credentials" "$SANDBOX_NAME:/home/agent/.aws/credentials"
fi

# Copy the fetch-temp-token.sh script
if [ -f "/opt/bin/fetch-temp-token.sh" ]; then
  timeout 30s sbx cp /opt/bin/fetch-temp-token.sh "$SANDBOX_NAME:/opt/fetch-temp-token.sh"
  timeout 30s sbx exec -d "$SANDBOX_NAME" chmod +x /opt/fetch-temp-token.sh
elif [ -f "$SCRIPT_DIR/fetch-temp-token.sh" ]; then
  timeout 30s sbx cp "$SCRIPT_DIR/fetch-temp-token.sh" "$SANDBOX_NAME:/opt/fetch-temp-token.sh"
  timeout 30s sbx exec -d "$SANDBOX_NAME" chmod +x /opt/fetch-temp-token.sh
fi

# Launch the agent
echo "Starting agent sandbox..."
sbx run --name "$SANDBOX_NAME" claude