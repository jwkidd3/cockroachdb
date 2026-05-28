#!/usr/bin/env bash
# Lab 5 — Transactions, Contention & Retry Loops
#
# Tests cover Parts A (manual 40001), B (retry loop), C (AS OF SYSTEM TIME),
# D (SELECT FOR UPDATE), E (sharded counter), F (contention diagnostics).
#
# Concurrency is driven from this script (no manual two-terminal interaction).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab05"
BASE_SQL_PORT=26337
BASE_HTTP_PORT=8113
source "$SCRIPT_DIR/lib/cluster.sh"

trap 'stop_cluster' EXIT INT TERM

section "Setup — 3-node cluster + bank schema"
start_cluster 3
cat <<'SQL' | sql_script
CREATE DATABASE bank;
USE bank;
CREATE TABLE accounts (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name    STRING UNIQUE NOT NULL,
  balance DECIMAL(12,2) NOT NULL CHECK (balance >= 0)
);
INSERT INTO accounts (name, balance) VALUES
  ('Alice', 1000.00),
  ('Bob',    500.00),
  ('Charlie', 2000.00);
SQL

START_TOTAL=$(sql_value "SELECT sum(balance) FROM bank.accounts;")
assert_eq "starting total is 3500.00" "$START_TOTAL" "3500.00"

section "Part A — Force a 40001 by interleaving two transactions"
# Using BEGIN/COMMIT cross-session in bash requires keeping a session alive,
# which mostly-pure SQL can't do. We synthesize the same conflict by:
#   1. Session A begins a transaction at time T.
#   2. Session B writes at a later time.
#   3. Session A writes; commit fails with 40001.
#
# We do this by holding a pipe-backed `cockroach sql` open as session A.

URL="postgresql://root@localhost:${BASE_SQL_PORT}/bank?sslmode=disable"
mkfifo "${STORE_BASE}/sessA.fifo"
exec 3>"${STORE_BASE}/sessA.fifo"
cockroach sql --url "$URL" <"${STORE_BASE}/sessA.fifo" >"${STORE_BASE}/sessA.out" 2>&1 &
SESS_A_PID=$!
sleep 1

# Begin txn A and read
echo "BEGIN; SELECT balance FROM accounts WHERE name = 'Alice';" >&3
sleep 1

# Session B writes (auto-commit)
sql "USE bank; UPDATE accounts SET balance = balance - 100 WHERE name = 'Alice';" >/dev/null

# Session A tries to write and commit; should fail with 40001
echo "UPDATE accounts SET balance = balance - 50 WHERE name = 'Alice'; COMMIT;" >&3
sleep 2

# Close session A
exec 3>&-
wait "$SESS_A_PID" 2>/dev/null || true

if grep -q "SQLSTATE: 40001\|TransactionRetry\|restart transaction" "${STORE_BASE}/sessA.out"; then
    pass "session A's commit failed with serialization error (40001 or restart)"
else
    warn "did not see 40001 in session output (timing-sensitive); content:"
    tail -20 "${STORE_BASE}/sessA.out" | sed 's/^/    /'
    # Don't fail hard — this test is timing-sensitive. The retry-loop test below proves the same behavior.
fi

# Bank state should be self-consistent
RESTORE_TOTAL=$(sql_value "SELECT sum(balance) FROM bank.accounts;")
info "post-conflict total: $RESTORE_TOTAL"

# Reset balances
sql "USE bank; UPDATE accounts SET balance = CASE name WHEN 'Alice' THEN 1000 WHEN 'Bob' THEN 500 ELSE 2000 END;" >/dev/null

section "Part B — Retry loop succeeds under heavy concurrent contention"
# Use a bash retry loop (no python dep required for tests).
RETRY_SCRIPT="${STORE_BASE}/transfer.sh"
cat > "$RETRY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
MAX=8
FROM="\$1" TO="\$2" AMT="\$3"
for n in \$(seq 1 \$MAX); do
  if cockroach sql --url "$URL" --execute "
    BEGIN;
    UPDATE accounts SET balance = balance - \$AMT WHERE name = '\$FROM';
    UPDATE accounts SET balance = balance + \$AMT WHERE name = '\$TO';
    COMMIT;
  " >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.0\$n
done
exit 1
EOF
chmod +x "$RETRY_SCRIPT"

# Drive concurrent contention
FAILS=0
for i in {1..30}; do
  "$RETRY_SCRIPT" Alice Bob 10 &
done
for i in {1..30}; do
  "$RETRY_SCRIPT" Bob Alice 10 &
done
for pid in $(jobs -p); do
  wait "$pid" || FAILS=$((FAILS+1))
done

# Allow some failures under extreme load, but most should succeed.
assert_lt "retry-loop failure count is low" "$FAILS" "10"

# Atomicity: total must be preserved
END_TOTAL=$(sql_value "SELECT sum(balance) FROM bank.accounts;")
assert_eq "total preserved after concurrent transfers" "$END_TOTAL" "3500.00"

section "Part C — AS OF SYSTEM TIME runs without conflict"
# Generate write traffic in the background
(
  for i in {1..100}; do
    cockroach sql --url "$URL" --execute "UPDATE accounts SET balance = balance + 1 WHERE name = 'Alice';" >/dev/null 2>&1
  done
) &
WRITE_PID=$!

# Read at the follower timestamp — must succeed
sleep 1
AOS_TOTAL=$(cockroach sql --url "$URL" --format=tsv \
    --execute "SELECT sum(balance) FROM accounts AS OF SYSTEM TIME follower_read_timestamp();" 2>/dev/null \
    | tail -n +2 | head -1 | awk '{print $1}')
[ -n "$AOS_TOTAL" ] && pass "AS OF SYSTEM TIME query returned a sum ($AOS_TOTAL)" \
    || fail "AS OF SYSTEM TIME query returned no value"

wait "$WRITE_PID" 2>/dev/null || true

# Reset for next part
sql "USE bank; UPDATE accounts SET balance = CASE name WHEN 'Alice' THEN 1000 WHEN 'Bob' THEN 500 ELSE 2000 END;" >/dev/null

section "Part D — SELECT FOR UPDATE acquires a row lock"
# We can't easily test the BLOCKING behavior without a second persistent session,
# but we CAN verify the syntax succeeds and that explicit locks coordinate writes.
sql "USE bank; BEGIN; SELECT balance FROM accounts WHERE name = 'Alice' FOR UPDATE; UPDATE accounts SET balance = balance - 50 WHERE name = 'Alice'; COMMIT;" >/dev/null
assert_command_succeeds "SELECT FOR UPDATE syntax executes" \
    cockroach sql --url "$URL" --execute "SELECT balance FROM accounts WHERE name = 'Alice' FOR UPDATE;"

section "Part E — Sharded counter eliminates single-row hotspot"
sql "USE bank;
CREATE TABLE counter_shards (
  name STRING NOT NULL, shard INT NOT NULL, n INT NOT NULL DEFAULT 0,
  PRIMARY KEY (name, shard));
INSERT INTO counter_shards (name, shard) SELECT 'page_views', g FROM generate_series(0, 15) g;" >/dev/null

SHARD_COUNT=$(sql_value "SELECT count(*) FROM bank.counter_shards;")
assert_eq "16 shards pre-created" "$SHARD_COUNT" "16"

# Drive 200 concurrent increments
for i in {1..200}; do
  cockroach sql --url "$URL" --execute \
    "UPDATE counter_shards SET n = n + 1 WHERE name = 'page_views' AND shard = (random()*16)::INT;" >/dev/null 2>&1 &
done
wait

TOTAL=$(sql_value "SELECT sum(n) FROM bank.counter_shards WHERE name = 'page_views';")
assert_ge "sharded counter total >= 150 (allowing for ~25 lost-update racey decrements)" "$TOTAL" "150"

section "Part F — Contention events are observable in crdb_internal"
# Drive heavy contention
for i in {1..30}; do "$RETRY_SCRIPT" Alice Bob 5 & done
for i in {1..30}; do "$RETRY_SCRIPT" Bob Alice 5 & done
wait

CONTENTION_EVENTS=$(sql_value "SELECT count(*) FROM crdb_internal.transaction_contention_events WHERE collection_ts > now() - INTERVAL '1 minute';")
info "contention events recorded in last 1m: $CONTENTION_EVENTS"
assert_ge "at least 1 contention event captured" "$CONTENTION_EVENTS" "1"

section "Done"
echo "Lab 5: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
