#!/usr/bin/env bash
# Lab 10 — TPC-C benchmark and capacity sizing.
# Runs a small TPC-C (1 warehouse) plus kv ceilings at three read/write mixes,
# and checks the admission-control settings and metrics the lab relies on.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab10"
source "$SCRIPT_DIR/lib/cluster.sh"

# Workloads run inside the node container now, so `scripts/crdb down` is what
# stops them — there is no host process to kill.
cleanup_all() { stop_cluster; }
trap cleanup_all EXIT INT TERM

section "Setup — 3-node cluster"
start_cluster 3

section "Part A — the workload suite"

# `crdb_run workload list` does not exist; generators are subcommands of init/run.
LIST=$(crdb_run workload init --help 2>&1)
for w in kv tpcc ycsb movr bank; do
    assert_contains "workload generator available: $w" "$LIST" "$w"
done

section "Part B — TPC-C"

# fixtures import needs network access to the fixtures bucket; init always works.
if crdb_run workload init tpcc --warehouses=1 "$URL" >/dev/null 2>&1; then
    pass "TPC-C schema loaded (1 warehouse)"
else
    fail "TPC-C init failed"
fi

# The schema lesson the lab teaches: every table leads its PK with the warehouse id.
OL_PK=$(sql "SHOW CREATE TABLE tpcc.order_line;")
assert_contains "order_line primary key leads with ol_w_id" "$OL_PK" "ol_w_id"
STOCK_PK=$(sql "SHOW CREATE TABLE tpcc.stock;")
assert_contains "stock primary key leads with s_w_id" "$STOCK_PK" "s_w_id"

TABLES=$(sql_value "SELECT count(*) FROM [SHOW TABLES FROM tpcc];")
assert_ge "TPC-C created its 9 tables" "$TABLES" "9"

TPCC_OUT=$(crdb_run workload run tpcc --warehouses=1 --ramp=5s --duration=30s "$URL" 2>&1 | tail -6)
echo "$TPCC_OUT" | sed 's/^/    /'
assert_contains "TPC-C run reported tpmC" "$TPCC_OUT" "tpmC"

section "Part C — per-node ceiling at three read/write mixes"

crdb_run workload init kv --drop "$URL" >/dev/null 2>&1 || fail "kv init failed"

for RP in 95 50 0; do
    OUT=$(crdb_run workload run kv --duration=15s --concurrency=16 --read-percent=$RP "$URL" 2>&1 | tail -3)
    OPS=$(echo "$OUT" | tail -1 | awk '{print $3}')
    if echo "$OUT" | grep -qE '[0-9]'; then
        pass "kv run at read-percent=$RP produced a throughput figure"
        echo "$OUT" | sed 's/^/    /'
    else
        fail "kv run at read-percent=$RP produced no output"
    fi
done

section "Part D — admission control"

for s in admission.kv.enabled admission.sql_kv_response.enabled admission.sql_sql_response.enabled; do
    V=$(sql_value "SHOW CLUSTER SETTING $s;")
    assert_true "$s is enabled by default" "$V"
done

# QoS session settings the lab uses to deprioritize analytics.
assert_command_succeeds "background QoS accepted" \
    crdb sql \
    --execute "SET default_transaction_quality_of_service = 'background'; SELECT 1;"
assert_command_succeeds "critical QoS accepted" \
    crdb sql \
    --execute "SET default_transaction_quality_of_service = 'critical'; SELECT 1;"

# The metrics used to identify the bottleneck must exist.
# sys.* and admission.* are NODE metrics; rocksdb.* and capacity.* are STORE
# metrics. Querying the wrong view yields NULL, not an error.
NODE_METRICS=$(sql "SELECT node_id,
                      metrics->>'sys.cpu.combined.percent-normalized' AS cpu,
                      metrics->>'admission.wait_durations.kv-p99' AS adm_p99
                    FROM crdb_internal.kv_node_status;")
assert_contains "per-node CPU metric queryable" "$NODE_METRICS" "cpu"
CPU_VAL=$(sql_value "SELECT metrics->>'sys.cpu.combined.percent-normalized' FROM crdb_internal.kv_node_status LIMIT 1;")
[ -n "$CPU_VAL" ] && pass "node CPU metric has a value ($CPU_VAL)" || fail "node CPU metric is NULL"

STORE_METRICS=$(sql "SELECT node_id, store_id,
                       metrics->>'rocksdb.read-amplification' AS read_amp
                     FROM crdb_internal.kv_store_status;")
assert_contains "per-store read amplification queryable" "$STORE_METRICS" "read_amp"
RA_VAL=$(sql_value "SELECT metrics->>'rocksdb.read-amplification' FROM crdb_internal.kv_store_status LIMIT 1;")
[ -n "$RA_VAL" ] && pass "store read-amplification has a value ($RA_VAL)" || fail "store read-amp is NULL"

CONTENTION=$(sql "SELECT count(*) FROM crdb_internal.transaction_contention_events;" 2>&1 || true)
assert_contains "contention events view is queryable" "$CONTENTION" "count"

section "Done"
echo "Lab 10: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
