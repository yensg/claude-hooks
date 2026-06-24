#!/usr/bin/env bash
# Test suite for ship-gate-check.sh
#
# RUN STANDALONE — not inside a Claude Code Bash tool call. This script's text
# contains "git push", which would trip the very hook it tests. Run it from a
# plain terminal:
#     bash ~/.claude/hooks/ship-gate-check.test.sh
# or in a Claude session prefix with `!` so it runs in your shell, not the tool.
#
# Exit 0 = all pass. Exit 1 = one or more failures.

set -uo pipefail

HOOK="$HOME/.claude/hooks/ship-gate-check.sh"
PASS=0
FAIL=0
TMPROOT=""

cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/ship-gate-test.XXXXXX")"

# --- fixtures -----------------------------------------------------------------
# A repo dir WITH a valid .planning/ in phase:plan (should block pushes)
REPO_PLAN="$HOME/.ship-gate-test-plan"
# A repo dir WITH .planning/ in phase:ship (should allow)
REPO_SHIP="$HOME/.ship-gate-test-ship"
# A repo dir with NO .planning/ (should allow)
REPO_CLEAN="$HOME/.ship-gate-test-clean"

# Hook requires paths strictly under $HOME, so fixtures live under $HOME not /tmp.
rm -rf "$REPO_PLAN" "$REPO_SHIP" "$REPO_CLEAN"
mkdir -p "$REPO_PLAN/.planning" "$REPO_SHIP/.planning" "$REPO_CLEAN/sub"

_good_handoff() {
  cat > "$1" <<'HEOF'
# Handoff
Project: real project state captured here with enough bytes to pass the
minimum-size check. Status: done. Next action: ship it.
HEOF
}

echo "phase: plan" > "$REPO_PLAN/.planning/state.md"
_good_handoff "$REPO_PLAN/.planning/handoff.md"

echo "phase: ship" > "$REPO_SHIP/.planning/state.md"
_good_handoff "$REPO_SHIP/.planning/handoff.md"

# also make a subdir inside the plan repo for the subdirectory case
mkdir -p "$REPO_PLAN/sub"

trap 'rm -rf "$REPO_PLAN" "$REPO_SHIP" "$REPO_CLEAN"; cleanup' EXIT INT TERM

# --- helpers ------------------------------------------------------------------
# Build a PreToolUse JSON payload via python (robust quoting) and pipe to hook.
payload() {
  # $1 = tool_name, $2 = command, $3 = cwd
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
print(json.dumps({
    "tool_name": sys.argv[1],
    "tool_input": {"command": sys.argv[2]},
    "cwd": sys.argv[3],
}))
PYEOF
}

# assert_exit <expected_code> <description> <tool> <command> <cwd>
assert_exit() {
  local expected="$1" desc="$2" tool="$3" cmd="$4" cwd="$5"
  local out code
  out="$(payload "$tool" "$cmd" "$cwd" | bash "$HOOK" 2>&1)"
  code=$?
  if [ "$code" -eq "$expected" ]; then
    PASS=$((PASS+1))
    printf '  PASS [%d] %s\n' "$code" "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL exp=%d got=%d  %s\n' "$expected" "$code" "$desc"
    [ -n "$out" ] && printf '        out: %s\n' "$out"
  fi
}

PUSH="git push origin main"   # built at runtime so this literal isn't in a heredoc

echo "Running ship-gate-check.sh test suite..."
echo

# --- early-exit cases (should always allow) -----------------------------------
assert_exit 0 "non-Bash tool ignored" \
  "Write" "$PUSH" "$REPO_PLAN"

assert_exit 0 "command with no push/pr ignored" \
  "Bash" "ls -la && git status" "$REPO_PLAN"

assert_exit 0 "cwd outside HOME ignored" \
  "Bash" "$PUSH" "/tmp"

# --- repo-resolution cases ----------------------------------------------------
assert_exit 0 "git -C clean-repo push (no .planning -> allow)" \
  "Bash" "git -C $REPO_CLEAN push origin main" "$REPO_PLAN"

assert_exit 0 "cd clean-repo && push (no .planning -> allow)" \
  "Bash" "cd $REPO_CLEAN && git push origin main" "$REPO_PLAN"

assert_exit 2 "bare push, cwd=plan-repo (phase:plan -> BLOCK)" \
  "Bash" "$PUSH" "$REPO_PLAN"

assert_exit 0 "bare push, cwd=ship-repo (phase:ship -> allow)" \
  "Bash" "$PUSH" "$REPO_SHIP"

assert_exit 2 "git -C plan-repo push from clean cwd (phase:plan -> BLOCK)" \
  "Bash" "git -C $REPO_PLAN push origin main" "$REPO_CLEAN"

# --- state validation cases ---------------------------------------------------
# missing handoff.md
rm -f "$REPO_SHIP/.planning/handoff.md"
assert_exit 2 "ship-repo missing handoff.md -> BLOCK" \
  "Bash" "$PUSH" "$REPO_SHIP"
_good_handoff "$REPO_SHIP/.planning/handoff.md"   # restore

# blank phase
echo "phase:" > "$REPO_SHIP/.planning/state.md"
assert_exit 2 "ship-repo blank phase -> BLOCK" \
  "Bash" "$PUSH" "$REPO_SHIP"
echo "phase: ship" > "$REPO_SHIP/.planning/state.md"  # restore

# symlinked .planning
SYMREPO="$HOME/.ship-gate-test-sym"
rm -rf "$SYMREPO"; mkdir -p "$SYMREPO"
ln -s "$REPO_SHIP/.planning" "$SYMREPO/.planning"
assert_exit 2 "symlinked .planning -> BLOCK" \
  "Bash" "$PUSH" "$SYMREPO"
rm -rf "$SYMREPO"

# --- false-positive fix -------------------------------------------------------
# A command whose TEXT only contains "git push" inside quotes (echo, docs, JSON
# payloads) is NOT a push. The hook strips quoted substrings before detection, so
# even in a blocking repo this is allowed. Previously a documented known-limit.
assert_exit 0 "quoted 'git push' as text in cwd=plan-repo -> ALLOW" \
  "Bash" "echo 'docs about git push command'" "$REPO_PLAN"
assert_exit 0 "double-quoted git push as text -> ALLOW" \
  "Bash" "echo \"remember to git push later\"" "$REPO_PLAN"

# --- spaced / apostrophe path resolution (cd & git -C) ------------------------
# Paths with spaces or apostrophes (e.g. an iCloud vault ".../Yen's Claude") must
# resolve, not truncate at the first space. Regression guard for the cd/-C parser.
SP_CLEAN="$HOME/.ship gate test 'clean'"   # spaces + apostrophe, NO .planning
SP_PLAN="$HOME/.ship gate test plan"       # spaces, phase:plan -> should block
rm -rf "$SP_CLEAN" "$SP_PLAN"
mkdir -p "$SP_CLEAN/sub" "$SP_PLAN/.planning"
echo "phase: plan" > "$SP_PLAN/.planning/state.md"
_good_handoff "$SP_PLAN/.planning/handoff.md"
trap 'rm -rf "$REPO_PLAN" "$REPO_SHIP" "$REPO_CLEAN" "$SP_CLEAN" "$SP_PLAN"; cleanup' EXIT INT TERM

assert_exit 0 "cd \"spaced+apostrophe clean path\" && push (no .planning -> ALLOW)" \
  "Bash" "cd \"$SP_CLEAN\" && git push origin main" "$REPO_PLAN"
assert_exit 0 "git -C \"spaced clean path\" push (no .planning -> ALLOW)" \
  "Bash" "git -C \"$SP_CLEAN\" push origin main" "$REPO_PLAN"
assert_exit 2 "cd \"spaced plan path\" && push (phase:plan -> BLOCK)" \
  "Bash" "cd \"$SP_PLAN\" && git push origin main" "$REPO_CLEAN"
assert_exit 2 "var path cd \"\$X/y\" && push -> bails to cwd plan-repo (BLOCK)" \
  "Bash" "cd \"\$X/y\" && git push origin main" "$REPO_PLAN"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
