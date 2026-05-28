#!/usr/bin/env bash
# Lab 1 — Cluster Bootstrap & Lifecycle
#
# Tests cover Parts A, B, C (cluster start + node kill + recovery),
# Part D (real multi-process cluster), Part E (decommission/recommission),
# Part F (PG wire compatibility), and Part G (error scenarios).
#
# Web UI observation steps (visual) are noted but not directly asserted.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab01"
BASE_SQL_PORT=26257
BASE_HTTP_PORT=8080
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Part A/D — Start a 3-node cluster (this exercises the real cockroach start + init flow)"
start_cluster 3

LIVE_NODES=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "3 live nodes after start+init" "$LIVE_NODES" "3"

section "Part A — Create database and load notes"
sql "CREATE DATABASE lab1;" >/dev/null
sql "CREATE TABLE lab1.notes (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), body STRING NOT NULL, made TIMESTAMPTZ DEFAULT now());" >/dev/null
sql "INSERT INTO lab1.notes (body) SELECT 'note ' || generate_series(1, 1000)::STRING;" >/dev/null

NOTE_COUNT=$(sql_value "SELECT count(*) FROM lab1.notes;")
assert_eq "1000 notes inserted" "$NOTE_COUNT" "1000"

RANGE_COUNT=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS];")
assert_ge "notes table has at least 1 range" "$RANGE_COUNT" "1"

section "Part B — Kill a follower; verify cluster keeps serving"
# Identify the leaseholder for notes. We'll kill a non-leaseholder.
LEASEHOLDER=$(sql_value "SELECT lease_holder FROM [SHOW RANGES FROM TABLE lab1.notes WITH DETAILS] LIMIT 1;")
info "leaseholder is node $LEASEHOLDER"

# Pick any non-leaseholder
VICTIM=1
for n in 1 2 3; do
    if [ "$n" != "$LEASEHOLDER" ]; then VICTIM="$n"; break; fi
done
info "killing follower: node $VICTIM"

kill_node "$VICTIM"

# Reads/writes still work against a survivor (pick one that's not the victim).
SURVIVOR=$((VICTIM % 3 + 1))   # any node != VICTIM
[ "$SURVIVOR" = "$VICTIM" ] && SURVIVOR=$((SURVIVOR % 3 + 1))

# Query against a survivor
COUNT_AFTER_KILL=$(sql_value_on_node "$SURVIVOR" "SELECT count(*) FROM lab1.notes;")
assert_eq "reads still work after follower kill" "$COUNT_AFTER_KILL" "1000"

sql_on_node "$SURVIVOR" "INSERT INTO lab1.notes (body) VALUES ('survives a follower outage');" >/dev/null
COUNT_AFTER_INSERT=$(sql_value_on_node "$SURVIVOR" "SELECT count(*) FROM lab1.notes;")
assert_eq "writes still work after follower kill" "$COUNT_AFTER_INSERT" "1001"

section "Part B — Restart and verify recovery"
restart_node "$VICTIM"
sleep 5  # give it a moment to catch up via Raft

LIVE_AFTER_RESTART=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "3 live nodes after restart" "$LIVE_AFTER_RESTART" "3"

# Under-replicated ranges should converge to 0
wait_for "under-replicated ranges drop to 0" 60 \
    "cockroach sql --insecure --host=localhost:${BASE_SQL_PORT} --format=tsv --execute \"SELECT (SELECT count(*) FROM crdb_internal.ranges_no_leases WHERE array_length(replicas,1) < 3) = 0;\" | tail -n +2 | grep -q '^true'"
pass "all ranges back to full replication"

section "Part E — Graceful decommission, then recommission"
# Decommission node 3 (or whichever survived all the above)
DECOMM_NODE=3
info "decommissioning node $DECOMM_NODE"
if cockroach node decommission "$DECOMM_NODE" --insecure --host="localhost:${BASE_SQL_PORT}" >/dev/null 2>&1; then
    pass "decommission command completed"
else
    fail "decommission command failed"
fi

# After decommission, the node should be marked draining/decommissioning AND is_live = false.
sleep 3
DECOMM_STATE=$(sql_value "SELECT membership FROM crdb_internal.kv_node_liveness WHERE node_id = $DECOMM_NODE;")
assert_contains "node $DECOMM_NODE is decommissioning or decommissioned" \
    "$DECOMM_STATE" "decommiss"

# Recommission won't bring a fully decommissioned node back; that's the documented behavior.
# Confirm the cluster is still serving with the remaining nodes.
COUNT_AFTER_DECOMM=$(sql_value "SELECT count(*) FROM lab1.notes;")
assert_eq "cluster still serves after decommission" "$COUNT_AFTER_DECOMM" "1001"

section "Part F — PG wire compatibility"
# psql is optional but most CI runners have it. Skip cleanly if absent.
if command -v psql >/dev/null 2>&1; then
    PSQL_COUNT=$(PGPASSWORD="" psql -At "postgresql://root@localhost:${BASE_SQL_PORT}/lab1?sslmode=disable" \
        -c "SELECT count(*) FROM notes;" 2>/dev/null)
    assert_eq "psql sees the same row count" "$PSQL_COUNT" "1001"
else
    warn "psql not on PATH; skipping psql connectivity check (lab content still valid)"
fi

# Python check is also optional
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
    assert_eq "python (psycopg2) sees the same row count" "$PY_COUNT" "1001"
else
    warn "psycopg2 not installed; skipping Python connectivity check"
fi

section "Part F — CRDB built-ins via PG protocol"
CLUSTER_ID=$(sql_value "SELECT crdb_internal.cluster_id();")
assert_ge "cluster_id() returned a non-empty UUID" "${#CLUSTER_ID}" "30"

section "Part G — Common startup errors produce diagnosable output"
# Port-in-use error: start a node on a port that's already taken.
PORT_ERR_OUT=$(cockroach start --insecure --store="${STORE_BASE}/dup" \
    --listen-addr="localhost:${BASE_SQL_PORT}" --http-addr=localhost:9091 \
    --join="localhost:${BASE_SQL_PORT}" --background 2>&1 || true)
assert_contains "port-in-use error message is clear" "$PORT_ERR_OUT" "in use"
rm -rf "${STORE_BASE}/dup"

section "Done"
echo "Lab 1: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
