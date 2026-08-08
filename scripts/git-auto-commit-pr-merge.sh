#!/usr/bin/env bash
set -e

# ---------------- HELP ----------------
if [[ "$1" == "--help" ]]; then
cat <<EOF
Usage: $0 --repo <repo|dir> -b <branch> -m <commit message>

Options:
  --repo   Path to a single repo or folder containing multiple repos
  -b       Branch name to create/use
  -m       Commit message
  --help   Show this help message

Description:
  This script will:
    1. Detect changes (including untracked files)
    2. Create branch if needed
    3. Commit changes
    4. Push branch
    5. Create a PR if missing
    6. Merge PR automatically (squash)
    7. Delete feature branch after merge
EOF
    exit 0
fi

# ---------------- ARGUMENTS ----------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --repo) TARGET="$2"; shift ;;
    -b) BRANCH="$2"; shift ;;
    -m) MESSAGE="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$TARGET" || -z "$BRANCH" || -z "$MESSAGE" ]]; then
  echo "Missing arguments. Use --help for usage."
  exit 1
fi

# ---------------- FUNCTION ----------------
process_repo() {
  local repo="$1"
  echo "---- Processing $repo ----"

  [[ -d "$repo/.git" ]] || { echo "Not a git repo, skipping"; return; }
  cd "$repo"

  # Detect default branch
  DEFAULT_BRANCH=$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')

  # Detect changes including untracked files
  UNTRACKED=$(git ls-files --others --exclude-standard)
  if git diff --quiet && git diff --cached --quiet && [[ -z "$UNTRACKED" ]]; then
    echo "No changes found"
    cd - >/dev/null
    return
  fi

  CURRENT_BRANCH=$(git branch --show-current)

  # Create or switch branch
  if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    if git show-ref --verify --quiet refs/heads/$BRANCH; then
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
  gh pr merge "$BRANCH" \
    --squash \
    --delete-branch \
    --auto

  echo "✔ Merged $repo"
  cd - >/dev/null
}

# ---------------- SINGLE OR MULTI REPO ----------------
if [[ -d "$TARGET/.git" ]]; then
  process_repo "$TARGET"
else
  for r in "$TARGET"/*; do
    [[ -d "$r" ]] && process_repo "$r"
  done
fi
