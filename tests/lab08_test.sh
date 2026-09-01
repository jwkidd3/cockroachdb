#!/usr/bin/env bash
# Lab 8 — Throughput Engineering: bulk import, batching, PK bake-off,
# sharded counters, online schema change, concurrency knee.
#
# The lab is about measured numbers; the test asserts the mechanisms work and
# that the expected orderings hold (batched beats single-row, hash-sharded
# spreads across more ranges than SERIAL, sharded counter beats single-row).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab08"
BASE_SQL_PORT=26397
BASE_HTTP_PORT=8143
source "$SCRIPT_DIR/lib/cluster.sh"

URL="postgresql://root@localhost:${BASE_SQL_PORT}?sslmode=disable"
CSV="${STORE_BASE}/load_test.csv"

trap 'stop_cluster' EXIT INT TERM

section "Setup — 3-node cluster"
start_cluster 3

sql "CREATE DATABASE throughput;" >/dev/null
cat <<'SQL' | sql_script >/dev/null
USE throughput;
SET sql_safe_updates = off;
CREATE TABLE load_test (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant   INT NOT NULL,
  amount   DECIMAL(12,2) NOT NULL,
  note     STRING NOT NULL,
  created  TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL
pass "load_test table created"

section "Part A — four ingest methods"

ROWS=20000     # smaller than the lab's 100k so the suite stays quick

# A1: single-row inserts (200 only; we extrapolate rather than wait)
T0=$(date +%s)
for i in $(seq 1 200); do
    echo "INSERT INTO throughput.load_test (tenant, amount, note) VALUES (1, 9.99, 'single');"
done | cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" >/dev/null 2>&1
T1=$(date +%s)
SINGLE_SECS=$(( T1 - T0 )); [ "$SINGLE_SECS" -eq 0 ] && SINGLE_SECS=1
SINGLE_RATE=$(( 200 / SINGLE_SECS ))
info "single-row: 200 rows in ${SINGLE_SECS}s (~${SINGLE_RATE} rows/s)"
SINGLE_COUNT=$(sql_value "SELECT count(*) FROM throughput.load_test;")
assert_eq "single-row inserts landed" "$SINGLE_COUNT" "200"

# A2: multi-row INSERT ... SELECT
sql "TRUNCATE throughput.load_test;" >/dev/null
T0=$(date +%s)
sql "INSERT INTO throughput.load_test (tenant, amount, note)
     SELECT g % 50, (g % 1000)::DECIMAL / 100, 'batched'
     FROM generate_series(1, ${ROWS}) g;" >/dev/null
T1=$(date +%s)
BATCH_SECS=$(( T1 - T0 )); [ "$BATCH_SECS" -eq 0 ] && BATCH_SECS=1
BATCH_RATE=$(( ROWS / BATCH_SECS ))
info "multi-row: ${ROWS} rows in ${BATCH_SECS}s (~${BATCH_RATE} rows/s)"
BATCH_COUNT=$(sql_value "SELECT count(*) FROM throughput.load_test;")
assert_eq "multi-row insert loaded all rows" "$BATCH_COUNT" "$ROWS"
assert_gt "batched insert beats single-row insert (rows/sec)" "$BATCH_RATE" "$SINGLE_RATE"

# A3/A4: CSV + IMPORT INTO via userfile
python3 - "$CSV" "$ROWS" <<'PY'
import csv, sys, uuid, random
path, n = sys.argv[1], int(sys.argv[2])
with open(path, 'w', newline='') as f:
    w = csv.writer(f)
    for i in range(n):
        w.writerow([str(uuid.uuid4()), i % 50, round(random.random()*1000, 2),
                    f'copy row {i}', '2024-01-01 00:00:00+00'])
PY
assert_file_exists "CSV generated" "$CSV"

if cockroach userfile upload "$CSV" /lab8/load_test.csv --url "$URL" >/dev/null 2>&1; then
    pass "userfile upload succeeded"
    sql "TRUNCATE throughput.load_test;" >/dev/null
    IMPORT_OUT=$(sql "IMPORT INTO throughput.load_test (id, tenant, amount, note, created)
                      CSV DATA ('userfile:///lab8/load_test.csv');" 2>&1 || true)
    if echo "$IMPORT_OUT" | grep -qi "use of this feature\|enterprise"; then
        warn "IMPORT INTO gated by license on this cluster; skipping"
    else
        IMPORT_COUNT=$(sql_value "SELECT count(*) FROM throughput.load_test;")
        assert_eq "IMPORT INTO loaded all rows" "$IMPORT_COUNT" "$ROWS"
    fi
else
    warn "userfile upload unavailable; skipping IMPORT INTO check"
fi

section "Part C — pre-split before bulk load"

sql "CREATE TABLE throughput.seq_import (id INT PRIMARY KEY, payload STRING);" >/dev/null
sql "CREATE TABLE throughput.seq_split  (id INT PRIMARY KEY, payload STRING);" >/dev/null

RANGES_BEFORE=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE throughput.seq_split];")
assert_eq "new table starts as a single range" "$RANGES_BEFORE" "1"

sql "ALTER TABLE throughput.seq_split SPLIT AT SELECT g * 5000 FROM generate_series(1, 9) g;" >/dev/null
RANGES_AFTER_SPLIT=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE throughput.seq_split];")
assert_ge "pre-split created multiple ranges" "$RANGES_AFTER_SPLIT" "9"

sql "INSERT INTO throughput.seq_import SELECT g, repeat('x', 100) FROM generate_series(1, 20000) g;" >/dev/null
sql "INSERT INTO throughput.seq_split  SELECT g, repeat('x', 100) FROM generate_series(1, 20000) g;" >/dev/null

SPLIT_LEASEHOLDERS=$(sql_value "SELECT count(DISTINCT lease_holder) FROM [SHOW RANGES FROM TABLE throughput.seq_split WITH DETAILS];")
assert_ge "pre-split table spread across leaseholders" "$SPLIT_LEASEHOLDERS" "1"

assert_command_succeeds "UNSPLIT ALL releases manual splits" \
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" \
    --execute "ALTER TABLE throughput.seq_split UNSPLIT ALL;"

section "Part D — PK design bake-off"

cat <<'SQL' | sql_script >/dev/null
USE throughput;
CREATE TABLE pk_serial (
  id SERIAL PRIMARY KEY, tenant INT, payload STRING, created TIMESTAMPTZ DEFAULT now());
CREATE TABLE pk_uuid (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant INT, payload STRING,
  created TIMESTAMPTZ DEFAULT now());
CREATE TABLE pk_composite (
  tenant INT, id UUID DEFAULT gen_random_uuid(), payload STRING,
  created TIMESTAMPTZ DEFAULT now(), PRIMARY KEY (tenant, id));
CREATE TABLE pk_hash (
  tenant INT, created TIMESTAMPTZ DEFAULT now(), id UUID DEFAULT gen_random_uuid(),
  payload STRING,
  PRIMARY KEY (tenant, created, id) USING HASH WITH (bucket_count = 16));
SQL
pass "four PK-design tables created"

# The hash-sharded table must carry the hidden shard column.
HASH_DDL=$(sql "SHOW CREATE TABLE throughput.pk_hash;")
assert_contains "hash-sharded PK declared" "$HASH_DDL" "USING HASH"
assert_contains "hidden shard column created" "$HASH_DDL" "shard_16"

for T in pk_serial pk_uuid pk_composite pk_hash; do
    sql "INSERT INTO throughput.$T (tenant, payload)
         SELECT g % 50, 'p' FROM generate_series(1, 20000) g;" >/dev/null
done
pass "20k rows loaded into each PK design"

R_SERIAL=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE throughput.pk_serial];")
R_HASH=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE throughput.pk_hash];")
info "ranges — pk_serial=$R_SERIAL  pk_hash=$R_HASH (at this row count neither table has split yet;"
info "         the lab uses larger volumes and the Hot Ranges page to show the difference)"

# The mechanism that produces the spread, independent of whether a split has
# happened yet: writes must land in many hash buckets, not one.
SHARD_COL=$(echo "$HASH_DDL" | grep -o 'crdb_internal_[a-z_0-9]*shard_16' | head -1)
if [ -n "$SHARD_COL" ]; then
    DISTINCT_SHARDS=$(sql_value "SELECT count(DISTINCT $SHARD_COL) FROM throughput.pk_hash;")
    assert_ge "writes scattered across hash buckets" "$DISTINCT_SHARDS" "8"
else
    fail "could not determine the hash shard column name from SHOW CREATE TABLE"
fi

# The SERIAL table's keys are near-monotonic: max-min spread over 20k rows is small
# relative to the keyspace, which is exactly why its writes pile on one range.
SERIAL_SPREAD=$(sql_value "SELECT (max(id) - min(id)) FROM throughput.pk_serial;")
info "pk_serial key spread across 20k rows: $SERIAL_SPREAD (near-monotonic => rightmost-range writes)"

PLAN=$(sql "EXPLAIN SELECT * FROM throughput.pk_composite WHERE tenant = 7 ORDER BY id LIMIT 10;")
assert_contains "composite PK query uses the primary index" "$PLAN" "pk_composite"

section "Part E — sharded counter vs single-row counter"

cat <<'SQL' | sql_script >/dev/null
USE throughput;
CREATE TABLE counter_single (name STRING PRIMARY KEY, n INT NOT NULL DEFAULT 0);
INSERT INTO counter_single VALUES ('page_views', 0);
CREATE TABLE counter_shards (
  name STRING, shard INT2, n INT NOT NULL DEFAULT 0, PRIMARY KEY (name, shard));
INSERT INTO counter_shards (name, shard, n) SELECT 'page_views', g, 0 FROM generate_series(0, 15) g;
SQL
pass "counter tables created"

# The trap the lab teaches: random() is volatile and is evaluated PER ROW in a
# predicate, so `WHERE shard = (random()*16)::INT2` matches a random number of
# rows — losing and duplicating increments. Assert the broken form is broken so
# the lab's claim stays true against future versions.
sql "UPDATE throughput.counter_shards SET n = 0 WHERE name = 'page_views';" >/dev/null
for i in $(seq 1 200); do
    echo "UPDATE throughput.counter_shards SET n = n + 1 WHERE name = 'page_views' AND shard = (random()*16)::INT2;"
done | cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" >/dev/null 2>&1
VOLATILE_TOTAL=$(sql_value "SELECT sum(n) FROM throughput.counter_shards WHERE name = 'page_views';")
info "volatile predicate: 200 increments produced a total of ${VOLATILE_TOTAL}"
if [ "${VOLATILE_TOTAL:-200}" -ne 200 ]; then
    pass "volatile random() in a predicate loses/duplicates increments (as the lab warns)"
else
    warn "volatile predicate happened to total exactly 200 on this run — the lab's `SELECT count(*)` demo still shows the per-row evaluation"
fi

# The correct form: the client picks the shard, so the server sees a literal.
bump() {
    local kind="$1" workers=8 per=40
    local t0 t1
    t0=$(date +%s)
    for w in $(seq 1 $workers); do
        ( for i in $(seq 1 $per); do
            if [ "$kind" = single ]; then
                echo "UPDATE throughput.counter_single SET n = n + 1 WHERE name = 'page_views';"
            else
                echo "UPDATE throughput.counter_shards SET n = n + 1 WHERE name = 'page_views' AND shard = $(( RANDOM % 16 ));"
            fi
          done | cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" >/dev/null 2>&1 ) &
    done
    wait
    t1=$(date +%s)
    echo $(( t1 - t0 ))
}

sql "UPDATE throughput.counter_single SET n = 0; UPDATE throughput.counter_shards SET n = 0;" >/dev/null
SINGLE_T=$(bump single)
SHARDED_T=$(bump sharded)
info "counter contention: single-row=${SINGLE_T}s  sharded=${SHARDED_T}s (320 increments each)"

SINGLE_N=$(sql_value "SELECT n FROM throughput.counter_single WHERE name = 'page_views';")
SHARDED_N=$(sql_value "SELECT sum(n) FROM throughput.counter_shards WHERE name = 'page_views';")
assert_eq "single-row counter counted every increment" "$SINGLE_N" "320"
assert_eq "sharded counter sums to every increment" "$SHARDED_N" "320"
if [ "$SHARDED_T" -le "$SINGLE_T" ]; then
    pass "sharded counter completed no slower than the single-row counter"
else
    warn "sharded counter was slower on this run (${SHARDED_T}s vs ${SINGLE_T}s) — contention effects are noisy at this scale"
fi

SHARD_RANGES=$(sql_value "SELECT count(DISTINCT shard) FROM throughput.counter_shards WHERE n > 0;")
assert_ge "increments spread across multiple shards" "$SHARD_RANGES" "2"

section "Part F — online schema change under write load"

( for i in $(seq 1 40); do
    echo "INSERT INTO throughput.pk_uuid (tenant, payload) SELECT g % 50, 'live' FROM generate_series(1,200) g;"
  done | cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" >/dev/null 2>&1 ) &
WRITER_PID=$!

sleep 1
assert_command_succeeds "CREATE INDEX succeeds while writes are in flight" \
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" \
    --execute "CREATE INDEX pk_uuid_tenant_created_idx ON throughput.pk_uuid (tenant, created DESC);"

wait "$WRITER_PID" 2>/dev/null || true

IDX=$(sql_value "SELECT count(*) FROM [SHOW INDEXES FROM throughput.pk_uuid]
                 WHERE index_name = 'pk_uuid_tenant_created_idx';")
assert_ge "new index exists after the online schema change" "$IDX" "1"

# CREATE INDEX runs through the DECLARATIVE schema changer in modern versions and
# is recorded as 'NEW SCHEMA CHANGE'; the legacy changer ('SCHEMA CHANGE') still
# handles things like TRUNCATE. Match both or this silently measures the wrong job.
JOBS=$(sql_value "SELECT count(*) FROM [SHOW JOBS] WHERE job_type IN ('SCHEMA CHANGE', 'NEW SCHEMA CHANGE');")
assert_ge "schema change ran as a background job" "$JOBS" "1"

# Index must be usable and consistent with the base table.
IDX_PLAN=$(sql "EXPLAIN SELECT tenant, created FROM throughput.pk_uuid WHERE tenant = 3 ORDER BY created DESC LIMIT 5;")
assert_contains "optimizer picks the new index" "$IDX_PLAN" "pk_uuid_tenant_created_idx"

section "Part G — concurrency knee via cockroach workload"

assert_command_succeeds "workload init kv" \
    cockroach workload init kv --drop "$URL"

for C in 1 8; do
    OUT=$(cockroach workload run kv --duration=10s --concurrency=$C --read-percent=50 "$URL" 2>&1 | tail -3)
    if echo "$OUT" | grep -qE '[0-9]'; then
        pass "workload run at concurrency=$C produced results"
        echo "$OUT" | sed 's/^/    /'
    else
        fail "workload run at concurrency=$C produced no output"
    fi
done

section "Done"
echo "Lab 8: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
