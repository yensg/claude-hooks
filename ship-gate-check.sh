#!/usr/bin/env bash
# PreToolUse hook: block git push / gh pr create if project isn't ready to ship.
# Exit 0 = allow. Exit 2 = block (message shown to Claude).

set -euo pipefail

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")"
[ "$TOOL" != "Bash" ] && exit 0

COMMAND="$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")"

# Strip single- and double-quoted substrings before detection so a push that
# appears only as literal TEXT (echo, prompts, JSON payloads, diagnostics) does
# not trip the gate. Real invocations — `git push`, `cd repo && git push`,
# `git -C <path> push` — are unquoted and survive the strip, so they still match.
DETECT="$(printf '%s' "$COMMAND" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"

# Detect push intent against the quote-stripped command. Fixed-string "git push"
# catches the bare form; the regex catches `git -C <path> push` where the -C flag
# splits "git" and "push" apart. A missed match just means the gate doesn't apply,
# never a false block.
if ! printf '%s' "$DETECT" | grep -qF "git push" && \
   ! printf '%s' "$DETECT" | grep -qE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+push' && \
   ! printf '%s' "$DETECT" | grep -qF "gh pr create"; then
    exit 0
fi

# Validate CWD is real absolute path strictly under HOME
CWD="$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")"
[ -z "$CWD" ] && exit 0
CWD_RESOLVED="$(realpath "$CWD" 2>/dev/null || echo "")"
if [ -z "$CWD_RESOLVED" ] || [[ "$CWD_RESOLVED" != "$HOME/"* ]]; then
    exit 0
fi

# Resolve the actual repo dir being pushed — may differ from session CWD when
# the command uses `git -C <path>` or `cd <path> && git push`.
EFFECTIVE_DIR="$CWD_RESOLVED"

# Extract the path argument after a keyword, handling "double-quoted", 'single-quoted',
# and bare (space/&/;/|-terminated) forms — so paths WITH SPACES or apostrophes (e.g. an
# iCloud vault "…/Yen's Claude") resolve instead of truncating at the first space.
# $1 = command string, $2 = keyword regex (e.g. 'cd' or 'git[[:space:]]+-C').
# Limitation: a path built from a shell variable (cd "$DIR/x") cannot be expanded by a
# static parser — those are bailed below and fall back to the session CWD gate (safe default).
_xpath() {
  local cmd="$1" kw="$2" p
  p=$(printf '%s' "$cmd" | sed -nE "s/.*${kw}[[:space:]]+\"([^\"]+)\".*/\\1/p"); [ -n "$p" ] && { printf '%s' "$p"; return; }
  p=$(printf '%s' "$cmd" | sed -nE "s/.*${kw}[[:space:]]+'([^']+)'.*/\\1/p");   [ -n "$p" ] && { printf '%s' "$p"; return; }
  printf '%s' "$cmd" | sed -nE "s/.*${kw}[[:space:]]+([^[:space:]&;|]+).*/\\1/p"
}

# Pattern: git -C <path> push ...
if printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+-C[[:space:]]+'; then
  _GIT_C=$(_xpath "$COMMAND" 'git[[:space:]]+-C')
  _GIT_C="${_GIT_C/#\~/$HOME}"
  case "$_GIT_C" in *'$'*) _GIT_C="";; esac   # unexpandable shell var — cannot resolve
  _GIT_C_RESOLVED=$(realpath "$_GIT_C" 2>/dev/null || echo "")
  if [ -n "$_GIT_C_RESOLVED" ] && [[ "$_GIT_C_RESOLVED" == "$HOME/"* ]]; then
    EFFECTIVE_DIR="$_GIT_C_RESOLVED"
  fi
fi

# Pattern: cd <path> && git push (only if git -C not already found)
if [ "$EFFECTIVE_DIR" = "$CWD_RESOLVED" ] && printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_])cd[[:space:]]'; then
  _CD=$(_xpath "$COMMAND" 'cd')
  _CD="${_CD/#\~/$HOME}"
  case "$_CD" in *'$'*) _CD="";; esac        # unexpandable shell var — cannot resolve
  _CD_RESOLVED=$(realpath "$_CD" 2>/dev/null || echo "")
  if [ -n "$_CD_RESOLVED" ] && [[ "$_CD_RESOLVED" == "$HOME/"* ]]; then
    EFFECTIVE_DIR="$_CD_RESOLVED"
  fi
fi

PLANNING="${EFFECTIVE_DIR}/.planning"
[ -d "$PLANNING" ] || exit 0

# Reject symlinked .planning — prevents gate bypass via attacker-controlled state
if [ -L "$PLANNING" ]; then
    echo "SHIP BLOCKED: .planning/ is a symlink — cannot safely verify project state." >&2
    exit 2
fi

HANDOFF="${PLANNING}/handoff.md"
if [ ! -f "$HANDOFF" ]; then
    echo "SHIP BLOCKED: .planning/handoff.md missing. Run /context-save after /qa before shipping." >&2
    exit 2
fi

# Check handoff.md has actual content — template has multiple placeholder markers
if grep -qE "^\[timestamp\]|^\[project\]|^\[status\]|\[next_action\]" "$HANDOFF" 2>/dev/null; then
    echo "SHIP BLOCKED: .planning/handoff.md still has blank template content. Run /qa then /context-save first." >&2
    exit 2
fi

# Minimum size — real context-save output is never tiny
HANDOFF_SIZE="$(wc -c < "$HANDOFF" 2>/dev/null || echo 0)"
if [ "$HANDOFF_SIZE" -lt 100 ]; then
    echo "SHIP BLOCKED: .planning/handoff.md is too small (${HANDOFF_SIZE} bytes) — run /context-save first." >&2
    exit 2
fi

# Check state.md phase — allowlist: only qa and ship permitted
STATE="${PLANNING}/state.md"
if [ -f "$STATE" ]; then
    PHASE_COUNT="$(grep -c '^phase:' "$STATE" 2>/dev/null || echo 0)"
    if [ "$PHASE_COUNT" -ne 1 ]; then
        echo "SHIP BLOCKED: state.md has $PHASE_COUNT phase: lines (expected exactly 1). Fix state.md before shipping." >&2
        exit 2
    fi
    PHASE="$(grep '^phase:' "$STATE" | head -1 | sed 's/^phase:[[:space:]]*//' | tr -d '[:space:]\r')"
    if [ -z "$PHASE" ]; then
        echo "SHIP BLOCKED: state.md phase is blank. Set phase to 'qa' or 'ship' before shipping." >&2
        exit 2
    fi
    case "$PHASE" in
        qa|ship) ;;
        *) echo "SHIP BLOCKED: state.md phase is '$PHASE'. Must be 'qa' or 'ship' before shipping." >&2; exit 2 ;;
    esac
fi

exit 0
