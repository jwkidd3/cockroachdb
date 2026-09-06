#!/usr/bin/env bash
# The two cluster wrappers must stay in step.
#
# scripts/crdb.sh is exercised end to end by lab_cluster_test.sh. scripts/crdb.bat
# cannot be: cmd.exe does not exist on macOS or Linux, and there is no emulator in
# this toolchain. What CAN be checked without Windows is checked here:
#
#   1. both wrappers implement the same subcommands, on the same ports
#   2. the .bat is structurally valid cmd (labels, gotos, CRLF)
#   3. the docker commands the .bat builds are real, working commands — run here
#
# What remains unverified on this platform: cmd.exe's own parsing and quoting.
# Run scripts\crdb.bat on a Windows host before teaching a class with Windows
# students.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

SH="$REPO/scripts/crdb.sh"
BAT="$REPO/scripts/crdb.bat"

cleanup_all() { ( cd "$REPO" && bash scripts/crdb.sh down >/dev/null 2>&1 ) || true; }
trap cleanup_all EXIT INT TERM

section "Both wrappers exist and the .bat is Windows-shaped"
assert_file_exists "scripts/crdb.sh" "$SH"
assert_file_exists "scripts/crdb.bat" "$BAT"

# cmd.exe requires CRLF; a batch file saved with LF endings fails in ways that
# look like corruption (labels not found, stray characters in echo output).
if file "$BAT" | grep -q CRLF; then pass "crdb.bat has CRLF line endings"
else fail "crdb.bat has LF line endings — cmd.exe will misparse it"; fi

section "The same subcommands, in both wrappers"
SH_CMDS=$(grep -oE '^  ([a-z-]+)\)' "$SH" | tr -d ' )' | sort -u)
BAT_CMDS=$(grep -oE 'if /i "%CMD%"=="[a-z-]+"' "$BAT" | sed 's/.*=="//; s/"//' | sort -u)

for c in $SH_CMDS; do
    case "$c" in help) continue ;; esac
    if grep -q "^${c}$" <<<"$BAT_CMDS"; then pass "crdb.bat implements '$c'"
    else fail "crdb.bat is missing '$c', which crdb.sh has"; fi
done
for c in $BAT_CMDS; do
    case "$c" in help|--help|-h) continue ;; esac
    if grep -q "^${c}$" <<<"$SH_CMDS"; then pass "crdb.sh implements '$c'"
    else fail "crdb.sh is missing '$c', which crdb.bat has"; fi
done

section "The same port map in both wrappers"
for pair in "8080:26257" "8180:26357" "8280:26457"; do
    http="${pair%%:*}"; sql="${pair##*:}"
    if grep -q "$http" "$SH" && grep -q "$http" "$BAT"; then pass "console port $http in both"
    else fail "console port $http is not in both wrappers"; fi
    if grep -q "$sql" "$SH" && grep -q "$sql" "$BAT"; then pass "SQL port $sql in both"
    else fail "SQL port $sql is not in both wrappers"; fi
done

for feat in COCKROACH_LICENSE CRDB_COMPOSE; do
    if grep -q "$feat" "$SH" && grep -q "$feat" "$BAT"; then pass "$feat supported in both"
    else fail "$feat is only in one wrapper"; fi
done

section "crdb.bat is structurally valid cmd"
STRUCT=$(python3 - "$BAT" <<'PY'
import re, sys
s = open(sys.argv[1], newline='').read().replace('\r\n', '\n')
labels = set(re.findall(r'(?m)^\s*:([A-Za-z_0-9]+)', s))
targets = set(re.findall(r'goto :([A-Za-z_0-9]+)', s)) | set(re.findall(r'call :([A-Za-z_0-9]+)', s))
missing = sorted(targets - labels - {'eof'})
depth, bad = 0, []
for i, line in enumerate(s.split('\n'), 1):
    t = line.strip()
    if t.startswith(':') and not t.startswith('::') and depth > 0:
        bad.append(f"{i}:{t}")
    depth = max(0, depth + line.count('(') - line.count(')'))
print(f"{'none' if not missing else ','.join(missing)}|{'none' if not bad else ','.join(bad)}")
PY
)
assert_eq "every goto/call target has a label" "${STRUCT%%|*}" "none"
assert_eq "no label sits inside a parenthesised block" "${STRUCT##*|}" "none"

section "The docker commands crdb.bat builds actually work"
# These are the literal strings the batch file assembles for the default stack
# (NODE=crdb, AUTH=--insecure). Running them here proves the docker half is
# right, leaving only cmd's own parsing unverified.
( cd "$REPO" && bash scripts/crdb.sh up >/dev/null 2>&1 ) || fail "could not start the cluster"
DC=(docker compose -f "$REPO/docker/labs.yml")

OUT=$("${DC[@]}" exec -T crdb1 ./cockroach sql --insecure -e "SELECT 1" 2>&1 | tail -1)
assert_contains "  sql  -> exec crdb1 ./cockroach sql --insecure" "$OUT" "1"

OUT=$("${DC[@]}" exec -T crdb2 ./cockroach sql --insecure -e "SELECT 2" 2>&1 | tail -1)
assert_contains "  sql-on 2  -> exec crdb2" "$OUT" "2"

OUT=$("${DC[@]}" exec -T crdb1 ./cockroach node status --insecure 2>&1 | head -2)
assert_contains "  status  -> node status --insecure" "$OUT" "id"

OUT=$("${DC[@]}" exec -T crdb1 ./cockroach version 2>&1 | head -1)
assert_contains "  run version  -> exec crdb1 ./cockroach" "$OUT" "Build Tag"

OUT=$("${DC[@]}" exec -T crdb1 ./cockroach sql --insecure --format=csv \
        -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live" 2>&1 | tail -1 | tr -d '[:space:]')
assert_eq "  up's readiness poll (--format=csv) parses" "$OUT" "3"

assert_command_succeeds "  ps   -> compose ps" "${DC[@]}" ps
assert_command_succeeds "  stop -> compose stop crdb3" "${DC[@]}" stop crdb3
assert_command_succeeds "  start-> compose start crdb3" "${DC[@]}" start crdb3

warn "cmd.exe parsing and quoting remain unverified — run scripts\\crdb.bat on Windows"

section "Done"
echo "crdb wrappers: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
