#!/usr/bin/env bash

# Fetch credentials with a 15-second timeout to avoid getting stuck if AWS endpoints are unreachable
if ! CREDS=$(timeout 15s aws sts get-session-token --duration-seconds 3600 --profile default 2>/dev/null); then
  echo "Error: Failed to fetch temporary AWS credentials or command timed out." >&2
  exit 1
fi

if [[ -z "$CREDS" ]]; then
  echo "Error: AWS credentials returned empty." >&2
  exit 1
fi

jq '{
  Version: 1,
  AccessKeyId: .Credentials.AccessKeyId,
  SecretAccessKey: .Credentials.SecretAccessKey,
  SessionToken: .Credentials.SessionToken,
  Expiration: .Credentials.Expiration
}' <<< "$CREDS"

