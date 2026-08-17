#!/usr/bin/env bash
# Install the pinned, safety-reviewed skill set from skills.lock.yaml.
#
# Runs at IMAGE BUILD time (see Dockerfile.ubuntu*), not at sandbox launch: the
# `skills` CLI prompts for install scope and target agent when it cannot detect
# an agent, which silently hangs a non-interactive start.
#
# Installs straight from git at the commit in each lock entry's `ref`, because
# the CLI has no way to pin a revision — `skills add` always takes upstream
# HEAD, so a rebuild could pull in unreviewed changes. A skill is just a
# directory containing SKILL.md, so copying the reviewed tree is equivalent to
# what `skills add --copy` does, minus the network resolution.
#
# Idempotent: a skill already installed at the locked ref is skipped; one
# installed at a different ref is replaced. Safe to re-run inside a container.
#
# Env overrides:
#   SKILLS_DIR     target skills dir (default: $HOME/.claude/skills)
#   SKILLS_LOCK    lockfile path (default: $HOME/.claude/skills.lock.yaml,
#                  falling back to skills.lock.yaml beside this script)
#   FETCH_TIMEOUT  per-repository fetch timeout in seconds (default: 300)
#   SKILLS_PRUNE   1 = delete installed skills absent from the lockfile
#                  (default: 1; set 0 to keep hand-added skills)
#   SKILLS_STRICT  1 = exit non-zero if any skill failed (default: 0)

set -uo pipefail

SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-300}"
SKILLS_PRUNE="${SKILLS_PRUNE:-1}"
SKILLS_STRICT="${SKILLS_STRICT:-0}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${SKILLS_LOCK:-}" ]; then
  for candidate in "$HOME/.claude/skills.lock.yaml" "$script_dir/skills.lock.yaml" \
                   "$script_dir/../skills.lock.yaml"; do
    [ -f "$candidate" ] && { SKILLS_LOCK="$candidate"; break; }
  done
fi
if [ -z "${SKILLS_LOCK:-}" ] || [ ! -f "$SKILLS_LOCK" ]; then
  echo "!! no lockfile found (set SKILLS_LOCK)" >&2
  exit 1
fi

# skill<TAB>repo<TAB>ref of what is currently installed, so a ref bump in the
# lockfile is detected as "needs replacing" rather than "already present".
RECORD="$SKILLS_DIR/.skills-installed.tsv"

# Flat records out of the lockfile: repo<TAB>skill<TAB>ref, in file order.
parse_lock() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      if (match($0, /^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*/))  repo  = substr($0, RSTART + RLENGTH)
      else if (match($0, /^[[:space:]]*skill:[[:space:]]*/))          skill = substr($0, RSTART + RLENGTH)
      else if (match($0, /^[[:space:]]*ref:[[:space:]]*/))            ref   = substr($0, RSTART + RLENGTH)
      if (repo != "" && skill != "" && ref != "") {
        print repo "\t" skill "\t" ref
        skill = ""; ref = ""      # keep repo: entries may share one repo block
      }
    }
  ' "$1"
}

# A skill lives in the directory holding its SKILL.md. Prefer the shortest
# matching path so a repo's canonical skills/<name>/ wins over a copy nested
# under plugins/; fall back to matching the `name:` frontmatter, since some
# repos name the directory differently from the skill (vercel-labs/agent-skills
# ships vercel-react-best-practices in skills/react-best-practices/).
find_skill_dir() {
  local root="$1" skill="$2" found=""
  found=$(find "$root" -name SKILL.md -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null \
    | while read -r f; do
        [ "$(basename "$(dirname "$f")")" = "$skill" ] && printf '%s\t%s\n' "${#f}" "$f"
      done | sort -n | head -1 | cut -f2-)
  if [ -z "$found" ]; then
    found=$(grep -rl --include=SKILL.md -E "^name:[[:space:]]*[\"']?${skill}[\"']?[[:space:]]*$" "$root" 2>/dev/null \
      | grep -v "/node_modules/" | awk '{print length "\t" $0}' | sort -n | head -1 | cut -f2-)
  fi
  [ -n "$found" ] && dirname "$found"
}

# Shallow-fetch exactly the locked commit, then verify we got it. GitHub allows
# fetching an arbitrary SHA, so no full clone or tag resolution is needed.
fetch_repo() {
  local repo="$1" ref="$2" dest="$3"
  git init -q "$dest" 2>/dev/null || return 1
  git -C "$dest" remote add origin "$repo" || return 1
  timeout "$FETCH_TIMEOUT" git -C "$dest" fetch -q --depth 1 origin "$ref" || return 1
  git -C "$dest" checkout -q FETCH_HEAD || return 1
  [ "$(git -C "$dest" rev-parse HEAD)" = "$ref" ] || return 1
}

record_ref() {
  local skill="$1" repo="$2" ref="$3" tmp="$RECORD.tmp"
  { [ -f "$RECORD" ] && grep -v -P "^\Q$skill\E\t" "$RECORD" 2>/dev/null || true; } > "$tmp"
  printf '%s\t%s\t%s\n' "$skill" "$repo" "$ref" >> "$tmp"
  sort -o "$RECORD" "$tmp" && rm -f "$tmp"
}

installed_ref() {
  [ -f "$RECORD" ] || return 0
  awk -F'\t' -v s="$1" '$1 == s { print $3 }' "$RECORD" | tail -1
}

mkdir -p "$SKILLS_DIR"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

records="$(parse_lock "$SKILLS_LOCK")"
[ -n "$records" ] || { echo "!! no skills found in $SKILLS_LOCK" >&2; exit 1; }
total=$(printf '%s\n' "$records" | wc -l)
echo "skills: $total locked entries from $SKILLS_LOCK"

installed=0 skipped=0 pruned=0
failed=()

while IFS=$'\t' read -r repo skill ref; do
  [ -n "$skill" ] || continue

  if [ -d "$SKILLS_DIR/$skill" ] && [ "$(installed_ref "$skill")" = "$ref" ]; then
    echo "== $skill: at locked ref, skipping"
    skipped=$((skipped + 1))
    continue
  fi

  # One checkout per repo+ref, reused by every skill sharing it.
  key="$(printf '%s@%s' "$repo" "$ref" | tr -c 'a-zA-Z0-9' '_')"
  checkout="$workdir/$key"
  if [ ! -d "$checkout" ]; then
    echo "-- fetching ${repo##*/} @ ${ref:0:12}"
    if ! fetch_repo "$repo" "$ref" "$checkout"; then
      echo "   FAILED: could not fetch $repo at $ref"
      rm -rf "$checkout"
      failed+=("$skill")
      continue
    fi
  fi

  src="$(find_skill_dir "$checkout" "$skill")"
  if [ -z "$src" ] || [ ! -f "$src/SKILL.md" ]; then
    echo "== $skill: FAILED — no SKILL.md found in $repo at ${ref:0:12}"
    failed+=("$skill")
    continue
  fi

  echo "== $skill: installing from ${repo##*/} @ ${ref:0:12}"
  rm -rf "$SKILLS_DIR/$skill"
  mkdir -p "$SKILLS_DIR/$skill"
  if cp -R "$src/." "$SKILLS_DIR/$skill/" && [ -f "$SKILLS_DIR/$skill/SKILL.md" ]; then
    record_ref "$skill" "$repo" "$ref"
    echo "   ok"
    installed=$((installed + 1))
  else
    echo "   FAILED: copy error"
    rm -rf "$SKILLS_DIR/$skill"
    failed+=("$skill")
  fi
done <<< "$records"

# Anything installed that the lockfile no longer names is unreviewed — drop it.
if [ "$SKILLS_PRUNE" = "1" ]; then
  locked=$(printf '%s\n' "$records" | cut -f2)
  for dir in "$SKILLS_DIR"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if ! printf '%s\n' "$locked" | grep -qxF "$name"; then
      echo "-- pruning $name (not in lockfile)"
      rm -rf "$dir"
      [ -f "$RECORD" ] && { grep -v -P "^\Q$name\E\t" "$RECORD" > "$RECORD.tmp" 2>/dev/null || true; mv "$RECORD.tmp" "$RECORD"; }
      pruned=$((pruned + 1))
    fi
  done
fi

echo
echo "skills: ${installed} installed, ${skipped} at locked ref, ${pruned} pruned, ${#failed[@]} failed"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed: ${failed[*]}"
  [ "$SKILLS_STRICT" = "1" ] && exit 1
fi
exit 0
