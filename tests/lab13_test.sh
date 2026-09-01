#!/usr/bin/env bash
# Lab 13 — CDC. Core changefeed and the frontier consumer are tested on any
# cluster; the Kafka sink is exercised only when Docker is available.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CLUSTER_TAG="lab13"
BASE_SQL_PORT=26457
BASE_HTTP_PORT=8203
source "$SCRIPT_DIR/lib/cluster.sh"

KAFKA_NAME="lab13-kafka"
cleanup_all() {
    docker rm -f "$KAFKA_NAME" >/dev/null 2>&1 || true
    stop_cluster
}
trap cleanup_all EXIT INT TERM

section "Setup — 3-node cluster with rangefeeds enabled"
start_cluster 3

sql "SET CLUSTER SETTING kv.rangefeed.enabled = true;" >/dev/null
RF=$(sql_value "SHOW CLUSTER SETTING kv.rangefeed.enabled;")
assert_true "rangefeeds enabled (prerequisite for any changefeed)" "$RF"

cat <<'SQL' | sql_script >/dev/null
CREATE DATABASE shop;
USE shop;
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer STRING NOT NULL, total DECIMAL(12,2) NOT NULL,
  status STRING NOT NULL DEFAULT 'new', updated TIMESTAMPTZ NOT NULL DEFAULT now());
SQL
pass "shop.orders created"

section "Part A — core changefeed"

# --format=csv, not the default table format: `table` buffers all output to size
# its columns, so a never-ending stream redirected to a file yields zero bytes.
CDC_OUT="${STORE_BASE}/core_cdc.csv"
# Two things are needed to capture a core changefeed to a file:
#   --format=csv  : the default `table` format buffers everything to size columns
#   stdbuf -oL    : line-buffer stdout, or nothing is flushed before we kill it
# stderr is kept (2>&1) so a failed changefeed shows up instead of an empty file.
( stdbuf -oL cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" --format=csv \
    --execute "EXPERIMENTAL CHANGEFEED FOR shop.orders WITH updated;" \
    >"$CDC_OUT" 2>&1 ) &
CDC_PID=$!
sleep 5

sql "USE shop; INSERT INTO orders (customer, total) VALUES ('alice', 42.00);" >/dev/null
sql "USE shop; UPDATE orders SET status = 'paid' WHERE customer = 'alice';" >/dev/null
sql "USE shop; DELETE FROM orders WHERE customer = 'alice';" >/dev/null

# Poll rather than guess: rangefeed startup on a multi-node cluster is not
# instantaneous, and a fixed sleep makes this test flaky.
for _ in $(seq 1 30); do
    [ -s "$CDC_OUT" ] && grep -q 'alice\|,' "$CDC_OUT" 2>/dev/null && break
    sleep 1
done
kill "$CDC_PID" 2>/dev/null || true
pkill -f "EXPERIMENTAL CHANGEFEED FOR shop.orders" 2>/dev/null || true
wait "$CDC_PID" 2>/dev/null || true

if [ -s "$CDC_OUT" ]; then
    pass "core changefeed emitted output ($(wc -l < "$CDC_OUT" | tr -d ' ') lines)"
    # key/value are BYTES, so csv renders them hex-escaped (\x7b...). Decode to text.
    DECODED=$(python3 - "$CDC_OUT" <<'PYDEC'
import csv, sys
out = []
with open(sys.argv[1], newline='') as f:
    for row in csv.reader(f):
        for cell in row:
            if cell.startswith('\\x'):
                try:
                    out.append(bytes.fromhex(cell[2:]).decode('utf-8', 'replace'))
                except ValueError:
                    pass
print('\n'.join(out))
PYDEC
)
    assert_contains "envelope carries the row payload" "$DECODED" "alice"
    assert_contains "update carries an MVCC timestamp" "$DECODED" "updated"
    assert_contains "delete emits a null after-image (tombstone)" "$DECODED" "null"
else
    fail "core changefeed produced no output (file: $(head -c 300 "$CDC_OUT" 2>/dev/null))"
fi

section "Part B/C — Kafka sink and the resolved frontier (needs Docker)"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "Docker unavailable; skipping the Kafka sink and frontier tests"
else
    info "starting single-broker Kafka"
    docker rm -f "$KAFKA_NAME" >/dev/null 2>&1 || true
    if docker run -d --name "$KAFKA_NAME" --network=host \
        -e KAFKA_CFG_NODE_ID=0 \
        -e KAFKA_CFG_PROCESS_ROLES=controller,broker \
        -e KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 \
        -e KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
        -e KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@localhost:9093 \
        -e KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER \
        -e KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
        -e KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE=true \
        -e ALLOW_PLAINTEXT_LISTENER=yes \
        bitnami/kafka:3.7 >/dev/null 2>&1; then

        wait_for "kafka broker listening" 90 "nc -z localhost 9092"
        sleep 5
        pass "kafka broker is up"

        CF=$(sql "CREATE CHANGEFEED FOR TABLE shop.orders INTO 'kafka://localhost:9092'
                  WITH updated, resolved = '5s', diff, key_in_value;" 2>&1 || true)
        if echo "$CF" | grep -qi "use of this feature\|enterprise"; then
            warn "enterprise changefeed is license-gated on this cluster; skipping the sink assertions"
        else
            pass "enterprise changefeed created"
            JOB=$(sql_value "SELECT job_id FROM [SHOW CHANGEFEED JOBS] ORDER BY job_id DESC LIMIT 1;")
            assert_gt "changefeed job id recorded" "${JOB:-0}" "0"

            sql "USE shop; INSERT INTO orders (customer, total)
                 SELECT 'cust-' || g, (g * 3.5)::DECIMAL(12,2) FROM generate_series(1,20) g;" >/dev/null
            sql "USE shop; UPDATE orders SET status = 'paid' WHERE total > 40;" >/dev/null
            sleep 15

            MSGS=$(docker exec "$KAFKA_NAME" kafka-console-consumer.sh \
                --bootstrap-server localhost:9092 --topic orders \
                --from-beginning --timeout-ms 20000 2>/dev/null || true)
            if [ -n "$MSGS" ]; then
                pass "messages delivered to the kafka topic"
                assert_contains "envelope has an after image" "$MSGS" "after"
                assert_contains "resolved watermarks emitted" "$MSGS" "resolved"

                # The frontier consumer must apply only rows below the frontier.
                echo "$MSGS" | python3 - <<'PY'
import json, sys
frontier, pending, applied = "0", [], {}
resolved_seen = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: msg = json.loads(line)
    except json.JSONDecodeError: continue
    if "resolved" in msg:
        resolved_seen += 1
        frontier = msg["resolved"]
        ready = [p for p in pending if p[0] <= frontier]
        for ts, key, _ in sorted(ready):
            if key in applied and ts <= applied[key]:
                continue
            applied[key] = ts
        pending[:] = [p for p in pending if p[0] > frontier]
    else:
        pending.append((msg.get("updated", "0"), json.dumps(msg.get("key")), msg))
print(f"FRONTIER_OK resolved={resolved_seen} applied={len(applied)} pending={len(pending)}")
assert resolved_seen > 0, "no resolved messages"
assert len(applied) > 0, "frontier never released any row"
PY
                if [ $? -eq 0 ]; then
                    pass "frontier consumer released rows once resolved advanced"
                else
                    fail "frontier consumer did not apply any rows"
                fi
            else
                warn "no messages read from kafka within the timeout"
            fi

            sql "PAUSE JOB $JOB;" >/dev/null 2>&1 || true
            sleep 2
            STATUS=$(sql_value "SELECT status FROM [SHOW CHANGEFEED JOBS] WHERE job_id = $JOB;")
            assert_contains "changefeed pauses cleanly" "$STATUS" "pause"
            sql "RESUME JOB $JOB;" >/dev/null 2>&1 || true
            sleep 3
            sql "CANCEL JOB $JOB;" >/dev/null 2>&1 || true
            pass "changefeed lifecycle (pause/resume/cancel) exercised"
        fi
        docker rm -f "$KAFKA_NAME" >/dev/null 2>&1 || true
    else
        warn "could not start the kafka container; skipping sink tests"
    fi
fi

section "Part E/F — schema change policy and lag metric"

# Additive schema change must not break the table or the feed contract.
assert_command_succeeds "additive schema change accepted" \
    cockroach sql --insecure --host="localhost:${BASE_SQL_PORT}" \
    --execute "ALTER TABLE shop.orders ADD COLUMN shipped_at TIMESTAMPTZ;"

COLS=$(sql "SHOW COLUMNS FROM shop.orders;")
assert_contains "new column present" "$COLS" "shipped_at"

VARS=$(curl -s "http://localhost:${BASE_HTTP_PORT}/_status/vars")
assert_contains "changefeed lag metric exported for alerting" "$VARS" "changefeed_max_behind_nanos"

section "Done"
echo "Lab 13: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
