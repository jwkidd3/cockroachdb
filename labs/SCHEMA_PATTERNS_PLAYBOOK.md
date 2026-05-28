# Schema Patterns Playbook — Designs for High-Volume, Heavy-Throughput Workloads

A take-home reference. Every pattern lists its target workload, the canonical schema, the trap it avoids, and where it shows up in this course.

| # | Pattern | Where it's taught |
| --- | --- | --- |
| 1 | Hash-Sharded Time-Series PK | Lab 3 Part D, Lab 4 Part D |
| 2 | Append-Only Event Log | Lab 3 Part G |
| 3 | Per-Tenant Co-located PK | Lab 3 Part C |
| 4 | Time-Bucketed Composite PK | Lab 3 review |
| 5 | Sharded Counter | Lab 5 Part E |
| 6 | Hot/Cold Split via Partial Index | Lab 4 Part C |
| 7 | GLOBAL Reference Table | Lab 7 Part C |
| 8 | Outbox Pattern + CDC | Lab 3 Part H |
| 9 | TTL Table for Automatic Expiry | Lab 3 Part G |
| 10 | Pre-Split + Bulk Import | Lab 3 Part E |

The anti-pattern checklist at the bottom is what to flag in a code review.

---

## 1. Hash-Sharded Time-Series PK

**For:** write-heavy, timestamp-ordered data — events, metrics, audit logs.

```sql
CREATE TABLE events (
  account_id  UUID,
  created     TIMESTAMPTZ DEFAULT now(),
  payload     STRING,
  PRIMARY KEY (account_id, created) USING HASH WITH (bucket_count = 16)
);
```

CockroachDB prepends a hidden `crdb_internal_account_id_created_shard_16` column to the key — writes scatter across 16 ranges instead of pile-up on the rightmost one.

**Avoids:** rightmost-range write hotspot on monotonic keys.
**Watch:** `bucket_count` ≈ your concurrency. 16 is usually right; over 64 is rarely useful and slows range scans.

---

## 2. Append-Only Event Log

**For:** ingest-heavy logs that are never updated and aged out by time. Pair with TTL.

```sql
CREATE TABLE event_log (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ts       TIMESTAMPTZ DEFAULT now(),
  payload  JSONB
) WITH (ttl_expire_after = '30 days', ttl_job_cron = '@hourly');
```

UUID PK distributes writes; TTL job sweeps expired rows automatically.

**Avoids:** unbounded growth and the dreaded "DELETE-as-you-go" job that competes with live traffic.
**Watch:** the TTL job runs at the cron you set — too frequent and it adds load, too rare and you over-retain.

---

## 3. Per-Tenant Co-located PK

**For:** multi-tenant SaaS where most queries filter by tenant.

```sql
CREATE TABLE orders (
  tenant_id  UUID,
  order_id   UUID DEFAULT gen_random_uuid(),
  status     STRING,
  total      DECIMAL(12,2),
  PRIMARY KEY (tenant_id, order_id)
);
```

A single tenant's data lives in a contiguous key range — queries by `tenant_id` become single-range scans. Sets up cleanly for `REGIONAL BY ROW` later.

**Avoids:** cross-range scans for single-tenant queries.
**Watch:** one hot tenant becomes one hot range. Layer hash sharding on top if you have outliers (see #1).

---

## 4. Time-Bucketed Composite PK

**For:** per-tenant time-range queries that need ordering.

```sql
CREATE TABLE metrics (
  tenant_id    UUID,
  hour_bucket  TIMESTAMPTZ,           -- truncated to the hour
  metric_id    UUID DEFAULT gen_random_uuid(),
  value        DECIMAL,
  PRIMARY KEY (tenant_id, hour_bucket, metric_id)
);

-- Insert:
INSERT INTO metrics (tenant_id, hour_bucket, value)
VALUES ('...', date_trunc('hour', now()), 42.0);
```

The bucket column lets the optimizer prune to one hour's worth of keys without an extra index.

**Avoids:** unbounded range scans; sequential keys without coarser-grained pruning.

---

## 5. Sharded Counter

**For:** very-high-frequency counters (page views, likes, gauges).

```sql
CREATE TABLE counter_shards (
  name   STRING,
  shard  INT,
  n      INT DEFAULT 0,
  PRIMARY KEY (name, shard)
);

-- Pre-create shards
INSERT INTO counter_shards (name, shard)
SELECT 'page_views', g FROM generate_series(0, 15) g;

-- Increment: random shard pick
UPDATE counter_shards SET n = n + 1
WHERE name = 'page_views' AND shard = (random()*16)::INT;

-- Read: sum across shards
SELECT sum(n) FROM counter_shards WHERE name = 'page_views';
```

**Avoids:** SQLSTATE 40001 retry storms on a single-row counter.
**Watch:** reads are now O(shards). Don't shard a low-frequency counter — pay the read cost for nothing.

---

## 6. Hot/Cold Split via Partial Index

**For:** big table where 99% of queries hit a small recent or active slice.

```sql
CREATE INDEX orders_open
  ON orders(total DESC)
  STORING (customer_id)
  WHERE status = 'open';
```

The partial index holds only "open" rows — sorted by `total`, with the columns the hot query needs. Updates that change `status` away from `open` remove the row from the index in the same transaction.

**Avoids:** wasting index space on rows that are never queried; slow `ORDER BY` over the whole table.

---

## 7. GLOBAL Reference Table

**For:** small read-anywhere lookup data — country codes, currencies, feature flags.

```sql
CREATE TABLE country_codes (
  code  STRING(2) PRIMARY KEY,
  name  STRING NOT NULL
) LOCALITY GLOBAL;
```

Non-blocking transactions make this look like it has a leaseholder in every region — reads are fast everywhere.

**Avoids:** cross-region reads on hot lookup paths.
**Watch:** writes are slow (cross-region clock skew waits). Don't `LOCALITY GLOBAL` a write-heavy table.

---

## 8. Outbox Pattern + CDC

**For:** publishing events atomically with business writes. Replaces "write to DB and Kafka from app code" which can dual-write inconsistently.

```sql
-- Same transaction as the business write:
BEGIN;
INSERT INTO orders (...) VALUES (...);
INSERT INTO events_outbox (topic, payload)
  VALUES ('orders.created', jsonb_build_object('id', $1, ...));
COMMIT;

-- One-time setup:
CREATE TABLE events_outbox (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic    STRING NOT NULL,
  payload  JSONB,
  created  TIMESTAMPTZ DEFAULT now()
) WITH (ttl_expire_after = '7 days');

CREATE CHANGEFEED FOR TABLE events_outbox
  INTO 'kafka://...'
  WITH updated, resolved = '10s';
```

**Avoids:** the dual-write inconsistency where you write to the DB, the process dies, and Kafka never gets the event (or vice versa).
**Watch:** events are at-least-once. Downstream consumers must be idempotent.

---

## 9. TTL Table for Automatic Expiry

**For:** rows with a natural expiration — sessions, tokens, soft locks, short-lived caches.

```sql
-- TTL by static duration:
CREATE TABLE sessions (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id  UUID,
  data     JSONB
) WITH (ttl_expire_after = '24 hours', ttl_job_cron = '@hourly');

-- TTL driven by a per-row expression:
CREATE TABLE access_tokens (
  id       UUID PRIMARY KEY,
  expires  TIMESTAMPTZ
) WITH (ttl_expiration_expression = 'expires', ttl_job_cron = '*/10 * * * *');
```

Background TTL job sweeps expired rows on schedule.

**Avoids:** application-managed cleanup; `DELETE FROM ... WHERE created < now() - INTERVAL ...` that competes with live traffic.
**Watch:** the TTL job is a job — visible in `[SHOW JOBS]`, pausable, monitorable. Tune `ttl_job_cron` to your retention SLO.

---

## 10. Pre-Split + Bulk Import

**For:** one-time loads of sequential-key data — analytics imports, archive restores, migrations.

```sql
ALTER TABLE big_import SPLIT AT
  VALUES (100000), (200000), (300000), (400000), (500000),
         (600000), (700000), (800000), (900000);

IMPORT INTO big_import (id, payload)
  CSV DATA ('s3://my-bucket/data.csv?...');
```

Splits the table into N empty ranges before the load — every range gets writes from the start.

**Avoids:** writing 100M rows into a single range and waiting for the splitter to catch up. The first hour of the load runs ~3× faster.

---

## Anti-Patterns to Spot in Code Review

| Pattern | Why it hurts | Replace with |
| --- | --- | --- |
| `id SERIAL PRIMARY KEY` on a high-volume table | Rightmost-range hotspot | UUID PK (#1) or hash-sharded composite (#1) |
| `UPDATE counters SET n = n + 1 WHERE id = '...'` | 40001 retry storm | Sharded Counter (#5) |
| Low-cardinality lead column in PK (`region`, `status`) | One range per value → severe hotspot | Reorder to put a high-cardinality column first |
| Indexes on every column "just in case" | Write amplification multiplies inserts | Audit with `crdb_internal.index_usage_statistics`; drop unused |
| `DELETE FROM logs WHERE created < ...` as a recurring job | Competes with live traffic, locks | TTL Table (#9) |
| Application code that writes to Kafka *and* the database | Dual-write inconsistency | Outbox Pattern + CDC (#8) |
| Reading then writing without `BEGIN ... COMMIT` | No atomicity guarantees | Wrap in an explicit transaction |
| `SELECT *` everywhere | Forces PK lookup; defeats covering indexes | List columns; add `STORING` for hot paths |
| One big bulk load into an un-split table | Initial single-range write storm | Pre-Split + Bulk Import (#10) |
| `LOCALITY GLOBAL` on a write-heavy table | Cross-region clock-skew waits on every commit | Use `REGIONAL BY ROW` or `REGIONAL BY TABLE IN` instead |

---

## A Quick Decision Tree

When designing a new table, ask in this order:

1. **What's the write pattern?**
   - One-shot bulk import → Pattern #10 (Pre-Split + IMPORT INTO)
   - Steady high-throughput inserts, timestamp-ordered → #1 (Hash-Sharded Time-Series PK)
   - Many writes per tenant, mostly read by tenant → #3 (Per-Tenant Co-located PK)
   - Bursts to a single row (counter, gauge) → #5 (Sharded Counter)
   - Application produces events for downstream → #8 (Outbox + CDC)

2. **What's the lifecycle?**
   - Rows expire naturally → #9 (TTL Table)
   - Append-only logs → #2 (Append-Only Event Log = #9 + UUID PK)
   - Long-lived but rarely-updated reference data → #7 (GLOBAL) if multi-region

3. **What's the read pattern?**
   - Most queries hit a hot subset → #6 (Hot/Cold Split via Partial Index)
   - Time-range queries per tenant → #4 (Time-Bucketed Composite PK)
   - Read from every region → #7 (GLOBAL) for small tables; per-row regional for large

Mix and match — production schemas usually combine 2-4 of these patterns. The anti-pattern checklist catches the rest.
