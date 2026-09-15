#!/usr/bin/env bash
# Lab 16 — the on-call drill. Drives scripts/incident exactly as the lab does:
# start each incident, prove the symptom the lab says to look for is really there,
# apply the fix the lab prescribes (DDL, a deploy to loop.sh, a runbook edit, a job
# command), and prove the recovery signal the lab says to verify.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab16"
source "$SCRIPT_DIR/lib/cluster.sh"

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INCIDENT="$REPO/scripts/incident"
export ONCALL_DIR="${ONCALL_DIR:-/tmp/oncall}"

cleanup() { bash "$INCIDENT" stop all >/dev/null 2>&1 || true; stop_cluster; }
trap cleanup EXIT INT TERM

section "Setup"
start_cluster 3
bash "$INCIDENT" status >/dev/null && pass "scripts/incident status runs"

# ---------------------------------------------------------------- incident 1
section "Incident 1 — hot range on a SERIAL key"
bash "$INCIDENT" start 1 >/dev/null
sleep 30
RANGES=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE oncall.events];")
LEASES=$(sql_value "SELECT count(DISTINCT lease_holder) FROM [SHOW RANGES FROM TABLE oncall.events WITH DETAILS];")
assert_eq "symptom: one leaseholder carries the table" "$LEASES" "1"
HOT=$(curl -s -X POST "http://localhost:${BASE_HTTP_PORT:-8080}/_status/v2/hotranges" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(max((r['writesPerSecond'] for r in d.get('ranges',[]) if r.get('tableName')=='events'), default=0)))")
assert_ge "symptom: the events range is hot on the Hot Ranges API (writes/s)" "${HOT:-0}" "1000"
sql_quiet "ALTER TABLE oncall.events ALTER PRIMARY KEY USING COLUMNS (id) USING HASH WITH (bucket_count = 16);" \
  || fail "online primary-key change failed"
pass "fix: primary key changed to hash-sharded under load"
wait_for "writes spread across leaseholders" 120 \
  "[ \"\$(sql_value \"SELECT count(DISTINCT lease_holder) FROM [SHOW RANGES FROM TABLE oncall.events WITH DETAILS];\")\" = '3' ]"
RANGES2=$(sql_value "SELECT count(*) FROM [SHOW RANGES FROM TABLE oncall.events];")
assert_ge "recovery: the table is now many ranges" "$RANGES2" "8"
bash "$INCIDENT" stop 1 >/dev/null && pass "incident 1 torn down"

# ---------------------------------------------------------------- incident 2
section "Incident 2 — sixteen writers on one row"
bash "$INCIDENT" start 2 >/dev/null
sleep 30
EVENTS=$(sql_value "SELECT count(*) FROM crdb_internal.transaction_contention_events WHERE collection_ts > now() - INTERVAL '1 minute';")
assert_ge "symptom: contention events on the hit counter" "${EVENTS:-0}" "50"
MEAN_OLD=$(sql_value "SELECT round((statistics->'statistics'->'svcLat'->>'mean')::FLOAT * 1000, 1) FROM crdb_internal.statement_statistics WHERE metadata->>'query' LIKE 'UPDATE oncall.page_hits SET%' ORDER BY (statistics->'statistics'->>'cnt')::INT DESC LIMIT 1;")
info "single-row UPDATE mean latency: ${MEAN_OLD} ms"
sql_quiet "CREATE TABLE oncall.page_hit_shards (page STRING, shard INT2, hits INT NOT NULL DEFAULT 0, PRIMARY KEY (page, shard)); INSERT INTO oncall.page_hit_shards (page, shard) SELECT '/home', g FROM generate_series(0, 15) g;" \
  || fail "could not create the sharded table"
# the deploy: change the statement the application runs
python3 - "$ONCALL_DIR/2/loop.sh" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
old="UPDATE oncall.page_hits SET hits = hits + 1 WHERE page = '/home';"
new="UPDATE oncall.page_hit_shards SET hits = hits + 1 WHERE page = '/home' AND shard = $((RANDOM % 16));"
assert old in s; open(p,'w').write(s.replace(old,new))
PY
pass "fix: application deployed with a client-chosen shard"
wait_for "the new statement is executing" 60 \
  "[ \"\$(sql_value \"SELECT sum(hits) FROM oncall.page_hit_shards;\")\" -gt 100 ]"
sleep 30
EVENTS2=$(sql_value "SELECT count(*) FROM crdb_internal.transaction_contention_events WHERE collection_ts > now() - INTERVAL '20 seconds';")
assert_ge "recovery: contention events in the last 20 s are few" "$((50 - ${EVENTS2:-0}))" "1"
MEAN_NEW=$(sql_value "SELECT round((statistics->'statistics'->'svcLat'->>'mean')::FLOAT * 1000, 1) FROM crdb_internal.statement_statistics WHERE metadata->>'query' LIKE 'UPDATE oncall.page_hit_shards%' ORDER BY (statistics->'statistics'->>'cnt')::INT DESC LIMIT 1;")
info "sharded UPDATE mean latency: ${MEAN_NEW} ms (was ${MEAN_OLD} ms)"
FASTER=$(python3 -c "print(1 if float('${MEAN_NEW:-99}') < float('${MEAN_OLD:-0}') else 0)")
assert_eq "recovery: sharded statement is faster than the contended one" "$FASTER" "1"
bash "$INCIDENT" stop 2 >/dev/null && pass "incident 2 torn down"

# ---------------------------------------------------------------- incident 3
section "Incident 3 — node rebuilt with a locality typo"
bash "$INCIDENT" start 3 >/dev/null
wait_for "node 4 advertises the typo" 90 \
  "sql_value \"SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality LIKE '%us-esat1%' AND is_live;\" | grep -q '^1$'"
pass "symptom: a live node advertises region=us-esat1"
wait_for "the replication report flags the pinned table" 150 \
  "[ \"\$(sql_value \"SELECT count(*) FROM system.replication_constraint_stats WHERE violating_ranges > 0;\")\" -ge 1 ]"
pass "symptom: system.replication_constraint_stats shows a violation"
grep -q 'us-esat1' "$ONCALL_DIR/3/start-node4.sh" && pass "the runbook contains the typo"
sed -i.bak 's/us-esat1/us-east1/' "$ONCALL_DIR/3/start-node4.sh" && bash "$ONCALL_DIR/3/start-node4.sh" >/dev/null
pass "fix: runbook corrected and node 4 restarted"
wait_for "node 4 advertises us-east1" 90 \
  "sql_value \"SELECT count(*) FROM crdb_internal.gossip_nodes WHERE locality = 'region=us-east1,zone=d' AND is_live;\" | grep -q '^1$'"
N4=$(sql_value "SELECT node_id FROM crdb_internal.gossip_nodes WHERE locality = 'region=us-east1,zone=d' AND is_live;")
wait_for "lease moves to the us-east1 node" 180 \
  "[ \"\$(sql_value \"SELECT lease_holder FROM [SHOW RANGES FROM TABLE oncall.pins WITH DETAILS];\")\" = '$N4' ]"
pass "recovery: pins is led from node $N4"
wait_for "replication report clears" 180 \
  "[ \"\$(sql_value \"SELECT count(*) FROM system.replication_constraint_stats WHERE violating_ranges > 0;\")\" = '0' ]"
pass "recovery: no violating ranges"
bash "$INCIDENT" stop 3 >/dev/null && pass "incident 3 torn down"

# ---------------------------------------------------------------- incident 4
section "Incident 4 — paused changefeed holding GC back"
bash "$INCIDENT" start 4 >/dev/null
SIZE0=$(sql_value "SELECT round(range_size_mb) FROM [SHOW RANGES FROM TABLE oncall.sessions WITH DETAILS];")
sleep 60
SIZE1=$(sql_value "SELECT round(range_size_mb) FROM [SHOW RANGES FROM TABLE oncall.sessions WITH DETAILS];")
assert_gt "symptom: the range grows while the row count does not (${SIZE0} -> ${SIZE1} MB)" "${SIZE1%.*}" "${SIZE0%.*}"
PAUSED=$(sql_value "SELECT count(*) FROM [SHOW CHANGEFEED JOBS] WHERE status = 'paused';")
assert_eq "symptom: a paused changefeed" "$PAUSED" "1"
PTS=$(sql_value "SELECT count(*) FROM crdb_internal.kv_protected_ts_records;")
assert_ge "symptom: a protected timestamp record pins history" "$PTS" "1"
JOB=$(sql_value "SELECT job_id FROM [SHOW CHANGEFEED JOBS] WHERE status = 'paused';")
sql_quiet "CANCEL JOB $JOB;" || fail "CANCEL JOB failed"
pass "fix: job cancelled"
wait_for "protected record released" 30 \
  "[ \"\$(sql_value \"SELECT count(*) FROM crdb_internal.kv_protected_ts_records;\")\" = '0' ]"
PEAK=${SIZE1%.*}
RECOVERED=0
for i in $(seq 1 16); do
  sql_quiet "SELECT crdb_internal.kv_enqueue_replica(range_id, 'mvccGC', true) FROM [SHOW RANGES FROM TABLE oncall.sessions];"
  sleep 20
  S=$(sql_value "SELECT round(range_size_mb) FROM [SHOW RANGES FROM TABLE oncall.sessions WITH DETAILS];"); S=${S%.*}
  [ "$S" -gt "$PEAK" ] && PEAK=$S
  if [ "$S" -lt $(( PEAK * 6 / 10 )) ]; then RECOVERED=1; info "range shrank to ${S} MB (peak ${PEAK} MB) after $((i*20)) s"; break; fi
done
assert_eq "recovery: GC reclaims the pinned history once the job is gone" "$RECOVERED" "1"
bash "$INCIDENT" stop 4 >/dev/null && pass "incident 4 torn down"

# ---------------------------------------------------------------- incident 5
section "Incident 5 — rolling restart under load (optional part)"
bash "$INCIDENT" start 5 >/dev/null
wait_for "the order service is reporting" 60 "docker logs oncall-app-5 2>&1 | grep -qE '^[0-9:]+ +[0-9.]+s'"
crdb upgrade 2 "${CRDB_VERSION:-v23.2.5}" >/dev/null 2>&1 || fail "scripts/crdb upgrade 2 failed"
wait_live 3 120 || fail "node 2 did not rejoin"
pass "node 2 restarted on its image via scripts/crdb upgrade; cluster back to 3 live"
sleep 25
LINES=$(docker logs oncall-app-5 2>&1 | grep -cE '^[0-9:]+ +[0-9.]+s')
assert_ge "the application kept reporting through the restart" "$LINES" "2"
bash "$INCIDENT" stop 5 >/dev/null && pass "incident 5 torn down"

section "Done"
echo "Lab 16: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
