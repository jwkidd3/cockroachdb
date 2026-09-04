# Cluster lifecycle helpers for lab tests.
# Source AFTER lib/common.sh.
#
# These helpers drive the SAME thing students drive: the compose stacks in
# docker/ through the scripts/crdb wrapper. There is no native cockroach binary
# anywhere in this course, so there is none here either — every cockroach
# invocation below runs inside a cluster container via `scripts/crdb run`.
#
# Which stack a test uses is selected with CRDB_COMPOSE, exactly as in the labs:
#
#   (unset)                  docker/labs.yml         3-4 nodes, insecure   Labs 1-11, 13-15
#   docker/labs-b.yml        the standby cluster     Lab 11 restore target
#   docker/labs-secure.yml   TLS single node         Lab 12
#
# Because all tests share one Docker project per stack, they are sequential by
# design. run_all.sh runs them one at a time.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CRDB_COMPOSE="${CRDB_COMPOSE:-docker/labs.yml}"
export CRDB_COMPOSE

# Ports and container names follow the compose file, matching scripts/crdb.
case "$CRDB_COMPOSE" in
    *labs-b*)      NODE_PREFIX=crdbb; BASE_SQL_PORT=26357; BASE_HTTP_PORT=8180 ;;
    *labs-secure*) NODE_PREFIX=crdbs; BASE_SQL_PORT=26457; BASE_HTTP_PORT=8280 ;;
    *)             NODE_PREFIX=crdb;  BASE_SQL_PORT=26257; BASE_HTTP_PORT=8080 ;;
esac

CLUSTER_SIZE="${CLUSTER_SIZE:-3}"

# Host-side scratch space for files a test builds before copying them into a
# container (CSV fixtures, log configs, debug zips it pulls back out).
CLUSTER_TAG="${CLUSTER_TAG:-test-$$}"
STORE_BASE="${STORE_BASE:-/tmp/crdb-${CLUSTER_TAG}}"

# The URL workloads use. It is resolved INSIDE the cluster network, because
# `scripts/crdb run workload ...` executes in the node container — which is
# exactly what the labs tell students to type.
CRDB_URL="postgresql://root@${NODE_PREFIX}1:26257?sslmode=disable"
URL="$CRDB_URL"

# ---- The student wrapper --------------------------------------------------

# Every helper below funnels through this, so a test can never accidentally
# reach a cluster by a route no student has.
crdb() {
    ( cd "$REPO_ROOT" && bash scripts/crdb.sh "$@" )
}

# `scripts/crdb run <cockroach subcommand ...>` — workload, node, debug, cert,
# userfile, all of it.
crdb_run() {
    crdb run "$@"
}

# `scripts/crdb cp <src> <dst>` — move a file between host and container.
crdb_cp() {
    crdb cp "$@"
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        fail "Docker is not running. The labs and these tests both need it: start Docker Desktop (or dockerd) and retry."
    fi
}

# ---- Lifecycle ------------------------------------------------------------

# How many nodes report live right now. Ask a node that is actually up: the
# default is node 1, but Lab 1 stops node 1 on purpose.
live_nodes() {
    local via="${1:-1}"
    crdb sql-on "$via" --format=tsv -e \
        "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2>/dev/null \
        | tail -1 | tr -d '[:space:]'
}

# Block until the cluster reports exactly N live nodes.
wait_live() {
    local want="$1" timeout="${2:-90}" via="${3:-1}" i n
    for i in $(seq 1 "$timeout"); do
        n=$(live_nodes "$via")
        [ "$n" = "$want" ] && return 0
        sleep 1
    done
    return 1
}

# A node index that is not $1, for asking questions while $1 is down.
_other_node() {
    local down="$1" i
    for i in $(seq 1 "$CLUSTER_SIZE"); do
        [ "$i" != "$down" ] && { echo "$i"; return; }
    done
    echo 1
}

# Start a clean cluster. `scripts/crdb reset` is `down -v` then `up`, so each
# test begins with empty stores no matter how the previous one ended.
#
# Usage: start_cluster [N]   N is 3 (default) or 4 (adds the scale-profile node).
start_cluster() {
    require_docker
    local n="${1:-$CLUSTER_SIZE}"

    mkdir -p "$STORE_BASE"

    if [ "$CRDB_COMPOSE" = "docker/labs-secure.yml" ]; then
        info "starting the secure single-node cluster ($CRDB_COMPOSE)"
        crdb down >/dev/null 2>&1 || true
        crdb up >/dev/null 2>&1 || fail "secure cluster failed to start"
        CLUSTER_SIZE=1
        info "secure cluster ready; SQL on localhost:${BASE_SQL_PORT}"
        return 0
    fi

    info "starting a ${n}-node cluster via scripts/crdb ($CRDB_COMPOSE)"
    crdb reset >/dev/null 2>&1 || fail "scripts/crdb reset failed — run it by hand to see why"

    wait_live 3 90 || fail "cluster did not reach 3 live nodes"
    CLUSTER_SIZE=3

    if [ "$n" -ge 4 ]; then
        add_node
        n=$CLUSTER_SIZE
    elif [ "$n" -lt 3 ]; then
        warn "the compose cluster is 3 nodes; ignoring request for $n"
    fi

    info "cluster ready: ${CLUSTER_SIZE} nodes; SQL on localhost:${BASE_SQL_PORT}"
}

# `scripts/crdb add-node` — the 4th node from the scale profile.
add_node() {
    crdb add-node >/dev/null 2>&1 || fail "scripts/crdb add-node failed"
    wait_live 4 90 || fail "node 4 did not join"
    CLUSTER_SIZE=4
}

# `scripts/crdb down` — removes containers AND volumes.
stop_cluster() {
    info "stopping cluster ($CRDB_COMPOSE)"
    crdb down >/dev/null 2>&1 || true
    if [ "${KEEP_ON_FAIL:-0}" != "1" ]; then
        rm -rf "$STORE_BASE"
    else
        warn "leaving $STORE_BASE in place (KEEP_ON_FAIL=1)"
    fi
}

# `scripts/crdb stop N` — simulate a node failure, as Lab 1 does.
kill_node() {
    local idx="$1"
    info "stopping node $idx (scripts/crdb stop $idx)"
    crdb stop "$idx" >/dev/null 2>&1 || fail "scripts/crdb stop $idx failed"
    local want=$((CLUSTER_SIZE - 1))
    local via; via=$(_other_node "$idx")
    wait_live "$want" 60 "$via" \
        || warn "cluster reports $(live_nodes "$via") live nodes (wanted $want)"
}

# `scripts/crdb start N` — bring it back with its data intact.
restart_node() {
    local idx="$1"
    info "starting node $idx (scripts/crdb start $idx)"
    crdb start "$idx" >/dev/null 2>&1 || fail "scripts/crdb start $idx failed"
    wait_live "$CLUSTER_SIZE" 90 "$idx" || fail "node $idx did not rejoin"
}

# ---- SQL helpers ----------------------------------------------------------
# All of these are `scripts/crdb sql`, which is `cockroach sql` inside node 1.

# Run a SQL statement, dump the output to stdout. Errors are fatal.
sql() {
    crdb sql -e "$1"
}

# Run SQL silently. Returns the exit code.
sql_quiet() {
    crdb sql -e "$1" >/dev/null 2>&1
}

# Run SQL and capture a single scalar (first column of the first data row).
sql_value() {
    crdb sql --format=tsv -e "$1" 2>/dev/null \
        | tail -n +2 | head -1 | awk '{print $1}'
}

# Run SQL expected to fail; echo the error. Returns 0 iff it did fail.
sql_expect_fail() {
    local err rc
    err=$(crdb sql -e "$1" 2>&1 >/dev/null)
    rc=$?
    if [ $rc -eq 0 ]; then
        return 1
    fi
    echo "$err"
    return 0
}

# Feed a multi-statement script in on stdin:  sql_script <<'SQL' ... SQL
# scripts/crdb passes -T when stdin is not a TTY, so this pipes correctly.
sql_script() {
    crdb sql
}

# Run SQL on a specific node — `scripts/crdb sql-on N`.
sql_on_node() {
    local idx="$1" stmt="$2"
    crdb sql-on "$idx" -e "$stmt"
}

sql_value_on_node() {
    local idx="$1" stmt="$2"
    crdb sql-on "$idx" --format=tsv -e "$stmt" 2>/dev/null \
        | tail -n +2 | head -1 | awk '{print $1}'
}

# Run SQL as a non-root user (Lab 12): scripts/crdb sql --user=app_user -e ...
sql_as() {
    local user="$1" stmt="$2"
    crdb sql --user="$user" -e "$stmt"
}

sql_as_expect_fail() {
    local user="$1" stmt="$2" err rc
    err=$(crdb sql --user="$user" -e "$stmt" 2>&1 >/dev/null)
    rc=$?
    [ $rc -eq 0 ] && return 1
    echo "$err"
    return 0
}
