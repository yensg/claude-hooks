#!/usr/bin/env bash
# PreToolUse hook: block git push if personal data found in tracked files.
# Exit 0 = allow. Exit 2 = block (message shown to Claude).

set -euo pipefail

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")"
[ "$TOOL" != "Bash" ] && exit 0

COMMAND="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")"

# Only fire on git push. Fixed-string catches bare "git push"; regex catches
# `git -C <path> push` where -C splits "git" and "push" apart (the form
# /publish-skill uses). Detection only broadens — a miss means no scan, never
# a false block.
if ! printf '%s' "$COMMAND" | grep -qF "git push" && \
   ! printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+push'; then
    exit 0
fi

# Resolve repo dir — prefer -C <path> from command, fall back to CWD
CWD="$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")"
GIT_C_PATH=""
if printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+-C[[:space:]]+'; then
  GIT_C_PATH=$(printf '%s' "$COMMAND" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
  GIT_C_PATH="${GIT_C_PATH//\"/}"
  GIT_C_PATH="${GIT_C_PATH//\'/}"
  GIT_C_PATH="${GIT_C_PATH/#\~/$HOME}"
fi

REPO_DIR="${GIT_C_PATH:-$CWD}"
[ -z "$REPO_DIR" ] && exit 0
[ -d "$REPO_DIR/.git" ] || exit 0

# --- Build personal pattern list ---
USERNAME="$(whoami 2>/dev/null || echo "")"
GIT_EMAIL="$(git -C "$REPO_DIR" config user.email 2>/dev/null || echo "")"
GLOBAL_EMAIL="$(git config --global user.email 2>/dev/null || echo "")"

PATTERNS=()
[ -n "$USERNAME" ] && PATTERNS+=("/Users/$USERNAME")

# Add emails (deduplicated)
for email in "$GIT_EMAIL" "$GLOBAL_EMAIL"; do
  [ -z "$email" ] && continue
  already=0
  for p in "${PATTERNS[@]+"${PATTERNS[@]}"}"; do [ "$p" = "$email" ] && already=1 && break; done
  [ "$already" -eq 0 ] && PATTERNS+=("$email")
done

# Additional patterns from config file (one per line, # = comment)
PATTERNS_FILE="$HOME/.claude/privacy-patterns.txt"
if [ -f "$PATTERNS_FILE" ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$ ]] && continue
    PATTERNS+=("$line")
  done < "$PATTERNS_FILE"
fi

[ "${#PATTERNS[@]}" -eq 0 ] && exit 0

# --- Scan tracked text files ---
TRACKED="$(git -C "$REPO_DIR" ls-files 2>/dev/null)" || exit 0
[ -z "$TRACKED" ] && exit 0

FINDINGS=""
while IFS= read -r rel; do
  full="$REPO_DIR/$rel"
  [ -f "$full" ] || continue
  # Skip binaries: null byte anywhere = binary. Portable (BSD/macOS grep lacks -P).
  if [ "$(LC_ALL=C tr -cd '\000' < "$full" 2>/dev/null | wc -c | tr -d '[:space:]')" != "0" ]; then
    continue
  fi
  for pattern in "${PATTERNS[@]}"; do
    hits="$(grep -nF "$pattern" "$full" 2>/dev/null | head -3)" || true
    [ -z "$hits" ] && continue
    while IFS= read -r hit; do
      FINDINGS="${FINDINGS}  ${rel}:${hit}\n"
    done <<< "$hits"
  done
done <<< "$TRACKED"

if [ -n "$FINDINGS" ]; then
  echo "PUSH BLOCKED: personal data found in tracked files."
  echo "Fix before pushing (replace hardcoded paths/emails with env vars or placeholders)."
  echo "Run /privacy-scan for a full report."
  echo ""
  printf '%b' "$FINDINGS" | head -40
  exit 2
fi

exit 0
