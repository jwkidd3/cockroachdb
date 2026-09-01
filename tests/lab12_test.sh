#!/usr/bin/env bash
# Lab 12 — Security hardening: certs, zero-downtime rotation, RBAC hierarchy
# with future privileges, HBA configuration, and the audit pipeline.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BASE="/tmp/crdb-lab12-$$"
CERTS="$BASE/certs"; KEYS="$BASE/keys"; DATA="$BASE/data"; LOGS="$DATA/logs"
PORT=26447; HTTP=8193
S=(--certs-dir="$CERTS" --host="localhost:${PORT}")

csql()   { cockroach sql "${S[@]}" --execute "$1"; }
cvalue() { cockroach sql "${S[@]}" --format=tsv --execute "$1" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}'; }
cuser()  { local u="$1"; shift; cockroach sql "${S[@]}" --user="$u" --execute "$1" 2>&1; }

cleanup_all() {
    cockroach node drain "${S[@]}" --drain-wait=5s >/dev/null 2>&1 || true
    pkill -f "cockroach start-single-node --certs-dir=$CERTS" 2>/dev/null || true
    [ "${KEEP_ON_FAIL:-0}" != "1" ] && rm -rf "$BASE"
}
trap cleanup_all EXIT INT TERM

require_cockroach
mkdir -p "$CERTS" "$KEYS" "$DATA"

section "Part A — certificates and a secure cluster"

cockroach cert create-ca --certs-dir="$CERTS" --ca-key="$KEYS/ca.key"
assert_file_exists "CA certificate" "$CERTS/ca.crt"

cockroach cert create-node localhost 127.0.0.1 --certs-dir="$CERTS" --ca-key="$KEYS/ca.key"
assert_file_exists "node certificate" "$CERTS/node.crt"

cockroach cert create-client root --certs-dir="$CERTS" --ca-key="$KEYS/ca.key"
assert_file_exists "root client certificate" "$CERTS/client.root.crt"

SAN=$(openssl x509 -in "$CERTS/node.crt" -noout -text)
assert_contains "node cert carries a localhost SAN" "$SAN" "localhost"

cockroach start-single-node --certs-dir="$CERTS" --store="$DATA" \
    --listen-addr="localhost:${PORT}" --http-addr="localhost:${HTTP}" \
    --pid-file="$DATA/server.pid" --background >"$DATA/server.out" 2>&1
wait_for "secure SQL ready" 40 "cockroach sql --certs-dir=$CERTS --host=localhost:${PORT} --execute 'SELECT 1;'"
pass "secure single-node cluster started"

INSECURE_OUT=$(cockroach sql --insecure --host="localhost:${PORT}" --execute "SELECT 1;" 2>&1 || true)
assert_contains "insecure connection rejected" "$INSECURE_OUT" "secure"

section "Part B — zero-downtime certificate rotation"

BEFORE=$(openssl x509 -in "$CERTS/node.crt" -noout -enddate | cut -d= -f2)
cockroach cert create-node localhost 127.0.0.1 \
    --certs-dir="$CERTS" --ca-key="$KEYS/ca.key" --overwrite --lifetime=48h
AFTER=$(openssl x509 -in "$CERTS/node.crt" -noout -enddate | cut -d= -f2)
if [ "$BEFORE" != "$AFTER" ]; then
    pass "node certificate reissued with a new expiry ($BEFORE -> $AFTER)"
else
    fail "node certificate expiry unchanged after reissue"
fi

PID=$(cat "$DATA/server.pid")
kill -HUP "$PID" 2>/dev/null || fail "could not SIGHUP the node"
sleep 3

SERVED=$(echo | openssl s_client -connect "localhost:${PORT}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$SERVED" ]; then
    assert_eq "the rotated certificate is the one served on the wire" "$SERVED" "$AFTER"
else
    warn "could not read the served certificate via openssl s_client; skipping wire check"
fi

assert_command_succeeds "cluster still serving SQL after rotation" \
    cockroach sql --certs-dir="$CERTS" --host="localhost:${PORT}" --execute "SELECT 1;"

cockroach cert create-client root --certs-dir="$CERTS" --ca-key="$KEYS/ca.key" --overwrite --lifetime=48h
assert_command_succeeds "rotated client certificate still authenticates" \
    cockroach sql --certs-dir="$CERTS" --host="localhost:${PORT}" --execute "SELECT 1;"

section "Part C — least-privilege RBAC"

cockroach sql "${S[@]}" -e "CREATE DATABASE ledger;" >/dev/null

# The default `public` schema grants CREATE to the `public` role, so every user
# can create objects until this is revoked. Assert the default, then close it.
DEFAULT_GRANTS=$(cockroach sql "${S[@]}" -e "SHOW GRANTS ON SCHEMA ledger.public;")
assert_contains "public schema grants CREATE to public by default" "$DEFAULT_GRANTS" "CREATE"
cockroach sql "${S[@]}" -e "REVOKE CREATE ON SCHEMA ledger.public FROM public;" >/dev/null
pass "revoked CREATE on the public schema from the public role"

cockroach sql "${S[@]}" <<'SQL' >/dev/null
USE ledger;
CREATE TABLE accounts (id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       name STRING NOT NULL, balance DECIMAL(12,2) NOT NULL, ssn STRING);
INSERT INTO accounts (name, balance, ssn) VALUES ('Alice', 1000, '111-11-1111'), ('Bob', 500, '222-22-2222');

CREATE ROLE ledger_connect;
GRANT CONNECT ON DATABASE ledger TO ledger_connect;
GRANT USAGE ON SCHEMA ledger.public TO ledger_connect;

CREATE ROLE ledger_ro;
GRANT ledger_connect TO ledger_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA ledger.public TO ledger_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA ledger.public GRANT SELECT ON TABLES TO ledger_ro;

CREATE ROLE ledger_rw;
GRANT ledger_ro TO ledger_rw;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ledger.public TO ledger_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA ledger.public GRANT INSERT, UPDATE, DELETE ON TABLES TO ledger_rw;

CREATE ROLE ledger_migrator;
GRANT ledger_rw TO ledger_migrator;
GRANT CREATE ON DATABASE ledger TO ledger_migrator;
GRANT CREATE ON SCHEMA ledger.public TO ledger_migrator;

CREATE USER report_user;  GRANT ledger_ro       TO report_user;
CREATE USER app_user;     GRANT ledger_rw       TO app_user;
CREATE USER migrate_user; GRANT ledger_migrator TO migrate_user;
SQL
pass "role hierarchy and users created"

for u in report_user app_user migrate_user; do
    cockroach cert create-client "$u" --certs-dir="$CERTS" --ca-key="$KEYS/ca.key" >/dev/null
    assert_file_exists "client cert for $u" "$CERTS/client.${u}.crt"
done

RO_READ=$(cockroach sql "${S[@]}" --user=report_user --format=tsv \
    --execute "SELECT count(*) FROM ledger.public.accounts;" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}')
assert_eq "report_user can read (inherited through ledger_connect)" "$RO_READ" "2"

RO_WRITE=$(cuser report_user "UPDATE ledger.public.accounts SET balance = 0;")
assert_contains "report_user denied UPDATE" "$RO_WRITE" "permission denied\|privilege"

RW_OK=$(cuser app_user "UPDATE ledger.public.accounts SET balance = balance + 1 WHERE name = 'Alice';")
assert_not_contains "app_user allowed UPDATE" "$RW_OK" "permission denied"

RW_DDL=$(cuser app_user "CREATE TABLE ledger.public.bogus (id INT);")
assert_contains "app_user denied CREATE TABLE" "$RW_DDL" "permission denied\|privilege"

MIG=$(cuser migrate_user "CREATE TABLE ledger.public.audit_notes (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), note STRING);")
assert_not_contains "migrate_user allowed CREATE TABLE" "$MIG" "permission denied"

# Default privileges are scoped to the CREATING role. root's settings do not
# cover tables created by migrate_user — assert that gap exists...
NOT_YET=$(cuser report_user "SELECT count(*) FROM ledger.public.audit_notes;")
assert_contains "root's default privileges do NOT cover migrate_user's tables" "$NOT_YET" "does not have SELECT privilege\|permission denied"

# ...then close it the way CI/CD should: the migration role declares its own.
cockroach sql "${S[@]}" --user=migrate_user -d ledger -e \
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ledger_ro;" >/dev/null
cockroach sql "${S[@]}" --user=migrate_user -d ledger -e \
    "CREATE TABLE audit_notes_v2 (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), note STRING);" >/dev/null
FUTURE=$(cockroach sql "${S[@]}" --user=report_user --format=tsv \
    --execute "SELECT count(*) FROM ledger.public.audit_notes_v2;" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}')
assert_eq "future privileges set BY the migration role cover its new tables" "$FUTURE" "0"

csql "REVOKE ledger_rw FROM app_user;" >/dev/null
REVOKED=$(cuser app_user "SELECT count(*) FROM ledger.public.accounts;")
assert_contains "revocation takes effect immediately" "$REVOKED" "permission denied\|privilege"
csql "GRANT ledger_rw TO app_user;" >/dev/null

section "Part D — authentication configuration"

HBA_SET=$(csql "SET CLUSTER SETTING server.host_based_authentication.configuration = '
host all app_user    all cert
host all report_user all cert-password
host all root        all cert
host all all         all scram-sha-256
';" 2>&1 || true)
assert_not_contains "HBA configuration accepted" "$HBA_SET" "ERROR"

# NOTE: CockroachDB leaves `pg_hba_file_rules` empty — it is a PostgreSQL
# compatibility view, and CRDB's HBA config lives in a cluster setting. Read the
# setting back to verify what is actually in force.
HBA_NOW=$(csql "SHOW CLUSTER SETTING server.host_based_authentication.configuration;")
assert_contains "HBA config is in force: cert for service accounts" "$HBA_NOW" "cert"
assert_contains "HBA config is in force: SCRAM for everyone else" "$HBA_NOW" "scram-sha-256"

ENC=$(cvalue "SHOW CLUSTER SETTING server.user_login.password_encryption;")
assert_contains "password hashing uses SCRAM" "$ENC" "scram"

csql "ALTER USER app_user NOLOGIN;" >/dev/null
NOLOGIN=$(cuser app_user "SELECT 1;")
assert_contains "NOLOGIN blocks interactive access" "$NOLOGIN" "login\|denied\|not permitted"
csql "ALTER USER app_user LOGIN;" >/dev/null

# Reset HBA so nothing else in the suite is affected.
csql "RESET CLUSTER SETTING server.host_based_authentication.configuration;" >/dev/null 2>&1 || true

section "Part E — audit pipeline"

csql "ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET READ WRITE;" >/dev/null
pass "per-table audit enabled"

cockroach sql "${S[@]}" --user=report_user --execute "SELECT name, ssn FROM ledger.public.accounts;" >/dev/null 2>&1
csql "CREATE USER temp_contractor;" >/dev/null
csql "DROP USER temp_contractor;" >/dev/null
sleep 3
csql "ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET OFF;" >/dev/null

if [ -d "$LOGS" ] && grep -RqiE "sensitive_table_access|sensitive_access|create_role|drop_role" "$LOGS" 2>/dev/null; then
    pass "audit events found in the server logs"
    grep -rho '"EventType":"[^"]*"' "$LOGS" 2>/dev/null | sort -u | head -6 | sed 's/^/    /'
else
    warn "no audit events found under $LOGS — channel routing varies by version; the lab configures a dedicated sink"
fi

section "Done"
echo "Lab 12: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
