#!/usr/bin/env bash
# Lab 12 — Security hardening: certs, zero-downtime rotation, RBAC hierarchy
# with future privileges, HBA configuration, and the audit pipeline.
#
# Everything runs against the secure compose stack the lab uses:
#   export CRDB_COMPOSE=docker/labs-secure.yml

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab12"
CRDB_COMPOSE="docker/labs-secure.yml"
source "$SCRIPT_DIR/lib/cluster.sh"

DC=(docker compose -f "$REPO_ROOT/docker/labs-secure.yml")
CERT_VOL="crdb-labs-secure_crdbs-certs"
LAB12_DIR="$REPO_ROOT/lab12"

# The cockroach image has no openssl; the lab reaches for a container that does.
openssl_on_certs() { docker run --rm -v "${CERT_VOL}:/certs" postgres:16 openssl "$@" 2>/dev/null; }
cert_exists() { "${DC[@]}" exec -T crdbs1 test -f "/certs/$1" >/dev/null 2>&1; }

csql()   { sql "$1"; }
cvalue() { sql_value "$1"; }
cuser()  { local u="$1"; shift; crdb sql --user="$u" -e "$1" 2>&1; }

cleanup_all() {
    "${DC[@]}" -f "$REPO_ROOT/docker/labs-secure.logging.yml" down -v >/dev/null 2>&1 || true
    stop_cluster
    [ "${KEEP_ON_FAIL:-0}" != "1" ] && rm -rf "$LAB12_DIR"
    return 0
}
trap cleanup_all EXIT INT TERM

section "Part A — certificates and a secure cluster"

# `scripts/crdb up` on this stack runs the one-shot certs service first.
start_cluster

CERT_LIST=$(crdb_run cert list --certs-dir=/certs 2>&1)
assert_contains "cert list shows the CA" "$CERT_LIST" "ca.crt"
assert_contains "cert list shows the node certificate" "$CERT_LIST" "node.crt"
assert_contains "cert list shows the root client certificate" "$CERT_LIST" "client.root.crt"

for f in ca.crt node.crt node.key client.root.crt; do
    if cert_exists "$f"; then pass "certificate volume holds $f"; else fail "missing /certs/$f"; fi
done

SAN=$(openssl_on_certs x509 -in /certs/node.crt -noout -text)
for name in crdbs1 localhost 127.0.0.1; do
    assert_contains "node cert carries the $name SAN" "$SAN" "$name"
done

OK=$(sql_value "SELECT 'secure_ok';")
assert_eq "certificate-authenticated connection works" "$OK" "secure_ok"

INSECURE_OUT=$("${DC[@]}" exec -T crdbs1 ./cockroach sql --insecure --host=crdbs1 -e "SELECT 1;" 2>&1 || true)
assert_contains "insecure connection rejected" "$INSECURE_OUT" "secure"

section "Part B — zero-downtime certificate rotation"

BEFORE=$(openssl_on_certs x509 -in /certs/node.crt -noout -enddate | cut -d= -f2)

# The SAN list must keep every name the node is reached by. Dropping crdbs1 here
# would break `scripts/crdb sql`, which connects with --host=crdbs1.
crdb_run cert create-node crdbs1 localhost 127.0.0.1 \
    --certs-dir=/certs --ca-key=/certs/ca.key --overwrite --lifetime=48h >/dev/null 2>&1 \
    || fail "node certificate reissue failed"

AFTER=$(openssl_on_certs x509 -in /certs/node.crt -noout -enddate | cut -d= -f2)
assert_not_eq "node certificate reissued with a new expiry" "$AFTER" "$BEFORE"

NEW_SAN=$(openssl_on_certs x509 -in /certs/node.crt -noout -text)
assert_contains "the rotated cert still carries the crdbs1 SAN" "$NEW_SAN" "crdbs1"

# SIGHUP reloads certificates without a restart. This only works because the
# compose file runs the binary as PID 1 — through the image's cockroach.sh
# wrapper the signal is swallowed and the old cert keeps being served.
PID1=$("${DC[@]}" exec -T crdbs1 cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')
assert_contains "cockroach is PID 1, so signals reach it" "$PID1" "/cockroach/cockroach"

"${DC[@]}" kill -s HUP crdbs1 >/dev/null 2>&1 || fail "could not SIGHUP crdbs1"
sleep 3

SERVED=$(docker run --rm --network crdb-labs-secure_default postgres:16 \
    bash -c "echo | openssl s_client -connect crdbs1:26257 2>/dev/null | openssl x509 -noout -enddate" 2>/dev/null | cut -d= -f2)
if [ -n "$SERVED" ]; then
    assert_eq "the rotated certificate is the one served on the wire" "$SERVED" "$AFTER"
else
    warn "could not read the served certificate; skipping the wire check"
fi

STILL=$(sql_value "SELECT 'still_connected';")
assert_eq "cluster still serving SQL after rotation" "$STILL" "still_connected"

crdb_run cert create-client root --certs-dir=/certs --ca-key=/certs/ca.key \
    --overwrite --lifetime=48h >/dev/null 2>&1 || fail "client cert reissue failed"
ROTATED=$(sql_value "SELECT 'client_rotated';")
assert_eq "rotated client certificate still authenticates" "$ROTATED" "client_rotated"

section "Part C — least-privilege RBAC"

sql "CREATE DATABASE ledger;" >/dev/null

# A new database's `public` schema grants CREATE to the `public` role, so every
# user can create objects until this is revoked. Assert the default, then close it.
DEFAULT_GRANTS=$(sql "SHOW GRANTS ON SCHEMA ledger.public;")
assert_contains "public schema grants CREATE to public by default" "$DEFAULT_GRANTS" "CREATE"
sql "REVOKE CREATE ON SCHEMA ledger.public FROM public;" >/dev/null
pass "revoked CREATE on the public schema from the public role"

sql_script <<'SQL' >/dev/null
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

# Each human/service account gets its own client certificate.
for u in report_user app_user migrate_user; do
    crdb_run cert create-client "$u" --certs-dir=/certs --ca-key=/certs/ca.key >/dev/null 2>&1
    if cert_exists "client.${u}.crt"; then
        pass "client cert for $u"
    else
        fail "no client certificate generated for $u"
    fi
done

RO_READ=$(crdb sql --user=report_user --format=tsv -e \
    "SELECT count(*) FROM ledger.public.accounts;" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}')
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
assert_contains "root's default privileges do NOT cover migrate_user's tables" "$NOT_YET" \
    "does not have SELECT privilege\|permission denied"

# ...then close it the way CI/CD should: the migration role declares its own.
crdb sql --user=migrate_user -d ledger -e \
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ledger_ro;" >/dev/null
crdb sql --user=migrate_user -d ledger -e \
    "CREATE TABLE audit_notes_v2 (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), note STRING);" >/dev/null
FUTURE=$(crdb sql --user=report_user --format=tsv -e \
    "SELECT count(*) FROM ledger.public.audit_notes_v2;" 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}')
assert_eq "future privileges set BY the migration role cover its new tables" "$FUTURE" "0"

sql "REVOKE ledger_rw FROM app_user;" >/dev/null
REVOKED=$(cuser app_user "SELECT count(*) FROM ledger.public.accounts;")
assert_contains "revocation takes effect immediately" "$REVOKED" "permission denied\|privilege"
sql "GRANT ledger_rw TO app_user;" >/dev/null

section "Part D — authentication configuration"

HBA_SET=$(sql "SET CLUSTER SETTING server.host_based_authentication.configuration = '
host all app_user    all cert
host all report_user all cert-password
host all root        all cert
host all all         all scram-sha-256
';" 2>&1 || true)
assert_not_contains "HBA configuration accepted" "$HBA_SET" "ERROR"

# CockroachDB leaves `pg_hba_file_rules` empty — it is a PostgreSQL
# compatibility view, and CRDB's HBA config lives in a cluster setting. Read the
# setting back to verify what is actually in force.
HBA_NOW=$(sql "SHOW CLUSTER SETTING server.host_based_authentication.configuration;")
assert_contains "HBA config is in force: cert for service accounts" "$HBA_NOW" "cert"
assert_contains "HBA config is in force: SCRAM for everyone else" "$HBA_NOW" "scram-sha-256"

ENC=$(sql_value "SHOW CLUSTER SETTING server.user_login.password_encryption;")
assert_contains "password hashing uses SCRAM" "$ENC" "scram"

sql "ALTER USER app_user NOLOGIN;" >/dev/null
NOLOGIN=$(cuser app_user "SELECT 1;")
assert_contains "NOLOGIN blocks interactive access" "$NOLOGIN" "login\|denied\|not permitted"
sql "ALTER USER app_user LOGIN;" >/dev/null

sql "RESET CLUSTER SETTING server.host_based_authentication.configuration;" >/dev/null 2>&1 || true

section "Part E — audit pipeline"

# The lab has students write lab12/logs.yaml and restart with the logging
# overlay. mkdir first so the directory belongs to the user, not to Docker.
mkdir -p "$LAB12_DIR"
cat > "$LAB12_DIR/logs.yaml" <<'YAML'
file-defaults:
  dir: /lab12/logs
sinks:
  file-groups:
    security:
      channels: [SENSITIVE_ACCESS, USER_ADMIN, PRIVILEGES]
      filter: INFO
      auditable: true
      buffered-writes: false
  stderr:
    filter: NONE
YAML

CHECK=$(crdb_run debug check-log-config --log-config-file=/lab12/logs.yaml 2>&1 || true)
assert_not_contains "the log config is valid" "$CHECK" "ERROR"

"${DC[@]}" -f "$REPO_ROOT/docker/labs-secure.logging.yml" up -d crdbs1 >/dev/null 2>&1 \
    || fail "restart with the logging overlay failed"
wait_for "secure node back with the audit sink" 60 "sql_quiet 'SELECT 1;'"
pass "node restarted with the security log sink"

sql "ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET READ WRITE;" >/dev/null
pass "per-table audit enabled"

crdb sql --user=report_user -e "SELECT name, ssn FROM ledger.public.accounts;" >/dev/null 2>&1
crdb sql --user=app_user -e "UPDATE ledger.public.accounts SET balance = balance + 5 WHERE name = 'Bob';" >/dev/null 2>&1
sql "CREATE USER temp_contractor;" >/dev/null
sql "DROP USER temp_contractor;" >/dev/null
sleep 4
sql "ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET OFF;" >/dev/null

if ls "$LAB12_DIR"/logs/cockroach-security*.log >/dev/null 2>&1; then
    pass "the security sink wrote its own log file under lab12/logs/"
    EVENTS=$(grep -ho '"EventType":"[^"]*"' "$LAB12_DIR"/logs/cockroach-security*.log 2>/dev/null | sort -u)
    assert_contains "sensitive table access was audited" "$EVENTS" "sensitive_table_access"
    assert_contains "user administration was audited" "$EVENTS" "create_role\|drop_role"
    echo "$EVENTS" | head -6 | sed 's/^/    /'
else
    fail "no cockroach-security*.log under $LAB12_DIR/logs — the audit sink did not engage"
fi

section "Done"
echo "Lab 12: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
