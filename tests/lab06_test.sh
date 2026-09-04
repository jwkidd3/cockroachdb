#!/usr/bin/env bash
# Lab 6 — EXPLAIN ANALYZE & Query Tuning
#
# Tests cover Parts A (baseline plans), B (index fixes), C (insights),
# D (stale stats), E (debug bundle), F (distSQL/vectorize).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab06"
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup — 3-node cluster, catalog schema, 5k products + 100k orders"
start_cluster 3
cat <<'SQL' | sql_script
CREATE DATABASE catalog;
USE catalog;

CREATE TABLE products (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku       STRING NOT NULL,
  name      STRING NOT NULL,
  category  STRING NOT NULL,
  price     DECIMAL(10,2) NOT NULL,
  in_stock  BOOL NOT NULL DEFAULT true,
  created   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE orders (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id   UUID NOT NULL REFERENCES products(id),
  customer_id  UUID NOT NULL,
  qty          INT NOT NULL CHECK (qty > 0),
  total        DECIMAL(12,2) NOT NULL,
  status       STRING NOT NULL,
  placed       TIMESTAMPTZ DEFAULT now()
);

INSERT INTO products (sku, name, category, price)
SELECT
  'SKU-' || lpad(g::STRING, 6, '0'),
  'Product ' || g,
  (ARRAY['books','elec','toys','home','garden','sport','food','health','auto','pet'])[1 + (g % 10)],
  (random() * 200)::DECIMAL(10,2)
FROM generate_series(1, 5000) g;

INSERT INTO orders (product_id, customer_id, qty, total, status)
SELECT
  (SELECT id FROM products ORDER BY random() LIMIT 1),
  gen_random_uuid(),
  1 + (random() * 4)::INT,
  (random() * 500)::DECIMAL(12,2),
  (ARRAY['open','paid','shipped','shipped','shipped','cancelled'])[1 + (random()*5)::INT]
FROM generate_series(1, 100000);

CREATE STATISTICS p FROM products;
CREATE STATISTICS o FROM orders;
SQL

ORDERS=$(sql_value "SELECT count(*) FROM catalog.orders;")
assert_eq "100k orders loaded" "$ORDERS" "100000"

section "Part A — Baseline plans (full scans expected)"
PLAN_Q1=$(sql "EXPLAIN ANALYZE SELECT p.category, count(*) FROM catalog.orders o JOIN catalog.products p ON o.product_id = p.id WHERE o.placed > now() - INTERVAL '1 hour' GROUP BY p.category;")
assert_contains "Q1 EXPLAIN runs and contains a scan" "$PLAN_Q1" "scan"
assert_contains "Q1 plan reports execution time" "$PLAN_Q1" "execution time"

PLAN_Q3=$(sql "EXPLAIN ANALYZE SELECT status, count(*) FROM catalog.orders GROUP BY status;")
assert_contains "Q3 EXPLAIN runs" "$PLAN_Q3" "scan"

section "Part B — Add covering index for Q2"
sql "USE catalog;
CREATE INDEX orders_by_customer_placed ON orders(customer_id, placed DESC) STORING (qty, total);" >/dev/null

ONE_CUST=$(sql_value "SELECT customer_id FROM catalog.orders LIMIT 1;")
PLAN_Q2_AFTER=$(sql "EXPLAIN SELECT id, qty, total, placed FROM catalog.orders WHERE customer_id = '$ONE_CUST' ORDER BY placed DESC LIMIT 20;")
assert_contains "Q2 plan now uses orders_by_customer_placed" "$PLAN_Q2_AFTER" "orders_by_customer_placed"
assert_not_contains "Q2 plan has no index join" "$PLAN_Q2_AFTER" "index join"

section "Part B — Hash-sharded placed index for Q1"
sql "USE catalog;
CREATE INDEX orders_by_placed ON orders(placed DESC) USING HASH STORING (product_id, total) WITH (bucket_count = 8);" >/dev/null

PLAN_Q1_AFTER=$(sql "EXPLAIN SELECT p.category, count(*) FROM catalog.orders o JOIN catalog.products p ON o.product_id = p.id WHERE o.placed > now() - INTERVAL '1 hour' GROUP BY p.category;")
assert_contains "Q1 plan runs after hash-sharded index added" "$PLAN_Q1_AFTER" "scan"

section "Part C — Missing index gets recommended (and applied)"
# Run a query that requires a sequential scan to surface the recommendation
sql "SELECT name, price FROM catalog.products WHERE sku = 'SKU-001234';" >/dev/null

# The insights view might take a moment to populate; tolerate empty
sleep 2
INSIGHTS_QUERY=$(sql_value "SELECT count(*) FROM crdb_internal.cluster_execution_insights WHERE end_time > now() - INTERVAL '1 minute';" 2>/dev/null || echo 0)
info "execution insights captured in last 1m: $INSIGHTS_QUERY"

# Add the recommended index and verify use
sql "USE catalog; CREATE INDEX ON products(sku);" >/dev/null
PLAN_SKU=$(sql "EXPLAIN SELECT name, price FROM catalog.products WHERE sku = 'SKU-001234';")
assert_contains "sku index used after creation" "$PLAN_SKU" "products_sku_idx"

section "Part D — Stale statistics affect estimates"
# Capture estimated row count for status='open' BEFORE the update
BEFORE_OPEN_EST=$(sql "EXPLAIN ANALYZE SELECT count(*) FROM catalog.orders WHERE status = 'open';" | grep -E "estimated row count:" | head -1 || true)

# Bulk-shift the distribution
sql "USE catalog; UPDATE orders SET status = 'shipped' WHERE status = 'open';" >/dev/null

# Now estimated and actual will diverge
PLAN_STALE=$(sql "EXPLAIN ANALYZE SELECT count(*) FROM catalog.orders WHERE status = 'open';")
assert_contains "EXPLAIN ANALYZE after distribution shift still runs" "$PLAN_STALE" "actual row count"

# Refresh and re-check — must succeed
sql "USE catalog; CREATE STATISTICS o2 FROM orders;" >/dev/null
PLAN_REFRESHED=$(sql "EXPLAIN ANALYZE SELECT count(*) FROM catalog.orders WHERE status = 'open';")
assert_contains "post-refresh EXPLAIN ANALYZE runs" "$PLAN_REFRESHED" "actual row count"

section "Part E — EXPLAIN ANALYZE (DEBUG) produces a bundle hint"
DEBUG_OUT=$(sql "EXPLAIN ANALYZE (DEBUG) SELECT category, count(*) FROM catalog.products GROUP BY category;" 2>&1 || true)
assert_contains "DEBUG mode outputs a bundle/Statement diagnostics hint" "$DEBUG_OUT" "bundle"

section "Part F — DistSQL and vectorization are observable"
PLAN_GRP=$(sql "EXPLAIN SELECT category, count(*) FROM catalog.products GROUP BY category;")
assert_contains "EXPLAIN reports distribution" "$PLAN_GRP" "distribution"
assert_contains "EXPLAIN reports vectorized" "$PLAN_GRP" "vectorized"

# Toggle vectorize and back; both must succeed
assert_command_succeeds "vectorize off works" \
    crdb sql -e "SET vectorize = 'off'; SELECT category, count(*) FROM catalog.products GROUP BY category; SET vectorize = 'on';"

section "Done"
echo "Lab 6: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
