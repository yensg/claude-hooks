#!/usr/bin/env bash
# Test suite for pre-push-privacy-check.sh
#
# RUN STANDALONE — not inside a Claude Code Bash tool call. Test payloads contain
# "git push" / "git -C ... push", which trip the very hooks being tested. Run from
# a plain terminal:
#     bash ~/.claude/hooks/pre-push-privacy-check.test.sh
# or in a Claude session prefix with `!` so it runs in your shell.
#
# Exit 0 = all pass. Exit 1 = one or more failures.
#
# Strategy: the hook always adds "/Users/<whoami>" to its pattern list, so a
# tracked file containing that string is a guaranteed finding regardless of the
# user's privacy-patterns.txt. "Clean" fixtures use trivial content that cannot
# match any auto-detected pattern.

set -uo pipefail

HOOK="$HOME/.claude/hooks/pre-push-privacy-check.sh"
PASS=0
FAIL=0
TMPROOT=""

cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/privacy-hook-test.XXXXXX")"
USER_NAME="$(whoami)"
DIRTY_STR="/Users/$USER_NAME/secret-path"   # guaranteed pattern match
CLEAN_STR="hello world nothing to flag here"

# mkrepo <dir> <filename> <content>  — real git repo with one committed file
mkrepo() {
  local dir="$1" fname="$2" content="$3"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  printf '%s\n' "$content" > "$dir/$fname"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "init" >/dev/null 2>&1
}

DIRTY_REPO="$TMPROOT/dirty"
CLEAN_REPO="$TMPROOT/clean"
NO_GIT_DIR="$TMPROOT/nogit"
BIN_REPO="$TMPROOT/binary"
UNTRACKED_REPO="$TMPROOT/untracked"

mkrepo "$DIRTY_REPO" "config.txt" "$DIRTY_STR"
mkrepo "$CLEAN_REPO" "readme.txt" "$CLEAN_STR"
mkdir -p "$NO_GIT_DIR"; printf '%s\n' "$DIRTY_STR" > "$NO_GIT_DIR/file.txt"

# binary repo: tracked file with a null byte + personal data → must be skipped
mkrepo "$BIN_REPO" "placeholder.txt" "$CLEAN_STR"
printf 'prefix\x00%s\n' "$DIRTY_STR" > "$BIN_REPO/blob.bin"
git -C "$BIN_REPO" add -A && git -C "$BIN_REPO" commit -qm "add blob" >/dev/null 2>&1

# untracked repo: clean tracked file, personal data only in an UNtracked file
mkrepo "$UNTRACKED_REPO" "tracked.txt" "$CLEAN_STR"
printf '%s\n' "$DIRTY_STR" > "$UNTRACKED_REPO/untracked.txt"   # never git-added

# --- helpers ------------------------------------------------------------------
payload() {  # $1=tool, $2=command, $3=cwd
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
print(json.dumps({
    "tool_name": sys.argv[1],
    "tool_input": {"command": sys.argv[2]},
    "cwd": sys.argv[3],
}))
PYEOF
}

assert_exit() {  # <expected> <desc> <tool> <command> <cwd>
  local expected="$1" desc="$2" tool="$3" cmd="$4" cwd="$5"
  local out code
  out="$(payload "$tool" "$cmd" "$cwd" | bash "$HOOK" 2>&1)"
  code=$?
  if [ "$code" -eq "$expected" ]; then
    PASS=$((PASS+1)); printf '  PASS [%d] %s\n' "$code" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  FAIL exp=%d got=%d  %s\n' "$expected" "$code" "$desc"
    [ -n "$out" ] && printf '        out: %s\n' "$(printf '%s' "$out" | head -2)"
  fi
}

PUSH="git push origin main"

echo "Running pre-push-privacy-check.sh test suite..."
echo

# --- early-exit cases ---------------------------------------------------------
assert_exit 0 "non-Bash tool ignored" \
  "Write" "$PUSH" "$DIRTY_REPO"

assert_exit 0 "command with no push ignored" \
  "Bash" "git status && ls" "$DIRTY_REPO"

assert_exit 0 "push but cwd has no .git -> allow" \
  "Bash" "$PUSH" "$NO_GIT_DIR"

# --- core scan cases ----------------------------------------------------------
assert_exit 0 "bare push, clean repo -> allow" \
  "Bash" "$PUSH" "$CLEAN_REPO"

assert_exit 2 "bare push, dirty repo (personal path) -> BLOCK" \
  "Bash" "$PUSH" "$DIRTY_REPO"

# --- git -C detection (the fix) -----------------------------------------------
assert_exit 2 "git -C dirty-repo push from clean cwd -> BLOCK" \
  "Bash" "git -C $DIRTY_REPO push origin main" "$CLEAN_REPO"

assert_exit 0 "git -C clean-repo push from dirty cwd -> allow" \
  "Bash" "git -C $CLEAN_REPO push origin main" "$DIRTY_REPO"

# --- edge cases ---------------------------------------------------------------
assert_exit 0 "binary file with null byte skipped -> allow" \
  "Bash" "$PUSH" "$BIN_REPO"

assert_exit 0 "personal data only in UNtracked file -> allow (not scanned)" \
  "Bash" "$PUSH" "$UNTRACKED_REPO"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
