#!/usr/bin/env bash
set -e

# ---------------- HELP ----------------
if [[ "$1" == "--help" ]]; then
cat <<EOF
Usage:
  $0 --repo <repo|dir> -b <branch> -m <commit message>
  $0 --repo <repo|dir> --pull

Options:
  --repo   Path to a single repo or folder containing multiple repos
  -b       Branch name to create/use
  -m       Commit message
  --pull   Fetch remote and hard-reset local repo to the remote default branch
  --help   Show this help message

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