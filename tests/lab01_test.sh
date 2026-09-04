#!/usr/bin/env bash
# Lab 1 — Cluster Bootstrap & Lifecycle
#
# Drives exactly what the lab tells students to type: scripts/crdb against
# docker/labs.yml. Parts A-D (start, inspect, kill a follower, kill the
# leaseholder), Part E (decommission), Part F (three ways to connect),
# Part G (troubleshooting a cluster that won't start).
#
# DB Console observation steps are visual and are not asserted here.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab01"
source "$SCRIPT_DIR/lib/cluster.sh"

NET="crdb-labs_default"

cleanup_all() {
    docker rm -f lab01-portgrab lab01-lonely >/dev/null 2>&1 || true
    stop_cluster
}
trap cleanup_all EXIT INT TERM

section "Setup — scripts/crdb up"
start_cluster 3

LIVE_NODES=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "3 live nodes after scripts/crdb up" "$LIVE_NODES" "3"

section "Part A — Create database and load notes"
sql "CREATE DATABASE lab1;" >/dev/null
sql "CREATE TABLE lab1.notes (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), body STRING NOT NULL, made TIMESTAMPTZ DEFAULT now());" >/dev/null
sql "INSERT INTO lab1.notes (body) SELECT 'note ' || generate_series(1, 1000)::STRING;" >/dev/null

NOTE_COUNT=$(sql_value "SELECT count(*) FROM lab1.notes;")
assert_eq "1000 notes inserted" "$NOTE_COUNT" "1000"

RANGE_COUNT=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS];")
assert_ge "notes table has at least 1 range" "$RANGE_COUNT" "1"

section "Part A — scripts/crdb status reports every node"
STATUS=$(crdb status 2>&1)
for n in 1 2 3; do
    assert_contains "node status lists crdb${n}" "$STATUS" "crdb${n}:26257"
done

section "Part B — How the cluster was formed"
# Every node was given the same --join list; the init container ran once.
JOINED=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes;")
assert_eq "all three nodes are in gossip" "$JOINED" "3"

section "Part C — Stop a follower; the cluster keeps serving"
LEASEHOLDER=$(sql_value "SELECT lease_holder FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS] LIMIT 1;")
info "leaseholder is node $LEASEHOLDER"

VICTIM=1
for n in 1 2 3; do
    if [ "$n" != "$LEASEHOLDER" ]; then VICTIM="$n"; break; fi
done
info "stopping follower: node $VICTIM"

kill_node "$VICTIM"

# Reads/writes still work against a survivor. Node 1 hosts `scripts/crdb sql`,
# so when node 1 is the victim we must ask a different node explicitly.
SURVIVOR=$((VICTIM % 3 + 1))

COUNT_AFTER_KILL=$(sql_value_on_node "$SURVIVOR" "SELECT count(*) FROM lab1.notes;")
assert_eq "reads still work with a follower down" "$COUNT_AFTER_KILL" "1000"

sql_on_node "$SURVIVOR" "INSERT INTO lab1.notes (body) VALUES ('survives a follower outage');" >/dev/null
COUNT_AFTER_INSERT=$(sql_value_on_node "$SURVIVOR" "SELECT count(*) FROM lab1.notes;")
assert_eq "writes still work with a follower down" "$COUNT_AFTER_INSERT" "1001"

section "Part C — scripts/crdb start brings it back with its data"
restart_node "$VICTIM"

LIVE_AFTER_RESTART=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "3 live nodes after restart" "$LIVE_AFTER_RESTART" "3"

# Under-replicated ranges converge back to 0. --format=tsv renders booleans as
# 't', not 'true'; grepping for '^true' silently burns the whole timeout.
wait_for "under-replicated ranges drop to 0" 120 \
    "[ \"\$(cd '$REPO_ROOT' && bash scripts/crdb.sh sql --format=tsv -e \"SELECT count(*) FROM crdb_internal.ranges_no_leases WHERE array_length(replicas,1) < 3;\" 2>/dev/null | tail -1 | tr -d '[:space:]')\" = '0' ]"
pass "all ranges back to full replication"

section "Part D — Stop the leaseholder; a new one is elected"
LH=$(sql_value "SELECT lease_holder FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS] LIMIT 1;")
if [ "$LH" = "1" ]; then
    # Node 1 is where `scripts/crdb sql` connects, so stopping it would take the
    # shell down with it. The lab has students query a different node; do the same.
    OTHER=2
else
    OTHER=1
fi
kill_node "$LH"
COUNT_NO_LH=$(sql_value_on_node "$OTHER" "SELECT count(*) FROM lab1.notes;")
assert_eq "reads survive losing the leaseholder" "$COUNT_NO_LH" "1001"
NEW_LH=$(sql_value_on_node "$OTHER" "SELECT lease_holder FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS] LIMIT 1;")
assert_not_eq "a new leaseholder was elected" "$NEW_LH" "$LH"
restart_node "$LH"

section "Part E — Decommission needs spare capacity"
DECOMM_NODE=3

# A 3-node cluster at RF=3 has nowhere to put node 3's replicas, so this is
# REFUSED. That refusal is the lesson, not a failure.
info "attempting to decommission node $DECOMM_NODE on a 3-node RF=3 cluster"
REFUSAL=$(crdb_run node decommission "$DECOMM_NODE" --insecure 2>&1 || true)
assert_contains "decommission is refused without spare capacity" "$REFUSAL" \
    "Cannot decommission\|likely not enough nodes\|blocking decommission"

STILL_ACTIVE=$(sql_value "SELECT membership FROM crdb_internal.kv_node_liveness WHERE node_id = $DECOMM_NODE;")
assert_contains "node $DECOMM_NODE is still usable after the refusal" "$STILL_ACTIVE" "active\|decommissioning"

section "Part E — scripts/crdb add-node, then retry"
add_node
LIVE4=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "cluster reports 4 live nodes" "$LIVE4" "4"

info "decommissioning node $DECOMM_NODE (this moves every replica off it)"
if crdb_run node decommission "$DECOMM_NODE" --insecure >/dev/null 2>&1; then
    pass "decommission completed once spare capacity existed"
else
    fail "decommission still failed with 4 nodes"
fi

DECOMM_STATE=$(sql_value "SELECT membership FROM crdb_internal.kv_node_liveness WHERE node_id = $DECOMM_NODE;")
assert_contains "node $DECOMM_NODE is decommissioning or decommissioned" \
    "$DECOMM_STATE" "decommiss"

COUNT_AFTER_DECOMM=$(sql_value "SELECT count(*) FROM lab1.notes;")
assert_eq "cluster still serves after decommission" "$COUNT_AFTER_DECOMM" "1001"

section "Part F — Three ways to connect"

# 1. The built-in shell, via the published port on the host.
SHELL_COUNT=$(sql_value "SELECT count(*) FROM lab1.notes;")
assert_eq "scripts/crdb sql" "$SHELL_COUNT" "1001"

# 2. psql. The lab offers a local binary or a container; test whichever is here.
if command -v psql >/dev/null 2>&1; then
    PSQL_COUNT=$(psql -At "postgresql://root@localhost:${BASE_SQL_PORT}/lab1?sslmode=disable" \
        -c "SELECT count(*) FROM notes;" 2>/dev/null)
    assert_eq "psql on the host via the published port" "$PSQL_COUNT" "1001"
else
    PSQL_COUNT=$(docker run --rm --network "$NET" postgres:16 \
        psql -At "postgresql://root@crdb1:26257/lab1?sslmode=disable" \
        -c "SELECT count(*) FROM notes;" 2>/dev/null | tr -d '[:space:]')
    assert_eq "psql in a container via the Docker network" "$PSQL_COUNT" "1001"
fi

# 3. Python. Same choice: host psycopg2 if present, container otherwise.
if command -v python3 >/dev/null 2>&1 && python3 -c "import psycopg2" >/dev/null 2>&1; then
    PY_COUNT=$(python3 - <<PY
import psycopg2
conn = psycopg2.connect("postgresql://root@localhost:${BASE_SQL_PORT}/lab1?sslmode=disable")
with conn.cursor() as cur:
    cur.execute("SELECT count(*) FROM notes;")
    print(cur.fetchone()[0])
conn.close()
PY
)
    assert_eq "python psycopg2 on the host" "$PY_COUNT" "1001"
else
    warn "no host psycopg2; using the containerised path the lab also offers"
    PY_COUNT=$(docker run --rm --network "$NET" python:3.12-slim bash -c \
        "pip install -q psycopg2-binary 2>/dev/null && python -c \"
import psycopg2
c = psycopg2.connect('postgresql://root@crdb1:26257/lab1?sslmode=disable')
cur = c.cursor(); cur.execute('SELECT count(*) FROM notes'); print(cur.fetchone()[0])\"" 2>/dev/null | tr -d '[:space:]')
    assert_eq "python psycopg2 in a container" "$PY_COUNT" "1001"
fi

# The two-addresses gotcha the lab calls out: localhost from the host, crdb1
# from inside the network. Prove the in-network name really is different.
HOSTNAME_ERR=$(docker run --rm --network "$NET" postgres:16 \
    psql -At "postgresql://root@localhost:26257/lab1?sslmode=disable" -c "SELECT 1;" 2>&1 || true)
assert_contains "localhost does NOT work from inside the network" "$HOSTNAME_ERR" \
    "refused\|could not connect\|failed"

section "Part F — CRDB built-ins over the PG protocol"
CLUSTER_ID=$(sql_value "SELECT crdb_internal.cluster_id();")
assert_ge "cluster_id() returned a non-empty UUID" "${#CLUSTER_ID}" "30"

section "Part G — Troubleshooting a cluster that won't start"

# 1. Published port already taken. Bring the cluster down, let something else
#    grab 26257, and confirm the failure students will actually see.
crdb down >/dev/null 2>&1 || true
docker rm -f lab01-portgrab >/dev/null 2>&1 || true
docker run -d --name lab01-portgrab -p ${BASE_SQL_PORT}:26257 alpine sleep 60 >/dev/null 2>&1 \
    || warn "could not start the port-grabbing container"

PORT_ERR=$(crdb up 2>&1 || true)
assert_contains "port-in-use error names the conflict" "$PORT_ERR" \
    "already allocated\|address already in use\|port is already"
docker rm -f lab01-portgrab >/dev/null 2>&1 || true

# 2. A node with a --join list nobody shares hangs rather than erroring.
crdb up >/dev/null 2>&1 || fail "cluster did not come back after freeing the port"
docker rm -f lab01-lonely >/dev/null 2>&1 || true
docker run -d --name lab01-lonely --network "$NET" cockroachdb/cockroach:v23.2.5 \
    start --insecure --advertise-addr=lonely --join=nosuchnode:26257 \
    --http-addr=0.0.0.0:8080 >/dev/null 2>&1 || true
sleep 25
LONELY=$(docker logs lab01-lonely 2>&1 || true)
RUNNING=$(docker inspect -f '{{.State.Running}}' lab01-lonely 2>/dev/null || echo unknown)
assert_eq "the node is still running, not exited — it hangs rather than failing" "$RUNNING" "true"
docker rm -f lab01-lonely >/dev/null 2>&1 || true
# This is the exact symptom: it announces it is waiting, and then says nothing
# more. No error, no exit — which is why a bad --join is hard to spot.
assert_contains "the node reports it is waiting to join, and never errors" "$LONELY" \
    "attempt to join a running cluster\|wait for .cockroach init"
assert_not_contains "it never reports a started cluster" "$LONELY" "CockroachDB node starting"

# 3. Logs are reachable through the wrapper.
LOGS=$(run_for 8 bash "$REPO_ROOT/scripts/crdb.sh" logs 1)
assert_contains "scripts/crdb logs shows node startup" "$LOGS" "CockroachDB node starting\|node starting\|started with"

section "Done"
echo "Lab 1: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
