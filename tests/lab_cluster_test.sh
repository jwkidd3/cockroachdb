#!/usr/bin/env bash
# The student path: docker/labs*.yml driven through scripts/crdb.
#
# The other tests in this suite start throwaway clusters with the cockroach
# binary inside the test image — fast and isolated, but they never touch the
# compose files or the wrapper scripts that students actually use. This test
# covers exactly that gap, so a broken compose file or wrapper cannot ship
# green.
#
# It runs on the HOST (it needs the docker daemon), not inside the test image.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CRDB="bash $REPO/scripts/crdb.sh"

cleanup_all() {
    (cd "$REPO" && bash scripts/crdb.sh down >/dev/null 2>&1) || true
    (cd "$REPO" && CRDB_COMPOSE=docker/labs-b.yml bash scripts/crdb.sh down >/dev/null 2>&1) || true
    (cd "$REPO" && docker compose -f docker/labs-secure.yml down -v >/dev/null 2>&1) || true
    rm -rf "$REPO/lab12" 2>/dev/null || true
}
trap cleanup_all EXIT INT TERM

if ! docker info >/dev/null 2>&1; then
    warn "Docker is not running; skipping the lab-cluster test"
    echo "lab-cluster: skipped"
    exit 0
fi

cd "$REPO"

section "Compose files are valid"
for f in docker/labs.yml docker/labs-b.yml docker/labs-secure.yml; do
    assert_command_succeeds "compose config: $f" docker compose -f "$f" config
done
assert_command_succeeds "compose config: labs + logging overlay" \
    docker compose -f docker/labs.yml -f docker/labs.logging.yml config
assert_command_succeeds "compose config: secure + logging overlay" \
    docker compose -f docker/labs-secure.yml -f docker/labs-secure.logging.yml config

# Relative bind mounts must land in the repo root, not in docker/.
MOUNT=$(docker compose -f docker/labs-secure.yml config 2>/dev/null | grep -A1 'source:.*lab12' | head -1)
assert_contains "lab12 bind mount resolves to the repo root" "$MOUNT" "$REPO/lab12"

section "scripts/crdb up"
cleanup_all
$CRDB up >/dev/null 2>&1 || fail "scripts/crdb up failed"
pass "cluster started"

NODES=$($CRDB sql --format=tsv -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "three live nodes" "$NODES" "3"

section "scripts/crdb sql"
ANSWER=$($CRDB sql --format=tsv -e "SELECT 1+1;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "sql -e returns a result" "$ANSWER" "2"

# Piping matters: several labs feed many statements in on stdin.
$CRDB sql -e "CREATE DATABASE piped; CREATE TABLE piped.t (id INT PRIMARY KEY);" >/dev/null 2>&1
for i in 1 2 3 4 5; do echo "INSERT INTO piped.t VALUES ($i);"; done | $CRDB sql >/dev/null 2>&1
PIPED=$($CRDB sql --format=tsv -e "SELECT count(*) FROM piped.t;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "piped statements are executed" "$PIPED" "5"

section "scripts/crdb run"
WL=$($CRDB run workload init kv --drop 'postgresql://root@crdb1:26257?sslmode=disable' 2>&1)
assert_not_contains "workload runs inside the cluster" "$WL" "executable file not found"

section "Published ports reach the cluster from the host"
assert_command_succeeds "DB Console metrics on :8080" curl -sf http://localhost:8080/_status/vars

section "scripts/crdb stop / start"
$CRDB stop 3 >/dev/null 2>&1 || fail "stop failed"
sleep 8
DOWN=$($CRDB sql --format=tsv -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "cluster reports 2 live nodes after stopping one" "$DOWN" "2"

STILL=$($CRDB sql --format=tsv -e "SELECT count(*) FROM piped.t;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "reads still served with a node down" "$STILL" "5"

$CRDB start 3 >/dev/null 2>&1 || fail "start failed"
wait_for "node 3 rejoins" 90 \
    "[ \"\$(cd '$REPO' && bash scripts/crdb.sh sql --format=tsv -e 'SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;' 2>/dev/null | tail -1 | tr -d '[:space:]')\" = '3' ]"
pass "node rejoined with its data"

section "scripts/crdb add-node"
$CRDB add-node >/dev/null 2>&1 || fail "add-node failed"
wait_for "four live nodes" 90 \
    "[ \"\$(cd '$REPO' && bash scripts/crdb.sh sql --format=tsv -e 'SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;' 2>/dev/null | tail -1 | tr -d '[:space:]')\" = '4' ]"
pass "fourth node joined"

section "Lab 11: standby cluster and cross-cluster restore"
CRDB_COMPOSE=docker/labs-b.yml bash "$REPO/scripts/crdb.sh" up >/dev/null 2>&1 || fail "standby cluster failed to start"
pass "standby cluster started alongside the main one"

$CRDB sql -e "CREATE DATABASE dr; CREATE TABLE dr.t (id INT PRIMARY KEY); INSERT INTO dr.t VALUES (1),(2),(3);" >/dev/null 2>&1
sleep 7
BK=$($CRDB sql -e "BACKUP DATABASE dr INTO 'nodelocal://1/suite-test' AS OF SYSTEM TIME '-5s';" 2>&1)
assert_contains "backup succeeded on the main cluster" "$BK" "succeeded"

RS=$(CRDB_COMPOSE=docker/labs-b.yml bash "$REPO/scripts/crdb.sh" sql -e "RESTORE DATABASE dr FROM LATEST IN 'nodelocal://1/suite-test';" 2>&1)
assert_contains "restore succeeded on the standby" "$RS" "succeeded"

ROWS=$(CRDB_COMPOSE=docker/labs-b.yml bash "$REPO/scripts/crdb.sh" sql --format=tsv -e "SELECT count(*) FROM dr.t;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "restored rows match the source (shared backup volume)" "$ROWS" "3"

section "Lab 12: secure cluster"
CRDB_COMPOSE=docker/labs-secure.yml bash "$REPO/scripts/crdb.sh" up >/dev/null 2>&1 || fail "secure cluster failed to start"
SEC=$(CRDB_COMPOSE=docker/labs-secure.yml bash "$REPO/scripts/crdb.sh" sql --format=tsv -e "SELECT 1;" 2>/dev/null | tail -1 | tr -d '[:space:]')
assert_eq "TLS connection works" "$SEC" "1"

INSEC=$(docker compose -f docker/labs-secure.yml exec -T crdbs1 ./cockroach sql --insecure --host=crdbs1 -e "SELECT 1;" 2>&1)
assert_contains "insecure connection is refused" "$INSEC" "secure"

# The binary must be PID 1, or SIGHUP never reaches it and cert rotation silently no-ops.
PID1=$(docker compose -f docker/labs-secure.yml exec -T crdbs1 cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')
assert_contains "cockroach runs as PID 1 (so SIGHUP reaches it)" "$PID1" "/cockroach/cockroach"

section "scripts/crdb down"
$CRDB down >/dev/null 2>&1 || fail "down failed"
LEFT=$(docker ps --filter "name=crdb1" --format '{{.Names}}' | wc -l | tr -d ' ')
assert_eq "main cluster removed" "$LEFT" "0"

section "Done"
echo "lab-cluster: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
