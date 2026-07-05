#!/usr/bin/env bash
# statusline/combined-status.sh
# Two-panel status line: rate-limit stats left, buddy art right.
# buddy-status.sh is intentionally untouched (kept clean for upstream PR).

[ "$BUDDY_SHELL" = "1" ] && exit 0

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
BUDDY_SCRIPT="$SCRIPT_DIR/buddy-status.sh"

# On Windows, `python3` often resolves to the Microsoft Store app-execution-alias
# stub (a real file under .../WindowsApps/, so `command -v` finds it, but running
# it just prints a store-redirect message and produces no output). Skip candidates
# that resolve there without spending a process spawn on them; only exec-probe the
# rest, since a real interpreter may still be installed only as `python`.
PYTHON_BIN=""
for _candidate in python3 python; do
    _path=$(command -v "$_candidate" 2>/dev/null) || continue
    case "$_path" in
        */WindowsApps/*) continue ;;
    esac
    if "$_candidate" -c "" >/dev/null 2>&1; then
        PYTHON_BIN="$_candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    exec "$BUDDY_SCRIPT"
fi

# Force UTF-8 I/O (Python 3.7+). Without this, Python on Windows falls back to
# the system codepage (e.g. cp1252 on a German locale) for stdin/stdout, which
# corrupts the BRAILLE (U+2800) anchor byte used below to locate stat lines —
# the merge silently never matches and stats never appear.
export PYTHONUTF8=1

# ── Capture stdin from Claude Code ──────────────────────────────────────────
STDIN_DATA=$(cat)

# ── Git branch, cached (5s TTL) ───────────────────────────────────────────────
# Keyed by cwd (not session_id/pid): concurrent sessions in the same repo can
# safely share one cache entry, and different repos never collide. A plain
# `git branch --show-current` on every tick is exactly the kind of slow
# per-tick subprocess that has bitten this statusline before (see
# claude_buddy_statusline_perf / claude_buddy_combined_status_windows_bugs
# memories) — cache it instead of calling it unconditionally.
GIT_BRANCH=""
if command -v git >/dev/null 2>&1; then
    _cache_key=$(printf '%s' "$PWD" | tr -c 'A-Za-z0-9' '_')
    _cache_file="${TMPDIR:-/tmp}/claude-buddy-git-branch-${_cache_key}"
    _cache_age=999
    if [ -f "$_cache_file" ]; then
        _mtime=$(stat -c %Y "$_cache_file" 2>/dev/null || stat -f %m "$_cache_file" 2>/dev/null || echo 0)
        _cache_age=$(( $(date +%s) - _mtime ))
    fi
    if [ "$_cache_age" -gt 5 ]; then
        GIT_BRANCH=$(git branch --show-current 2>/dev/null)
        printf '%s' "$GIT_BRANCH" > "$_cache_file"
    else
        GIT_BRANCH=$(cat "$_cache_file" 2>/dev/null)
    fi
fi

# ── Capture buddy art (buddy reads state files, not stdin) ───────────────────
BUDDY_OUTPUT=$("$BUDDY_SCRIPT" </dev/null 2>/dev/null)

# No buddy output → exit silently (muted, no state, etc.)
[ -z "$BUDDY_OUTPUT" ] && exit 0

# ── Parse fields, merge stat lines into buddy output ─────────────────────────
# One Python process for the whole step (was three) — each extra interpreter
# spawn costs ~100-300ms on Windows and had pushed total runtime past
# refreshInterval, making Crittner disappear the same way as the jq-call
# issue in claude_buddy_statusline_perf memory.
printf '%s\n' "$BUDDY_OUTPUT" | STDIN_DATA="$STDIN_DATA" GIT_BRANCH="$GIT_BRANCH" "$PYTHON_BIN" -c "
import sys, json, os, datetime

BRAILLE = '⠀'
GREEN   = '\033[32m'
YELLOW  = '\033[33m'
RED     = '\033[31m'
CYAN    = '\033[38;2;0;232;255m'
DIM     = '\033[2m'
NC      = '\033[0m'

def fmt_session_reset(ts):
    if not ts: return None
    diff = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc) - datetime.datetime.now(datetime.timezone.utc)
    mins = max(0, int(diff.total_seconds() / 60))
    h, m = mins // 60, mins % 60
    return f'{h}h{m:02d}m' if h else f'{m}m'

def fmt_weekly_reset(ts):
    if not ts: return None
    diff = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc) - datetime.datetime.now(datetime.timezone.utc)
    secs = max(0, int(diff.total_seconds()))
    d = secs // 86400
    h = (secs % 86400) // 3600
    m = (secs % 3600) // 60
    return f'{d}d{h:02d}h' if d else (f'{h}h{m:02d}m' if h else f'{m}m')

try:
    data = json.loads(os.environ.get('STDIN_DATA', '') or '{}')
except Exception:
    data = {}

rl = data.get('rate_limits', {}) or {}
fh = rl.get('five_hour', {}) or {}
sd = rl.get('seven_day', {}) or {}
sess_pct = fh.get('used_percentage')
week_pct = sd.get('used_percentage')
ctx_pct = (data.get('context_window', {}) or {}).get('used_percentage')
model_name = (data.get('model', {}) or {}).get('display_name')
git_branch = (os.environ.get('GIT_BRANCH') or '').strip()

sys.stdin.reconfigure(encoding='utf-8', newline='')  # disable universal-newline translation:
# a bare stdin.read() rewrites every embedded \r (used mid-row for cursor return) into \n,
# doubling the row count and shifting every merge target off by one.
buddy_data = sys.stdin.read()
if buddy_data.endswith('\n'):
    buddy_data = buddy_data[:-1]
lines = buddy_data.split('\n')  # not splitlines(): would still split on the (now-preserved) \r

def color_for(pct):
    if pct is None: return DIM
    if pct < 30:   return GREEN
    if pct < 70:   return YELLOW
    return RED

def build_bar(pct, width=10):
    if pct is None:
        return DIM + '░' * width + NC
    c = color_for(pct)
    filled = max(0, min(width, round(pct / 100 * width)))
    return c + '█' * filled + NC + DIM + '░' * (width - filled) + NC

def fmt_bar_stat(label, pct, reset=None):
    c = color_for(pct)
    pct_str = f'{round(pct):3d}%' if pct is not None else '  -%'
    bar = build_bar(pct)
    if reset is not None:
        text = f'{DIM}{label}{NC} {c}{pct_str}{NC} {bar} {c}↻ {reset}{NC}'
        visual_width = len(label) + 1 + 4 + 1 + 10 + 1 + 1 + 1 + len(reset)
    else:
        text = f'{DIM}{label}{NC} {c}{pct_str}{NC} {bar}'
        visual_width = len(label) + 1 + 4 + 1 + 10
    return text, visual_width

def fmt_text_stat(label, value):
    text = f'{DIM}{label}{NC} {CYAN}{value}{NC}'
    visual_width = len(label) + 1 + len(value)
    return text, visual_width

# Rows 0-4 are buddy's art (row 0 always an invisible spacer, see
# claude_buddy_statusline_perf memory); the last line is the name and is
# never touched. One stat per row, top to bottom; a None entry leaves that
# row's original content untouched.
stat_items = [None] * 5
if model_name:
    stat_items[0] = fmt_text_stat('model', model_name)
if sess_pct is not None:
    stat_items[1] = fmt_bar_stat('5h', sess_pct, fmt_session_reset(fh.get('resets_at')))
if week_pct is not None:
    stat_items[2] = fmt_bar_stat('7d', week_pct, fmt_weekly_reset(sd.get('resets_at')))
if ctx_pct is not None:
    stat_items[3] = fmt_bar_stat('ctx', ctx_pct)
if git_branch:
    stat_items[4] = fmt_text_stat('git', git_branch)

for i, line in enumerate(lines):
    item = stat_items[i] if 0 <= i < len(stat_items) else None
    if item is not None and line.startswith(BRAILLE):
        stat_text, stat_width = item
        after_braille = line[1:]
        num_spaces = len(after_braille) - len(after_braille.lstrip(' '))
        if num_spaces >= stat_width:
            remaining = ' ' * (num_spaces - stat_width)
            rest = after_braille.lstrip(' ')
            print(BRAILLE + stat_text + remaining + rest)
        else:
            print(line)
    else:
        print(line)
"
