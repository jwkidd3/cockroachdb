#!/usr/bin/env bash
# Drive the course's lab cluster. Everything runs in Docker — there is no
# cockroach binary to install.
#
#   scripts/crdb.sh up             start a 3-node cluster and initialise it
#   scripts/crdb.sh sql            open a SQL shell on node 1
#   scripts/crdb.sh sql -e "..."   run SQL non-interactively
#   scripts/crdb.sh sql-on 2       open a SQL shell on node 2
#   scripts/crdb.sh status         node status
#   scripts/crdb.sh stop 2         stop node 2 (simulate a failure)
#   scripts/crdb.sh start 2        bring node 2 back
#   scripts/crdb.sh add-node       start a 4th node
#   scripts/crdb.sh upgrade 2 v23.2.6   restart node 2 on another version (rolling upgrade)
#   scripts/crdb.sh run <cmd...>   any cockroach subcommand on node 1
#   scripts/crdb.sh console        print the DB Console URL
#   scripts/crdb.sh logs [n]       tail a node's logs
#   scripts/crdb.sh down           remove the cluster AND its data
#   scripts/crdb.sh reset          down, then up
#
# The class licence is read from .license.env in the repo root and applied by
# `up`. COCKROACH_LICENSE in the environment overrides it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# The class enterprise licence lives in .license.env at the repo root and is
# distributed with the repo. Plain KEY=VALUE lines. Applied automatically by
# `up`, so students never touch it.
if [ -f .license.env ]; then
    set -a; . ./.license.env; set +a
fi
# CRDB_COMPOSE selects which cluster to drive. Lab 11 uses the standby:
#   CRDB_COMPOSE=docker/labs-b.yml scripts/crdb.sh up
CRDB_COMPOSE="${CRDB_COMPOSE:-docker/labs.yml}"
COMPOSE=(docker compose -f "$CRDB_COMPOSE")
# Service names are crdb1..4 in the main cluster, crdbb1..4 in the standby.
case "$CRDB_COMPOSE" in
  *labs-b*)      NODE=crdbb; HTTP0=8180; SQL0=26357; SECURE=0 ;;
  *labs-secure*) NODE=crdbs; HTTP0=8280; SQL0=26457; SECURE=1 ;;
  *)             NODE=crdb;  HTTP0=8080; SQL0=26257; SECURE=0 ;;
esac
# The secure cluster authenticates with certificates instead of --insecure.
if [ "$SECURE" = "1" ]; then
    AUTH=(--certs-dir=/certs --host=${NODE}1)
else
    AUTH=(--insecure)
fi
CMD="${1:-help}"; shift || true

# Apply an enterprise licence if the instructor has one in the environment.
# Unlocks incremental backups and revision_history (Lab 11), Kafka-sink
# changefeeds (Lab 13), and multi-region SQL on this cluster (Lab 7 normally
# borrows the temporary licence that `cockroach demo` ships with).
apply_license() {
    [ -n "${COCKROACH_LICENSE:-}" ] || return 0
    # A licence is bound to an organization NAME, which may be empty — the class
    # key is. Setting cluster.organization to anything else makes the key
    # invalid ("license valid only for ..."), so only set it when told to.
    local org_sql=""
    [ -n "${COCKROACH_ORG:-}" ] && org_sql="SET CLUSTER SETTING cluster.organization = '${COCKROACH_ORG}';"
    "${COMPOSE[@]}" exec -T ${NODE}1 ./cockroach sql "${AUTH[@]}" -e \
        "${org_sql} SET CLUSTER SETTING enterprise.license = '${COCKROACH_LICENSE}';" >/dev/null 2>&1 \
      && echo "enterprise licence applied" \
      || echo "WARNING: could not apply COCKROACH_LICENSE (is it valid and unexpired?)" >&2
}

need_docker() {
    docker info >/dev/null 2>&1 || {
        echo "ERROR: Docker is not running. Start Docker Desktop and try again." >&2
        exit 1
    }
}

case "$CMD" in
  up)
    need_docker
    if [ "$SECURE" = "1" ]; then
        "${COMPOSE[@]}" up -d
        echo "waiting for the secure node..."
        for _ in $(seq 1 60); do
            "${COMPOSE[@]}" exec -T ${NODE}1 ./cockroach sql "${AUTH[@]}" -e "SELECT 1" >/dev/null 2>&1 && break
            sleep 2
        done
        "${COMPOSE[@]}" exec -T ${NODE}1 ./cockroach cert list --certs-dir=/certs
        apply_license
        echo
        echo "DB Console: https://localhost:${HTTP0}   (self-signed certificate)"
        exit 0
    fi
    "${COMPOSE[@]}" up -d ${NODE}1 ${NODE}2 ${NODE}3
    echo "waiting for the cluster to initialise..."
    "${COMPOSE[@]}" up init
    # Nodes join through gossip, which takes a moment after init returns. Wait for
    # all three, or the node list below prints a half-formed cluster and looks broken.
    echo "waiting for all nodes to join..."
    for _ in $(seq 1 60); do
        n=$("${COMPOSE[@]}" exec -T ${NODE}1 ./cockroach sql "${AUTH[@]}" --format=tsv \
              -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2>/dev/null \
              | tail -1 | tr -d '[:space:]')
        [ "$n" = "3" ] && break
        sleep 2
    done
    "${COMPOSE[@]}" exec -T ${NODE}1 ./cockroach sql "${AUTH[@]}" -e \
        "SELECT node_id, address, is_live FROM crdb_internal.gossip_nodes ORDER BY node_id;"
    apply_license
    echo
    echo "DB Console: http://localhost:${HTTP0}   (node 2: $((HTTP0+1)), node 3: $((HTTP0+2)))"
    echo "SQL:        localhost:${SQL0}"
    ;;
  sql)      need_docker
            # -T (no TTY) when stdin is a pipe, so `... | scripts/crdb sql` works;
            # a TTY when it is interactive, so the shell behaves normally.
            if [ -t 0 ]; then TTY=(); else TTY=(-T); fi
            "${COMPOSE[@]}" exec ${TTY[@]+"${TTY[@]}"} ${NODE}1 ./cockroach sql "${AUTH[@]}" "$@" ;;
  sql-on)   need_docker; n="${1:-1}"; shift || true
            if [ -t 0 ]; then TTY=(); else TTY=(-T); fi
            "${COMPOSE[@]}" exec ${TTY[@]+"${TTY[@]}"} "${NODE}${n}" ./cockroach sql "${AUTH[@]}" "$@" ;;
  run)      need_docker
            if [ -t 0 ]; then TTY=(); else TTY=(-T); fi
            "${COMPOSE[@]}" exec ${TTY[@]+"${TTY[@]}"} ${NODE}1 ./cockroach "$@" ;;
  status)   need_docker; "${COMPOSE[@]}" exec ${NODE}1 ./cockroach node status "${AUTH[@]}" ;;
  stop)     need_docker; "${COMPOSE[@]}" stop "${NODE}${1:?usage: stop <node-number>}" ;;
  start)    need_docker; "${COMPOSE[@]}" start "${NODE}${1:?usage: start <node-number>}" ;;
  add-node) need_docker; "${COMPOSE[@]}" --profile scale up -d ${NODE}4
            echo "node 4 started (SQL on $((SQL0+3)), console on $((HTTP0+3)))" ;;
  upgrade)  need_docker; n="${1:?usage: upgrade <node-number> <version>}"; v="${2:?usage: upgrade <node-number> <version>}"
            # Recreate ONE node's container on the new image; the others keep serving.
            CRDB_VERSION="$v" "${COMPOSE[@]}" up -d --no-deps "${NODE}${n}"
            echo "node $n restarted on $v" ;;
  console)  echo "http://localhost:${HTTP0}  (node 2: $((HTTP0+1)), node 3: $((HTTP0+2)))" ;;
  logs)     need_docker; "${COMPOSE[@]}" logs -f "${NODE}${1:-1}" ;;
  ps)       need_docker; "${COMPOSE[@]}" ps ;;
  down)     need_docker; "${COMPOSE[@]}" --profile scale down -v ;;
  reset)    need_docker; "${COMPOSE[@]}" --profile scale down -v; exec "$0" up ;;
  cp)       need_docker; "${COMPOSE[@]}" cp "$@" ;;
  help|--help|-h|*)
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
esac
