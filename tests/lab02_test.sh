#!/usr/bin/env bash
# Lab 2 — DB Console & SQL Operational Tour
#
# Tests cover Parts B (workload generation), C (crdb_internal queries),
# D (custom dashboard SQL), E (jobs), F (session inspection).
# Part A is pure UI observation — not directly testable.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab02"
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup — 3-node cluster"
start_cluster 3

section "Part B — Initialize and run kv workload"
crdb_run workload init kv --drop "$CRDB_URL" >/dev/null 2>&1
assert_command_succeeds "kv workload init succeeded" \
    crdb sql \
    --execute "SELECT count(*) FROM kv.kv;"

# Short workload run — read/write mix
info "running 10s read-heavy kv workload (50/50 r/w, concurrency 4)"
crdb_run workload run kv \
    --duration=10s --concurrency=4 --read-percent=50 \
    "$CRDB_URL" >/dev/null 2>&1
KV_ROWS=$(sql_value "SELECT count(*) FROM kv.kv;")
assert_gt "workload produced rows in kv.kv" "$KV_ROWS" "0"

info "running 8s write-heavy kv workload (10/90 r/w, concurrency 8)"
crdb_run workload run kv \
    --duration=8s --concurrency=8 --read-percent=10 \
    "$CRDB_URL" >/dev/null 2>&1

info "running 8s high-contention workload (--cycle-length=10)"
crdb_run workload run kv \
    --duration=8s --concurrency=8 --read-percent=0 \
    --batch=1 --cycle-length=10 \
    "$CRDB_URL" >/dev/null 2>&1

section "Part C — crdb_internal operational queries each return data"

# 1. Node health
LIVE=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "3 live nodes" "$LIVE" "3"

# 2. Top statements: the kv workload should have left UPSERT or SELECT in stats
TOP_HAS_KV=$(sql_value "SELECT count(*) FROM crdb_internal.statement_statistics \
    WHERE metadata->>'query' LIKE '%kv%' OR metadata->>'query' LIKE '%UPSERT%';")
assert_gt "statement_statistics has kv workload entries" "$TOP_HAS_KV" "0"

# 3. cluster_sessions returns at least our own
# A session is only 'active' while a statement is in flight; by the time this
# query runs, our own session is 'idle'. Count every session instead.
SESSION_COUNT=$(sql_value "SELECT count(*) FROM crdb_internal.cluster_sessions;")
assert_ge "cluster_sessions returns at least our own session" "$SESSION_COUNT" "1"

# 4. kv_store_status has per-node entries
STORE_ROWS=$(sql_value "SELECT count(*) FROM crdb_internal.kv_store_status;")
assert_ge "kv_store_status has per-node rows" "$STORE_ROWS" "3"

# 5. Storage usage parseable
AVAIL=$(sql_value "SELECT (metrics->>'capacity.available')::DECIMAL FROM crdb_internal.kv_store_status LIMIT 1;")
[ -n "$AVAIL" ] && pass "capacity.available metric is parseable ($AVAIL)" \
    || fail "capacity.available metric missing or unparseable"

# 6. Ranges for the kv table.
# NOTE: crdb_internal.ranges_no_leases has no table_name column (and there is no
# crdb_internal.cluster_replicas). Use SHOW RANGES for anything table-scoped.
USER_RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE kv.kv];")
assert_ge "kv table has at least 1 range" "$USER_RANGES" "1"

section "Part D — Custom dashboard query returns sensible values"
DASHBOARD=$(sql "WITH
   liveness AS (SELECT count(*) FILTER (WHERE is_live) AS up,
                       count(*) FILTER (WHERE NOT is_live) AS down
                FROM crdb_internal.gossip_nodes)
   SELECT (SELECT up FROM liveness) AS nodes_up,
          (SELECT down FROM liveness) AS nodes_down;")
assert_contains "dashboard query reports 3 nodes_up" "$DASHBOARD" "3"

section "Part E — Jobs and schema change"
# Trigger a schema change job
sql "CREATE INDEX kv_v_idx ON kv.kv(v);" >/dev/null
sleep 2

# v23.2 records CREATE INDEX as 'NEW SCHEMA CHANGE' (declarative schema changer);
# 'SCHEMA CHANGE' is the legacy changer, still used by e.g. TRUNCATE.
JOB_COUNT=$(sql_value "SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE', 'NEW SCHEMA CHANGE');")
assert_ge "schema change recorded as a job" "$JOB_COUNT" "1"

# Wait for it to finish
wait_for "schema change job completes" 30 \
    "crdb sql --format=tsv -e \"SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE', 'NEW SCHEMA CHANGE') AND status NOT IN ('succeeded','failed','canceled');\" | tail -n +2 | grep -q '^0\$'"

section "Part F — Session inspection"
SESSIONS_LIST=$(sql "SELECT node_id, application_name, client_address FROM crdb_internal.cluster_sessions WHERE status = 'active';")
assert_contains "session list contains node_id column" "$SESSIONS_LIST" "node_id"

section "Done"
echo "Lab 2: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
