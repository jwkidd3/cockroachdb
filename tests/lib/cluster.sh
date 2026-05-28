# Cluster lifecycle helpers for lab tests.
# Source AFTER lib/common.sh.

# Per-test isolation: every test gets its own port range and store directory,
# selected from the test script name + PID so multiple tests can run in parallel.

CLUSTER_TAG="${CLUSTER_TAG:-test-$$}"
CLUSTER_SIZE="${CLUSTER_SIZE:-3}"
STORE_BASE="${STORE_BASE:-/tmp/crdb-${CLUSTER_TAG}}"
BASE_SQL_PORT="${BASE_SQL_PORT:-26257}"
BASE_HTTP_PORT="${BASE_HTTP_PORT:-8080}"

# Pipe-joined list of localities (one entry per node), used by start_cluster.
# Default is empty (single-region). Override for Lab 7 multi-region:
#   CLUSTER_LOCALITIES="region=us-east1,zone=a|region=us-east1,zone=b|..."
CLUSTER_LOCALITIES="${CLUSTER_LOCALITIES:-}"

# Track PIDs so stop_cluster can SIGTERM them.
CLUSTER_PIDS=()

# Build a localhost:port list for --join.
_join_string() {
    local n="$1" i first=1 out=""
    for i in $(seq 1 "$n"); do
        if [ $first -eq 1 ]; then first=0; else out="${out},"; fi
        out="${out}localhost:$((BASE_SQL_PORT+i-1))"
    done
    echo "$out"
}

# Start an insecure N-node cluster on localhost.
# Usage: start_cluster [N]
start_cluster() {
    require_cockroach
    local n="${1:-$CLUSTER_SIZE}"
    local join
    join=$(_join_string "$n")

    info "starting $n-node insecure cluster (stores under $STORE_BASE)"
    rm -rf "$STORE_BASE"
    mkdir -p "$STORE_BASE"

    local i locality_flag=""
    for i in $(seq 1 "$n"); do
        locality_flag=""
        if [ -n "$CLUSTER_LOCALITIES" ]; then
            # CLUSTER_LOCALITIES is comma-separated, one per node
            locality_flag="--locality=$(echo "$CLUSTER_LOCALITIES" | awk -v n="$i" -F'|' '{print $n}')"
        fi

        cockroach start --insecure \
            --store="${STORE_BASE}/n${i}" \
            --listen-addr="localhost:$((BASE_SQL_PORT+i-1))" \
            --http-addr="localhost:$((BASE_HTTP_PORT+i-1))" \
            --join="$join" \
            --pid-file="${STORE_BASE}/n${i}.pid" \
            --log="{sinks: {stderr: {filter: NONE}}}" \
            $locality_flag \
            --background \
            >>"${STORE_BASE}/n${i}.out" 2>&1 \
            || fail "node $i failed to start (see ${STORE_BASE}/n${i}.out)"
    done

    # Initialize the cluster (one-time per cluster lifetime).
    cockroach init --insecure --host="localhost:${BASE_SQL_PORT}" \
        >/dev/null 2>&1 \
        || fail "cluster init failed"

    # Wait until SQL is reachable on node 1.
    wait_for "SQL ready on node 1" 30 \
        "cockroach sql --insecure --host=localhost:${BASE_SQL_PORT} --execute 'SELECT 1;'"

    # Track PIDs (used by kill_node / stop_cluster).
    CLUSTER_PIDS=()
    for i in $(seq 1 "$n"); do
        CLUSTER_PIDS[$i]=$(cat "${STORE_BASE}/n${i}.pid" 2>/dev/null || echo "")
    done

    CLUSTER_SIZE="$n"
    info "cluster ready: ${n} nodes; SQL on localhost:${BASE_SQL_PORT}"
}

# Forcibly stop the cluster and clean up.
stop_cluster() {
    info "stopping cluster"
    # Quit each node; tolerate errors (node may already be down).
    local i
    for i in $(seq 1 "${CLUSTER_SIZE:-3}"); do
        cockroach node drain --insecure --host="localhost:$((BASE_SQL_PORT+i-1))" \
            --drain-wait=5s >/dev/null 2>&1 || true
    done
    # SIGTERM any survivors.
    for i in $(seq 1 "${CLUSTER_SIZE:-3}"); do
        local pid="${CLUSTER_PIDS[$i]:-}"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    sleep 1
    # SIGKILL stragglers.
    pkill -f "cockroach start --insecure --store=${STORE_BASE}" 2>/dev/null || true

    if [ "${KEEP_ON_FAIL:-0}" != "1" ]; then
        rm -rf "$STORE_BASE"
    else
        warn "leaving $STORE_BASE in place (KEEP_ON_FAIL=1)"
    fi
}

# Kill a specific node by its index (1-based). Survives by Raft quorum if you started 3+.
kill_node() {
    local idx="$1"
    local pid="${CLUSTER_PIDS[$idx]:-}"
    [ -n "$pid" ] || fail "kill_node: no PID for node $idx"
    info "killing node $idx (pid $pid)"
    kill "$pid" 2>/dev/null || true
    # Wait until the node really is gone.
    wait_for "node $idx down" 10 "! kill -0 $pid 2>/dev/null"
}

# Restart a previously-killed node (reuses its store; rejoins).
restart_node() {
    local idx="$1"
    local n="$CLUSTER_SIZE"
    local join
    join=$(_join_string "$n")
    info "restarting node $idx"
    local locality_flag=""
    if [ -n "$CLUSTER_LOCALITIES" ]; then
        locality_flag="--locality=$(echo "$CLUSTER_LOCALITIES" | cut -d',' -f"$idx")"
    fi
    cockroach start --insecure \
        --store="${STORE_BASE}/n${idx}" \
        --listen-addr="localhost:$((BASE_SQL_PORT+idx-1))" \
        --http-addr="localhost:$((BASE_HTTP_PORT+idx-1))" \
        --join="$join" \
        --pid-file="${STORE_BASE}/n${idx}.pid" \
        --log="{sinks: {stderr: {filter: NONE}}}" \
        $locality_flag \
        --background \
        >>"${STORE_BASE}/n${idx}.out" 2>&1 \
        || fail "node $idx failed to restart"
    CLUSTER_PIDS[$idx]=$(cat "${STORE_BASE}/n${idx}.pid")
    wait_for "node $idx back" 30 \
        "cockroach sql --insecure --host=localhost:$((BASE_SQL_PORT+idx-1)) --execute 'SELECT 1;'"
}

# ---- SQL helpers ----------------------------------------------------------

# Run a SQL statement, dump the (default) output to stdout. Errors are fatal.
sql() {
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" --execute "$1"
}

# Run SQL silently. Returns the exit code of the cockroach call.
sql_quiet() {
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" --execute "$1" \
        >/dev/null 2>&1
}

# Run SQL and capture a single scalar value (first column of first non-header row).
sql_value() {
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" \
        --format=tsv --execute "$1" 2>/dev/null \
        | tail -n +2 | head -1 | awk '{print $1}'
}

# Run SQL expected to fail; capture the error message on stderr.
# Returns 0 if the SQL failed (with msg on stdout), non-zero if it unexpectedly succeeded.
sql_expect_fail() {
    local err
    err=$(cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" --execute "$1" 2>&1 >/dev/null)
    if [ $? -eq 0 ]; then
        return 1
    fi
    echo "$err"
    return 0
}

# Run SQL via stdin (multi-statement scripts).
sql_script() {
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}"
}

# Run SQL against a specific node (1-based index). For multi-region / locality tests.
sql_on_node() {
    local idx="$1" stmt="$2"
    cockroach sql --insecure --host="localhost:$((BASE_SQL_PORT+idx-1))" --execute "$stmt"
}

sql_value_on_node() {
    local idx="$1" stmt="$2"
    cockroach sql --insecure --host="localhost:$((BASE_SQL_PORT+idx-1))" \
        --format=tsv --execute "$stmt" 2>/dev/null \
        | tail -n +2 | head -1 | awk '{print $1}'
}
