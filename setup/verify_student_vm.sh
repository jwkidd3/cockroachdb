#!/usr/bin/env bash
# Verify a provisioned student VM can run every lab in the 4-day course.
# Run as the student user (NOT root):
#   bash verify_student_vm.sh
# Exits non-zero on the first hard failure.

set -uo pipefail

PASS=0; FAIL=0; WARN=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m';
else G=""; R=""; Y=""; B=""; N=""; fi

# All three go to stdout so the report reads in order. Redirecting failures to
# stderr interleaved them into the wrong section, which made the report look
# like it was failing checks it had not reached yet. The exit code is the
# machine-readable signal.
ok()   { PASS=$((PASS+1)); echo "${G}PASS${N} $*"; }
bad()  { FAIL=$((FAIL+1)); echo "${R}FAIL${N} $*"; }
warn() { WARN=$((WARN+1)); echo "${Y}WARN${N} $*"; }
sec()  { echo; echo "${B}=== $* ===${N}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# The cluster smoke test below reads more naturally as pass/fail, and needs an
# equality check. Without these it silently did nothing but print
# "command not found" — and still reported the VM ready.
pass() { ok "$@"; }
fail() { bad "$@"; }
assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then ok "$desc (= $expected)"
    else bad "$desc — expected '$expected', got '$actual'"; fi
}

sec "Hardware"
# Under WSL2 every number below describes the WSL virtual machine, not the
# Windows host — which is exactly what matters, since Docker runs inside it.
IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
    IS_WSL=1
    ok "running under WSL2${WSL_DISTRO_NAME:+ ($WSL_DISTRO_NAME)} — the Linux path, so every lab command works verbatim"
fi

CPUS=$(nproc)
MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')

[ "$CPUS" -ge 8 ]     && ok "vCPU: $CPUS (>= 8)"      || { [ "$CPUS" -ge 4 ] && warn "vCPU: $CPUS — Days 1-2 only; 8 recommended" || bad "vCPU: $CPUS — need at least 4"; }
# The course is sized for a 12 GB student VM. The kernel reserves a little, so
# a 12,287 MB machine reports 11 GB here — that is the expected PASS value.
[ "$MEM_GB" -ge 11 ]  && ok "RAM: ${MEM_GB} GB (12 GB VM)" || { [ "$MEM_GB" -ge 8 ] && warn "RAM: ${MEM_GB} GB — every lab fits one stack at a time; Lab 16 (7.6 GB measured) has little margin" || bad "RAM: ${MEM_GB} GB — need at least 8; Lab 16 (kind) will not run"; }

# WSL2 does not hand the whole machine to Linux. Recent builds default to half
# of host RAM, so a 12 GB laptop gives WSL ~6 GB — enough for Labs 1-6 and
# nothing heavier. This is the single most likely reason the heavy labs fail on Windows.
if [ "$IS_WSL" = "1" ] && [ "$MEM_GB" -lt 10 ]; then
    warn "WSL2 has only ${MEM_GB} GB of the host's RAM. Raise it on the Windows side:"
    warn "    create %UserProfile%\\.wslconfig containing:"
    warn "        [wsl2]"
    warn "        memory=10GB"
    warn "        processors=4"
    warn "    then run 'wsl --shutdown' in PowerShell and reopen this shell."
fi
[ "$DISK_GB" -ge 100 ] && ok "Free disk: ${DISK_GB} GB" || { [ "$DISK_GB" -ge 50 ] && warn "Free disk: ${DISK_GB} GB — Lab 10 TPC-C needs headroom" || bad "Free disk: ${DISK_GB} GB — need at least 50"; }

# Every lab runs in containers, so the ceiling that matters is the one the Docker
# daemon has — on Docker Desktop that is a VM allocation, not the host's RAM.
if docker info >/dev/null 2>&1; then
    DOCKER_GB=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    if   [ "$DOCKER_GB" -ge 11 ]; then ok "Docker memory: ${DOCKER_GB} GB"
    elif [ "$DOCKER_GB" -ge 8 ];  then warn "Docker memory: ${DOCKER_GB} GB — every lab fits one stack at a time; Lab 16 (7.6 GB measured) has little margin"
    elif [ "$DOCKER_GB" -ge 6 ];  then warn "Docker memory: ${DOCKER_GB} GB — Labs 1-15 fit one stack at a time; Lab 16 (kind, 7.6 GB) will not"
    else bad "Docker memory: ${DOCKER_GB} GB — too little for Lab 7 (6 GB) or Lab 10 (TPC-C)"; fi
fi

sec "Binaries"
# The only binaries the course needs locally. cockroach, molt and helm are all
# containers. kind/kubectl are only for the optional Kubernetes exercise (checked below as warnings).
for b in docker psql python3 git jq nc bc openssl curl unzip; do
    have "$b" && ok "$b: $(command -v $b)" || bad "$b missing"
done
for b in kind kubectl; do command -v $b >/dev/null 2>&1 && ok "$b present (optional Kubernetes exercise)" || warn "$b not installed — only the optional Kubernetes exercise needs it"; done

# molt and helm are containers, not local binaries — checked with the images below.

sec "Limits and kernel settings"
# CockroachDB runs in containers, which take the Docker daemon's file-handle
# limit — not this shell's. Check the limit the database actually runs under.
if docker info >/dev/null 2>&1; then
    CNOFILE=$(docker run --rm alpine sh -c 'ulimit -n' 2>/dev/null || echo 0)
    [ "${CNOFILE:-0}" -ge 65536 ] \
        && ok "container ulimit -n = $CNOFILE (what CockroachDB runs under)" \
        || bad "container ulimit -n = ${CNOFILE:-?} — set Docker's default-ulimits nofile to 65536 (daemon.json)"
fi
# The host shell's limit matters only to host-side tools (psql, python), which
# need nothing like 65536. WSL commonly reports 1024 here; that is harmless.
NOFILE=$(ulimit -n)
[ "$NOFILE" -ge 65536 ] && ok "host shell ulimit -n = $NOFILE" \
    || warn "host shell ulimit -n = $NOFILE — fine; only the container limit above affects the database"
MMC=$(sysctl -n vm.max_map_count)
[ "$MMC" -ge 262144 ] && ok "vm.max_map_count = $MMC" || warn "vm.max_map_count = $MMC (the optional Kubernetes exercise needs 262144)"

sec "Docker"
if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable without sudo"
    docker run --rm hello-world >/dev/null 2>&1 && ok "docker can run a container" || bad "docker run failed"
else
    bad "docker not reachable as this user (is '$USER' in the docker group? log out and back in)"
fi

sec "Pre-pulled images"
for img in cockroachdb/cockroach kindest/node prom/prometheus grafana/grafana \
           apache/kafka postgres cockroachdb/molt alpine/helm; do
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

sec "Memory for the heavy labs (7, 10, 16)"
# Measured, not estimated: Lab 7's 9-node demo ~6 GB; the optional kind cluster
# completed at 7.6 GB, scale-out included. Both assume the compose cluster
# (~4 GB) is down first.
L7_GB="${DOCKER_GB:-$MEM_GB}"
if [ "$L7_GB" -ge 11 ]; then
    ok "Docker has ${L7_GB} GB — Labs 7, 10 and 16 all fit with room to spare"
    warn "Still run 'scripts/crdb down' before Labs 7, 10 and 16: the compose cluster holds ~4 GB"
elif [ "$L7_GB" -ge 8 ]; then
    ok "Docker has ${L7_GB} GB — Lab 7 (6 GB) fits comfortably; the optional Kubernetes exercise (7.6 GB) fits with ~$((L7_GB*1000-7600)) MB to spare"
    warn "'scripts/crdb down' before Labs 7, 10 and 16 is mandatory at this size, not advice"
    if [ "$IS_WSL" = "1" ]; then
        warn "On a 12 GB machine WSL can safely have 9 GB. In %UserProfile%\\.wslconfig set:  [wsl2]  memory=9GB  — then 'wsl --shutdown'"
    fi
elif [ "$L7_GB" -ge 6 ]; then
    warn "Docker has ${L7_GB} GB — Lab 7 fits with the cluster down; the optional Kubernetes exercise (7.6 GB) will not run"
else
    warn "Docker has ${L7_GB} GB — too little for Lab 7 (6 GB); have students pair up or use --nodes 3"
fi

sec "Summary"
echo "Pass: $PASS   Warn: $WARN   Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "${R}VM is NOT ready.${N} Fix the failures above and re-run."
    exit 1
fi
[ "$WARN" -gt 0 ] && echo "${Y}VM is usable with caveats — review the warnings.${N}"
echo "${G}VM is ready for the course.${N}"
