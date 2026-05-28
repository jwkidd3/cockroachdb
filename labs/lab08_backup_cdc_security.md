# Lab 8: Backup, Restore, Changefeeds & Security Hardening (75 min)

## Learning Objectives

By the end of this lab you will be able to:

- Take a full backup, an incremental backup, and a scheduled backup; restore at a point in time
- Build a Core changefeed (no enterprise license required) and an Enterprise changefeed to an external sink
- Generate TLS certs (CA, node, client) and start a secure single-node cluster
- Build read-only and read-write RBAC roles with future-grants; verify privileges with positive and negative tests
- Enable per-table audit logging and read the resulting structured log entries
- Decide between Self-Hosted / Dedicated / Serverless deployment models

## Prerequisites

- `cockroach` binary on `PATH`
- `nc` (netcat) on `PATH` for the webhook sink test — preinstalled on macOS/Linux

## Setup

Start a 3-node demo cluster — Parts A and B use it:

```bash
cockroach demo --nodes 3 --no-example-database --empty
```

Create a small dataset:

```sql
CREATE DATABASE bank;
USE bank;

CREATE TABLE accounts (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name    STRING NOT NULL,
  balance DECIMAL(12,2) NOT NULL,
  region  STRING
);

INSERT INTO accounts (name, balance, region) VALUES
  ('Alice',    1000.00, 'us-east'),
  ('Bob',       500.00, 'us-west'),
  ('Charlie',  2500.00, 'eu-west'),
  ('Dana',     1200.00, 'us-east');
```

## Tasks

### Part A: BACKUP, RESTORE, Point-In-Time Recovery (15 min)

`cockroach demo` enables enterprise features automatically; backups to userfile work out of the box.

1. **Take a full backup:**
   ```sql
   BACKUP DATABASE bank INTO 'userfile:///lab8/backups';
   ```

2. **List backups:**
   ```sql
   SHOW BACKUPS IN 'userfile:///lab8/backups';
   SHOW BACKUP FROM LATEST IN 'userfile:///lab8/backups';
   ```

3. **Drop the database:**
   ```sql
   USE defaultdb;
   DROP DATABASE bank CASCADE;
   SHOW DATABASES;
   ```

4. **Restore:**
   ```sql
   RESTORE DATABASE bank FROM LATEST IN 'userfile:///lab8/backups';
   USE bank;
   SELECT * FROM accounts ORDER BY name;
   ```

5. **Take an incremental:**
   ```sql
   UPDATE accounts SET balance = balance + 100 WHERE name = 'Alice';
   BACKUP DATABASE bank INTO LATEST IN 'userfile:///lab8/backups';
   SHOW BACKUP FROM LATEST IN 'userfile:///lab8/backups';
   ```

6. **Point-in-time restore into a new database:**
   ```sql
   -- Restore as of 10 seconds ago into a side-by-side db
   RESTORE DATABASE bank
     FROM LATEST IN 'userfile:///lab8/backups'
     AS OF SYSTEM TIME '-10s'
     WITH new_db_name = 'bank_archive';

   SELECT name, balance FROM bank_archive.public.accounts ORDER BY name;
   ```

7. **Schedule a recurring backup:**
   ```sql
   CREATE SCHEDULE bank_hourly
     FOR BACKUP DATABASE bank INTO 'userfile:///lab8/backups-scheduled'
     RECURRING '@hourly'
     FULL BACKUP '@daily'
     WITH SCHEDULE OPTIONS first_run = 'now';

   SHOW SCHEDULES;
   ```
   Cancel it (just the syntax — we don't want it running for the rest of the lab):
   ```sql
   PAUSE SCHEDULE <id from SHOW SCHEDULES>;
   ```

### Part B: Changefeeds — Core and Enterprise (15 min)

Two flavors:

- **Core** — emits to the SQL session, no enterprise required, no external sink
- **Enterprise** — emits to Kafka, webhook, cloud storage; needs a license (the demo provides one)

1. **Core changefeed** — open another `cockroach sql` session, then run:
   ```sql
   EXPERIMENTAL CHANGEFEED FOR bank.accounts;
   ```
   This session is now a stream. In another terminal:
   ```sql
   USE bank;
   INSERT INTO accounts (name, balance, region) VALUES ('Eve', 800, 'us-east');
   UPDATE accounts SET balance = 1500 WHERE name = 'Alice';
   ```
   Watch the changefeed session — it prints JSON for each row event. Ctrl+C to stop.

2. **Enterprise changefeed to a webhook** — start a tiny netcat sink in terminal B:
   ```bash
   while true; do nc -l 8888 < /dev/null; echo "---"; done
   ```

3. **Create the changefeed in the SQL shell:**
   ```sql
   SET CLUSTER SETTING kv.rangefeed.enabled = true;

   CREATE CHANGEFEED FOR TABLE bank.accounts
     INTO 'webhook-https://localhost:8888?insecure_tls_skip_verify=true'
     WITH updated, resolved = '5s';
   ```
   Capture the returned `job_id`.

4. **Make some changes:**
   ```sql
   UPDATE accounts SET balance = balance + 50 WHERE name = 'Bob';
   INSERT INTO accounts (name, balance, region) VALUES ('Frank', 600, 'us-east');
   DELETE FROM accounts WHERE name = 'Dana';
   ```

5. **Watch terminal B** — JSON payloads appear with each event.

6. **Pause, resume, cancel:**
   ```sql
   PAUSE JOB <job_id>;
   SHOW JOB <job_id>;
   RESUME JOB <job_id>;
   CANCEL JOB <job_id>;
   ```

### Part C: Generate Certs and Start a Secure Cluster (15 min)

Exit the demo (`\q`). We'll build a secure cluster the way you would in production.

1. **Create directories:**
   ```bash
   mkdir -p lab8-certs lab8-keys lab8-data
   ```

2. **Create the CA:**
   ```bash
   cockroach cert create-ca \
     --certs-dir=lab8-certs \
     --ca-key=lab8-keys/ca.key
   ```

3. **Create the node cert:**
   ```bash
   cockroach cert create-node \
     localhost 127.0.0.1 \
     --certs-dir=lab8-certs \
     --ca-key=lab8-keys/ca.key
   ```

4. **Create a client cert for `root`:**
   ```bash
   cockroach cert create-client root \
     --certs-dir=lab8-certs \
     --ca-key=lab8-keys/ca.key
   ```

5. **List certs:**
   ```bash
   cockroach cert list --certs-dir=lab8-certs
   ```

6. **Start a secure single-node cluster:**
   ```bash
   cockroach start-single-node \
     --certs-dir=lab8-certs \
     --store=lab8-data \
     --listen-addr=localhost:26257 \
     --http-addr=localhost:8080 \
     --background
   ```

7. **Connect — only cert-bearing client succeeds:**
   ```bash
   # Works
   cockroach sql --certs-dir=lab8-certs --host=localhost:26257

   # Fails (no certs)
   cockroach sql --insecure --host=localhost:26257 || echo "expected failure"
   ```

8. **Set a password for root** (useful if you want to support password auth alongside cert auth):
   ```sql
   ALTER USER root WITH PASSWORD 'lab8-root-pw';
   ```

### Part D: RBAC — Roles, Users, Grants, Future Privileges (15 min)

1. **Create an app database and schema:**
   ```sql
   CREATE DATABASE ledger;
   USE ledger;
   CREATE TABLE accounts (
     id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     name    STRING NOT NULL,
     balance DECIMAL(12,2) NOT NULL
   );
   INSERT INTO accounts (name, balance) VALUES ('Alice', 1000), ('Bob', 500);
   ```

2. **Build two roles with future-privileges:**
   ```sql
   -- Read-only
   CREATE ROLE ledger_ro;
   GRANT CONNECT ON DATABASE ledger TO ledger_ro;
   GRANT USAGE   ON SCHEMA   ledger.public TO ledger_ro;
   GRANT SELECT  ON ALL TABLES IN SCHEMA ledger.public TO ledger_ro;
   ALTER DEFAULT PRIVILEGES IN SCHEMA ledger.public
     GRANT SELECT ON TABLES TO ledger_ro;

   -- Read-write
   CREATE ROLE ledger_rw;
   GRANT CONNECT ON DATABASE ledger TO ledger_rw;
   GRANT USAGE   ON SCHEMA   ledger.public TO ledger_rw;
   GRANT SELECT, INSERT, UPDATE, DELETE
     ON ALL TABLES IN SCHEMA ledger.public TO ledger_rw;
   ALTER DEFAULT PRIVILEGES IN SCHEMA ledger.public
     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ledger_rw;
   ```

3. **Create users and assign roles:**
   ```sql
   CREATE USER report_user WITH PASSWORD 'report-pw';
   GRANT ledger_ro TO report_user;

   CREATE USER app_user WITH PASSWORD 'app-pw';
   GRANT ledger_rw TO app_user;
   ```

4. **Verify with positive and negative tests** — open a new shell as `report_user`:
   ```bash
   cockroach sql --certs-dir=lab8-certs --user=report_user --host=localhost:26257
   ```
   ```sql
   USE ledger;
   SELECT * FROM accounts;                                    -- ✅
   UPDATE accounts SET balance = 0;                           -- ❌ insufficient privilege
   INSERT INTO accounts (name, balance) VALUES ('Eve', 1);    -- ❌
   ```

5. **As `app_user`:**
   ```bash
   cockroach sql --certs-dir=lab8-certs --user=app_user --host=localhost:26257
   ```
   ```sql
   USE ledger;
   UPDATE accounts SET balance = balance + 1 WHERE name = 'Alice';   -- ✅
   CREATE TABLE bogus (id INT);                                       -- ❌ no CREATE
   ```

6. **Future-grants in action** — back as `root`, create a new table:
   ```sql
   USE ledger;
   CREATE TABLE transactions (
     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     amount DECIMAL(12,2)
   );
   ```
   Then as `report_user`, the new table is *automatically* readable thanks to the default-privileges grant:
   ```sql
   SELECT * FROM ledger.public.transactions;  -- ✅ works without an explicit GRANT
   ```

### Part E: Audit Logging (10 min)

1. **Enable read+write audit on `accounts`:**
   ```sql
   ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET READ WRITE;
   ```

2. **As `app_user`, do some queries:**
   ```bash
   cockroach sql --certs-dir=lab8-certs --user=app_user --host=localhost:26257 \
     --execute "SELECT * FROM ledger.public.accounts;
                UPDATE ledger.public.accounts SET balance = balance + 1 WHERE name = 'Bob';"
   ```

3. **Find the audit entries in the structured log:**
   ```bash
   ls lab8-data/logs/
   # The audit-related events go to cockroach.log by default; in production
   # you'd configure a separate SENSITIVE_ACCESS channel.
   ```
   ```bash
   grep -i "sensitive_access\|EXPERIMENTAL_AUDIT" lab8-data/logs/*.log | head -5
   ```

4. **Disable the audit:**
   ```sql
   ALTER TABLE ledger.public.accounts EXPERIMENTAL_AUDIT SET OFF;
   ```

### Part F: Deployment Decision Tree (5 min)

For each scenario, pick: **Self-Hosted**, **Dedicated**, or **Serverless**.

| Scenario | Choice |
| --- | --- |
| 5-developer startup, < 1 GB data, mostly evenings | ? |
| Regulated financial system, on-prem only | ? |
| Multi-region e-commerce, 10 TB, 24×7 | ? |
| Multi-region e-commerce with strict ops budget | ? |
| Internal tool prototype that will probably be retired in 6 months | ? |

> Discuss and defend each. Key dimensions: ops staff cost, compliance, scale, latency, predictability.

## Cleanup

```bash
cockroach quit --certs-dir=lab8-certs --host=localhost:26257
pkill -f "nc -l 8888"
rm -rf lab8-certs lab8-keys lab8-data
```

If you only used the demo (Parts A and B): `\q`.

## Lab 8 Deliverables

✅ **Backups**: full, incremental, scheduled, point-in-time restore into a new name
✅ **Changefeeds**: Core (SQL session) and Enterprise (webhook) emitted real row events
✅ **TLS cluster**: CA + node + client certs generated; secure cluster started; insecure connect rejected
✅ **RBAC**: two roles, two users, future-grants verified with positive AND negative tests
✅ **Audit logging**: enabled and observed entries for a sensitive table
✅ **Deployment dimensions**: decision tree across five scenarios

## Challenge Exercises

1. **Build a richer webhook sink** in Python that:
   - Logs every payload with a timestamp
   - Tracks the latest `resolved` timestamp and prints "all events through X are final" each time it advances
   - Why does `resolved` matter to a downstream consumer?

2. **Restore one table from a backup of an entire database.** Without restoring the rest of the schema. How does the syntax differ?

3. **Audit only failed writes.** Combine the audit logging with the SQL `ALTER ROLE NOSQLLOGIN` setting. Can you build an "alert on permission denied" pipeline using only built-in features?

## Reference

| Command | Purpose |
| --- | --- |
| `BACKUP ... INTO 'sink'` | Full backup |
| `BACKUP ... INTO LATEST IN 'sink'` | Incremental (auto-detects parent) |
| `CREATE SCHEDULE` | Recurring backup |
| `RESTORE ... AS OF SYSTEM TIME '...'` | Point-in-time restore |
| `EXPERIMENTAL CHANGEFEED FOR ...` | Core changefeed to SQL session |
| `CREATE CHANGEFEED FOR ... INTO 'sink'` | Enterprise changefeed |
| `cockroach cert create-{ca,node,client}` | TLS setup |
| `ALTER DEFAULT PRIVILEGES ...` | Future-grants for new objects |
| `ALTER TABLE ... EXPERIMENTAL_AUDIT SET READ WRITE` | Per-table audit logging |
