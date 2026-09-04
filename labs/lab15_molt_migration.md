# Lab 15: Migrate a PostgreSQL Schema and Live Data with MOLT (90 min)

## Learning Objectives

By the end of this lab you will be able to:

- Convert a PostgreSQL schema to CockroachDB and fix every incompatibility it surfaces
- **Redesign primary keys during the migration** — the one chance you get to fix distribution for free
- Move bulk data with `MOLT Fetch` and verify it with `MOLT Verify`
- Run a dual-write / shadow-read cutover and know the rollback point at each step
- Compare query plans on both sides and catch the queries that regress
- Decide when *not* to migrate

## Prerequisites

- **Docker Desktop** (or Docker Engine) running — there is no `cockroach` binary to install
- Docker (for PostgreSQL source)
- `psql` client
- MOLT tools — download from <https://www.cockroachlabs.com/docs/molt/molt-fetch> (a
  pure-SQL fallback path is given if the binaries are unavailable)

## Setup

### 1. Source PostgreSQL

```bash
mkdir -p /tmp/lab15 && cd /tmp/lab15

docker run -d --name lab15-pg -p 5432:5432 \
  -e POSTGRES_PASSWORD=pg -e POSTGRES_DB=legacy \
  postgres:16 -c wal_level=logical

sleep 8
export PG='postgresql://postgres:pg@localhost:5432/legacy'
```

### 2. A realistically bad legacy schema

```bash
psql "$PG" <<'SQL'
CREATE TABLE customers (
  id           SERIAL PRIMARY KEY,               -- sequential PK: hotspot waiting to happen
  email        VARCHAR(255) NOT NULL UNIQUE,
  name         VARCHAR(255) NOT NULL,
  tenant_id    INTEGER NOT NULL,
  created_at   TIMESTAMP DEFAULT now()
);

CREATE TABLE orders (
  id           SERIAL PRIMARY KEY,
  customer_id  INTEGER NOT NULL REFERENCES customers(id),
  tenant_id    INTEGER NOT NULL,
  total        NUMERIC(12,2) NOT NULL,
  status       VARCHAR(32) NOT NULL DEFAULT 'new',
  metadata     JSON,
  created_at   TIMESTAMP DEFAULT now()
);

CREATE TABLE order_events (
  id           BIGSERIAL PRIMARY KEY,            -- append-only, monotonic: the worst case
  order_id     INTEGER NOT NULL REFERENCES orders(id),
  event_type   VARCHAR(64) NOT NULL,
  occurred_at  TIMESTAMP DEFAULT now()
);

CREATE INDEX idx_orders_status  ON orders(status);          -- low cardinality
CREATE INDEX idx_orders_created ON orders(created_at);
CREATE INDEX idx_events_order   ON order_events(order_id);

-- A stored procedure and a trigger: neither survives the migration as-is
CREATE OR REPLACE FUNCTION touch_order() RETURNS TRIGGER AS $$
BEGIN NEW.created_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_touch BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION touch_order();

INSERT INTO customers (email, name, tenant_id)
SELECT 'user' || g || '@example.com', 'User ' || g, (g % 20) + 1
FROM generate_series(1, 20000) g;

INSERT INTO orders (customer_id, tenant_id, total, status, metadata)
SELECT (random()*19999)::int + 1, (g % 20) + 1, (random()*500)::numeric(12,2),
       (ARRAY['new','paid','shipped','cancelled'])[1 + (g % 4)],
       ('{"src":"web","seq":' || g || '}')::json
FROM generate_series(1, 100000) g;

INSERT INTO order_events (order_id, event_type)
SELECT (random()*99999)::int + 1, (ARRAY['created','paid','shipped'])[1 + (g % 3)]
FROM generate_series(1, 200000) g;
SQL

psql "$PG" -c "SELECT count(*) FROM customers; SELECT count(*) FROM orders; SELECT count(*) FROM order_events;"
```

### 3. Target CockroachDB

```bash
scripts/crdb up
export CRDB='postgresql://root@localhost:26257/target?sslmode=disable'
```

> The cluster runs in Docker (see [Lab 1](lab01_cluster_bootstrap.md)).
> From your machine it is `localhost:26257`; from inside another container it is
> `crdb1:26257`. `scripts/crdb run ...` executes inside node 1.

## Tasks

### Part A: Dialect Differences — What Actually Breaks (15 min)

1. **Dump the source schema and try it verbatim:**
   ```bash
   pg_dump "$PG" --schema-only --no-owner --no-privileges > /tmp/lab15/schema.sql
   scripts/crdb sql -f /tmp/lab15/schema.sql 2>&1 | tee /tmp/lab15/errors.log
   grep -i error /tmp/lab15/errors.log | head -20
   ```

2. **The cheat sheet.** Every row here is something you will hit:

   | PostgreSQL | CockroachDB | Action |
   | --- | --- | --- |
   | `SERIAL` / `BIGSERIAL` | Works, but means `unique_rowid()` | **Change to `UUID DEFAULT gen_random_uuid()`** |
   | Sequences (`nextval`) | Supported but serialize on one range | Avoid on hot paths; use UUID |
   | `plpgsql` triggers | Not supported | Move to application code or a UDF where possible |
   | Stored procedures | UDFs only (`CREATE FUNCTION`) | Rewrite |
   | `JSON` | Stored as `JSONB` | Fine — inverted-index it if you query into it |
   | `VARCHAR(n)` | Supported; `STRING` is idiomatic | Cosmetic |
   | `TIMESTAMP` | Prefer `TIMESTAMPTZ` | **Change** — timezone bugs are forever |
   | `text` search (`tsvector`) | Full-text search differs | Re-test |
   | PostGIS extension | Spatial is built in, syntax mostly compatible | Re-test |
   | `SELECT ... FOR UPDATE` | Supported | Behaviour differs under SERIALIZABLE |
   | Foreign keys | Supported; each FK check is a distributed read | Audit hot-path FKs |
   | `ON DELETE CASCADE` | Supported | Cascades can be surprisingly expensive |
   | Materialized views | Supported, manual refresh | Re-test refresh cost |
   | Table inheritance | Not supported | Redesign |
   | `pg_*` extensions | Not supported | Find built-in equivalent |

3. **Ask the source what it uses** — do this before you promise a timeline:
   ```bash
   psql "$PG" -c "SELECT count(*) FROM information_schema.triggers;"
   psql "$PG" -c "SELECT proname, prolang::regtype FROM pg_proc WHERE pronamespace = 'public'::regnamespace;"
   psql "$PG" -c "SELECT extname FROM pg_extension;"
   psql "$PG" -c "SELECT sequencename FROM pg_sequences;"
   ```

### Part B: Redesign the Schema for Distribution (20 min)

**This is the highest-value 20 minutes of the migration.** Changing a primary key after
cutover means another migration; changing it now costs nothing.

1. **Score the legacy schema against the Playbook:**

   | Legacy design | Problem | Playbook fix |
   | --- | --- | --- |
   | `customers.id SERIAL` | Rightmost-range write hotspot | UUID PK, or `(tenant_id, id)` |
   | `orders.id SERIAL` | Same, plus tenant queries scan everywhere | **#3 Per-Tenant Co-located PK** |
   | `order_events.id BIGSERIAL` | Pure append at max rate — worst case | **#1 Hash-Sharded Time-Series PK** |
   | `idx_orders_status` | Low-cardinality index, rarely selective | **#6 Hot/Cold partial index** |
   | Nothing ages out `order_events` | Unbounded growth | **#9 TTL table** |

2. **Write the target schema:**
   ```sql
   USE target;

   CREATE TABLE customers (
     id          UUID NOT NULL DEFAULT gen_random_uuid(),
     tenant_id   INT NOT NULL,
     email       STRING NOT NULL,
     name        STRING NOT NULL,
     created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
     legacy_id   INT NOT NULL,                    -- keep the old key for the cutover
     PRIMARY KEY (tenant_id, id),                 -- Playbook #3
     UNIQUE INDEX customers_email_key (email),
     UNIQUE INDEX customers_legacy_id_key (legacy_id)
   );

   CREATE TABLE orders (
     id           UUID NOT NULL DEFAULT gen_random_uuid(),
     tenant_id    INT NOT NULL,
     customer_id  UUID NOT NULL,
     total        DECIMAL(12,2) NOT NULL,
     status       STRING NOT NULL DEFAULT 'new',
     metadata     JSONB,
     created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
     legacy_id    INT NOT NULL,
     PRIMARY KEY (tenant_id, id),                 -- Playbook #3
     UNIQUE INDEX orders_legacy_id_key (legacy_id),
     INDEX orders_customer_idx (tenant_id, customer_id),
     -- Playbook #6: only "open" orders are queried by status
     INDEX orders_open_idx (tenant_id, created_at DESC)
       STORING (total, customer_id) WHERE status IN ('new', 'paid')
   );

   CREATE TABLE order_events (
     order_id    UUID NOT NULL,
     occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
     id          UUID NOT NULL DEFAULT gen_random_uuid(),
     event_type  STRING NOT NULL,
     legacy_id   INT NOT NULL,
     -- Playbook #1: hash-shard the time-ordered append stream
     PRIMARY KEY (order_id, occurred_at, id) USING HASH WITH (bucket_count = 16)
   ) WITH (ttl_expire_after = '180 days', ttl_job_cron = '@daily');   -- Playbook #9
   ```

   > **Note what is missing:** no foreign keys yet. FK validation during a bulk load is
   > expensive and serializing. Load first, add constraints after — see Part C step 5.
   >
   > **Note `legacy_id`:** during dual-write and shadow-read you must be able to match a row
   > on both sides. Keep the old key until cutover is complete, then drop the column.

3. **Predict the improvement before you measure it.** Which of these is now cheaper, and why?
   ```sql
   -- Q1: all of one tenant's orders
   SELECT * FROM orders WHERE tenant_id = 7 ORDER BY created_at DESC LIMIT 50;

   -- Q2: one order's event history
   SELECT * FROM order_events WHERE order_id = '...' ORDER BY occurred_at DESC;

   -- Q3: open orders across all tenants
   SELECT count(*) FROM orders WHERE status = 'new';
   ```
   Q1 and Q2 get faster (co-located, index-covered). Q3 gets *slower* — it now fans out across
   every tenant's ranges. If Q3 is a hot query, `(status, tenant_id)` deserves its own index —
   **but check whether the query is actually needed** before adding write amplification for it.

### Part C: Move the Data with MOLT Fetch (20 min)

1. **With MOLT Fetch:**
   ```bash
   molt fetch \
     --source "$PG" \
     --target "$CRDB" \
     --table-filter 'customers|orders|order_events' \
     --bucket-path '/tmp/lab15/fetch' \
     --cleanup \
     --direct-copy
   ```

   | Flag | Purpose |
   | --- | --- |
   | `--direct-copy` | Stream via `COPY`, no intermediate object store |
   | `--bucket-path` / `--s3-bucket` | Stage as CSV for `IMPORT INTO` (faster for large data) |
   | `--mode data-load-and-replication` | Bulk load, then stay in sync via logical replication |
   | `--table-filter` | Regex of tables to move |
   | `--cleanup` | Remove intermediate files when done |

2. **Without MOLT (the portable path).** Because the primary keys changed, this is a
   *transformation*, not a copy — which is exactly why we kept `legacy_id`:
   ```bash
   psql "$PG" -c "\copy (SELECT id, tenant_id, email, name, created_at FROM customers) TO '/tmp/lab15/customers.csv' CSV"
   psql "$PG" -c "\copy (SELECT id, customer_id, tenant_id, total, status, metadata::text, created_at FROM orders) TO '/tmp/lab15/orders.csv' CSV"
   psql "$PG" -c "\copy (SELECT id, order_id, event_type, occurred_at FROM order_events) TO '/tmp/lab15/order_events.csv' CSV"
   ```
   ```bash
   scripts/crdb sql <<'SQL'
   CREATE TABLE stage_customers (legacy_id INT PRIMARY KEY, tenant_id INT, email STRING, name STRING, created_at TIMESTAMPTZ);
   CREATE TABLE stage_orders (legacy_id INT PRIMARY KEY, customer_legacy INT, tenant_id INT, total DECIMAL(12,2), status STRING, metadata JSONB, created_at TIMESTAMPTZ);
   CREATE TABLE stage_events (legacy_id INT PRIMARY KEY, order_legacy INT, event_type STRING, occurred_at TIMESTAMPTZ);
   SQL

   # The CSVs are on your machine; the node is in a container and cannot see
   # them. Copy each one in, then stage it in the cluster's userfile store.
   for t in customers orders events; do
     scripts/crdb cp /tmp/lab15/${t/events/order_events}.csv crdb1:/tmp/$t.csv
     scripts/crdb run userfile upload /tmp/$t.csv /lab15/$t.csv --insecure
   done

   scripts/crdb sql <<'SQL'
   IMPORT INTO stage_customers CSV DATA ('userfile:///lab15/customers.csv');
   IMPORT INTO stage_orders    CSV DATA ('userfile:///lab15/orders.csv');
   IMPORT INTO stage_events    CSV DATA ('userfile:///lab15/events.csv');
   SQL
   ```

3. **Transform staging into the new key space:**
   ```sql
   INSERT INTO customers (tenant_id, email, name, created_at, legacy_id)
   SELECT tenant_id, email, name, created_at, legacy_id FROM stage_customers;

   INSERT INTO orders (tenant_id, customer_id, total, status, metadata, created_at, legacy_id)
   SELECT s.tenant_id, c.id, s.total, s.status, s.metadata, s.created_at, s.legacy_id
   FROM stage_orders s JOIN customers c ON c.legacy_id = s.customer_legacy;

   INSERT INTO order_events (order_id, occurred_at, event_type, legacy_id)
   SELECT o.id, s.occurred_at, s.event_type, s.legacy_id
   FROM stage_events s JOIN orders o ON o.legacy_id = s.order_legacy;
   ```

4. **Verify with MOLT Verify** — row counts *and* column-by-column comparison:
   ```bash
   molt verify --source "$PG" --target "$CRDB" --table-filter 'customers|orders|order_events'
   ```
   Portable fallback:
   ```bash
   for t in customers orders order_events; do
     echo -n "$t  pg="; psql "$PG" -tAc "SELECT count(*) FROM $t"
     echo -n "    crdb="; cockroach sql --insecure --url "$CRDB" --format=tsv -e "SELECT count(*) FROM $t" | tail -1
   done

   # Business checksum, not just a row count
   psql "$PG" -tAc "SELECT sum(total)::numeric(20,2) FROM orders"
   scripts/crdb sql --format=tsv -e "SELECT sum(total)::DECIMAL(20,2) FROM orders" | tail -1
   ```

5. **Add constraints after the load, not before:**
   ```sql
   ALTER TABLE orders ADD CONSTRAINT orders_customer_fk
     FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id);

   SELECT job_id, description, status FROM [SHOW JOBS]
   WHERE job_type IN ('SCHEMA CHANGE', 'NEW SCHEMA CHANGE') ORDER BY created DESC LIMIT 3;

   DROP TABLE stage_customers, stage_orders, stage_events;
   ```
   Time this step. FK validation is a full scan of both tables — on a real dataset it is a
   scheduled maintenance item, not an afterthought.

### Part D: Compare Plans — Catch the Regressions (15 min)

Migrations regress queries. Find out which ones before your users do.

1. **Same query, both engines:**
   ```bash
   psql "$PG" -c "EXPLAIN ANALYZE SELECT * FROM orders WHERE tenant_id = 7 ORDER BY created_at DESC LIMIT 50;"
   scripts/crdb sql -e "EXPLAIN ANALYZE SELECT * FROM orders WHERE tenant_id = 7 ORDER BY created_at DESC LIMIT 50;"
   ```

2. **Run the comparison across a query set:**

   | Query | PG time | CRDB time | CRDB rows read | Verdict |
   | --- | --- | --- | --- | --- |
   | Tenant order list | | | | |
   | Order event history | | | | |
   | Count by status (all tenants) | | | | |
   | Customer by email | | | | |
   | Join orders → customers | | | | |

3. **Statistics matter.** A freshly loaded table has no useful statistics until they're
   collected:
   ```sql
   SHOW STATISTICS FOR TABLE orders;
   CREATE STATISTICS orders_stats ON tenant_id, status, created_at FROM orders;
   --                ^^^^^^^^^^^^ the statistics name is required
   ```
   Re-run the plans. Several will change. **Always collect statistics before benchmarking a
   migration** — otherwise you are measuring the optimizer flying blind.

4. **The regressions to expect, and their fixes:**

   | Symptom | Cause | Fix |
   | --- | --- | --- |
   | Full scan where PG used an index | Missing/stale statistics, or index not carried over | `CREATE STATISTICS`, recreate index |
   | Slow multi-row `IN` lookup | Keys scattered across ranges | Reorder PK to co-locate |
   | Slow `COUNT(*)` on a big table | Distributed scan, no shortcut | `AS OF SYSTEM TIME` follower read, or maintain a counter |
   | Slow FK-heavy inserts | Each FK is a distributed read | Batch inserts; consider dropping non-critical FKs |
   | High p99 with fine p50 | Contention or cross-range transactions | Lab 5/Lab 8 techniques |

### Part E: Zero-Downtime Cutover (15 min)

The pattern, with the rollback point named at each step:

```
Phase 1  Schema in place on CRDB, PG live                     ← rollback: drop CRDB
Phase 2  Bulk load + continuous replication (MOLT Fetch)      ← rollback: stop replication
Phase 3  Dual write: app writes both, PG authoritative        ← rollback: stop CRDB writes
Phase 4  Shadow reads: read both, compare, serve PG           ← rollback: stop shadow reads
Phase 5  Flip: CRDB authoritative, PG still written           ← rollback: flip back (minutes)
Phase 6  Stop writing PG, decommission                        ← rollback: restore from backup
```

1. **Continuous replication (MOLT):**
   ```bash
   molt fetch --source "$PG" --target "$CRDB" \
     --mode data-load-and-replication \
     --table-filter 'customers|orders|order_events'
   ```

2. **Dual write, in application code:**
   ```python
   def create_order(pg_conn, crdb_conn, order):
       with pg_conn:                       # authoritative during phase 3
           pg_id = insert_pg(pg_conn, order)
       try:
           insert_crdb(crdb_conn, order, legacy_id=pg_id)
       except Exception as e:
           # NEVER fail the user request on the shadow write.
           metrics.increment("dual_write.crdb_failure")
           log.warning("crdb dual write failed: %s", e)
       return pg_id
   ```

3. **Shadow reads — compare, serve the authoritative one, alert on divergence:**
   ```python
   def get_order(pg_conn, crdb_conn, order_id):
       pg_row = read_pg(pg_conn, order_id)
       try:
           crdb_row = read_crdb(crdb_conn, order_id)
           if normalize(crdb_row) != normalize(pg_row):
               metrics.increment("shadow_read.divergence")
               log.warning("divergence on %s", order_id)
       except Exception:
           metrics.increment("shadow_read.error")
       return pg_row            # PG still serves the user
   ```

4. **The gate for flipping.** Do not flip on a schedule; flip on evidence:
   - [ ] Replication lag < 1 s sustained for 24 h
   - [ ] Shadow-read divergence rate = 0 over 24 h
   - [ ] Every query in the comparison table at or under its PG latency
   - [ ] A tested rollback path with a measured RTO (Lab 11)
   - [ ] Backups running on the target, with a restore drill completed

5. **After cutover:**
   ```sql
   ALTER TABLE customers    DROP COLUMN legacy_id;
   ALTER TABLE orders       DROP COLUMN legacy_id;
   ALTER TABLE order_events DROP COLUMN legacy_id;
   ```

### Part F: When NOT to Migrate (5 min)

Argue both sides for each. The honest answer is sometimes "stay on PostgreSQL".

| Workload | Migrate? | Why |
| --- | --- | --- |
| Single-region app, 50 GB, one PG instance is fine | | |
| Heavy analytical scans and window functions over the full dataset | | |
| Deep dependence on PostGIS-specific functions or extensions | | |
| Needs multi-region low-latency reads with strong consistency | | |
| Cannot tolerate a maintenance window for failover | | |
| Team of two with no distributed-systems experience | | |
| Write throughput exceeds one machine | | |

> The honest guidance: CockroachDB earns its complexity when you need **survivability**,
> **horizontal write scale**, or **data locality**. If you need none of those, PostgreSQL is
> simpler and you should keep it.

## Cleanup

```bash
docker rm -f lab15-pg
scripts/crdb down
```

## Lab 15 Deliverables

✅ **Dialect audit** of the source, with every incompatibility identified before migration
✅ **Redesigned schema** applying at least four Playbook patterns, with `legacy_id` for cutover
✅ **Data moved** and verified by row count *and* business checksum
✅ **Constraints added post-load**, with the validation cost measured
✅ **Plan comparison** across a query set, with regressions found and fixed
✅ **Cutover plan** with a named rollback point at every phase and an evidence-based flip gate
✅ **A defended "don't migrate" case**

## Challenge Exercises

1. **Trigger replacement.** The source has a `BEFORE INSERT` trigger. Implement the same
   behaviour three ways — column `DEFAULT`, a CockroachDB UDF, and application code — and
   argue for one.

2. **Migrate the sequence semantics.** Some downstream system depends on monotonically
   increasing order IDs. You just replaced them with UUIDs. Solve it without reintroducing
   the hotspot (hint: a per-tenant sequence, or a sortable UUID like ULID).

3. **Verify continuously.** Write a script that samples 1,000 random rows from both sides
   every minute during dual-write and reports divergence. What sampling rate gives you
   confidence at your data volume?

4. **Measure the FK tax.** Load `order_events` with and without the FK to `orders`.
   How much slower is the constrained load, and is the constraint worth it here?

## Reference

| Command | Purpose |
| --- | --- |
| `molt fetch --mode data-load-and-replication` | Bulk load, then stay in sync |
| `molt verify` | Row-by-row source/target comparison |
| `pg_dump --schema-only` | Extract the source schema |
| `IMPORT INTO ... CSV DATA (...)` | Fast bulk load into CockroachDB |
| `cockroach userfile upload` | Stage a file for `IMPORT` |
| `CREATE STATISTICS ON ... FROM t` | Collect stats before benchmarking |
| `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` | Add FKs after the load |
| `SHOW JOBS` | Watch validation and schema-change jobs |
