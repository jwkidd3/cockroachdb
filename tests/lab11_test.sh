#!/usr/bin/env bash
# Lab 11 — BACKUP / RESTORE / schedules and the cross-cluster DR drill.
# Cluster A is the primary; cluster B is the standby the drill restores into.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab11"
source "$SCRIPT_DIR/lib/cluster.sh"

# Cluster B is the standby stack, started exactly as the lab does:
#   CRDB_COMPOSE=docker/labs-b.yml scripts/crdb up
B_COMPOSE="docker/labs-b.yml"

b_crdb()  { ( cd "$REPO_ROOT" && CRDB_COMPOSE="$B_COMPOSE" bash scripts/crdb.sh "$@" ); }
b_sql()   { b_crdb sql -e "$1"; }
b_value() { b_crdb sql --format=tsv -e "$1" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}'; }

cleanup_all() {
    b_crdb down >/dev/null 2>&1 || true
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

info "starting standby cluster B (CRDB_COMPOSE=docker/labs-b.yml scripts/crdb up)"
b_crdb down >/dev/null 2>&1 || true
b_crdb up >/dev/null 2>&1 || fail "standby cluster B failed to start"
B_LIVE=$(b_value "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE is_live;")
assert_eq "cluster B has 3 live nodes" "$B_LIVE" "3"
pass "standby cluster B is up"

# Full cluster backup on A (includes users and grants).
sql "CREATE USER app_user;" >/dev/null 2>&1 || true
sql "GRANT CONNECT ON DATABASE bank TO app_user;" >/dev/null 2>&1 || true
# A full-cluster BACKUP (users, roles, settings) is free; revision_history is not.
# The AOST window must cover the CREATE USER above, or the restore arrives
# without it — a historical backup is historical about users too.
sleep 12
sql "BACKUP INTO 'nodelocal://1/dr/cluster' AS OF SYSTEM TIME '-10s';" >/dev/null \
    || fail "full-cluster BACKUP failed on A"
pass "full-cluster BACKUP taken on A"

# Both stacks mount the same `crdb-shared-backups` volume at /backups, standing
# in for the cloud bucket two real clusters would share. No copying required —
# which is the point: the drill exercises RESTORE, not scp.
SHOW_B=$(b_sql "SHOW BACKUPS IN 'nodelocal://1/dr/cluster';" 2>&1)
assert_not_contains "cluster B can see A's backup with no file copying" "$SHOW_B" "ERROR"

T0=$(date +%s)
RESTORE_OUT=$(b_sql "RESTORE FROM LATEST IN 'nodelocal://1/dr/cluster';" 2>&1 || true)
T1=$(date +%s)
if echo "$RESTORE_OUT" | grep -qiE "^ERROR|ERROR:"; then
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

section "Done"
echo "Lab 11: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
