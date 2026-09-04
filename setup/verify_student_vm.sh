#!/usr/bin/env bash
# Verify a provisioned student VM can run every lab in the 4-day course.
# Run as the student user (NOT root):
#   bash verify_student_vm.sh
# Exits non-zero on the first hard failure.

set -uo pipefail

PASS=0; FAIL=0; WARN=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m';
else G=""; R=""; Y=""; B=""; N=""; fi

ok()   { PASS=$((PASS+1)); echo "${G}PASS${N} $*"; }
bad()  { FAIL=$((FAIL+1)); echo "${R}FAIL${N} $*" >&2; }
warn() { WARN=$((WARN+1)); echo "${Y}WARN${N} $*" >&2; }
sec()  { echo; echo "${B}=== $* ===${N}"; }

have() { command -v "$1" >/dev/null 2>&1; }

sec "Hardware"
CPUS=$(nproc)
MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')

[ "$CPUS" -ge 8 ]     && ok "vCPU: $CPUS (>= 8)"      || { [ "$CPUS" -ge 4 ] && warn "vCPU: $CPUS — Days 1-2 only; 8 recommended" || bad "vCPU: $CPUS — need at least 4"; }
[ "$MEM_GB" -ge 30 ]  && ok "RAM: ${MEM_GB} GB (>= 32)" || { [ "$MEM_GB" -ge 15 ] && warn "RAM: ${MEM_GB} GB — Lab 16 (kind) and Lab 7 (9 nodes) may OOM" || bad "RAM: ${MEM_GB} GB — need at least 16"; }
[ "$DISK_GB" -ge 100 ] && ok "Free disk: ${DISK_GB} GB" || { [ "$DISK_GB" -ge 50 ] && warn "Free disk: ${DISK_GB} GB — Lab 10 TPC-C needs headroom" || bad "Free disk: ${DISK_GB} GB — need at least 50"; }

sec "Binaries"
# cockroach itself is NOT installed on the host any more - it runs in containers.
for b in docker kind kubectl psql python3 git jq nc bc openssl curl unzip; do
    have "$b" && ok "$b: $(command -v $b)" || bad "$b missing"
done
have helm && ok "helm present" || warn "helm missing (Lab 16 Part E comparison only)"
have molt && ok "molt present" || warn "molt missing — Lab 15 falls back to the pure-SQL path"
have go   && ok "go present"   || warn "go missing (optional, Lab 14 Go variants)"

sec "Limits and kernel settings"
NOFILE=$(ulimit -n)
[ "$NOFILE" -ge 65536 ] && ok "ulimit -n = $NOFILE" || bad "ulimit -n = $NOFILE (need 65536; log out and back in after provisioning)"
MMC=$(sysctl -n vm.max_map_count)
[ "$MMC" -ge 262144 ] && ok "vm.max_map_count = $MMC" || bad "vm.max_map_count = $MMC (kind needs 262144)"

sec "Docker"
if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable without sudo"
    docker run --rm hello-world >/dev/null 2>&1 && ok "docker can run a container" || bad "docker run failed"
else
    bad "docker not reachable as this user (is '$USER' in the docker group? log out and back in)"
fi

sec "Pre-pulled images"
for img in prom/prometheus grafana/grafana apache/kafka postgres kindest/node; do
    docker image ls --format '{{.Repository}}' 2>/dev/null | grep -q "^${img}$" \
        && ok "image cached: $img" || warn "image not cached: $img (first use will download)"
done

sec "Python drivers"
python3 -c "import psycopg2" 2>/dev/null && ok "psycopg2 importable" || bad "psycopg2 missing (Labs 1, 14)"
python3 -c "import sqlalchemy" 2>/dev/null && ok "sqlalchemy importable" || warn "sqlalchemy missing (Lab 14 ORM section)"

sec "CockroachDB smoke test (containerised)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO/docker/labs.yml" ]; then
    if (cd "$REPO" && bash scripts/crdb.sh up >/dev/null 2>&1); then
        pass "lab cluster started via docker compose"
        OUT=$(cd "$REPO" && bash scripts/crdb.sh sql --format=tsv -e "SELECT 1+1;" 2>/dev/null | tail -1 | tr -d '[:space:]')
        [ "$OUT" = "2" ] && pass "SQL query returned the right answer" || fail "SQL query failed (got '$OUT')"

        NODES=$(cd "$REPO" && bash scripts/crdb.sh sql --format=tsv \
                  -e "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;" 2>/dev/null \
                  | tail -1 | tr -d '[:space:]')
        assert_eq "all 3 nodes are live" "$NODES" "3"

        (cd "$REPO" && bash scripts/crdb.sh sql -e "
           CREATE DATABASE verify;
           CREATE TABLE verify.t (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), n INT);
           INSERT INTO verify.t (n) SELECT g FROM generate_series(1,1000) g;" >/dev/null 2>&1) \
          && pass "DDL + bulk insert succeeded" || fail "DDL/insert failed"

        ROWS=$(cd "$REPO" && bash scripts/crdb.sh sql --format=tsv -e "SELECT count(*) FROM verify.t;" 2>/dev/null | tail -1 | tr -d '[:space:]')
        assert_eq "row count correct" "$ROWS" "1000"

        (cd "$REPO" && bash scripts/crdb.sh run workload init kv --drop \
            'postgresql://root@crdb1:26257?sslmode=disable' >/dev/null 2>&1) \
          && pass "cockroach workload available in the cluster" || fail "workload init failed"

        curl -sf http://localhost:8080/_status/vars >/dev/null 2>&1 \
          && pass "DB Console / metrics endpoint reachable on :8080" \
          || fail "http://localhost:8080/_status/vars unreachable"

        psql 'postgresql://root@localhost:26257/verify?sslmode=disable' -c 'SELECT 1' >/dev/null 2>&1 \
          && pass "psql reaches the published SQL port" || warn "psql could not connect on :26257"

        (cd "$REPO" && bash scripts/crdb.sh sql -e "DROP DATABASE verify CASCADE;" >/dev/null 2>&1)
        (cd "$REPO" && bash scripts/crdb.sh down >/dev/null 2>&1) && pass "cluster torn down cleanly"
    else
        fail "could not start the lab cluster (scripts/crdb.sh up)"
    fi
else
    fail "docker/labs.yml not found - is the course repo checked out at $REPO?"
fi

sec "Multi-node capability (Lab 7 needs 9 nodes)"
if [ "$MEM_GB" -ge 30 ]; then
    ok "RAM sufficient for the 9-node demo cluster in Lab 7"
else
    warn "RAM may be insufficient for Lab 7's 9-node cluster — have students pair up or use --nodes 3"
fi

sec "Summary"
echo "Pass: $PASS   Warn: $WARN   Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "${R}VM is NOT ready.${N} Fix the failures above and re-run." >&2
    exit 1
fi
[ "$WARN" -gt 0 ] && echo "${Y}VM is usable with caveats — review the warnings.${N}"
echo "${G}VM is ready for the course.${N}"
