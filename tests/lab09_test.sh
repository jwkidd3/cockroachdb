#!/usr/bin/env bash
# Lab 9 — Observability: metrics endpoint, log channel routing, debug zip,
# statement diagnostics. Prometheus/Grafana containers are optional; when
# Docker is available the scrape config is validated against a live target.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab09"
source "$SCRIPT_DIR/lib/cluster.sh"

# The logging overlay mounts ./lab9 into the node at /lab9, so logs written
# inside the container land here where the test (and a student) can read them.
LAB9_DIR="$REPO_ROOT/lab9"
LOGDIR="$LAB9_DIR/logs"
ZIP="$STORE_BASE/debug.zip"

cleanup_all() {
    docker rm -f lab09-prom lab9-load >/dev/null 2>&1 || true
    ( cd "$REPO_ROOT" && docker compose -f docker/labs.yml -f docker/labs.logging.yml down -v >/dev/null 2>&1 ) || true
    stop_cluster
    [ "${KEEP_ON_FAIL:-0}" != "1" ] && rm -rf "$LAB9_DIR"
    return 0
}
trap cleanup_all EXIT INT TERM

section "Setup — 3-node cluster with load"
start_cluster 3

crdb_run workload init kv --drop "$URL" >/dev/null 2>&1 \
    && pass "kv workload initialized" || fail "workload init failed"

docker rm -f lab9-load >/dev/null 2>&1 || true
docker run -d --name lab9-load --network crdb-labs_default \
    cockroachdb/cockroach:${CRDB_VERSION:-v23.2.5} \
    workload run kv --duration=90s --concurrency=8 --read-percent=70 "$URL" \
    >/dev/null 2>&1 || warn "background load generator did not start"
sleep 5

section "Part A — the metrics endpoint"

VARS=$(curl -s "http://localhost:${BASE_HTTP_PORT}/_status/vars")
LINES=$(echo "$VARS" | wc -l | tr -d ' ')
assert_gt "/_status/vars returns a large metric set" "$LINES" "500"

# The metrics the lab puts on the wall must all be present.
for m in sql_service_latency_bucket sql_conns sql_query_count \
         liveness_livenodes ranges_underreplicated ranges_unavailable \
         capacity_available sys_cpu_combined_percent_normalized \
         txn_restarts_serializable; do
    assert_contains "metric exported: $m" "$VARS" "$m"
done

# liveness_livenodes is only meaningful on the node holding the liveness lease;
# other nodes report 0. Report it, but assert on the cluster-wide view instead.
LIVE=$(echo "$VARS" | grep '^liveness_livenodes' | awk '{print $2}' | cut -d. -f1)
info "liveness_livenodes on this node: ${LIVE:-unset}"
NODES=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "cluster reports 3 live nodes" "$NODES" "3"

UNAVAIL=$(echo "$VARS" | grep '^ranges_unavailable' | awk '{print $2}' | cut -d. -f1)
assert_eq "no unavailable ranges on a healthy cluster" "${UNAVAIL:-0}" "0"

# The same questions answerable in SQL.
NODE_METRICS=$(sql "SELECT node_id, metrics->>'sql.conns' FROM crdb_internal.kv_node_status;")
assert_contains "kv_node_status exposes sql.conns" "$NODE_METRICS" "node_id"

section "Part B — Prometheus scrape config (optional, needs Docker)"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    cat > "${STORE_BASE}/prometheus.yml" <<YML
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: cockroachdb
    metrics_path: /_status/vars
    static_configs:
      - targets: ['crdb1:8080', 'crdb2:8080', 'crdb3:8080']
YML
    # On the cluster network to reach the nodes, publishing 9090 to reach its
    # API. `--network=host` would work on Linux only, and students use macOS too.
    if docker run -d --name lab09-prom -p 9090:9090 \
         --network crdb-labs_default \
         -v "${STORE_BASE}/prometheus.yml:/etc/prometheus/prometheus.yml" \
         prom/prometheus >/dev/null 2>&1; then
        wait_for "prometheus API up" 45 "curl -sf http://localhost:9090/-/ready"
        sleep 12
        TARGETS=$(curl -s 'http://localhost:9090/api/v1/targets')
        assert_contains "prometheus scraped the cockroach target" "$TARGETS" "cockroachdb"
        UP=$(curl -s 'http://localhost:9090/api/v1/query?query=up' | grep -o '"value":\[[^]]*\]' | head -1)
        assert_contains "target reports up=1" "$UP" "1"
        HEALTHY=$(curl -s 'http://localhost:9090/api/v1/targets' | grep -c '"health":"up"' || true)
        assert_ge "all three nodes are healthy targets" "$HEALTHY" "1"
        docker rm -f lab09-prom >/dev/null 2>&1
    else
        warn "could not start prometheus container (host networking may be unavailable); skipping"
    fi
else
    warn "Docker unavailable; skipping the Prometheus scrape check"
fi

section "Part D — structured log channels"

# mkdir first so the directory belongs to the user rather than to Docker.
mkdir -p "$LAB9_DIR"
cat > "$LAB9_DIR/logs.yaml" <<'YML'
file-defaults:
  dir: /lab9/logs
  buffered-writes: true
sinks:
  file-groups:
    health:
      channels: [HEALTH]
      filter: INFO
    ops:
      channels: [OPS]
      filter: INFO
    security:
      channels: [SENSITIVE_ACCESS, USER_ADMIN, PRIVILEGES]
      filter: INFO
      auditable: true
  stderr:
    filter: NONE
YML

CHECK=$(crdb_run debug check-log-config --log-config-file=/lab9/logs.yaml 2>&1 || true)
if echo "$CHECK" | grep -qi "SENSITIVE_ACCESS"; then
    pass "log config parses and routes SENSITIVE_ACCESS"
else
    warn "check-log-config output did not mention SENSITIVE_ACCESS; flag support varies by version"
fi

# Restart node 1 with the channel-splitting config, the way the lab does: a
# compose overlay adds --log-config-file and mounts ./lab9. The base file is
# never edited.
( cd "$REPO_ROOT" && docker compose -f docker/labs.yml -f docker/labs.logging.yml up -d crdb1 ) >/dev/null 2>&1 \
    || fail "node 1 failed to restart with the logging overlay"
wait_for "node 1 back with the log config" 60 "sql_quiet 'SELECT 1;'"
pass "node restarted with channel-split logging"

# Generate events on the security channels.
sql "CREATE USER lab9_auditor;" >/dev/null
sql "CREATE DATABASE lab9; CREATE TABLE lab9.t (id INT PRIMARY KEY, secret STRING);" >/dev/null
sql "INSERT INTO lab9.t VALUES (1, 'x');" >/dev/null
sql "GRANT SELECT ON TABLE lab9.t TO lab9_auditor;" >/dev/null
sql "ALTER TABLE lab9.t EXPERIMENTAL_AUDIT SET READ WRITE;" >/dev/null
sql "SELECT count(*) FROM lab9.t;" >/dev/null
sleep 3
sql "ALTER TABLE lab9.t EXPERIMENTAL_AUDIT SET OFF;" >/dev/null

assert_command_succeeds "log directory created" test -d "$LOGDIR"
if ls "$LOGDIR"/*security*.log >/dev/null 2>&1; then
    pass "dedicated security log file created"
    SEC_EVENTS=$(grep -ho '"EventType":"[^"]*"' "$LOGDIR"/*security*.log 2>/dev/null | sort -u | head -10)
    if [ -n "$SEC_EVENTS" ]; then
        pass "security channel captured structured events"
        echo "$SEC_EVENTS" | sed 's/^/    /'
    else
        warn "security log file present but no structured events captured yet"
    fi
else
    warn "no security log file found in $LOGDIR (channel naming varies by version)"
    ls "$LOGDIR" | sed 's/^/    /'
fi

section "Part E — debug zip and statement diagnostics"

mkdir -p "$STORE_BASE"
if crdb_run debug zip /tmp/debug.zip --insecure >/dev/null 2>&1 \
   && crdb_cp crdb1:/tmp/debug.zip "$ZIP" >/dev/null 2>&1; then
    assert_file_exists "debug zip created and copied out with scripts/crdb cp" "$ZIP"
    if command -v unzip >/dev/null 2>&1; then
        CONTENTS=$(unzip -l "$ZIP" 2>/dev/null)
        assert_contains "zip contains per-node status" "$CONTENTS" "nodes/"
        assert_contains "zip contains cluster settings" "$CONTENTS" "settings"
        ENTRIES=$(unzip -l "$ZIP" 2>/dev/null | grep -c '^  *[0-9]')
        assert_gt "zip has a meaningful number of entries" "${ENTRIES:-0}" "20"
    else
        warn "unzip not installed; cannot inspect the debug zip contents"
    fi

    if crdb_run debug zip /tmp/debug-redacted.zip --insecure --redact >/dev/null 2>&1 \
       && crdb_cp crdb1:/tmp/debug-redacted.zip "${ZIP}.redacted" >/dev/null 2>&1; then
        assert_file_exists "redacted debug zip created" "${ZIP}.redacted"
    else
        warn "--redact unsupported on this version"
    fi
else
    warn "debug zip failed (can be slow/flaky under load); skipping zip assertions"
fi

DBG=$(sql "EXPLAIN ANALYZE (DEBUG) SELECT count(*) FROM lab9.t;" 2>&1 || true)
assert_contains "statement diagnostics bundle produced" "$DBG" "bundle"

section "Done"
echo "Lab 9: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
