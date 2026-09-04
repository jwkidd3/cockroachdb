#!/usr/bin/env bash
# Lab 4 — Indexing Strategies
#
# Tests cover Parts A (baseline), B (STORING), C (partial), D (hash-sharded),
# E (expression), F (inverted JSONB), G (audit).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab04"
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup — 3-node cluster, shop schema, 50k orders"
start_cluster 3
cat <<'SQL' | sql_script
CREATE DATABASE shop;
USE shop;

CREATE TABLE customers (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email  STRING UNIQUE NOT NULL,
  name   STRING NOT NULL,
  joined TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE orders (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID NOT NULL REFERENCES customers(id),
  status       STRING NOT NULL CHECK (status IN ('open','paid','shipped','cancelled')),
  total        DECIMAL(12,2) NOT NULL CHECK (total >= 0),
  region       STRING NOT NULL,
  payload      JSONB NOT NULL DEFAULT '{}',
  placed       TIMESTAMPTZ DEFAULT now()
);

INSERT INTO customers (email, name)
SELECT 'user' || g || '@example.com', 'User ' || g
FROM generate_series(1, 1000) g;

INSERT INTO orders (customer_id, status, total, region, payload)
SELECT
  (SELECT id FROM customers ORDER BY random() LIMIT 1),
  (ARRAY['open','paid','shipped','shipped','shipped','cancelled'])[1 + (random()*5)::INT],
  (random() * 500)::DECIMAL(12,2),
  (ARRAY['us-east','us-west','eu-west'])[1 + (random()*2)::INT],
  jsonb_build_object(
    'channel', (ARRAY['web','mobile','api'])[1 + (random()*2)::INT],
    'tags',    (ARRAY['fast','urgent','gift','plain'])[1 + (random()*3)::INT]
  )
FROM generate_series(1, 50000);

CREATE STATISTICS s1 FROM customers;
CREATE STATISTICS s2 FROM orders;
SQL

ORDER_COUNT=$(sql_value "SELECT count(*) FROM shop.orders;")
assert_eq "50000 orders loaded" "$ORDER_COUNT" "50000"

ONE_CUST=$(sql_value "SELECT id FROM shop.customers LIMIT 1;")

section "Part A — Full table scan without an index"
EXPLAIN_NOIDX=$(sql "EXPLAIN SELECT id, status, total FROM shop.orders WHERE customer_id = '$ONE_CUST';")
assert_contains "scan node present pre-index" "$EXPLAIN_NOIDX" "scan"

section "Part B — Secondary index with STORING removes index join"
sql "USE shop; CREATE INDEX orders_by_customer ON orders(customer_id) STORING (status, total);" >/dev/null
EXPLAIN_STORING=$(sql "EXPLAIN SELECT id, status, total FROM shop.orders WHERE customer_id = '$ONE_CUST';")
assert_contains "uses new index" "$EXPLAIN_STORING" "orders_by_customer"
assert_not_contains "no index join in plan" "$EXPLAIN_STORING" "index join"

section "Part C — Partial index for status = 'open'"
sql "USE shop; CREATE INDEX orders_open ON orders(total DESC) STORING (customer_id) WHERE status = 'open';" >/dev/null
EXPLAIN_PARTIAL=$(sql "EXPLAIN SELECT id, customer_id, total FROM shop.orders WHERE status = 'open' ORDER BY total DESC LIMIT 20;")
assert_contains "EXPLAIN uses partial index" "$EXPLAIN_PARTIAL" "orders_open"

# Update an open order; partial index should reflect the removal
ANY_OPEN=$(sql_value "SELECT id FROM shop.orders WHERE status = 'open' LIMIT 1;")
BEFORE_OPEN=$(sql_value "SELECT count(*) FROM shop.orders WHERE status = 'open';")
sql "USE shop; UPDATE orders SET status = 'paid' WHERE id = '$ANY_OPEN';" >/dev/null
AFTER_OPEN=$(sql_value "SELECT count(*) FROM shop.orders WHERE status = 'open';")
assert_lt "open count decreased after status change" "$AFTER_OPEN" "$BEFORE_OPEN"

section "Part D — Hash-sharded index for time-series writes"
# Clause order matters: ON t(col) USING HASH STORING (...) WITH (bucket_count = N).
# 'STORING (...) USING HASH' and 'USING HASH WITH (...) STORING (...)' are both
# syntax errors — and an un-created index makes the plan assertions below vacuous.
sql "USE shop; CREATE INDEX orders_placed_hashed ON orders(placed) USING HASH STORING (customer_id, total) WITH (bucket_count = 8);" >/dev/null

EXPLAIN_HASH=$(sql "EXPLAIN SELECT id, customer_id, total FROM shop.orders WHERE placed > now() - INTERVAL '5 minutes';")
assert_contains "hash-sharded index is actually used by the plan" "$EXPLAIN_HASH" "orders_placed_hashed"

# Inspect the index — should have its shard column.
# NOTE: the hidden shard column does not appear in information_schema.columns;
# read the DDL instead.
HASH_DDL=$(sql "SHOW CREATE TABLE shop.orders;")   # qualify: sql() has no database context
assert_contains "hash-sharded index declared" "$HASH_DDL" "USING HASH"
assert_contains "hidden shard column present in the DDL" "$HASH_DDL" "shard_"

section "Part E — Expression index"
sql "USE shop; CREATE INDEX customers_email_lower ON customers((lower(email)));" >/dev/null
EXPLAIN_EXPR=$(sql "EXPLAIN SELECT id, name FROM shop.customers WHERE lower(email) = 'user42@example.com';")
assert_contains "expression index used" "$EXPLAIN_EXPR" "customers_email_lower"

section "Part F — Inverted (GIN) index on JSONB"
sql "USE shop; CREATE INVERTED INDEX orders_payload_idx ON orders(payload);" >/dev/null
EXPLAIN_INV=$(sql "EXPLAIN SELECT id, total FROM shop.orders WHERE payload @> '{\"channel\": \"mobile\"}'::JSONB LIMIT 100;")
assert_contains "inverted index used for JSONB containment" "$EXPLAIN_INV" "orders_payload_idx"

section "Part G — Index audit"
SHOW_IDX=$(sql "SHOW INDEXES FROM shop.orders;")
assert_contains "audit lists orders_by_customer" "$SHOW_IDX" "orders_by_customer"
assert_contains "audit lists orders_open" "$SHOW_IDX" "orders_open"
assert_contains "audit lists orders_placed_hashed" "$SHOW_IDX" "orders_placed_hashed"
assert_contains "audit lists orders_payload_idx" "$SHOW_IDX" "orders_payload_idx"

# At least 5 user indexes on orders (primary + 4 we created)
IDX_COUNT=$(sql_value "SELECT count(DISTINCT index_name) FROM [SHOW INDEXES FROM shop.orders];")
assert_ge "orders has 5+ indexes including primary" "$IDX_COUNT" "5"

section "Done"
echo "Lab 4: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
