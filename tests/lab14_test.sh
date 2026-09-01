#!/usr/bin/env bash
# Lab 14 — Outbox pattern and idempotent retries. Exercises the Python code
# the lab ships: retry loop, atomic outbox write, idempotency keys, and the
# OCC vs SELECT FOR UPDATE comparison.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab14"
BASE_SQL_PORT=26467
BASE_HTTP_PORT=8213
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup"
start_cluster 3
export DSN="postgresql://root@localhost:${BASE_SQL_PORT}/shop?sslmode=disable"

python3 -c "import psycopg2" 2>/dev/null || {
    warn "psycopg2 not installed; skipping Lab 14 (pip install psycopg2-binary)"
    echo "Lab 14: skipped"
    exit 0
}
pass "psycopg2 available"

cat <<'SQL' | sql_script >/dev/null
CREATE DATABASE shop;
USE shop;
CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email STRING NOT NULL UNIQUE, balance DECIMAL(12,2) NOT NULL DEFAULT 0,
  version INT NOT NULL DEFAULT 1);
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account UUID NOT NULL REFERENCES accounts(id),
  amount DECIMAL(12,2) NOT NULL, status STRING NOT NULL DEFAULT 'new',
  created TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE events_outbox (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  created TIMESTAMPTZ NOT NULL DEFAULT now(),
  topic STRING NOT NULL, aggregate UUID NOT NULL, payload JSONB NOT NULL,
  PRIMARY KEY (id)) WITH (ttl_expire_after = '7 days', ttl_job_cron = '@hourly');
CREATE INDEX ON events_outbox (aggregate, created DESC);
CREATE TABLE idempotency (
  key STRING PRIMARY KEY, account UUID NOT NULL, response JSONB NOT NULL,
  created TIMESTAMPTZ NOT NULL DEFAULT now()) WITH (ttl_expire_after = '24 hours');
INSERT INTO accounts (email, balance)
SELECT 'user' || g || '@example.com', 1000 FROM generate_series(1, 100) g;
SQL
pass "schema created"

# The outbox design decisions the lab argues for must actually be in place.
OUTBOX_DDL=$(sql "SHOW CREATE TABLE shop.events_outbox;")
assert_contains "outbox uses a UUID primary key (no rightmost hotspot)" "$OUTBOX_DDL" "uuid"
assert_contains "outbox has row-level TTL (bounded growth)" "$OUTBOX_DDL" "ttl_expire_after"
assert_not_contains "outbox has no status column (not a polled queue)" "$OUTBOX_DDL" "status"

section "Part A — retry loop"

python3 - <<'PY'
import os, sys, threading, random, time, psycopg2, psycopg2.errors
DSN = os.environ["DSN"]
MAX_ATTEMPTS = 5
stats = {"ok": 0, "retried": 0, "gave_up": 0}
lock = threading.Lock()

def run_txn(conn, body):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with conn:
                with conn.cursor() as cur:
                    body(cur)
            return attempt
        except psycopg2.errors.SerializationFailure:
            if attempt == MAX_ATTEMPTS:
                raise
            time.sleep(random.uniform(0, min(0.5, 0.005 * (2 ** attempt))))

def transfer():
    conn = psycopg2.connect(DSN)
    def body(cur):
        cur.execute("SELECT balance FROM accounts WHERE email = 'user1@example.com'")
        bal = cur.fetchone()[0]
        cur.execute("UPDATE accounts SET balance = %s WHERE email = 'user1@example.com'", (bal + 1,))
    try:
        n = run_txn(conn, body)
        with lock:
            stats["ok"] += 1
            if n > 1: stats["retried"] += 1
    except psycopg2.errors.SerializationFailure:
        with lock: stats["gave_up"] += 1
    finally:
        conn.close()

threads = [threading.Thread(target=transfer) for _ in range(24)]
[t.start() for t in threads]; [t.join() for t in threads]
print("stats:", stats)

# 24-way contention on ONE row with a 5-attempt budget can legitimately exhaust
# that budget — that is the lab's point, not a failure. What must ALWAYS hold:
#   1. every transaction is accounted for,
#   2. retries actually happened (otherwise we aren't testing the loop),
#   3. no lost updates: balance == 1000 + committed transactions.
assert stats["ok"] + stats["gave_up"] == 24, f"transactions unaccounted for: {stats}"
assert stats["retried"] > 0, f"no retries observed — contention not exercised: {stats}"

conn = psycopg2.connect(DSN)
with conn.cursor() as cur:
    cur.execute("SELECT balance FROM accounts WHERE email = 'user1@example.com'")
    bal = cur.fetchone()[0]
assert bal == 1000 + stats["ok"], f"lost update: balance {bal}, expected {1000 + stats['ok']}"
print(f"OK: {stats['ok']} committed, {stats['gave_up']} exhausted the 5-attempt budget, "
      f"no lost updates (balance = {bal})")

# The single-statement form must be perfect: no retries, no failures.
def single_stmt():
    c = psycopg2.connect(DSN)
    c.autocommit = True
    try:
        with c.cursor() as cur:
            cur.execute("UPDATE accounts SET balance = balance + 1 WHERE email = 'user1@example.com'")
        return True
    except psycopg2.errors.SerializationFailure:
        return False
    finally:
        c.close()

before = bal
results = []
ts = [threading.Thread(target=lambda: results.append(single_stmt())) for _ in range(24)]
[t.start() for t in ts]; [t.join() for t in ts]
assert all(results), f"single-statement form should never fail: {results.count(False)} failures"
with psycopg2.connect(DSN).cursor() as cur:
    cur.execute("SELECT balance FROM accounts WHERE email = 'user1@example.com'")
    bal2 = cur.fetchone()[0]
assert bal2 == before + 24, f"single-statement lost updates: {bal2} != {before + 24}"
print("OK: single-statement form applied all 24 with zero failures")
PY
[ $? -eq 0 ] && pass "retry loop: every txn accounted for, no lost updates; single-statement form perfect" \
             || fail "retry loop test failed"

section "Part B — outbox atomicity"

python3 - <<'PY'
import os, json, psycopg2
DSN = os.environ["DSN"]
conn = psycopg2.connect(DSN)

def place_order(conn, account_id, amount, crash=False):
    with conn:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO orders (account, amount) VALUES (%s,%s) RETURNING id",
                        (account_id, amount))
            oid = cur.fetchone()[0]
            cur.execute("""INSERT INTO events_outbox (topic, aggregate, payload)
                           VALUES ('order.created', %s, %s)""",
                        (oid, json.dumps({"order_id": str(oid), "amount": float(amount)})))
            if crash:
                raise RuntimeError("simulated crash before commit")
    return oid

with conn.cursor() as cur:
    cur.execute("SELECT id FROM accounts LIMIT 3")
    accts = [r[0] for r in cur.fetchall()]

for a in accts:
    place_order(conn, a, 25.00)

with conn.cursor() as cur:
    cur.execute("SELECT count(*) FROM orders"); o1 = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM events_outbox"); e1 = cur.fetchone()[0]
assert o1 == 3 and e1 == 3, f"expected 3/3, got {o1}/{e1}"

try:
    place_order(conn, accts[0], 99.00, crash=True)
except RuntimeError:
    pass

with conn.cursor() as cur:
    cur.execute("SELECT count(*) FROM orders"); o2 = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM events_outbox"); e2 = cur.fetchone()[0]
assert (o2, e2) == (o1, e1), f"crash left partial state: {o2}/{e2} vs {o1}/{e1}"
print(f"OK: orders={o2} events={e2} — a crash before commit left neither row")
PY
[ $? -eq 0 ] && pass "outbox write is atomic with the business write" \
             || fail "outbox atomicity test failed"

section "Part C — idempotency keys"

python3 - <<'PY'
import os, json, uuid, threading, psycopg2, psycopg2.errors
DSN = os.environ["DSN"]

def place_order_idempotent(conn, key, account_id, amount):
    with conn:
        with conn.cursor() as cur:
            cur.execute("SELECT response FROM idempotency WHERE key = %s", (key,))
            row = cur.fetchone()
            if row:
                return row[0], True
            cur.execute("INSERT INTO orders (account, amount) VALUES (%s,%s) RETURNING id",
                        (account_id, amount))
            oid = cur.fetchone()[0]
            cur.execute("""INSERT INTO events_outbox (topic, aggregate, payload)
                           VALUES ('order.created', %s, %s)""",
                        (oid, json.dumps({"order_id": str(oid)})))
            resp = {"order_id": str(oid), "status": "created"}
            cur.execute("INSERT INTO idempotency (key, account, response) VALUES (%s,%s,%s)",
                        (key, account_id, json.dumps(resp)))
            return resp, False

conn = psycopg2.connect(DSN)

def verify(sql, params=None):
    """Read on a FRESH autocommit connection.

    Reusing a psycopg2 connection that is idle-in-transaction would reuse its
    snapshot, and under SERIALIZABLE that snapshot predates the writes we are
    trying to observe — the count comes back 0 and looks like lost data."""
    c = psycopg2.connect(DSN); c.autocommit = True
    try:
        with c.cursor() as cur:
            cur.execute(sql, params or ())
            return cur.fetchone()[0]
    finally:
        c.close()

acct = verify("SELECT id FROM accounts LIMIT 1")

key = str(uuid.uuid4())
r1, replay1 = place_order_idempotent(conn, key, acct, 42.00)
r2, replay2 = place_order_idempotent(conn, key, acct, 42.00)
r3, replay3 = place_order_idempotent(conn, key, acct, 42.00)
assert not replay1 and replay2 and replay3, "replay flags wrong"
assert r1["order_id"] == r2["order_id"] == r3["order_id"], "response not stable across retries"

n = verify("SELECT count(*) FROM orders WHERE amount = 42.00")
assert n == 1, f"sequential duplicates created {n} orders"

# Concurrent duplicates with the same key. Without a retry loop, SERIALIZABLE
# can abort EVERY caller (including the winner), so an idempotent handler must
# retry and treat "key already claimed" as a replay.
import time, random

def place_order_idempotent_retrying(conn, key, account_id, amount, max_attempts=10):
    for attempt in range(1, max_attempts + 1):
        try:
            return place_order_idempotent(conn, key, account_id, amount)
        except psycopg2.errors.UniqueViolation:
            conn.rollback()
            with conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT response FROM idempotency WHERE key = %s", (key,))
                    row = cur.fetchone()
            if row:
                return row[0], True
        except psycopg2.errors.SerializationFailure:
            conn.rollback()
        time.sleep(random.uniform(0, min(0.5, 0.005 * (2 ** attempt))))
    raise RuntimeError("idempotent handler exhausted its retry budget")

key2, results, errors, lock = str(uuid.uuid4()), [], [], threading.Lock()
def worker():
    c = psycopg2.connect(DSN)
    try:
        resp, replayed = place_order_idempotent_retrying(c, key2, acct, 77.00)
        with lock: results.append((resp["order_id"], replayed))
    except Exception as e:
        with lock: errors.append(repr(e))
    finally:
        c.close()

ts = [threading.Thread(target=worker) for _ in range(10)]
[t.start() for t in ts]; [t.join() for t in ts]

assert not errors, f"callers failed outright: {errors[:3]}"
assert len(results) == 10, f"expected 10 responses, got {len(results)}"

n2 = verify("SELECT count(*) FROM orders WHERE amount = 77.00")
assert n2 == 1, f"concurrent duplicates created {n2} orders (expected 1)"

ids = {r[0] for r in results}
assert len(ids) == 1, f"callers got different order_ids: {ids}"
replayed = sum(1 for r in results if r[1])
assert replayed == 9, f"expected 9 replays and 1 create, got {replayed} replays"
print(f"OK: 1 order created, all 10 callers returned the same order_id "
      f"({replayed} replays)")
PY
[ $? -eq 0 ] && pass "idempotency keys prevent duplicate work, sequentially and concurrently" \
             || fail "idempotency test failed"

section "Part D — OCC vs SELECT FOR UPDATE"

python3 - <<'PY'
import os, threading, time, random, psycopg2, psycopg2.errors
DSN = os.environ["DSN"]
CONCURRENCY, ITERATIONS = 8, 10

def reset():
    c = psycopg2.connect(DSN); c.autocommit = True
    with c.cursor() as cur:
        cur.execute("UPDATE accounts SET balance=1000, version=1 WHERE email='user1@example.com'")
    c.close()

def bench(name, fn):
    reset()
    counts = {"retries": 0}; lock = threading.Lock()
    def worker():
        conn = psycopg2.connect(DSN)
        for _ in range(ITERATIONS):
            r = fn(conn)
            with lock: counts["retries"] += r
        conn.close()
    ts = [threading.Thread(target=worker) for _ in range(CONCURRENCY)]
    t0 = time.time(); [t.start() for t in ts]; [t.join() for t in ts]
    el = time.time() - t0
    c = psycopg2.connect(DSN)
    with c.cursor() as cur:
        cur.execute("SELECT balance FROM accounts WHERE email='user1@example.com'")
        bal = cur.fetchone()[0]
    c.close()
    total = CONCURRENCY * ITERATIONS
    assert bal == 1000 + total, f"{name}: lost updates — balance {bal}, expected {1000+total}"
    print(f"{name:12} {total} ops in {el:.2f}s => {total/el:.0f} ops/s, retries={counts['retries']}")
    return el

def occ(conn):
    # OCC handles the LOGICAL conflict (version mismatch -> 0 rows), but the
    # database still raises 40001 for PHYSICAL write conflicts. Both must retry.
    retries = 0
    while True:
        try:
            with conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT balance, version FROM accounts WHERE email='user1@example.com'")
                    bal, ver = cur.fetchone()
                    cur.execute("""UPDATE accounts SET balance=%s, version=version+1
                                   WHERE email='user1@example.com' AND version=%s""", (bal+1, ver))
                    if cur.rowcount == 1:
                        return retries
        except psycopg2.errors.SerializationFailure:
            pass
        retries += 1
        time.sleep(random.uniform(0, 0.01))

def pessimistic(conn):
    retries = 0
    while True:
        try:
            with conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT balance FROM accounts WHERE email='user1@example.com' FOR UPDATE")
                    bal = cur.fetchone()[0]
                    cur.execute("UPDATE accounts SET balance=%s WHERE email='user1@example.com'", (bal+1,))
            return retries
        except psycopg2.errors.SerializationFailure:
            retries += 1
            time.sleep(random.uniform(0, 0.01))

bench("OCC", occ)
bench("FOR UPDATE", pessimistic)
print("OK: both strategies preserved every increment")
PY
[ $? -eq 0 ] && pass "OCC and SELECT FOR UPDATE both preserved every increment" \
             || fail "OCC/locking comparison failed"

section "Part E — connection accounting"

SESSIONS=$(sql "SELECT node_id, count(*) FROM crdb_internal.cluster_sessions GROUP BY node_id;")
assert_contains "cluster_sessions is queryable for pool sizing" "$SESSIONS" "node_id"

# The TTL *job* appears only after the cron fires; the SCHEDULE exists as soon as
# the table does. Assert the schedule — one per TTL table (outbox + idempotency).
TTL_SCHED=$(sql_value "SELECT count(*) FROM [SHOW SCHEDULES] WHERE label ILIKE '%row-level-ttl%';")
assert_ge "row-level TTL schedules registered for the outbox/idempotency tables" "${TTL_SCHED:-0}" "2"

section "Done"
echo "Lab 14: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
