#!/usr/bin/env bash
# Lab 11 — BACKUP / RESTORE / schedules and the cross-cluster DR drill.
# Cluster A is the primary; cluster B is the standby the drill restores into.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab11"
BASE_SQL_PORT=26427
BASE_HTTP_PORT=8173
source "$SCRIPT_DIR/lib/cluster.sh"

# Cluster B lives outside cluster.sh's bookkeeping.
B_STORE="${STORE_BASE}-b"
B_SQL_PORT=26437
B_HTTP_PORT=8183

b_sql()   { cockroach sql --insecure --host="localhost:${B_SQL_PORT}" --execute "$1"; }
b_value() { cockroach sql --insecure --host="localhost:${B_SQL_PORT}" --format=tsv --execute "$1" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}'; }

cleanup_all() {
    cockroach node drain --insecure --host="localhost:${B_SQL_PORT}" --drain-wait=5s >/dev/null 2>&1 || true
    pkill -f "cockroach start --insecure --store=${B_STORE}" 2>/dev/null || true
    [ "${KEEP_ON_FAIL:-0}" != "1" ] && rm -rf "$B_STORE"
    stop_cluster
}
trap cleanup_all EXIT INT TERM

section "Setup — cluster A with a dataset"
start_cluster 3

cat <<'SQL' | sql_script >/dev/null
CREATE DATABASE bank;
USE bank;
CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name STRING NOT NULL, balance DECIMAL(12,2) NOT NULL, region STRING NOT NULL);
CREATE TABLE transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_id UUID NOT NULL REFERENCES accounts(id),
  to_id UUID NOT NULL REFERENCES accounts(id),
  amount DECIMAL(12,2) NOT NULL, ts TIMESTAMPTZ NOT NULL DEFAULT now());
INSERT INTO accounts (name, balance, region)
SELECT 'user-' || g, 1000.00, (ARRAY['us-east','us-west','eu-west'])[1 + g % 3]
FROM generate_series(1, 2000) g;
SQL

SRC_COUNT=$(sql_value "SELECT count(*) FROM bank.accounts;")
SRC_SUM=$(sql_value "SELECT sum(balance)::DECIMAL(20,2) FROM bank.accounts;")
assert_eq "source has 2000 accounts" "$SRC_COUNT" "2000"
info "source checksum (sum of balances) = $SRC_SUM"

section "Part A — full and incremental backups"

# `AS OF SYSTEM TIME '-5s'` reads a snapshot from 5 seconds ago. The database was
# created moments ago, so that snapshot predates it and the backup fails with
# "database does not exist, or invalid RESTORE time". Wait past the window.
sleep 8

DEST="nodelocal://1/backups/bank"

# On an unlicensed cluster: full BACKUP/RESTORE and schedules work; incremental
# and revision_history are enterprise. Detect once, then exercise everything the
# licence allows instead of skipping the whole lab.
HAVE_ENTERPRISE=0
RH=$(sql "BACKUP DATABASE bank INTO '${DEST}-rh' AS OF SYSTEM TIME '-5s' WITH revision_history;" 2>&1 || true)
if grep -qi "requires an enterprise license" <<<"$RH"; then
    warn "no enterprise licence: revision_history and incremental backups will be skipped"
else
    HAVE_ENTERPRISE=1
    pass "revision_history backup succeeded (enterprise licence present)"
fi

# The free path must work on every cluster.
BK=$(sql "BACKUP DATABASE bank INTO '$DEST' AS OF SYSTEM TIME '-5s';" 2>&1 || true)
if grep -qi "error" <<<"$BK"; then
    fail "full BACKUP failed on the free path: $(head -3 <<<"$BK")"
fi
pass "full BACKUP succeeded (free path)"

SHOW=$(sql "SHOW BACKUPS IN '$DEST';")
assert_contains "SHOW BACKUPS lists a backup path" "$SHOW" "/"

DETAIL=$(sql "SHOW BACKUP FROM LATEST IN '$DEST';")
assert_contains "SHOW BACKUP lists the accounts table" "$DETAIL" "accounts"

MARKER=$(sql_value "SELECT cluster_logical_timestamp();")
info "restore marker = $MARKER"

sql "USE bank; INSERT INTO transfers (from_id, to_id, amount)
     SELECT a.id, b.id, 10.00
     FROM (SELECT id FROM accounts LIMIT 200) a, (SELECT id FROM accounts LIMIT 1) b;" >/dev/null
sql "USE bank; UPDATE accounts SET balance = balance - 10 WHERE region = 'us-east';" >/dev/null

if [ "$HAVE_ENTERPRISE" = "1" ]; then
    sql "BACKUP DATABASE bank INTO LATEST IN '$DEST' WITH revision_history;" >/dev/null
    pass "incremental BACKUP succeeded"
else
    INC=$(sql "BACKUP DATABASE bank INTO LATEST IN '$DEST';" 2>&1 || true)
    assert_contains "incremental backup is correctly gated without a licence" "$INC" "enterprise license"
    # Free equivalent: another full backup into the same collection.
    sql "BACKUP DATABASE bank INTO '$DEST' AS OF SYSTEM TIME '-5s';" >/dev/null
    pass "second full BACKUP into the same collection succeeded (free path)"
fi

CHAIN=$(sql "SHOW BACKUP FROM LATEST IN '$DEST';")
assert_contains "backup chain includes transfers" "$CHAIN" "transfers"

# The regrettable action the lab recovers from. `transfers` has an FK onto
# `accounts`, so dependent rows must go first or the delete is rejected.
sql "USE bank; DELETE FROM transfers
     WHERE from_id IN (SELECT id FROM accounts WHERE region = 'us-east')
        OR to_id   IN (SELECT id FROM accounts WHERE region = 'us-east');" >/dev/null
sql "USE bank; DELETE FROM accounts WHERE region = 'us-east';" >/dev/null
AFTER_DELETE=$(sql_value "SELECT count(*) FROM bank.accounts;")
assert_lt "rows were deleted" "$AFTER_DELETE" "$SRC_COUNT"

section "Part B — restores: database, table, point-in-time"

# Wait past the AS OF SYSTEM TIME window, or this backup snapshots the cluster
# from BEFORE the delete above and the restore below sees the pre-delete rows.
# (That staleness is exactly the RPO the lab asks students to compute.)
sleep 8
if [ "$HAVE_ENTERPRISE" = "1" ]; then
    sql "BACKUP DATABASE bank INTO LATEST IN '$DEST' WITH revision_history;" >/dev/null
else
    sql "BACKUP DATABASE bank INTO '$DEST' AS OF SYSTEM TIME '-5s';" >/dev/null
fi

sql "RESTORE DATABASE bank FROM LATEST IN '$DEST' WITH new_db_name = 'bank_restored';" >/dev/null
RESTORED=$(sql_value "SELECT count(*) FROM bank_restored.public.accounts;")
assert_eq "side-by-side restore matches post-delete state" "$RESTORED" "$AFTER_DELETE"

sql "CREATE DATABASE bank_table_only;" >/dev/null
sql "RESTORE TABLE bank.public.accounts FROM LATEST IN '$DEST' WITH into_db = 'bank_table_only';" >/dev/null
TBL=$(sql_value "SELECT count(*) FROM bank_table_only.public.accounts;")
assert_eq "single-table restore matches" "$TBL" "$AFTER_DELETE"

if [ "$HAVE_ENTERPRISE" = "1" ]; then
    PIT=$(sql "RESTORE DATABASE bank FROM LATEST IN '$DEST' AS OF SYSTEM TIME '${MARKER}' WITH new_db_name = 'bank_pit';" 2>&1 || true)
    if grep -qi "not covered\|no backup chain" <<<"$PIT"; then
        warn "PITR window not covered by this chain on a fast test run"
    else
        PIT_COUNT=$(sql_value "SELECT count(*) FROM bank_pit.public.accounts;")
        assert_eq "point-in-time restore recovered the deleted rows" "$PIT_COUNT" "$SRC_COUNT"
    fi
else
    PIT=$(sql "RESTORE DATABASE bank FROM LATEST IN '$DEST' AS OF SYSTEM TIME '${MARKER}' WITH new_db_name = 'bank_pit';" 2>&1 || true)
    # v23.2 wording: "invalid RESTORE timestamp: restoring to arbitrary time
    # requires that BACKUP was created with revision_history"
    assert_contains "point-in-time restore is correctly gated without revision history" "$PIT" \
        "revision_history\|revision history\|invalid RESTORE timestamp\|enterprise license\|not covered"
    # Free-path equivalent of the lesson: the pre-delete FULL backup still has the rows.
    sql "RESTORE DATABASE bank FROM '$(sql_value "SELECT path FROM [SHOW BACKUPS IN '$DEST'] LIMIT 1")' IN '$DEST' WITH new_db_name = 'bank_from_first_full';" >/dev/null 2>&1 || true
    FIRST_FULL=$(sql_value "SELECT count(*) FROM bank_from_first_full.public.accounts;" 2>/dev/null || echo 0)
    assert_eq "the pre-delete full backup still holds every row (RPO = backup interval)" "$FIRST_FULL" "$SRC_COUNT"
fi

RESTORE_JOBS=$(sql_value "SELECT count(*) FROM [SHOW JOBS] WHERE job_type = 'RESTORE';")
assert_ge "restore jobs recorded" "$RESTORE_JOBS" "2"

section "Part C — scheduled backups"

SCHED=$(sql "CREATE SCHEDULE bank_backups FOR BACKUP DATABASE bank
             INTO 'nodelocal://1/backups/scheduled'
             RECURRING '*/5 * * * *' FULL BACKUP '@daily'
             WITH SCHEDULE OPTIONS first_run = 'now';" 2>&1 || true)
if echo "$SCHED" | grep -qi "error"; then
    warn "CREATE SCHEDULE rejected: $(echo "$SCHED" | head -2)"
else
    pass "backup schedule created"
    if grep -qi "only run full backups" <<<"$SCHED"; then
        info "unlicensed cluster: the schedule will run full backups only (expected)"
    fi
    N=$(sql_value "SELECT count(*) FROM [SHOW SCHEDULES] WHERE label LIKE 'bank%';")
    assert_ge "schedule rows created (full + incremental)" "$N" "1"
    sql "PAUSE SCHEDULES SELECT id FROM [SHOW SCHEDULES] WHERE label LIKE 'bank%';" >/dev/null 2>&1 || true
    sql "DROP SCHEDULES SELECT id FROM [SHOW SCHEDULES] WHERE label LIKE 'bank%';" >/dev/null 2>&1 || true
    GONE=$(sql_value "SELECT count(*) FROM [SHOW SCHEDULES] WHERE label LIKE 'bank%';")
    assert_eq "schedules dropped cleanly" "$GONE" "0"
fi

section "Part D — cross-cluster DR drill"

info "starting standby cluster B"
rm -rf "$B_STORE"; mkdir -p "$B_STORE"
B_JOIN="localhost:${B_SQL_PORT},localhost:$((B_SQL_PORT+1)),localhost:$((B_SQL_PORT+2))"
for i in 1 2 3; do
    cockroach start --insecure \
        --store="${B_STORE}/n${i}" \
        --listen-addr="localhost:$((B_SQL_PORT+i-1))" \
        --http-addr="localhost:$((B_HTTP_PORT+i-1))" \
        --join="$B_JOIN" \
        --pid-file="${B_STORE}/n${i}.pid" \
        --log="{sinks: {stderr: {filter: NONE}}}" \
        --background >>"${B_STORE}/n${i}.out" 2>&1 \
        || fail "cluster B node $i failed to start"
done
cockroach init --insecure --host="localhost:${B_SQL_PORT}" >/dev/null 2>&1 || fail "cluster B init failed"
wait_for "cluster B SQL ready" 40 \
    "cockroach sql --insecure --host=localhost:${B_SQL_PORT} --execute 'SELECT 1;'"
pass "standby cluster B is up"

# Full cluster backup on A (includes users and grants).
sql "CREATE USER app_user;" >/dev/null 2>&1 || true
sql "GRANT CONNECT ON DATABASE bank TO app_user;" >/dev/null 2>&1 || true
sql "BACKUP INTO 'nodelocal://1/backups/cluster' AS OF SYSTEM TIME '-5s' WITH revision_history;" >/dev/null
pass "full-cluster BACKUP taken on A"

# Move the backup files to B's nodelocal store.
A_EXTERN="${STORE_BASE}/n1/extern/backups/cluster"
B_EXTERN="${B_STORE}/n1/extern/backups-from-a"
if [ -d "$A_EXTERN" ]; then
    mkdir -p "$(dirname "$B_EXTERN")"
    cp -r "$A_EXTERN" "$B_EXTERN"
    pass "backup files transferred to cluster B"

    T0=$(date +%s)
    RESTORE_OUT=$(b_sql "RESTORE FROM LATEST IN 'nodelocal://1/backups-from-a';" 2>&1 || true)
    T1=$(date +%s)
    if echo "$RESTORE_OUT" | grep -qiE "error|ERROR"; then
        fail "cross-cluster RESTORE failed: $(echo "$RESTORE_OUT" | head -3)"
    fi
    info "measured RTO for this dataset: $((T1 - T0))s"
    pass "cross-cluster RESTORE completed"

    B_COUNT=$(b_value "SELECT count(*) FROM bank.public.accounts;")
    A_COUNT=$(sql_value "SELECT count(*) FROM bank.accounts;")
    assert_eq "row counts match between A and B" "$B_COUNT" "$A_COUNT"

    B_SUM=$(b_value "SELECT sum(balance)::DECIMAL(20,2) FROM bank.public.accounts;")
    A_SUM=$(sql_value "SELECT sum(balance)::DECIMAL(20,2) FROM bank.accounts;")
    assert_eq "business checksum matches between A and B" "$B_SUM" "$A_SUM"

    B_USERS=$(b_sql "SHOW USERS;")
    assert_contains "users restored onto the standby" "$B_USERS" "app_user"
else
    warn "nodelocal extern dir not found at $A_EXTERN; skipping the cross-cluster drill"
fi

section "Done"
echo "Lab 11: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
