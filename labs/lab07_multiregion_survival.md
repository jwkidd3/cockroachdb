# Lab 7: Multi-Region Topologies & Survival Goals (75 min)

## Learning Objectives

By the end of this lab you will be able to:

- Spin up a simulated 3-region, 9-node CockroachDB cluster with `cockroach demo --global` (or a real multi-node start with localities)
- Toggle survival between `ZONE FAILURE` and `REGION FAILURE` and measure write latency
- Convert tables to `REGIONAL BY TABLE`, `REGIONAL BY ROW`, and `GLOBAL` and observe per-region read latency
- Take a region offline and confirm the cluster keeps serving
- Use `crdb_internal.zones` and `SHOW RANGES WITH DETAILS` to audit replica placement
- Choose the right locality for a given access pattern via a decision tree

## Prerequisites

- `cockroach` binary on `PATH`
- Enough RAM to run 9 in-memory nodes (~6 GB)
- Lab 5 / 6 not required, but Lab 1's concepts assumed

## Setup

```bash
cockroach demo --global --nodes 9 --no-example-database --empty
```

You should see something like:

```text
node | region        | zone
   1 | us-east1      | us-east1-a
   2 | us-east1      | us-east1-b
   3 | us-east1      | us-east1-c
   4 | us-west1      | us-west1-a
   5 | us-west1      | us-west1-b
   6 | us-west1      | us-west1-c
   7 | europe-west1  | europe-west1-a
   8 | europe-west1  | europe-west1-b
   9 | europe-west1  | europe-west1-c
```

Confirm:

```sql
SELECT node_id, locality FROM crdb_internal.gossip_nodes ORDER BY node_id;
```

The `--global` flag also injects simulated inter-region latency (~80–100ms RTT) so the locality benefits are observable.

## Tasks

### Part A: Pick a Survival Goal, Measure the Cost (15 min)

1. **Create a regional database and load the regions:**
   ```sql
   CREATE DATABASE shop;
   USE shop;

   ALTER DATABASE shop SET PRIMARY REGION "us-east1";
   ALTER DATABASE shop ADD REGION "us-west1";
   ALTER DATABASE shop ADD REGION "europe-west1";

   SHOW REGIONS FROM DATABASE shop;
   ```

2. **Default survival is `ZONE FAILURE`:**
   ```sql
   SHOW SURVIVAL GOAL FROM DATABASE shop;
   ```

3. **Create a simple table and time some inserts:**
   ```sql
   CREATE TABLE products (
     id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     name   STRING NOT NULL,
     price  DECIMAL(10,2) NOT NULL
   );

   \timing on
   INSERT INTO products (name, price)
   SELECT 'item-' || g, (random()*100)::DECIMAL(10,2)
   FROM generate_series(1, 100) g;
   ```
   Replicas are within `us-east1`. Writes have low intra-region latency.

4. **Switch to `REGION FAILURE`:**
   ```sql
   ALTER DATABASE shop SURVIVE REGION FAILURE;
   ```
   Replication factor goes from 3 → 5, spread across all three regions.

5. **Re-run the inserts:**
   ```sql
   INSERT INTO products (name, price)
   SELECT 'item2-' || g, (random()*100)::DECIMAL(10,2)
   FROM generate_series(1, 100) g;
   ```
   Each insert is slower — cross-region RTT shows up in the commit path.

6. **Switch back to `ZONE FAILURE`** to keep the rest of the lab snappy:
   ```sql
   ALTER DATABASE shop SURVIVE ZONE FAILURE;
   ```

### Part B: REGIONAL BY ROW (15 min)

1. **Create a table with row-level locality:**
   ```sql
   CREATE TABLE customers (
     id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     email       STRING UNIQUE,
     name        STRING NOT NULL,
     region      crdb_internal_region NOT NULL
   ) LOCALITY REGIONAL BY ROW AS region;
   ```

2. **Insert customers in each region:**
   ```sql
   INSERT INTO customers (email, name, region) VALUES
     ('alice@us.example.com',   'Alice',   'us-east1'),
     ('bob@us.example.com',     'Bob',     'us-west1'),
     ('charlie@eu.example.com', 'Charlie', 'europe-west1'),
     ('dana@us.example.com',    'Dana',    'us-east1');
   ```

3. **Verify each row's range leaseholder is in its region:**
   ```sql
   SELECT email, region FROM customers ORDER BY email;
   SHOW RANGES FROM TABLE customers WITH DETAILS;
   ```
   Compare each range's `lease_holder_locality` to the row's region — they should match.

4. **Connect to a `us-east1` node and time a regional read:**
   ```text
   \demo connect 1
   ```
   ```sql
   \timing on
   SELECT name FROM customers WHERE email = 'alice@us.example.com';   -- local
   SELECT name FROM customers WHERE email = 'charlie@eu.example.com'; -- remote
   ```

5. **Connect to a European node and watch the pattern flip:**
   ```text
   \demo connect 7
   ```
   ```sql
   SELECT name FROM customers WHERE email = 'alice@us.example.com';   -- now remote
   SELECT name FROM customers WHERE email = 'charlie@eu.example.com'; -- now local
   ```

### Part C: GLOBAL Tables for Reference Data (10 min)

For lookup tables read everywhere but rarely written.

1. **Reconnect to node 1:**
   ```text
   \demo connect 1
   ```

2. **Create a GLOBAL table:**
   ```sql
   CREATE TABLE country_codes (
     code  STRING(2) PRIMARY KEY,
     name  STRING NOT NULL
   ) LOCALITY GLOBAL;

   INSERT INTO country_codes (code, name) VALUES
     ('US', 'United States'),
     ('CA', 'Canada'),
     ('DE', 'Germany'),
     ('FR', 'France'),
     ('GB', 'United Kingdom');
   ```

3. **Time the same read from three regions:**
   ```text
   \demo connect 1
   ```
   ```sql
   \timing on
   SELECT name FROM country_codes WHERE code = 'US';
   ```
   ```text
   \demo connect 4
   ```
   ```sql
   SELECT name FROM country_codes WHERE code = 'US';
   ```
   ```text
   \demo connect 7
   ```
   ```sql
   SELECT name FROM country_codes WHERE code = 'US';
   ```
   All three reads should be fast — GLOBAL tables read locally everywhere.

4. **But writes are slow:**
   ```sql
   \timing on
   UPDATE country_codes SET name = 'United States of America' WHERE code = 'US';
   ```
   GLOBAL writes have to wait for clocks to advance past a future timestamp — slower than REGIONAL writes.

### Part D: REGIONAL BY TABLE — Pinned to One Region (10 min)

Sometimes you want a small reference table to live entirely in one region (think: legal-residency requirements).

1. **Create a REGIONAL BY TABLE pinned to Europe:**
   ```sql
   CREATE TABLE eu_pricing_rules (
     id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     rule  STRING NOT NULL
   ) LOCALITY REGIONAL BY TABLE IN "europe-west1";

   INSERT INTO eu_pricing_rules (rule) VALUES
     ('VAT 19%'), ('VAT 20%'), ('VAT 21%');
   ```

2. **Compare access from regions:**
   ```text
   \demo connect 7
   ```
   ```sql
   \timing on
   SELECT * FROM eu_pricing_rules;            -- local in EU (fast)
   ```
   ```text
   \demo connect 1
   ```
   ```sql
   SELECT * FROM eu_pricing_rules;            -- remote (slow)
   ```

### Part E: Take a Region Offline (10 min)

Now the proof. With `SURVIVE REGION FAILURE` set, does the cluster keep serving when a region disappears?

1. **Set the database to `SURVIVE REGION FAILURE`** so it can actually:
   ```text
   \demo connect 1
   ```
   ```sql
   ALTER DATABASE shop SURVIVE REGION FAILURE;
   ```
   Wait ~30 s for re-replication.

2. **List europe nodes:**
   ```sql
   SELECT node_id FROM crdb_internal.gossip_nodes
   WHERE locality LIKE '%europe-west1%';
   ```

3. **Take all three EU nodes offline:**
   ```text
   \demo shutdown 7
   \demo shutdown 8
   \demo shutdown 9
   ```

4. **Verify the cluster is still serving** (reconnect to a survivor if needed):
   ```text
   \demo connect 1
   ```
   ```sql
   SELECT count(*) FROM customers;
   INSERT INTO customers (email, name, region)
     VALUES ('eve@us.example.com', 'Eve', 'us-east1');
   SELECT email, region FROM customers ORDER BY email;
   ```

5. **What about querying a European customer's row?**
   ```sql
   SELECT email, region FROM customers WHERE email = 'charlie@eu.example.com';
   ```
   With `SURVIVE REGION FAILURE`, the leaseholder has been promoted to a surviving region; reads succeed. Give it ~10s after the outage to fully transition.

6. **Bring Europe back:**
   ```text
   \demo restart 7
   \demo restart 8
   \demo restart 9
   ```
   In the DB Console's **Replication** dashboard, watch under-replicated ranges drop back to 0.

### Part F: Audit Replica Placement (5 min)

1. **For each REGIONAL BY ROW row, where do its replicas live?**
   ```sql
   SELECT
     range_id,
     start_pretty,
     lease_holder,
     replicas,
     lease_holder_locality,
     replica_localities
   FROM [SHOW RANGES FROM TABLE customers WITH DETAILS]
   ORDER BY start_pretty;
   ```

2. **Zone configs in the system catalog:**
   ```sql
   SHOW ZONE CONFIGURATIONS;
   ```
   Look for the entries CockroachDB created for your database and tables — they reflect the locality and survival goal you set.

3. **For the database overall:**
   ```sql
   SELECT * FROM crdb_internal.zones WHERE target = 'DATABASE shop';
   ```

### Part G: Decision Tree (10 min)

For each row, pick the locality and survival goal.

| Workload | Locality | Survival |
| --- | --- | --- |
| App-config table read from any region; rarely written | ? | ? |
| Per-tenant SaaS data; tenant has a home region | ? | ? |
| Audit log written by every region; never read | ? | ? |
| Compliance-pinned EU customer data | ? | ? |
| Reference tax rates updated weekly, read everywhere | ? | ? |
| Shopping-cart row that follows the user across regions (rare) | ? | ? |

> Defend each choice. Then build them out on this cluster and confirm via `SHOW RANGES`.

## Cleanup

```sql
DROP DATABASE shop CASCADE;
```

`\q`.

## Lab 7 Deliverables

✅ **Multi-region cluster** with 9 nodes across 3 regions
✅ **Survival goals tested**: measured the latency tradeoff ZONE vs REGION
✅ **Locality applied**: REGIONAL BY ROW, REGIONAL BY TABLE IN, GLOBAL verified via per-region reads
✅ **Region outage survived**: 3 of 9 nodes (one entire region) offline; cluster kept serving
✅ **Placement audited**: read replica localities from `SHOW RANGES` and `crdb_internal.zones`
✅ **Decision tree applied** to six concrete scenarios

## Challenge Exercises

1. **Design a ride-share dataset.** Trips happen in regions and should be read/written locally. Vehicles (~5k entries) are looked up from anywhere. Pricing rules (~50 entries) are updated weekly. What locality + survival do you pick? Build it; verify with `SHOW RANGES`.

2. **Measure GLOBAL write cost.** Time 100 sequential updates to your `country_codes` table. Compare against 100 inserts into a REGIONAL BY TABLE. The gap is your cost-of-globalness.

3. **A "wrong" choice." What happens if you set `LOCALITY GLOBAL` on a high-write table? Try with `orders` analogous to Lab 4. Predict, then verify, the throughput hit.

## Reference

| Locality | Best for | Read latency | Write latency |
| --- | --- | --- | --- |
| `REGIONAL BY TABLE IN x` | Region-pinned reference data | Fast in x, slow elsewhere | Fast in x |
| `REGIONAL BY ROW` | Per-row home region | Fast in that row's region | Fast in that row's region |
| `GLOBAL` | Read-anywhere, rarely-written | Fast everywhere | Cross-region (slow) |

| Survival | Replicas | Tolerates |
| --- | --- | --- |
| `ZONE FAILURE` (default) | 3 | Loss of 1 zone in primary region |
| `REGION FAILURE` | 5 | Loss of 1 entire region |
