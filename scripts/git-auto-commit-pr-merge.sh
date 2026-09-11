#!/usr/bin/env bash
set -e

# ---------------- HELP ----------------
if [[ "$1" == "--help" ]]; then
cat <<EOF
Usage:
  $0 --repo <repo|dir> -b <branch> -m <commit message>
  $0 --repo <repo|dir> --pull

Options:
  --repo            Path to a single repo or folder containing multiple repos
  -b                Branch name to create/use
  -m                Commit message
  --pull            Fetch remote and hard-reset local repo to the remote default branch
  --allow-ai-name   Permit an AI product name in the message (see ATTRIBUTION below)
  --help            Show this help message

Description:
  Normal mode will:
    1. Detect changes (including untracked files)
    2. Create branch if needed
    3. Commit changes
    4. Push branch
    5. Create a PR if missing
    6. Merge PR automatically (squash)
    7. Delete feature branch after merge

  --pull mode will:
    1. Detect the remote default branch
    2. Fetch origin
    3. Reset local repo exactly to origin/<default-branch>
    4. Remove untracked files/directories
    5. Remove ignored files/directories
    6. Leave the repo clean and synchronized with remote

ATTRIBUTION:
  Nothing pushed from here credits an AI, an LLM or the tool that ran it. The commit message,
  the PR title (which is the same string) and every commit already on the branch are checked
  before anything is created, and the run aborts on:

    - a Co-Authored-By / co-authored-with / co-written-with trailer of any kind
    - "generated with <tool>", "written by an LLM", "AI-assisted", "vibe coded", and the like
    - a 🤖 line, an assistant vendor's noreply address, or a claude.ai / chatgpt.com /
      gemini.google.com style link
    - the name of an assistant, agent or model: claude, chatgpt, gemini, copilot, codex,
      cursor, devin, llama, mistral, deepseek, grok, gpt-4/5, and others

  The last group — a bare product name — is the only one that has a legitimate use: a commit
  that genuinely changes AI-facing code ("add the Gemini provider adapter"). Pass
  --allow-ai-name for that, and only that. It never permits an attribution trailer; the other
  three groups cannot be overridden at all.

WARNING:
  --pull is destructive. Local uncommitted/unpushed changes will be lost.
EOF
    exit 0
fi

# ---------------- ARGUMENTS ----------------
TARGET=""
BRANCH=""
MESSAGE=""
PULL=false
ALLOW_AI_NAME=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      TARGET="$2"
      shift
      ;;
    -b)
      BRANCH="$2"
      shift
      ;;
    -m)
      MESSAGE="$2"
      shift
      ;;
    --pull)
      PULL=true
      ;;
    --allow-ai-name)
      ALLOW_AI_NAME=true
      ;;
    --help)
      exec "$0" --help
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$TARGET" ]]; then
  echo "Missing --repo. Use --help for usage."
  exit 1
fi

if [[ "$PULL" == false && ( -z "$BRANCH" || -z "$MESSAGE" ) ]]; then
  echo "Missing -b or -m. Use --help for usage."
  exit 1
fi

# ---------------- ATTRIBUTION GUARD ----------------
# Nothing pushed from here credits an AI, an LLM or the tool that ran it. There is no
# attribution channel in this script by design, so a trailer can only arrive by mistake —
# and a mistake that reaches origin costs a history rewrite, so it is caught up front.
#
# Two lists. The phrase list is attribution however it is worded, and cannot be waived. The
# name list is product names, which a commit touching AI-facing code may legitimately need;
# that one, and only that one, --allow-ai-name waives.

AI_NAME_RE='claude|chatgpt|openai|anthropic|copilot|gemini|bard|codex|cursor ai|windsurf|devin|aider|cline|tabnine|codewhisperer|perplexity|deepseek|mistral|llama|qwen|grok|gpt-?[0-9]|sonnet|opus [0-9]|haiku [0-9]'

AI_PHRASE_RE="co-?authored[ -]?(by|with)\
|co-?(written|created|developed)[ -]?(by|with)\
|(ai|a\.i\.|llm|bot|robot|machine|assistant|agent|model)[ -](generated|written|authored|assisted|crafted|created|made)\
|(generated|written|authored|created|drafted|produced|assisted|coded|built|made)([ -][a-z]+){0,3}[ -](with|by|using)([ -][a-z]+){0,3}[ -]($AI_NAME_RE)\
|(generated|written|authored|created|drafted|produced|assisted|coded)([ -][a-z]+){0,2}[ -](with|by|using)[ -](an? )?(ai|a\.i\.|llm|language model|chatbot|bot|assistant|agent)\b\
|with the help of (an? )?(ai|llm|assistant|agent|bot|model)\
|vibe[ -]?coded\
|noreply@(anthropic|openai)\.com\
|claude\.ai|claude\.com/claude-code|chatgpt\.com|chat\.openai\.com|gemini\.google\.com|copilot\.github\.com"

# Prints why `$1` reads as AI attribution, or nothing when it is clean.
ai_attribution_reason() {
  local text lower
  text="$1"
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

  # Robot and android emoji, the usual "generated with" footer garnish.
  if [[ "$text" == *"🤖"* || "$text" == *"🦾"* || "$text" == *"🧠"* ]]; then
    echo "a robot/AI emoji"
    return 0
  fi

  local hit
  hit=$(printf '%s' "$lower" | grep -Eio "$AI_PHRASE_RE" | head -1 || true)
  if [[ -n "$hit" ]]; then
    echo "an attribution phrase (\"$hit\")"
    return 0
  fi

  if [[ "$ALLOW_AI_NAME" == false ]]; then
    # A filename or a config path is not attribution: CLAUDE.md, .claude/settings.json and
    # copilot-instructions.md name a file the change edits, so they come out before the scan.
    local scrubbed
    scrubbed=$(printf '%s' "$lower" |
      sed -E "s/($AI_NAME_RE)[-_.a-z0-9]*\.(md|mdx|json|ya?ml|toml|txt|sh|ts|js|py)//g" |
      sed -E "s#\.?($AI_NAME_RE)/[-_./a-z0-9]*##g")
    hit=$(printf '%s' "$scrubbed" | grep -Eiow "$AI_NAME_RE" | head -1 || true)
    if [[ -n "$hit" ]]; then
      echo "the name of an AI assistant or model (\"$hit\") — pass --allow-ai-name if the change itself is about $hit"
      return 0
    fi
  fi

  return 1
}

# Aborts the run. `$1` is what was checked, `$2` the reason, `$3` the offending text.
reject_attribution() {
  echo "✖ Refusing to push: $1 carries $2" >&2
  echo >&2
  printf '  %s\n' "$3" >&2
  echo >&2
  echo "  Commits and PRs from this script name no assistant, model or tool — write the" >&2
  echo "  message as the author of the change. See --help (ATTRIBUTION)." >&2
  exit 1
}

if [[ "$PULL" == false ]]; then
  if reason=$(ai_attribution_reason "$MESSAGE"); then
    reject_attribution "the commit message" "$reason" "$MESSAGE"
  fi
fi

# ---------------- PULL FUNCTION ----------------
pull_repo() {
  local repo="$1"

  echo "---- Syncing $repo ----"

  [[ -d "$repo/.git" ]] || {
    echo "Not a git repo, skipping"
    return
  }

  cd "$repo"

  # Detect default branch
  DEFAULT_BRANCH=$(git remote show origin 2>/dev/null |
    sed -n '/HEAD branch/s/.*: //p')

  if [[ -z "$DEFAULT_BRANCH" ]]; then
    echo "Could not determine default branch for $repo"
    cd - >/dev/null
    return 1
  fi

  echo "Remote default branch: $DEFAULT_BRANCH"

  # Fetch everything from origin and prune deleted refs
  git fetch origin --prune

  # Make sure the remote default branch actually exists
  if ! git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
    echo "Remote branch origin/$DEFAULT_BRANCH not found"
    cd - >/dev/null
    return 1
  fi

  echo "Resetting local repository to origin/$DEFAULT_BRANCH"

  # Exact remote state
  git reset --hard "origin/$DEFAULT_BRANCH"

  # Remove untracked files/directories
  git clean -fd

  # Also remove ignored files/directories.
  # This makes the working tree genuinely reproducible for fresh sandboxes.
  git clean -fdx

  echo "✔ Synced $repo to origin/$DEFAULT_BRANCH"

  cd - >/dev/null
}

# ---------------- NORMAL FUNCTION ----------------
process_repo() {
  local repo="$1"

  echo "---- Processing $repo ----"

  [[ -d "$repo/.git" ]] || {
    echo "Not a git repo, skipping"
    return
  }

  cd "$repo"

  # Detect default branch
  DEFAULT_BRANCH=$(git remote show origin |
    sed -n '/HEAD branch/s/.*: //p')

  if [[ -z "$DEFAULT_BRANCH" ]]; then
    echo "Could not determine default branch"
    cd - >/dev/null
    return 1
  fi

  # Detect changes including untracked files
  UNTRACKED=$(git ls-files --others --exclude-standard)

  if git diff --quiet &&
     git diff --cached --quiet &&
     [[ -z "$UNTRACKED" ]]; then
    echo "No changes found"
    cd - >/dev/null
    return
  fi

  CURRENT_BRANCH=$(git branch --show-current)

  # Create or switch branch
  if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git checkout "$BRANCH"
    else
      git checkout -b "$BRANCH"
    fi
  fi

  # The branch may already carry commits this script did not write — another tool, an earlier
  # session, a rebase. Their messages go out with this push and end up in the squash body, so
  # they are held to the same rule as the message above.
  if git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
    for sha in $(git rev-list "HEAD" --not "origin/$DEFAULT_BRANCH"); do
      subject=$(git log -1 --format=%s "$sha")
      if reason=$(ai_attribution_reason "$(git log -1 --format=%B "$sha")"); then
        reject_attribution "commit ${sha:0:8} already on $BRANCH" "$reason" "${sha:0:8} $subject"
      fi
    done
  fi

  # Stage all changes including untracked
  git add -A

  git commit -m "$MESSAGE"

  # Push branch
  git push -u origin "$BRANCH"

  # Create PR if not exists
  if ! gh pr view "$BRANCH" >/dev/null 2>&1; then
    gh pr create \
      --base "$DEFAULT_BRANCH" \
      --head "$BRANCH" \
      --title "$MESSAGE" \
      --body "Automated PR"
  fi

  # Merge PR

  # Merge PR. --auto queues the merge behind required status checks, but it only
  # exists when the repo has auto-merge switched on (Settings -> General -> Allow
  # auto-merge); elsewhere GitHub refuses the mutation outright, so fall back to
  # merging now.
  if ! gh pr merge "$BRANCH" --squash --delete-branch --auto; then
    echo "Auto-merge unavailable on this repo, merging directly"
    gh pr merge "$BRANCH" --squash --delete-branch
  fi

  echo "✔ Merged $repo"

  cd - >/dev/null
}

# ---------------- SINGLE OR MULTI REPO ----------------
if [[ "$PULL" == true ]]; then

  if [[ -d "$TARGET/.git" ]]; then
    pull_repo "$TARGET"
  else
    for r in "$TARGET"/*; do
      [[ -d "$r/.git" ]] && pull_repo "$r"
    done
  fi

else

  if [[ -d "$TARGET/.git" ]]; then
    process_repo "$TARGET"
  else
    for r in "$TARGET"/*; do
      [[ -d "$r" ]] && process_repo "$r"
    done
  fi

fi