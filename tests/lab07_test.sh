#!/usr/bin/env bash
# Lab 7 — Multi-Region Topologies & Survival Goals
#
# The lab runs `cockroach demo --global --nodes 9` in a container: it is the only
# way to get simulated inter-region latency AND the temporary enterprise licence
# that multi-region SQL requires. This test starts that same container and drives
# the same nine nodes.
#
# One difference, forced by the tool: the lab's `\demo connect N` / `\demo shutdown N`
# are client-side commands of the *interactive* SQL shell — piped into a
# non-interactive session they come back as `ERROR: invalid syntax`. So:
#   \demo connect N  ->  a SQL client run against node N's own port (same effect)
#   \demo shutdown N ->  no non-interactive equivalent exists. Part E asserts the
#                        survival configuration that makes a region outage
#                        survivable, and reports the shutdown as a manual step.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

IMAGE="cockroachdb/cockroach:${CRDB_VERSION:-v23.2.5}"
NAME="lab07-demo"
# demo assigns SQL ports sequentially from --sql-port: node N is 26256+N.
DEMO_CERTS="/root/.cockroach-demo"

cleanup_all() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup_all EXIT INT TERM

# Run SQL against a specific demo node — the scriptable form of `\demo connect N`.
dsql() {
    local n="$1"; shift
    docker exec "$NAME" ./cockroach sql \
        --url "postgresql://demo:demo1@127.0.0.1:$((26256+n))/defaultdb?sslmode=require&sslrootcert=${DEMO_CERTS}/ca.crt" \
        "$@" 2>&1
}
dvalue() {
    local n="$1"; shift
    dsql "$n" --format=tsv -e "$1" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}'
}

if ! docker info >/dev/null 2>&1; then
    warn "Docker is not running; skipping Lab 7"
    echo "Lab 7: skipped"
    exit 0
fi

MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
if [ "$MEM" -lt 6000000000 ] && [ "${FORCE_LAB07:-0}" != "1" ]; then
    warn "Docker has $((MEM/1000000000)) GB; Lab 7's 9-node demo needs ~6 GB. Set FORCE_LAB07=1 to try anyway."
    echo "Lab 7: skipped (insufficient memory)"
    exit 0
fi

section "Setup — cockroach demo --global --nodes 9 (the lab's own command)"
cleanup_all
docker run -dit --name "$NAME" -m 6g -p 8090:8080 "$IMAGE" \
    demo --global --nodes 9 --no-example-database --empty --http-port=8080 >/dev/null 2>&1 \
    || fail "could not start the demo container"

info "waiting for nine simulated regions to come up (this takes a minute)"
READY=0
for _ in $(seq 1 150); do
    if docker logs "$NAME" 2>&1 | grep -qa "brief introduction"; then READY=1; break; fi
    docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || break
    sleep 2
done
[ "$READY" = "1" ] || { docker logs "$NAME" 2>&1 | tail -20 | sed 's/^/    /'; fail "demo cluster never became ready"; }
pass "demo cluster is up"

wait_for "all nine nodes report their locality" 120 \
    "[ \"\$(dvalue 1 \"SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality != '';\")\" = '9' ]"

for r in us-east1 us-west1 europe-west1; do
    N=$(dvalue 1 "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality LIKE '%${r}%';")
    assert_eq "3 nodes in $r" "$N" "3"
done

section "Part A — Database regions and survival goal"
dsql 1 -e "CREATE DATABASE shop;" >/dev/null
dsql 1 -e "USE shop; ALTER DATABASE shop SET PRIMARY REGION 'us-east1';" >/dev/null \
    || fail "SET PRIMARY REGION failed — demo should carry a temporary licence"
pass "multi-region enabled: PRIMARY REGION set"

dsql 1 -e "USE shop; ALTER DATABASE shop ADD REGION 'us-west1';" >/dev/null
dsql 1 -e "USE shop; ALTER DATABASE shop ADD REGION 'europe-west1';" >/dev/null

REGIONS=$(dsql 1 -e "SHOW REGIONS FROM DATABASE shop;")
for r in us-east1 us-west1 europe-west1; do
    assert_contains "$r in database regions" "$REGIONS" "$r"
done

GOAL=$(dvalue 1 "SELECT survival_goal FROM [SHOW SURVIVAL GOAL FROM DATABASE shop];")
assert_contains "default survival is ZONE failure" "$GOAL" "zone"

dsql 1 -e "USE shop; ALTER DATABASE shop SURVIVE REGION FAILURE;" >/dev/null
GOAL2=$(dvalue 1 "SELECT survival_goal FROM [SHOW SURVIVAL GOAL FROM DATABASE shop];")
assert_contains "switched to REGION failure" "$GOAL2" "region"
dsql 1 -e "USE shop; ALTER DATABASE shop SURVIVE ZONE FAILURE;" >/dev/null

section "Part B — REGIONAL BY ROW table"
dsql 1 -e "USE shop; CREATE TABLE customers (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email  STRING UNIQUE,
  name   STRING NOT NULL,
  region crdb_internal_region NOT NULL
) LOCALITY REGIONAL BY ROW AS region;" >/dev/null

dsql 1 -e "USE shop;
INSERT INTO customers (email, name, region) VALUES
  ('alice@us.example.com',   'Alice',   'us-east1'),
  ('bob@us.example.com',     'Bob',     'us-west1'),
  ('charlie@eu.example.com', 'Charlie', 'europe-west1'),
  ('dana@us.example.com',    'Dana',    'us-east1');" >/dev/null

CUST=$(dvalue 1 "SELECT count(*) FROM shop.customers;")
assert_eq "4 customers inserted" "$CUST" "4"

sleep 5
PLACEMENT=$(dsql 1 -e "SHOW RANGES FROM TABLE shop.customers WITH DETAILS;")
assert_contains "customer ranges carry region locality" "$PLACEMENT" "region"

section "Part C — GLOBAL table, read from every region"
dsql 1 -e "USE shop; CREATE TABLE country_codes (
  code STRING(2) PRIMARY KEY, name STRING NOT NULL
) LOCALITY GLOBAL;
INSERT INTO country_codes VALUES ('US','United States'),('CA','Canada'),('DE','Germany');" >/dev/null

GC=$(dvalue 1 "SELECT count(*) FROM shop.country_codes;")
assert_eq "3 country codes inserted (GLOBAL table)" "$GC" "3"

# The scriptable form of `\demo connect N`: query node N directly. Nodes 1, 4
# and 7 are one per region.
for pair in "1:us-east1" "4:us-west1" "7:europe-west1"; do
    n="${pair%%:*}"; r="${pair##*:}"
    WHO=$(dvalue "$n" "SHOW node_id;")
    assert_eq "connected to node $n (in $r)" "$WHO" "$n"
    READ=$(dvalue "$n" "SELECT name FROM shop.country_codes WHERE code = 'US';")
    assert_eq "$r reads the GLOBAL row" "$READ" "United"
done

section "Part D — REGIONAL BY TABLE IN"
dsql 1 -e "USE shop; CREATE TABLE eu_pricing_rules (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule STRING NOT NULL
) LOCALITY REGIONAL BY TABLE IN 'europe-west1';
INSERT INTO eu_pricing_rules (rule) VALUES ('VAT 19%'),('VAT 20%'),('VAT 21%');" >/dev/null

EU=$(dvalue 1 "SELECT count(*) FROM shop.eu_pricing_rules;")
assert_eq "3 EU pricing rules" "$EU" "3"

EU_ZONE=$(dsql 1 -e "SHOW ZONE CONFIGURATION FROM TABLE shop.eu_pricing_rules;")
assert_contains "the EU table is pinned to europe-west1" "$EU_ZONE" "europe-west1"

section "Part E — Surviving a region outage"
dsql 1 -e "USE shop; ALTER DATABASE shop SURVIVE REGION FAILURE;" >/dev/null
info "waiting for re-replication after the survival-goal change"
sleep 20

# REGION survival is what makes losing three of nine nodes survivable: it raises
# the replica count so a quorum still exists with a whole region gone.
DB_ZONE=$(dsql 1 -e "SHOW ZONE CONFIGURATION FROM DATABASE shop;")
assert_contains "region survival raises num_replicas to 5" "$DB_ZONE" "num_replicas = 5"
assert_contains "voter placement constrains regions" "$DB_ZONE" "constraints\|voter_constraints"

# LIMIT must apply to the range, not to the unnested replica list — otherwise
# this counts the regions of exactly one replica and always answers 1.
REGIONS_HOLDING=$(dvalue 1 "
  SELECT count(DISTINCT substring(locality FROM 'region=([^,]*)'))
  FROM crdb_internal.gossip_nodes
  WHERE node_id IN (
    SELECT unnest(replicas)
    FROM (SELECT replicas FROM [SHOW RANGES FROM DATABASE shop WITH DETAILS] LIMIT 1)
  );")
assert_ge "a single range's replicas span at least 3 regions" "${REGIONS_HOLDING:-0}" "3"

# Reads keep working from every region while the goal is REGION survival.
for n in 1 4 7; do
    C=$(dvalue "$n" "SELECT count(*) FROM shop.customers;")
    assert_eq "node $n still serves reads under REGION survival" "$C" "4"
done

warn "The lab's \\demo shutdown 7/8/9 step is interactive-only and cannot be scripted;"
warn "run it by hand to watch the cluster serve through a full region outage."

section "Part F — Audit placement"
ZONES=$(dsql 1 -e "SHOW ZONE CONFIGURATIONS;")
assert_contains "zone configurations are listed" "$ZONES" "DATABASE"

CUST_RANGES=$(dvalue 1 "SELECT count(*) FROM [SHOW RANGES FROM TABLE shop.customers WITH DETAILS];")
assert_gt "customers has ranges to audit" "${CUST_RANGES:-0}" "0"

section "Done"
echo "Lab 7: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
