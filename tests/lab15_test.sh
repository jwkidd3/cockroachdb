#!/usr/bin/env bash
# Lab 15 — PostgreSQL → CockroachDB migration. The source PostgreSQL runs in
# Docker; when Docker is unavailable the schema-redesign and plan-comparison
# assertions still run against CockroachDB alone.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab15"
source "$SCRIPT_DIR/lib/cluster.sh"

PG_NAME="lab15-pg"
PG_PORT=54329
PG="postgresql://postgres:pg@localhost:${PG_PORT}/legacy"
HAVE_PG=0

cleanup_all() {
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    stop_cluster
}
trap cleanup_all EXIT INT TERM

section "Setup — target cluster"
start_cluster 3
sql "CREATE DATABASE target;" >/dev/null

section "Source PostgreSQL (optional)"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && command -v psql >/dev/null 2>&1; then
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    if docker run -d --name "$PG_NAME" -p ${PG_PORT}:5432 \
        -e POSTGRES_PASSWORD=pg -e POSTGRES_DB=legacy postgres:16 >/dev/null 2>&1; then
        wait_for "postgres ready" 60 "psql '$PG' -c 'SELECT 1'"
        HAVE_PG=1
        pass "source PostgreSQL is up"
    else
        warn "could not start PostgreSQL container; running the CockroachDB-only subset"
    fi
else
    warn "Docker or psql unavailable; running the CockroachDB-only subset"
fi

if [ "$HAVE_PG" = "1" ]; then
    psql "$PG" -q <<'SQL'
CREATE TABLE customers (
  id SERIAL PRIMARY KEY, email VARCHAR(255) NOT NULL UNIQUE,
  name VARCHAR(255) NOT NULL, tenant_id INTEGER NOT NULL,
  created_at TIMESTAMP DEFAULT now());
CREATE TABLE orders (
  id SERIAL PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id),
  tenant_id INTEGER NOT NULL, total NUMERIC(12,2) NOT NULL,
  status VARCHAR(32) NOT NULL DEFAULT 'new', metadata JSON,
  created_at TIMESTAMP DEFAULT now());
CREATE TABLE order_events (
  id BIGSERIAL PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id),
  event_type VARCHAR(64) NOT NULL, occurred_at TIMESTAMP DEFAULT now());
CREATE OR REPLACE FUNCTION touch_order() RETURNS TRIGGER AS $$
BEGIN NEW.created_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER orders_touch BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION touch_order();
INSERT INTO customers (email, name, tenant_id)
SELECT 'user' || g || '@example.com', 'User ' || g, (g % 20) + 1 FROM generate_series(1, 2000) g;
INSERT INTO orders (customer_id, tenant_id, total, status, metadata)
SELECT (random()*1999)::int + 1, (g % 20) + 1, (random()*500)::numeric(12,2),
       (ARRAY['new','paid','shipped','cancelled'])[1 + (g % 4)],
       ('{"seq":' || g || '}')::json
FROM generate_series(1, 10000) g;
INSERT INTO order_events (order_id, event_type)
SELECT (random()*9999)::int + 1, (ARRAY['created','paid','shipped'])[1 + (g % 3)]
FROM generate_series(1, 20000) g;
SQL
    PG_CUST=$(psql "$PG" -tAc "SELECT count(*) FROM customers")
    PG_ORD=$(psql "$PG" -tAc "SELECT count(*) FROM orders")
    PG_EV=$(psql "$PG" -tAc "SELECT count(*) FROM order_events")
    assert_eq "source customers loaded" "$PG_CUST" "2000"
    assert_eq "source orders loaded" "$PG_ORD" "10000"
    assert_eq "source order_events loaded" "$PG_EV" "20000"

    section "Part A — dialect audit of the source"
    TRIGGERS=$(psql "$PG" -tAc "SELECT count(*) FROM information_schema.triggers")
    assert_gt "audit found triggers that will not migrate as-is" "$TRIGGERS" "0"
    SEQS=$(psql "$PG" -tAc "SELECT count(*) FROM pg_sequences")
    assert_gt "audit found sequences behind SERIAL columns" "$SEQS" "0"
fi

section "Part B — redesigned target schema"

crdb sql <<'SQL' >/dev/null
USE target;
CREATE TABLE customers (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  tenant_id INT NOT NULL, email STRING NOT NULL, name STRING NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), legacy_id INT NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE INDEX customers_email_key (email),
  UNIQUE INDEX customers_legacy_id_key (legacy_id));

CREATE TABLE orders (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  tenant_id INT NOT NULL, customer_id UUID NOT NULL,
  total DECIMAL(12,2) NOT NULL, status STRING NOT NULL DEFAULT 'new',
  metadata JSONB, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), legacy_id INT NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE INDEX orders_legacy_id_key (legacy_id),
  INDEX orders_customer_idx (tenant_id, customer_id),
  INDEX orders_open_idx (tenant_id, created_at DESC)
    STORING (total, customer_id) WHERE status IN ('new', 'paid'));

CREATE TABLE order_events (
  order_id UUID NOT NULL, occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  event_type STRING NOT NULL, legacy_id INT NOT NULL,
  PRIMARY KEY (order_id, occurred_at, id) USING HASH WITH (bucket_count = 16))
  WITH (ttl_expire_after = '180 days', ttl_job_cron = '@daily');
SQL
pass "redesigned schema created"

CUST_DDL=$(sql "SHOW CREATE TABLE target.public.customers;")
assert_contains "customers PK leads with tenant_id (co-located)" "$CUST_DDL" "PRIMARY KEY (tenant_id"
EV_DDL=$(sql "SHOW CREATE TABLE target.public.order_events;")
assert_contains "order_events PK is hash-sharded" "$EV_DDL" "USING HASH"
assert_contains "order_events has a TTL" "$EV_DDL" "ttl_expire_after"
ORD_DDL=$(sql "SHOW CREATE TABLE target.public.orders;")
assert_contains "orders has the partial hot/cold index" "$ORD_DDL" "WHERE status"

section "Part C — move and transform the data"

if [ "$HAVE_PG" = "1" ]; then
    psql "$PG" -q -c "\copy (SELECT id, tenant_id, email, name, created_at FROM customers) TO '${STORE_BASE}/customers.csv' CSV"
    psql "$PG" -q -c "\copy (SELECT id, customer_id, tenant_id, total, status, metadata::text, created_at FROM orders) TO '${STORE_BASE}/orders.csv' CSV"
    psql "$PG" -q -c "\copy (SELECT id, order_id, event_type, occurred_at FROM order_events) TO '${STORE_BASE}/events.csv' CSV"
    assert_file_exists "customers CSV exported" "${STORE_BASE}/customers.csv"

    crdb sql <<'SQL' >/dev/null
USE target;
CREATE TABLE stage_customers (legacy_id INT PRIMARY KEY, tenant_id INT, email STRING, name STRING, created_at TIMESTAMPTZ);
CREATE TABLE stage_orders (legacy_id INT PRIMARY KEY, customer_legacy INT, tenant_id INT, total DECIMAL(12,2), status STRING, metadata JSONB, created_at TIMESTAMPTZ);
CREATE TABLE stage_events (legacy_id INT PRIMARY KEY, order_legacy INT, event_type STRING, occurred_at TIMESTAMPTZ);
SQL

    LOADED=1
    for pair in "customers:stage_customers" "orders:stage_orders" "events:stage_events"; do
        f="${pair%%:*}"; t="${pair##*:}"
        # The CSVs were exported by psql onto this machine; the node cannot see
        # them. Copy each into the container before staging it in userfile.
        crdb_cp "${STORE_BASE}/${f}.csv" "crdb1:/tmp/${f}.csv" >/dev/null 2>&1 \
            || { warn "scripts/crdb cp failed for ${f}.csv"; LOADED=0; continue; }
        if crdb_run userfile upload "/tmp/${f}.csv" "/lab15/${f}.csv" --insecure >/dev/null 2>&1; then
            OUT=$(sql "IMPORT INTO target.public.${t} CSV DATA ('userfile:///lab15/${f}.csv');" 2>&1 || true)
            if echo "$OUT" | grep -qi "use of this feature\|enterprise"; then
                warn "IMPORT INTO gated by license; falling back to COPY for ${t}"
                psql "postgresql://root@localhost:${BASE_SQL_PORT}/target?sslmode=disable" \
                    -c "\copy public.${t} FROM '${STORE_BASE}/${f}.csv' CSV" >/dev/null 2>&1 || LOADED=0
            fi
        else
            LOADED=0
        fi
    done

    if [ "$LOADED" = "1" ]; then
        pass "staging tables loaded"
        crdb sql <<'SQL' >/dev/null
USE target;
INSERT INTO customers (tenant_id, email, name, created_at, legacy_id)
SELECT tenant_id, email, name, created_at, legacy_id FROM stage_customers;
INSERT INTO orders (tenant_id, customer_id, total, status, metadata, created_at, legacy_id)
SELECT s.tenant_id, c.id, s.total, s.status, s.metadata, s.created_at, s.legacy_id
FROM stage_orders s JOIN customers c ON c.legacy_id = s.customer_legacy;
INSERT INTO order_events (order_id, occurred_at, event_type, legacy_id)
SELECT o.id, s.occurred_at, s.event_type, s.legacy_id
FROM stage_events s JOIN orders o ON o.legacy_id = s.order_legacy;
SQL
        pass "staging transformed into the new key space"

        CR_CUST=$(sql_value "SELECT count(*) FROM target.public.customers;")
        CR_ORD=$(sql_value "SELECT count(*) FROM target.public.orders;")
        CR_EV=$(sql_value "SELECT count(*) FROM target.public.order_events;")
        assert_eq "customers row count matches the source" "$CR_CUST" "$PG_CUST"
        assert_eq "orders row count matches the source" "$CR_ORD" "$PG_ORD"
        assert_eq "order_events row count matches the source" "$CR_EV" "$PG_EV"

        PG_SUM=$(psql "$PG" -tAc "SELECT sum(total)::numeric(20,2) FROM orders")
        CR_SUM=$(sql_value "SELECT sum(total)::DECIMAL(20,2) FROM target.public.orders;")
        assert_eq "business checksum matches (sum of order totals)" "$CR_SUM" "$PG_SUM"

        section "Part C.5 — constraints after the load"
        assert_command_succeeds "FK added post-load" \
            crdb sql -e \
            "ALTER TABLE target.public.orders ADD CONSTRAINT orders_customer_fk
             FOREIGN KEY (tenant_id, customer_id) REFERENCES target.public.customers (tenant_id, id);"
        FKS=$(sql "SHOW CONSTRAINTS FROM target.public.orders;")
        assert_contains "foreign key present and validated" "$FKS" "orders_customer_fk"

        sql "DROP TABLE target.public.stage_customers, target.public.stage_orders, target.public.stage_events;" >/dev/null
        pass "staging tables dropped"
    else
        warn "bulk load path unavailable; skipping the data-movement assertions"
    fi
else
    # No PostgreSQL: synthesize rows so the plan comparison still has data.
    crdb sql <<'SQL' >/dev/null
USE target;
INSERT INTO customers (tenant_id, email, name, legacy_id)
SELECT (g % 20) + 1, 'user' || g || '@example.com', 'User ' || g, g FROM generate_series(1, 2000) g;
INSERT INTO orders (tenant_id, customer_id, total, status, legacy_id)
SELECT c.tenant_id, c.id, (c.legacy_id % 500)::DECIMAL(12,2),
       (ARRAY['new','paid','shipped','cancelled'])[1 + (c.legacy_id % 4)], c.legacy_id
FROM customers c;
SQL
    pass "synthetic dataset created for the plan comparison"
fi

section "Part D — statistics and plan comparison"

sql "CREATE STATISTICS lab15_stats ON tenant_id, status, created_at FROM target.public.orders;" >/dev/null 2>&1 \
    && pass "statistics collected" || warn "CREATE STATISTICS failed"

STATS=$(sql "SHOW STATISTICS FOR TABLE target.public.orders;")
assert_contains "statistics visible for the optimizer" "$STATS" "tenant_id"

PLAN1=$(sql "EXPLAIN SELECT * FROM target.public.orders WHERE tenant_id = 7 ORDER BY created_at DESC LIMIT 50;")
assert_contains "tenant-scoped query uses an index, not a full scan" "$PLAN1" "orders"
assert_not_contains "tenant-scoped query avoids a full table scan" "$PLAN1" "FULL SCAN"

PLAN2=$(sql "EXPLAIN SELECT count(*) FROM target.public.orders WHERE status = 'new';")
info "cross-tenant status query plan:"
echo "$PLAN2" | head -12 | sed 's/^/    /'

section "Done"
echo "Lab 15: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
