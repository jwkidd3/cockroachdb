#!/usr/bin/env bash
# Reset a student VM to a clean state between labs.
# "Have you run the reset script?" answers a surprising share of lab problems.
#
#   bash reset_labs.sh          # clusters + lab temp dirs
#   bash reset_labs.sh --all    # also containers, kind clusters, and docker volumes

set -uo pipefail
ALL="${1:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> tearing down the lab clusters"
for f in docker-compose.labs.yml docker-compose.labs-b.yml docker-compose.labs-secure.yml; do
    [ -f "$REPO/$f" ] && (cd "$REPO" && docker compose -f "$f" --profile scale down -v 2>/dev/null) || true
done

echo "==> stopping any stray cockroach containers"
docker ps -a --filter "ancestor=cockroachdb/cockroach" --format '{{.ID}}' 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true

# Anything still running natively (from an older run of the course)
pkill -f "cockroach start" 2>/dev/null || true
pkill -f "cockroach demo"  2>/dev/null || true

echo "==> removing lab data directories"
rm -rf "$REPO"/lab9 "$REPO"/lab12/logs /tmp/lab13 /tmp/lab15 /tmp/lab16
rm -rf /tmp/crdb-* /tmp/verify-crdb-* /tmp/load_test.csv
rm -rf ./lab8-certs ./lab8-keys ./lab8-data ./cockroach-data 2>/dev/null || true

if [ "$ALL" = "--all" ]; then
    echo "==> removing lab containers"
    docker rm -f lab9-prom lab9-grafana lab15-pg 2>/dev/null || true
    for d in /tmp/lab13 /tmp/lab15; do
        [ -f "$d/docker-compose.yml" ] && (cd "$d" && docker compose down -v 2>/dev/null) || true
    done
    echo "==> deleting kind clusters"
    kind get clusters 2>/dev/null | xargs -r -n1 kind delete cluster --name 2>/dev/null || true
    echo "==> pruning dangling docker volumes"
    docker volume prune -f >/dev/null 2>&1 || true
fi

echo "==> checking ports are free"
BUSY=0
for p in 26257 26258 26259 26357 26358 26359 8080 8081 8082 3000 9090 9092 5432; do
    if lsof -i ":$p" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "  port $p still in use:"; lsof -i ":$p" -sTCP:LISTEN | tail -n +2 | sed 's/^/    /'
        BUSY=1
    fi
done
[ "$BUSY" -eq 0 ] && echo "  all lab ports free"

echo "==> done. Ready for the next lab."
