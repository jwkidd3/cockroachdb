# Lab 13: CDC → Kafka → Downstream Consumer with a Resolved-Timestamp Frontier (75 min)

## Learning Objectives

By the end of this lab you will be able to:

- Run a Core changefeed and an Enterprise changefeed and explain when each is appropriate
- Emit to Kafka with `updated`, `resolved`, `diff`, and `key_in_value` options and read the envelopes
- Track the **resolved-timestamp frontier** in a consumer and know when data is safe to act on
- Build an **idempotent consumer** that survives at-least-once delivery and replays
- Measure changefeed lag with `changefeed_max_behind_nanos` and know what makes it grow
- Handle schema changes under an active changefeed without breaking downstream consumers
- Pause, resume, and restart a changefeed from a cursor after a downstream outage

## Prerequisites

- **Docker Desktop** (or Docker Engine) running — there is no `cockroach` binary to install
- Docker (for Kafka). A webhook-sink fallback with `nc` is provided if Docker is unavailable.
- `python3` for the consumer

## Setup

### 1. Kafka

```bash
mkdir -p /tmp/lab13 && cd /tmp/lab13

cat > docker-compose.yml <<'YML'
services:
  kafka:
    image: bitnami/kafka:3.7
    ports: ["9092:9092"]
    environment:
      KAFKA_CFG_NODE_ID: "0"
      KAFKA_CFG_PROCESS_ROLES: "controller,broker"
      KAFKA_CFG_LISTENERS: "PLAINTEXT://:9092,CONTROLLER://:9093"
      KAFKA_CFG_ADVERTISED_LISTENERS: "PLAINTEXT://localhost:9092"
      KAFKA_CFG_CONTROLLER_QUORUM_VOTERS: "0@kafka:9093"
      KAFKA_CFG_CONTROLLER_LISTENER_NAMES: "CONTROLLER"
      KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
      KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE: "true"
      ALLOW_PLAINTEXT_LISTENER: "yes"
YML

docker compose up -d
docker compose logs -f kafka | grep -m1 "Kafka Server started"
```

### 2. Cluster

```bash
scripts/crdb up
export C='postgresql://root@localhost:26257?sslmode=disable'
```

> The cluster runs in Docker (see [Lab 1](lab01_cluster_bootstrap.md)).
> From your machine it is `localhost:26257`; from inside another container it is
> `crdb1:26257`. `scripts/crdb run ...` executes inside node 1.

> **Enterprise changefeeds need a license.** `cockroach demo` provides one automatically;
> a local `cockroach start` cluster does not. If `CREATE CHANGEFEED ... INTO` is rejected,
> either set a trial license (`SET CLUSTER SETTING enterprise.license = '...'`) or run this
> lab against a containerised demo cluster
> (`docker run --rm -it cockroachdb/cockroach:v23.2.5 demo --nodes 3 --no-example-database --empty`)
> and adjust the connection URL. Part A (Core
> changefeeds) works on any cluster.

```bash
scripts/crdb sql <<'SQL'
SET CLUSTER SETTING kv.rangefeed.enabled = true;

CREATE DATABASE shop;
USE shop;

CREATE TABLE orders (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer  STRING NOT NULL,
  total     DECIMAL(12,2) NOT NULL,
  status    STRING NOT NULL DEFAULT 'new',
  updated   TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL
```

## Tasks

### Part A: Core Changefeed — the Zero-Infrastructure Version (8 min)

A Core changefeed streams straight to the SQL session. No sink, no license, no delivery
guarantees beyond "this session is connected".

1. **Terminal A:**
   ```bash
   scripts/crdb sql -e "EXPERIMENTAL CHANGEFEED FOR shop.orders WITH updated;"
   ```

2. **Terminal B:**
   ```bash
   scripts/crdb sql -e "
     INSERT INTO shop.orders (customer, total) VALUES ('alice', 42.00);
     UPDATE shop.orders SET status = 'paid' WHERE customer = 'alice';
     DELETE FROM shop.orders WHERE customer = 'alice';"
   ```

3. **Read the envelopes in terminal A.** Note that a delete emits `after: null` — a tombstone.

   > **If you redirect a core changefeed to a file or a pipe, you get nothing.** The default
   > `--format=table` buffers all output to compute column widths, so a stream that never ends
   > never prints. Use a streaming format when the output is not a terminal:
   > ```bash
   > stdbuf -oL cockroach sql --format=csv --url "$C" \
   >   -e "EXPERIMENTAL CHANGEFEED FOR shop.orders WITH updated;" > /tmp/cdc.csv
   > ```
   > **Both parts matter.** `--format=csv` avoids the column-sizing buffer, and `stdbuf -oL`
   > line-buffers stdout — without it, nothing reaches the file until the process exits, and a
   > changefeed never exits. (On macOS, `stdbuf` comes from `brew install coreutils` as
   > `gstdbuf`; in a terminal you don't need either.)
   > The `key` and `value` columns come back **hex-encoded** (`\x7b2261...`) because they are
   > `BYTES`. Decode them with:
   > ```bash
   > python3 -c "import csv,sys
   > for r in csv.reader(open('/tmp/cdc.csv')):
   >     for c in r:
   >         if c.startswith(r'\x'): print(bytes.fromhex(c[2:]).decode('utf-8','replace'))"
   > ```
   > This is a `cockroach sql` presentation detail, not a changefeed one — an Enterprise
   > changefeed to a real sink emits plain JSON.

   | Use Core when | Use Enterprise when |
   | --- | --- |
   | Ad-hoc debugging | Anything in production |
   | You need no durability | You need at-least-once delivery |
   | Single consumer, short-lived | Multiple consumers, restartable |

### Part B: Enterprise Changefeed to Kafka (12 min)

1. **Create the changefeed:**
   ```sql
   CREATE CHANGEFEED FOR TABLE shop.orders
     INTO 'kafka://localhost:9092'
     WITH updated, resolved = '10s', diff, key_in_value,
          min_checkpoint_frequency = '10s';
   ```
   Note the returned `job_id`.

2. **Confirm the topic exists:**
   ```bash
   docker compose exec kafka kafka-topics.sh --bootstrap-server localhost:9092 --list
   ```
   The topic is named after the table: `orders`.

3. **Generate changes:**
   ```bash
   scripts/crdb sql <<'SQL'
   USE shop;
   INSERT INTO orders (customer, total) SELECT 'cust-' || g, (g * 3.50)::DECIMAL(12,2)
   FROM generate_series(1, 20) g;
   UPDATE orders SET status = 'paid', updated = now() WHERE total > 40;
   DELETE FROM orders WHERE total < 10;
   SQL
   ```

4. **Consume raw:**
   ```bash
   docker compose exec kafka kafka-console-consumer.sh \
     --bootstrap-server localhost:9092 --topic orders --from-beginning --timeout-ms 15000
   ```

5. **Decode an envelope.** With `updated, diff, key_in_value` you get:
   ```json
   {
     "after":   {"id":"...","customer":"cust-3","total":10.50,"status":"paid","updated":"..."},
     "before":  {"id":"...","customer":"cust-3","total":10.50,"status":"new","updated":"..."},
     "key":     ["..."],
     "updated": "1716400000000000000.0000000000"
   }
   ```

   | Option | Adds | Costs |
   | --- | --- | --- |
   | `updated` | MVCC timestamp of the change | negligible |
   | `resolved = 'Ns'` | Periodic watermark messages | more messages |
   | `diff` | The `before` image | ~2× payload size |
   | `key_in_value` | Primary key inside the value | small |
   | `format = avro` | Avro + schema registry | needs a registry |
   | `envelope = 'wrapped'` (default) | before/after wrapper | — |

6. **Watch the job:**
   ```sql
   SELECT job_id, status, running_status, high_water_timestamp
   FROM [SHOW CHANGEFEED JOBS];
   ```
   `high_water_timestamp` is the frontier: every change with an MVCC timestamp at or below it
   has already been emitted.

### Part C: The Resolved-Timestamp Frontier (15 min)

This is the part everyone gets wrong. Changefeed messages arrive **out of order across ranges**.
A `resolved` message is the cluster telling you: *no further message will arrive with a
timestamp below this value*. Only then is a time window complete.

1. **Watch the resolved messages arrive:**
   ```bash
   docker compose exec kafka kafka-console-consumer.sh \
     --bootstrap-server localhost:9092 --topic orders --timeout-ms 40000 \
     | grep resolved
   ```

2. **Build a frontier-tracking consumer** — `/tmp/lab13/consumer.py`:
   ```python
   #!/usr/bin/env python3
   """Frontier-tracking, idempotent CDC consumer.

   Buffers rows until the resolved timestamp passes them, then applies them
   exactly once (keyed by primary key + MVCC timestamp).
   """
   import json, sys, subprocess
   from collections import defaultdict

   frontier = "0"          # highest resolved timestamp seen
   pending  = []           # (updated_ts, key, payload) not yet final
   applied  = {}           # key -> last applied timestamp (idempotency ledger)

   def apply(key, ts, payload):
       # At-least-once delivery means we WILL see duplicates and replays.
       # Applying only when ts > last-applied makes the consumer idempotent.
       if key in applied and ts <= applied[key]:
           print(f"  skip duplicate  {key} @ {ts}")
           return
       applied[key] = ts
       action = "DELETE" if payload.get("after") is None else "UPSERT"
       print(f"  {action:6} {key} @ {ts}")

   def handle(line):
       global frontier
       try:
           msg = json.loads(line)
       except json.JSONDecodeError:
           return
       if "resolved" in msg:
           frontier = msg["resolved"]
           ready = [p for p in pending if p[0] <= frontier]
           for ts, key, payload in sorted(ready):
               apply(key, ts, payload)
           pending[:] = [p for p in pending if p[0] > frontier]
           print(f"FRONTIER advanced to {frontier} "
                 f"({len(ready)} applied, {len(pending)} still pending)")
           return
       key = json.dumps(msg.get("key"))
       ts  = msg.get("updated", "0")
       pending.append((ts, key, msg))

   for line in sys.stdin:
       handle(line.strip())
   ```

3. **Run it against the live topic:**
   ```bash
   docker compose exec -T kafka kafka-console-consumer.sh \
     --bootstrap-server localhost:9092 --topic orders --from-beginning --timeout-ms 60000 \
     | python3 /tmp/lab13/consumer.py
   ```

4. **In another terminal, make changes and watch the frontier advance:**
   ```bash
   scripts/crdb sql -e "
     USE shop;
     INSERT INTO orders (customer, total) VALUES ('frontier-test', 99.99);
     UPDATE orders SET status='shipped' WHERE customer='frontier-test';"
   ```
   The rows sit in `pending` until the next `resolved` message, then apply in timestamp order.

5. **The three questions the frontier answers:**

   | Question | Answer |
   | --- | --- |
   | "Is my materialized view up to date as of 14:00?" | Yes, iff frontier ≥ 14:00 |
   | "Can I close the books for yesterday?" | Yes, iff frontier ≥ midnight |
   | "Did I miss any events during the outage?" | No, iff you restart from the last frontier |

6. **Tune the trade-off.** Lower `resolved` interval = fresher frontier = more messages:
   ```sql
   -- Recreate with a 1-second frontier and compare message volume
   CREATE CHANGEFEED FOR TABLE shop.orders INTO 'kafka://localhost:9092?topic_prefix=fast_'
     WITH updated, resolved = '1s';
   ```

### Part D: Idempotency and Replay (10 min)

Changefeeds guarantee **at-least-once** delivery, not exactly-once. Duplicates are normal:
after a job restart, a lease transfer, or a rebalance, messages are re-emitted.

1. **Force a replay** — restart the changefeed from an earlier cursor:
   ```sql
   SELECT job_id, high_water_timestamp FROM [SHOW CHANGEFEED JOBS];
   PAUSE JOB <job_id>;
   ```
   ```sql
   CREATE CHANGEFEED FOR TABLE shop.orders
     INTO 'kafka://localhost:9092?topic_prefix=replay_'
     WITH updated, resolved = '10s', cursor = '<a timestamp from 5 minutes ago>';
   ```

2. **Run the consumer against the replay topic** and confirm your `applied` ledger skips
   the duplicates it already has.

3. **The three ways to be idempotent downstream:**

   | Technique | How | Best for |
   | --- | --- | --- |
   | Upsert by primary key | `INSERT ... ON CONFLICT DO UPDATE` | Materialized copies |
   | Timestamp guard | Apply only if `updated > last_seen` | Out-of-order safety |
   | Dedup ledger | Store `(key, ts)` seen-set with TTL | Side effects (emails, charges) |

   > For side effects, the ledger is the only safe option — you cannot "re-send" an email
   > idempotently by upserting a row.

4. **Verify no data was lost.** Compare the source with what your consumer applied:
   ```sql
   SELECT count(*) FROM shop.orders;
   ```
   Against the consumer's `applied` map size, minus the deletes.

### Part E: Schema Changes Under an Active Changefeed (10 min)

1. **With the changefeed running, add a column:**
   ```sql
   ALTER TABLE shop.orders ADD COLUMN shipped_at TIMESTAMPTZ;
   INSERT INTO shop.orders (customer, total, shipped_at) VALUES ('post-alter', 12.00, now());
   ```

2. **Watch the consumer.** The envelope now carries the new field. A consumer that parses
   strictly (fixed field list) breaks; one that reads by name survives.

3. **Control the behaviour explicitly:**
   ```sql
   CREATE CHANGEFEED FOR TABLE shop.orders INTO 'kafka://localhost:9092?topic_prefix=strict_'
     WITH updated, resolved='10s', schema_change_policy = 'stop';
   ```

   | `schema_change_policy` | Behaviour |
   | --- | --- |
   | `backfill` (default) | Emit a full backfill of the table after the change |
   | `nobackfill` | Continue without re-emitting existing rows |
   | `stop` | Fail the job so a human decides |

4. **The rule for downstream contracts:** additive changes (new nullable column) are safe;
   renames and type changes are not. Version your consumer's schema handling the same way
   you'd version an API.

### Part F: Lag, Failure & Recovery (10 min)

1. **Measure lag:**
   ```sql
   -- high_water_timestamp is an HLC DECIMAL; hlc_to_timestamp() converts it.
   -- (A direct ::DECIMAL::TIMESTAMPTZ cast is rejected: 'invalid cast'.)
   SELECT job_id,
          (now() - hlc_to_timestamp(high_water_timestamp)) AS lag
   FROM [SHOW CHANGEFEED JOBS] WHERE status = 'running';
   ```
   ```bash
   curl -s http://localhost:8080/_status/vars | grep changefeed_max_behind_nanos
   ```

2. **Kill the sink and watch the job react:**
   ```bash
   docker compose stop kafka
   ```
   ```sql
   SELECT job_id, status, running_status FROM [SHOW CHANGEFEED JOBS];
   ```
   The job retries; it does not silently drop events. `protected timestamps` keep the
   underlying MVCC data from being garbage-collected while the feed is behind.

3. **Bring the sink back:**
   ```bash
   docker compose start kafka
   ```
   ```sql
   SELECT job_id, status, high_water_timestamp FROM [SHOW CHANGEFEED JOBS];
   ```
   The frontier resumes from where it stopped. Nothing was lost.

   > **The hidden cost:** while a changefeed is paused or behind, its protected timestamp
   > prevents GC of old MVCC versions. A changefeed left paused for days grows your storage
   > and slows scans. `SHOW JOBS` is where you find the paused feed nobody remembered.

4. **Cancel cleanly:**
   ```sql
   CANCEL JOB <job_id>;
   SELECT job_id, status FROM [SHOW CHANGEFEED JOBS];
   ```

## Cleanup

```bash
cd lab13 && docker compose down -v && cd ..
scripts/crdb down
```

## Lab 13 Deliverables

✅ **Core and Enterprise changefeeds** both run, with a stated rule for when to use each
✅ **Kafka sink** with `updated`, `resolved`, `diff`, `key_in_value` and the envelopes decoded
✅ **Frontier consumer** that buffers until resolved and applies in timestamp order
✅ **Idempotency** proven by replaying from an earlier cursor
✅ **Schema change** handled under an active feed, with the policy options understood
✅ **Failure drill**: sink killed and restored with no data loss, lag measured

## Challenge Exercises

1. **Avro + schema registry.** Add Confluent Schema Registry to the compose file and re-create
   the changefeed with `format = avro, confluent_schema_registry = '...'`. What does the
   consumer gain?

2. **Fan out by tenant.** Use `WITH topic_in_value` and a changefeed on a `REGIONAL BY ROW`
   table. Can you route each region's events to a different topic?

3. **Exactly-once, end to end.** Combine the dedup ledger with Kafka transactions in your
   consumer. Where is the remaining window in which a duplicate side effect could occur?

4. **Alert on lag.** Add a Prometheus alert (Lab 9) on `changefeed_max_behind_nanos > 60e9`
   and prove it fires by pausing the job.

## Reference

| Command | Purpose |
| --- | --- |
| `EXPERIMENTAL CHANGEFEED FOR t` | Core changefeed to the SQL session |
| `CREATE CHANGEFEED FOR TABLE t INTO 'kafka://...'` | Enterprise changefeed |
| `WITH resolved = '10s'` | Emit frontier watermarks |
| `WITH diff` | Include the `before` image |
| `WITH cursor = '<ts>'` | Start (or replay) from a timestamp |
| `WITH schema_change_policy = 'stop'` | Fail on schema change instead of backfilling |
| `SHOW CHANGEFEED JOBS` | Status and `high_water_timestamp` |
| `PAUSE / RESUME / CANCEL JOB` | Feed lifecycle |
| `changefeed_max_behind_nanos` | Lag metric for alerting |
