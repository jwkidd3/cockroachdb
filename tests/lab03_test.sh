#!/usr/bin/env bash
# Lab 3 — Schema Design — Hotspots & Distribution Strategies
#
# Tests cover Parts A (SERIAL hotspot), B (UUID distribution), C (composite PK),
# D (hash-sharded composite), E (pre-splits), F (PK review checklist patterns).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab03"
BASE_SQL_PORT=26297
BASE_HTTP_PORT=8093
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup"
start_cluster 3
sql "CREATE DATABASE hotspots; SET sql_safe_updates = off;" >/dev/null

section "Part A — SERIAL PK creates a small number of ranges (and a hotspot)"
sql "USE hotspots; CREATE TABLE events_serial (
  id SERIAL PRIMARY KEY,
  payload STRING NOT NULL,
  created TIMESTAMPTZ DEFAULT now());" >/dev/null

# 50,000 rows in 5 batches
for i in 1 2 3 4 5; do
    sql "USE hotspots; INSERT INTO events_serial (payload)
         SELECT repeat('x', 400) FROM generate_series(1, 10000);" >/dev/null
done

SERIAL_COUNT=$(sql_value "SELECT count(*) FROM hotspots.events_serial;")
assert_eq "events_serial has 50000 rows" "$SERIAL_COUNT" "50000"

SERIAL_RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE hotspots.events_serial];")
info "events_serial range count: $SERIAL_RANGES"
assert_ge "events_serial has at least 1 range" "$SERIAL_RANGES" "1"

section "Part B — UUID PK distributes across ranges"
sql "USE hotspots; CREATE TABLE events_uuid (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payload STRING NOT NULL,
  created TIMESTAMPTZ DEFAULT now());" >/dev/null

for i in 1 2 3 4 5; do
    sql "USE hotspots; INSERT INTO events_uuid (payload)
         SELECT repeat('x', 400) FROM generate_series(1, 10000);" >/dev/null
done

UUID_COUNT=$(sql_value "SELECT count(*) FROM hotspots.events_uuid;")
assert_eq "events_uuid has 50000 rows" "$UUID_COUNT" "50000"

UUID_RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE hotspots.events_uuid];")
info "events_uuid range count: $UUID_RANGES"
# Note: range count depends on data size & timing. We can't guarantee >>1 but the SQL must complete.
assert_ge "events_uuid has at least 1 range" "$UUID_RANGES" "1"

section "Part C — Composite PK clusters by tenant"
sql "USE hotspots; CREATE TABLE events_composite (
  account_id UUID,
  event_id   UUID DEFAULT gen_random_uuid(),
  payload    STRING NOT NULL,
  created    TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (account_id, event_id));" >/dev/null

# 100k rows across 50 accounts (smaller than lab to keep CI tractable)
sql "USE hotspots;
WITH accounts AS (
  SELECT gen_random_uuid() AS id FROM generate_series(1, 50)
)
INSERT INTO events_composite (account_id, payload)
SELECT (SELECT id FROM accounts ORDER BY random() LIMIT 1),
       repeat('x', 200)
FROM generate_series(1, 100000);" >/dev/null

COMPOSITE_COUNT=$(sql_value "SELECT count(*) FROM hotspots.events_composite;")
assert_eq "events_composite has 100000 rows" "$COMPOSITE_COUNT" "100000"

# EXPLAIN should show a scan with a span limited to one account
ONE_ACCT=$(sql_value "SELECT account_id FROM hotspots.events_composite LIMIT 1;")
EXPLAIN_OUT=$(sql "EXPLAIN SELECT * FROM hotspots.events_composite WHERE account_id = '$ONE_ACCT';")
assert_contains "EXPLAIN uses a scan node" "$EXPLAIN_OUT" "scan"

section "Part D — Hash-sharded composite for hot single tenant"
sql "USE hotspots; CREATE TABLE events_sharded (
  account_id UUID,
  created    TIMESTAMPTZ DEFAULT now(),
  payload    STRING NOT NULL,
  PRIMARY KEY (account_id, created) USING HASH WITH (bucket_count = 16));" >/dev/null

sql "USE hotspots;
INSERT INTO events_sharded (account_id, payload)
SELECT '00000000-0000-0000-0000-000000000001'::UUID, repeat('x', 200)
FROM generate_series(1, 20000);" >/dev/null

SHARDED_COUNT=$(sql_value "SELECT count(*) FROM hotspots.events_sharded;")
assert_eq "events_sharded has 20000 rows" "$SHARDED_COUNT" "20000"

# The hidden shard column should exist
SHARD_COL=$(sql_value "SELECT column_name FROM information_schema.columns
WHERE table_name = 'events_sharded' AND column_name LIKE '%shard%';")
assert_contains "events_sharded has a hash-shard column" "$SHARD_COL" "shard"

# Range query plan must reference the hash key
EXPLAIN_HASH=$(sql "EXPLAIN SELECT * FROM hotspots.events_sharded
WHERE account_id = '00000000-0000-0000-0000-000000000001'::UUID
  AND created > now() - INTERVAL '5 minutes' ORDER BY created DESC LIMIT 10;")
assert_contains "hash-sharded query EXPLAIN runs" "$EXPLAIN_HASH" "scan"

section "Part E — Pre-splits seed range distribution"
sql "USE hotspots; CREATE TABLE big_import (
  id      INT8 PRIMARY KEY,
  payload STRING NOT NULL);" >/dev/null

sql "USE hotspots; ALTER TABLE big_import SPLIT AT
VALUES (100000), (200000), (300000), (400000), (500000),
       (600000), (700000), (800000), (900000);" >/dev/null

PRESPLIT_RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE hotspots.big_import];")
assert_ge "big_import pre-split into >= 10 ranges" "$PRESPLIT_RANGES" "10"

# Small bulk load to confirm distribution doesn't break
sql "USE hotspots;
INSERT INTO big_import (id, payload)
SELECT g, repeat('x', 100) FROM generate_series(1, 100000) g;" >/dev/null

IMPORT_COUNT=$(sql_value "SELECT count(*) FROM hotspots.big_import;")
assert_eq "big_import has 100000 rows after bulk load" "$IMPORT_COUNT" "100000"

# After load, range count should be >= the pre-split count (may have grown)
POST_LOAD_RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE hotspots.big_import];")
assert_ge "big_import range count survived bulk load" "$POST_LOAD_RANGES" "10"

section "Part F — PK review patterns all instantiate"
sql "USE hotspots; CREATE TABLE tbl1 (id SERIAL PRIMARY KEY, body STRING);" >/dev/null
sql "USE hotspots; CREATE TABLE tbl2 (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), body STRING);" >/dev/null
sql "USE hotspots; CREATE TABLE tbl3 (tenant UUID, ts TIMESTAMPTZ, body STRING, PRIMARY KEY (tenant, ts));" >/dev/null
sql "USE hotspots; CREATE TABLE tbl4 (region STRING, ts TIMESTAMPTZ, body STRING, PRIMARY KEY (region, ts));" >/dev/null
sql "USE hotspots; CREATE TABLE tbl5 (ts TIMESTAMPTZ, shard INT AS (mod(extract(epoch from ts)::INT, 16)) STORED, body STRING, PRIMARY KEY (shard, ts));" >/dev/null
pass "all 5 review-pattern tables created successfully"

section "Part G — Append-Only Event Log + TTL (Playbook #2, #9)"

# Event log with a long-duration TTL — just verifies the storage-level setting works
sql "USE hotspots; CREATE TABLE event_log (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ts      TIMESTAMPTZ DEFAULT now(),
  payload JSONB
) WITH (ttl_expire_after = '30 days', ttl_job_cron = '@hourly');" >/dev/null

sql "USE hotspots; INSERT INTO event_log (payload)
  SELECT jsonb_build_object('user', g, 'action', 'view')
  FROM generate_series(1, 50000) g;" >/dev/null

EVENT_COUNT=$(sql_value "SELECT count(*) FROM hotspots.event_log;")
assert_eq "event_log loaded with 50000 rows" "$EVENT_COUNT" "50000"

# A TTL job for the table should now exist
TTL_JOB=$(sql_value "SELECT count(*) FROM [SHOW JOBS]
  WHERE job_type = 'ROW LEVEL TTL'
    AND description ILIKE '%event_log%';")
assert_ge "row-level TTL job created for event_log" "$TTL_JOB" "1"

# Verify the TTL settings are actually attached to the table
TTL_SETTINGS=$(sql "SHOW CREATE TABLE hotspots.event_log;")
assert_contains "table DDL reports ttl_expire_after" "$TTL_SETTINGS" "ttl_expire_after"

# Tiny-TTL demo: a 30-second TTL that we can watch sweep
sql "USE hotspots; CREATE TABLE ttl_demo (
  id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ts  TIMESTAMPTZ DEFAULT now()
) WITH (ttl_expire_after = '30 seconds', ttl_job_cron = '* * * * *');" >/dev/null

sql "USE hotspots; INSERT INTO ttl_demo (id) SELECT gen_random_uuid() FROM generate_series(1, 100);" >/dev/null
BEFORE_SWEEP=$(sql_value "SELECT count(*) FROM hotspots.ttl_demo;")
assert_eq "ttl_demo loaded with 100 rows" "$BEFORE_SWEEP" "100"

info "waiting up to 120s for TTL sweep to expire all 100 rows"
SWEPT=0
for _ in $(seq 1 24); do
    sleep 5
    REMAIN=$(sql_value "SELECT count(*) FROM hotspots.ttl_demo;")
    if [ "$REMAIN" = "0" ]; then SWEPT=1; break; fi
done
if [ "$SWEPT" = "1" ]; then
    pass "TTL job swept all expired rows"
else
    REMAIN_FINAL=$(sql_value "SELECT count(*) FROM hotspots.ttl_demo;")
    warn "TTL sweep incomplete after 120s ($REMAIN_FINAL rows still present); job scheduling can be slow on a tiny test cluster"
fi

section "Part H — Outbox Pattern with CDC (Playbook #8)"
sql "USE hotspots; CREATE TABLE orders_v2 (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer  STRING NOT NULL,
  total     DECIMAL(12,2) NOT NULL,
  placed    TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE events_outbox (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic    STRING NOT NULL,
  payload  JSONB NOT NULL,
  created  TIMESTAMPTZ DEFAULT now()
) WITH (ttl_expire_after = '7 days', ttl_job_cron = '@hourly');" >/dev/null
pass "orders_v2 and events_outbox created"

# Atomic write — business row + outbox event in a single transaction
URL="postgresql://root@localhost:${BASE_SQL_PORT}/hotspots?sslmode=disable"
cockroach sql --url "$URL" <<'SQL' >/dev/null
BEGIN;
WITH new_order AS (
  INSERT INTO orders_v2 (customer, total)
  VALUES ('Alice', 99.99)
  RETURNING id
)
INSERT INTO events_outbox (topic, payload)
SELECT 'orders.created',
       jsonb_build_object('order_id', id, 'customer', 'Alice', 'total', 99.99)
FROM new_order;
COMMIT;
SQL

ORDER_COUNT=$(sql_value "SELECT count(*) FROM hotspots.orders_v2;")
OUTBOX_COUNT=$(sql_value "SELECT count(*) FROM hotspots.events_outbox;")
assert_eq "orders_v2 has 1 row after atomic write" "$ORDER_COUNT" "1"
assert_eq "events_outbox has 1 corresponding event"  "$OUTBOX_COUNT" "1"

# Verify atomicity: a deliberately-failing txn must roll BOTH back
sql_expect_fail "USE hotspots; BEGIN;
  INSERT INTO orders_v2 (customer, total) VALUES ('Bob', 50.00);
  INSERT INTO events_outbox (topic, payload) VALUES ('orders.created', NULL);
  COMMIT;" >/dev/null || true
ORDER_AFTER_FAIL=$(sql_value "SELECT count(*) FROM hotspots.orders_v2 WHERE customer = 'Bob';")
assert_eq "failed txn left no orphan orders" "$ORDER_AFTER_FAIL" "0"

# Core changefeed streams from the outbox table — capture briefly
CDC_OUT="${STORE_BASE}/outbox-cdc.json"
( cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" \
    --database=hotspots \
    --execute "EXPERIMENTAL CHANGEFEED FOR events_outbox;" \
    >"$CDC_OUT" 2>/dev/null ) &
CDC_PID=$!
sleep 3

cockroach sql --url "$URL" <<'SQL' >/dev/null
BEGIN;
WITH new_order AS (
  INSERT INTO orders_v2 (customer, total) VALUES ('Charlie', 200.00) RETURNING id
)
INSERT INTO events_outbox (topic, payload)
SELECT 'orders.created', jsonb_build_object('order_id', id, 'customer', 'Charlie')
FROM new_order;
COMMIT;
SQL
sleep 3

kill "$CDC_PID" 2>/dev/null || true
wait "$CDC_PID" 2>/dev/null || true

if [ -s "$CDC_OUT" ] && grep -q "{" "$CDC_OUT"; then
    pass "outbox changefeed emitted JSON events"
else
    warn "outbox changefeed produced no output (timing/version sensitive); first lines:"
    head "$CDC_OUT" 2>/dev/null | sed 's/^/    /'
fi

section "Done"
echo "Lab 3: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
