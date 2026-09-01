# Lab 1: Cluster Bootstrap & Lifecycle (75 min)

## Learning Objectives

By the end of this lab you will be able to:

- Start a 3-node CockroachDB cluster two ways: via `cockroach demo` and via `cockroach start` with a real init step
- Inspect node liveness, range distribution, and leaseholders from SQL
- Kill nodes and observe Raft's automatic re-replication
- Drive a graceful **decommission** of a node — and discover why it needs `replication factor + 1` nodes
- Connect to the cluster with three different clients: built-in `cockroach sql`, `psql`, and a quick Python script
- Diagnose a common "cluster won't start" error class — port collisions, join-list typos, version skew

## Prerequisites

- `cockroach` binary on `PATH` (`cockroach version` works)
- Modern browser for the DB Console
- Optional: `psql` and `python3` for the connectivity exercise (steps that need them are marked optional)

Open **two terminal windows** before starting — the demo cluster pins one terminal, and you'll need the other for `psql` / Python / killing processes.

## Setup

Pick a working directory for any artifacts:

```bash
mkdir -p ~/crdb-lab1 && cd ~/crdb-lab1
```

## Tasks

### Part A: `cockroach demo` — Fast Path (15 min)

The demo cluster is in-memory; it's perfect for exploration but disappears on exit.

1. **Start it (terminal A):**
   ```bash
   cockroach demo --nodes 3 --no-example-database --empty
   ```

2. **From the very first line of output, capture three things:**
   - The `Web UI:` URL (paste into your browser)
   - The `sql:` URL (you'll feed it to `psql` later)
   - The node localities printed in the startup banner

3. **Confirm cluster size and identity:**
   ```sql
   SHOW CLUSTER SETTING version;

   SELECT node_id, address, locality, is_live
   FROM crdb_internal.gossip_nodes
   ORDER BY node_id;

   SELECT count(*) AS total_ranges FROM crdb_internal.ranges_no_leases;
   ```
   You should see three live nodes and ~30–50 system ranges (no user data yet).

4. **Create a small dataset:**
   ```sql
   CREATE DATABASE lab1;
   USE lab1;

   CREATE TABLE notes (
     id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     body  STRING NOT NULL,
     made  TIMESTAMPTZ DEFAULT now()
   );

   INSERT INTO notes (body)
   SELECT 'note ' || generate_series(1, 1000)::STRING;

   SELECT count(*) FROM notes;
   ```
   Expected count: 1000.

5. **Find the leaseholder:**
   ```sql
   SHOW RANGES FROM TABLE notes WITH DETAILS;
   ```
   Note the `lease_holder` column — typically a single range for 1000 rows.

6. **Look at the Web UI:**
   - **Overview** — 3 live nodes, all green
   - **Databases** → `lab1` → `notes` — row count, size
   - **Hot Ranges** — should be quiet (no traffic right now)

### Part B: Kill a Follower, Watch Recovery (10 min)

The demo shell has a `\demo` meta-command that drives node lifecycle.

1. **List demo nodes:**
   ```text
   \demo ls
   ```

2. **Identify a victim** — pick a node that is **not** the leaseholder for `notes`. We're testing follower recovery first.

3. **Kill it:**
   ```text
   \demo shutdown 3
   ```

4. **Verify the cluster keeps serving:**
   ```sql
   SELECT count(*) FROM notes;          -- still 1000
   INSERT INTO notes (body) VALUES ('survives a follower outage');
   SELECT count(*) FROM notes;          -- 1001
   ```

5. **Watch the impact in the Web UI:**
   - **Overview** — node 3 marked unhealthy
   - **Metrics → Replication** — under-replicated may spike briefly

6. **Restart node 3:**
   ```text
   \demo restart 3
   ```
   Wait ~10 seconds and refresh the Replication dashboard. Under-replicated returns to 0.

### Part C: Kill the Leaseholder (5 min)

Same drill, but on the leaseholder. The lease has to transfer before reads resume.

1. **Identify the current leaseholder:**
   ```sql
   SELECT lease_holder FROM [SHOW RANGES FROM TABLE notes WITH DETAILS] LIMIT 1;
   ```

2. **Kill that node:**
   ```text
   \demo shutdown <that node id>
   ```

3. **Time a query immediately after** — expect a brief stall (≤9 s):
   ```sql
   \timing on
   SELECT count(*) FROM notes;
   ```

4. **Re-check the leaseholder:**
   ```sql
   SHOW RANGES FROM TABLE notes WITH DETAILS;
   ```
   It's now a surviving node. Cockroach Raft did the failover for you.

5. **Restart the node:**
   ```text
   \demo restart <that node id>
   ```

### Part D: Real Multi-Process Cluster With `cockroach start` (15 min)

Demo mode is convenient but hides the setup steps you'd do in production. Let's run a "real" 3-node cluster on this one machine.

1. **Exit the demo** (`\q`).

2. **Pick a workdir and three port pairs:**
   ```bash
   cd ~/crdb-lab1
   mkdir -p node1 node2 node3 logs
   ```

3. **Start node 1 in the background:**
   ```bash
   cockroach start --insecure \
     --store=node1 \
     --listen-addr=localhost:26257 \
     --http-addr=localhost:8080 \
     --join=localhost:26257,localhost:26258,localhost:26259 \
     --background
   ```
   Note that node 1 *does not* have data yet — it's waiting for cluster init.

4. **Start nodes 2 and 3:**
   ```bash
   cockroach start --insecure \
     --store=node2 \
     --listen-addr=localhost:26258 \
     --http-addr=localhost:8081 \
     --join=localhost:26257,localhost:26258,localhost:26259 \
     --background

   cockroach start --insecure \
     --store=node3 \
     --listen-addr=localhost:26259 \
     --http-addr=localhost:8082 \
     --join=localhost:26257,localhost:26258,localhost:26259 \
     --background
   ```

5. **Initialize the cluster — one time only:**
   ```bash
   cockroach init --insecure --host=localhost:26257
   ```

6. **Connect:**
   ```bash
   cockroach sql --insecure --host=localhost:26257
   ```

7. **Confirm topology:**
   ```sql
   SELECT node_id, address, locality, is_live
   FROM crdb_internal.gossip_nodes
   ORDER BY node_id;
   ```

8. **Recreate the lab1 schema** (because this is a fresh cluster):
   ```sql
   CREATE DATABASE lab1;
   USE lab1;
   CREATE TABLE notes (
     id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     body  STRING NOT NULL,
     made  TIMESTAMPTZ DEFAULT now()
   );
   INSERT INTO notes (body) SELECT 'note ' || g FROM generate_series(1,500) g;
   ```

### Part E: Graceful Decommission (10 min)

Decommissioning is how you shrink a cluster in production — different from a kill, because the cluster waits for every range to have a replacement replica before declaring the node gone.

1. **From a second terminal, watch the live status of node 3:**
   ```bash
   cockroach node status --host=localhost:26257 --insecure
   ```

2. **Try to decommission node 3 — and watch it be refused:**
   ```bash
   cockroach node decommission 3 --host=localhost:26257 --insecure
   ```
   ```
   ranges blocking decommission detected
   n3 has 67 replicas blocked with error: "0 of 2 live stores are able to take a new
   replica for the range (2 already have a voter, 0 already have a non-voter);
   likely not enough nodes in cluster"
   ERROR: Cannot decommission nodes.
   ```

   > **This is the lesson.** Decommissioning moves every replica off the node *before* it leaves.
   > With 3 nodes and a replication factor of 3, each range already has a replica on all three —
   > there is nowhere for node 3's replicas to go, so the cluster refuses rather than dropping
   > below its replication target.
   >
   > **You need spare capacity to shrink: at least `replication factor + 1` nodes.** This is the
   > single most common surprise when someone tries to scale a 3-node cluster down, and it is why
   > the Kubernetes lab (Lab 16) insists on decommissioning *before* reducing the replica count —
   > the same constraint, one layer up.

3. **Add a fourth node so the replicas have somewhere to go:**
   ```bash
   cockroach start --insecure \
     --store=lab1-data/n4 \
     --listen-addr=localhost:26260 --http-addr=localhost:8083 \
     --join=localhost:26257,localhost:26258,localhost:26259 \
     --background
   ```
   ```bash
   cockroach node status --host=localhost:26257 --insecure     # 4 nodes now
   ```

4. **Decommission node 3 again — now it works:**
   ```bash
   cockroach node decommission 3 --host=localhost:26257 --insecure
   ```
   The command blocks until every range with a replica on node 3 has a replacement elsewhere.
   On a cluster this small that's seconds; on a real production node it can take many minutes.

5. **Confirm:**
   ```sql
   SELECT node_id, membership FROM crdb_internal.kv_node_liveness ORDER BY node_id;
   ```
   Node 3 reports `decommissioned`; nodes 1, 2, and 4 are `active`. Reads and writes keep
   working throughout, and no data was lost.

6. **Note what recommission can and cannot do:**
   ```bash
   cockroach node recommission 3 --host=localhost:26257 --insecure
   ```
   Recommission reverses a decommission that is still *in progress*. Once a node reaches
   `decommissioned`, it is permanently out of the cluster — bringing that capacity back means
   starting a new node, which joins with a new node ID.

### Part F: Three Ways to Connect (10 min)

CockroachDB speaks PostgreSQL wire — any PG client works. Try at least the first two.

1. **`cockroach sql`** (you've been using it):
   ```bash
   cockroach sql --insecure --host=localhost:26257 \
     --execute "SELECT count(*) FROM lab1.notes;"
   ```

2. **`psql`** (optional — needs `psql` on `PATH`):
   ```bash
   psql "postgresql://root@localhost:26257/lab1?sslmode=disable" \
     -c "SELECT count(*) FROM notes;"
   ```
   The same wire protocol. Both tools see the same data.

3. **Python with `psycopg2`** (optional — needs `pip install psycopg2-binary`):
   ```bash
   python3 - <<'PY'
   import psycopg2
   conn = psycopg2.connect("postgresql://root@localhost:26257/lab1?sslmode=disable")
   with conn.cursor() as cur:
       cur.execute("SELECT count(*) FROM notes;")
       print("count =", cur.fetchone()[0])
   conn.close()
   PY
   ```

4. **CockroachDB-specific built-in from `psql`:**
   ```bash
   psql "postgresql://root@localhost:26257?sslmode=disable" \
     -c "SELECT crdb_internal.cluster_id();"
   ```
   These functions don't exist in PostgreSQL — but the wire protocol doesn't care.

### Part G: Troubleshooting Common Startup Errors (10 min)

You will hit these in production. Learn to recognize them now.

1. **Port already in use:**
   ```bash
   cockroach start --insecure --store=tmp_node --listen-addr=localhost:26257 \
     --join=localhost:26257 --background 2>&1 | head -20
   ```
   You should see `address already in use`. Fix: change `--listen-addr` to a free port, or stop the conflicting process.

2. **Wrong join list (typo):**
   ```bash
   cockroach start --insecure --store=tmp_node2 --listen-addr=localhost:26260 \
     --http-addr=localhost:8090 \
     --join=localhost:26999 --background 2>&1 | head -20
   ```
   The new node starts but doesn't join. It logs "no resolved addresses available" repeatedly. Fix: use the correct addresses, or include `localhost:26257` in the join list.

3. **Killing & restarting your test garbage:**
   ```bash
   pkill -f "cockroach start --insecure --store=tmp_node" 2>/dev/null
   rm -rf tmp_node tmp_node2
   ```

## Cleanup

```bash
# Stop the 3-node real cluster
cockroach quit --insecure --host=localhost:26257
cockroach quit --insecure --host=localhost:26258
cockroach quit --insecure --host=localhost:26259

# Wipe the stores
cd ~ && rm -rf ~/crdb-lab1
```

If you used the demo cluster only: just type `\q` to exit.

## Lab 1 Deliverables

✅ **Cluster started two ways**: `cockroach demo` and 3-process `cockroach start`+`init`
✅ **Live topology inspected**: identified leaseholders, locality, range count from `crdb_internal`
✅ **Failure tolerance verified**: killed a follower, killed the leaseholder, watched Raft recover both
✅ **Graceful decommission**: drove a clean node removal; observed a "stuck" decommission and recovered with recommission
✅ **PG wire compatibility**: connected with `cockroach sql`, `psql`, and Python
✅ **Common errors triggered**: recognized port conflicts and bad join lists by their log signatures

## Challenge Exercises

1. **Kill two of three nodes simultaneously.** Why do queries against the third node hang? What setting controls how long they hang before erroring? *Hint:* `kv.raft.election_timeout_ticks`.

2. **Add a fourth node** to the running 3-node cluster from Part D. Watch the ranges rebalance in the Web UI. Why doesn't the cluster automatically replicate every range to 4 nodes? (*Hint:* default replication factor.)

3. **Tune the replication factor.** Try `ALTER RANGE default CONFIGURE ZONE USING num_replicas = 5;` on the 4-node cluster. What happens? Now try the same with a 3-node cluster — why does the cluster refuse to go above 3 there?

## Reference

- **Web UI default port:** 8080
- **SQL default port:** 26257
- **Stop a node:** `cockroach quit --insecure --host=<host:port>`
- **Tail logs:** they're in `<store>/logs/` once the node is running
- **Decommission state:** `SELECT * FROM crdb_internal.gossip_liveness;`
- **Lease state:** `SHOW RANGES FROM TABLE <t> WITH DETAILS;` shows the current leaseholder
