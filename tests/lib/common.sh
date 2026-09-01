# Shared helpers for lab test scripts.
# Source from a test with:   source "$(dirname "$0")/lib/common.sh"

set -u
set -o pipefail

# ---- Colors ---------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET=""
fi

# ---- Logging --------------------------------------------------------------
log()      { echo "${C_DIM}[$(date +%H:%M:%S)]${C_RESET} $*"; }
info()     { echo "${C_BLUE}INFO${C_RESET} $*"; }
warn()     { echo "${C_YELLOW}WARN${C_RESET} $*" >&2; }
pass()     { PASS_COUNT=$((PASS_COUNT+1)); echo "${C_GREEN}PASS${C_RESET} $*"; }
section()  { echo; echo "${C_BLUE}=== $* ===${C_RESET}"; }

# ---- Failure --------------------------------------------------------------
FAIL_COUNT=${FAIL_COUNT:-0}
PASS_COUNT=${PASS_COUNT:-0}

fail() {
    FAIL_COUNT=$((FAIL_COUNT+1))
    echo "${C_RED}FAIL${C_RESET} $*" >&2
    if [ "${KEEP_ON_FAIL:-0}" = "1" ]; then
        warn "KEEP_ON_FAIL=1 set; leaving cluster running for inspection"
        warn "Manual cleanup: pkill -f 'cockroach start --insecure --store=${STORE_BASE:-?}'"
    fi
    exit 1
}

# ---- Assertions -----------------------------------------------------------
# Each takes a description as the first arg, so failures are self-documenting.

assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc (= $expected)"
    else
        fail "$desc — expected '$expected', got '$actual'"
    fi
}

assert_ge() {
    local desc="$1" actual="$2" min="$3"
    if [ "$actual" -ge "$min" ] 2>/dev/null; then
        pass "$desc ($actual >= $min)"
    else
        fail "$desc — expected >= $min, got '$actual'"
    fi
}

assert_gt() {
    local desc="$1" actual="$2" min="$3"
    if [ "$actual" -gt "$min" ] 2>/dev/null; then
        pass "$desc ($actual > $min)"
    else
        fail "$desc — expected > $min, got '$actual'"
    fi
}

assert_lt() {
    local desc="$1" actual="$2" max="$3"
    if [ "$actual" -lt "$max" ] 2>/dev/null; then
        pass "$desc ($actual < $max)"
    else
        fail "$desc — expected < $max, got '$actual'"
    fi
}

# NOTE: these use a here-string, not `echo "$haystack" | grep`.
# With `set -o pipefail`, `grep -q` exits on its first match and closes the pipe;
# the writing side then dies of SIGPIPE (141) and pipefail makes the whole
# pipeline non-zero. On a large haystack (e.g. an 800 KB /_status/vars dump)
# that turns a real match into a FAIL — and, in assert_not_contains, turns a
# real match into a silent PASS. A here-string has no pipeline, so no SIGPIPE.
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -q -- "$needle" <<<"$haystack"; then
        pass "$desc (contains '$needle')"
    else
        fail "$desc — '$needle' not found in: $(head -c 2000 <<<"$haystack")"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -q -- "$needle" <<<"$haystack"; then
        fail "$desc — unexpected '$needle' found in: $(head -c 2000 <<<"$haystack")"
    else
        pass "$desc (does not contain '$needle')"
    fi
}

# `SHOW CLUSTER SETTING <bool>` renders as 't'/'f' in --format=tsv, but as
# 'true'/'false' in other formats and in docs. Accept either spelling.
assert_true() {
    local desc="$1" actual="$2"
    case "$actual" in
        t|true|TRUE|True) pass "$desc (= $actual)" ;;
        *) fail "$desc — expected a true value, got '$actual'" ;;
    esac
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$desc ($path)"
    else
        fail "$desc — file missing: $path"
    fi
}

assert_command_succeeds() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — command exited non-zero: $*"
    fi
}

assert_command_fails() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc — command unexpectedly succeeded: $*"
    else
        pass "$desc"
    fi
}

# ---- Prerequisite checks --------------------------------------------------

require_cockroach() {
    if ! command -v cockroach >/dev/null 2>&1; then
        fail "cockroach binary not on PATH (install per README)"
    fi
}

# ---- Misc helpers ---------------------------------------------------------

# Wait for a condition; usage: wait_for "describe" 30 "command that exits 0 when ready"
wait_for() {
    local desc="$1" timeout="$2" cmd="$3"
    local i
    for i in $(seq 1 "$timeout"); do
        if bash -c "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "$desc — condition not met within ${timeout}s: $cmd"
}

# Random free port in a range. Useful when running multiple test suites in parallel.
pick_free_port() {
    local lo="${1:-30000}" hi="${2:-39999}"
    local p
    while :; do
        p=$(( RANDOM % (hi - lo) + lo ))
        if ! lsof -i ":${p}" >/dev/null 2>&1; then
            echo "$p"; return 0
        fi
    done
}
