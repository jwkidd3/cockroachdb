#!/usr/bin/env bash
# Lab 7 — Multi-Region Topologies & Survival Goals
#
# Tests cover Parts A (survival goals), B (REGIONAL BY ROW), C (GLOBAL),
# D (REGIONAL BY TABLE IN), E (regional outage), F (placement audit).
#
# Uses a real 9-node cluster with locality tags (not `cockroach demo`),
# because we need to kill 3 specific nodes to simulate a region outage.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab07"
BASE_SQL_PORT=26377
BASE_HTTP_PORT=8133

# 9 nodes, 3 per region. Pipe-separated (see lib/cluster.sh).
export CLUSTER_LOCALITIES="\
region=us-east1,zone=us-east1-a|\
region=us-east1,zone=us-east1-b|\
region=us-east1,zone=us-east1-c|\
region=us-west1,zone=us-west1-a|\
region=us-west1,zone=us-west1-b|\
region=us-west1,zone=us-west1-c|\
region=europe-west1,zone=europe-west1-a|\
region=europe-west1,zone=europe-west1-b|\
region=europe-west1,zone=europe-west1-c"

source "$SCRIPT_DIR/lib/cluster.sh"
trap 'stop_cluster' EXIT INT TERM

section "Setup — 9-node cluster across 3 simulated regions"
start_cluster 9

# Confirm localities propagated
# Localities propagate through gossip; asserting immediately after start_cluster
# races that propagation and sees only the node we are connected to.
wait_for "all 9 nodes have gossiped their locality" 90 \
    "[ \"\$(cockroach sql --insecure --host=localhost:${BASE_SQL_PORT} --format=tsv \
        --execute \"SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality != '';\" \
        | tail -n +2 | head -1)\" = '9' ]"

EAST_NODES=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality LIKE '%us-east1%';")
WEST_NODES=$(sql_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality LIKE '%us-west1%';")
EU_NODES=$(sql_value   "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality LIKE '%europe-west1%';")
assert_eq "3 nodes in us-east1" "$EAST_NODES" "3"
assert_eq "3 nodes in us-west1" "$WEST_NODES" "3"
assert_eq "3 nodes in europe-west1" "$EU_NODES" "3"

section "Part A — Database regions and survival goal"
sql "CREATE DATABASE shop;" >/dev/null

# Multi-region SQL (SET PRIMARY REGION, REGIONAL BY ROW, GLOBAL, survival goals)
# is an enterprise feature. `cockroach demo` — which the lab itself uses — ships a
# temporary licence; a plain `cockroach start` cluster like this one does not.
# Set COCKROACH_LICENSE (and COCKROACH_ORG) to exercise the full lab here.
if [ -n "${COCKROACH_LICENSE:-}" ]; then
    sql "SET CLUSTER SETTING cluster.organization = '${COCKROACH_ORG:-Lab}';" >/dev/null 2>&1 || true
    sql "SET CLUSTER SETTING enterprise.license = '${COCKROACH_LICENSE}';" >/dev/null 2>&1 || true
fi

MR_PROBE=$(sql "USE shop; ALTER DATABASE shop SET PRIMARY REGION 'us-east1';" 2>&1 || true)
if grep -qi "requires an enterprise license" <<<"$MR_PROBE"; then
    warn "multi-region SQL requires an enterprise licence; skipping Parts A-E"
    warn "the localities above are the part that works on any cluster — the lab itself"
    warn "uses 'cockroach demo --global', which includes a temporary licence"
    section "Done"
    echo "Lab 7: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed (multi-region parts skipped: no licence)."
    [ "$FAIL_COUNT" -eq 0 ]
    exit $?
fi
pass "multi-region enabled: PRIMARY REGION set"
sql "USE shop; ALTER DATABASE shop ADD REGION 'us-west1';" >/dev/null
sql "USE shop; ALTER DATABASE shop ADD REGION 'europe-west1';" >/dev/null

REGIONS=$(sql "SHOW REGIONS FROM DATABASE shop;")
assert_contains "us-east1 in regions" "$REGIONS" "us-east1"
assert_contains "us-west1 in regions" "$REGIONS" "us-west1"
assert_contains "europe-west1 in regions" "$REGIONS" "europe-west1"

GOAL=$(sql_value "SELECT survival_goal FROM [SHOW SURVIVAL GOAL FROM DATABASE shop];")
assert_contains "default survival is ZONE failure" "$GOAL" "zone"

# Toggle survival to region; replication factor should adjust internally
sql "USE shop; ALTER DATABASE shop SURVIVE REGION FAILURE;" >/dev/null
GOAL2=$(sql_value "SELECT survival_goal FROM [SHOW SURVIVAL GOAL FROM DATABASE shop];")
assert_contains "switched to REGION failure" "$GOAL2" "region"

# Revert
sql "USE shop; ALTER DATABASE shop SURVIVE ZONE FAILURE;" >/dev/null

section "Part B — REGIONAL BY ROW table"
sql "USE shop; CREATE TABLE customers (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email  STRING UNIQUE,
  name   STRING NOT NULL,
  region crdb_internal_region NOT NULL
) LOCALITY REGIONAL BY ROW AS region;" >/dev/null

sql "USE shop;
INSERT INTO customers (email, name, region) VALUES
  ('alice@us.example.com',   'Alice',   'us-east1'),
  ('bob@us.example.com',     'Bob',     'us-west1'),
  ('charlie@eu.example.com', 'Charlie', 'europe-west1'),
  ('dana@us.example.com',    'Dana',    'us-east1');" >/dev/null

CUST_COUNT=$(sql_value "SELECT count(*) FROM shop.customers;")
assert_eq "4 customers inserted" "$CUST_COUNT" "4"

# Verify leaseholder locality matches each row's region (best-effort: not always immediate)
# Sample at least one row's range placement
sleep 5  # allow allocator to apply the locality
PLACEMENT=$(sql "SHOW RANGES FROM TABLE shop.customers WITH DETAILS;")
assert_contains "ranges include region locality info" "$PLACEMENT" "region"

section "Part C — GLOBAL table"
sql "USE shop; CREATE TABLE country_codes (
  code STRING(2) PRIMARY KEY, name STRING NOT NULL
) LOCALITY GLOBAL;
INSERT INTO country_codes VALUES ('US','United States'),('CA','Canada'),('DE','Germany');" >/dev/null

GLOBAL_COUNT=$(sql_value "SELECT count(*) FROM shop.country_codes;")
assert_eq "3 country codes inserted (GLOBAL table)" "$GLOBAL_COUNT" "3"

# Read from each region — should succeed (we can't easily measure latency here, but correctness is testable)
READ_FROM_E=$(sql_value_on_node 1 "SELECT name FROM shop.country_codes WHERE code = 'US';")
READ_FROM_W=$(sql_value_on_node 4 "SELECT name FROM shop.country_codes WHERE code = 'US';")
READ_FROM_EU=$(sql_value_on_node 7 "SELECT name FROM shop.country_codes WHERE code = 'US';")
assert_eq "us-east1 reads GLOBAL row" "$READ_FROM_E" "United"
assert_eq "us-west1 reads GLOBAL row" "$READ_FROM_W" "United"
assert_eq "europe reads GLOBAL row"  "$READ_FROM_EU" "United"

section "Part D — REGIONAL BY TABLE IN"
sql "USE shop; CREATE TABLE eu_pricing_rules (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule STRING NOT NULL
) LOCALITY REGIONAL BY TABLE IN 'europe-west1';
INSERT INTO eu_pricing_rules (rule) VALUES ('VAT 19%'),('VAT 20%'),('VAT 21%');" >/dev/null

EU_RULES=$(sql_value "SELECT count(*) FROM shop.eu_pricing_rules;")
assert_eq "3 EU pricing rules" "$EU_RULES" "3"

# Replicas should be in europe-west1
EU_RANGES=$(sql "SHOW RANGES FROM TABLE shop.eu_pricing_rules WITH DETAILS;")
assert_contains "EU pricing table replicas reference europe-west1" "$EU_RANGES" "europe-west1"

section "Part E — Take a region offline; cluster still serves"
sql "USE shop; ALTER DATABASE shop SURVIVE REGION FAILURE;" >/dev/null
info "waiting 15s for re-replication after survival-goal change"
sleep 15

# Kill all europe-west1 nodes (7, 8, 9)
kill_node 7
kill_node 8
kill_node 9
sleep 10  # allow lease transfer

# A query against a survivor must succeed
ALIVE_COUNT=$(sql_value_on_node 1 "SELECT count(*) FROM shop.customers;")
assert_eq "cluster still serves after losing 1 region (3 nodes)" "$ALIVE_COUNT" "4"

# Write must succeed too
sql_on_node 1 "INSERT INTO shop.customers (email, name, region) VALUES ('eve@us.example.com', 'Eve', 'us-east1');" >/dev/null
NEW_COUNT=$(sql_value_on_node 1 "SELECT count(*) FROM shop.customers;")
assert_eq "writes succeed after region outage" "$NEW_COUNT" "5"

# Restart the EU nodes
restart_node 7
restart_node 8
restart_node 9
sleep 10

section "Part F — Audit placement via SHOW RANGES and crdb_internal.zones"
ZONES=$(sql "SHOW ZONE CONFIGURATIONS;" 2>&1 || true)
assert_contains "zone configurations are listed" "$ZONES" "DATABASE"

CUSTOMERS_PLACEMENT=$(sql "SHOW RANGES FROM TABLE shop.customers WITH DETAILS;")
assert_contains "customers ranges have replica info" "$CUSTOMERS_PLACEMENT" "replicas"

section "Done"
echo "Lab 7: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
