# CockroachDB — Distributed SQL in Practice

A **4-day** course on CockroachDB's distributed SQL architecture, with an emphasis on
**schema design and performance**: how the primary key decides distribution, how to measure
throughput instead of guessing at it, and how those decisions turn into dashboards, node
counts, and a hardware bill.

Built from the outline in [`cockroachdb_4day.md`](cockroachdb_4day.md).

## Course Objectives

By the end of the course, attendees will be able to:

- **Explain** CockroachDB's distributed SQL architecture and how it achieves survivability, consistency, and scale.
- **Design** schemas whose primary keys distribute load — and defend each choice with a measured number.
- **Optimize** queries with `EXPLAIN ANALYZE`, statistics, and the right index type.
- **Engineer throughput**: bulk-load methods, batch-size knees, pre-splits, and concurrency limits.
- **Operate** clusters: observability with SLO alerting, capacity sizing from a throughput target, backup/DR with a measured RTO.
- **Harden** deployments: TLS rotation without downtime, least-privilege RBAC, SSO, and an audit pipeline.
- **Integrate** with application stacks: retry loops, the outbox pattern, idempotency keys, connection pooling.
- **Migrate** from PostgreSQL with MOLT, redesigning primary keys during the move.
- **Deploy** on Kubernetes with the `cockroach-operator`.

**Course length:** 4 days · **Lab share:** ~72%

## Audience & Prerequisites

Backend engineers, DBAs, SREs, and platform engineers who are comfortable with SQL and have some
experience with PostgreSQL or another relational database. Familiarity with the command line and
basic Docker concepts helps.

Per learner:

| | Days 1–2 | Days 3–4 |
| --- | --- | --- |
| RAM | 16 GB | **32 GB** |
| Disk | 60 GB | **150 GB** |
| Tools | `cockroach` binary | plus Docker, `kind`, `kubectl`, `psql`, `python3` |

Instructors provisioning machines: see **[`setup/INSTRUCTOR_SETUP.md`](setup/INSTRUCTOR_SETUP.md)** —
it ships a provisioning script, a verification script, and a teardown procedure.

## Quick Start — Install the `cockroach` Binary

Labs 1–12 and 14 run against local `cockroach demo` / `cockroach start` clusters.
Labs 13, 15, and 16 add Docker (Kafka, PostgreSQL, `kind`).

### macOS (Homebrew)

```bash
brew install cockroachdb/tap/cockroach
cockroach version
```

### macOS / Linux (manual)

```bash
curl https://binaries.cockroachdb.com/cockroach-latest.darwin-11.0-amd64.tgz | tar -xz
sudo mv cockroach-*/cockroach /usr/local/bin/
cockroach version
```

### Windows (PowerShell)

Download the latest Windows zip from <https://www.cockroachlabs.com/docs/releases/> and add the
extracted folder to `PATH`, then run `cockroach version`.

### Verify

```bash
cockroach demo --no-example-database --empty
```

You should land at a `defaultdb>` prompt. Type `\q` to exit.

## Course Structure

| Day | Module | Topics |
| --- | --- | --- |
| **Day 1** | Architecture & Foundations | Distributed SQL, Raft & ranges, KV layer, install & tooling, DB Console, SQL dialect, **schema design** |
| **Day 2** | Distributed Operations & Resilience | Transactions & contention, query optimization, multi-region, **high-volume schema patterns, throughput engineering** |
| **Day 3** | Production Operations & Security | Observability & SLOs, **capacity planning**, benchmarking, backup/restore/DR, security hardening, on-call |
| **Day 4** | Advanced Features & Integration | CDC in depth, outbox & idempotency, ORMs & pooling, migrations & CI/CD, PostgreSQL migration, Kubernetes |

### Labs

| Day | # | Lab | Duration |
| --- | --- | --- | --- |
| 1 | 1 | [Cluster Bootstrap & Lifecycle](labs/lab01_cluster_bootstrap.md) | 75 min |
| 1 | 2 | [DB Console & SQL Operational Tour](labs/lab02_db_console_sql_tour.md) | 70 min |
| 1 | 3 | [Schema Design — Hotspots & Distribution](labs/lab03_schema_design_hotspots.md) | 90 min |
| 1 | 4 | [Indexing Strategies](labs/lab04_indexing_strategies.md) | 70 min |
| 2 | 5 | [Transactions, Contention & Retry Loops](labs/lab05_transactions_contention.md) | 75 min |
| 2 | 6 | [EXPLAIN ANALYZE & Query Tuning](labs/lab06_explain_analyze_tuning.md) | 70 min |
| 2 | 7 | [Multi-Region Topologies & Survival Goals](labs/lab07_multiregion_survival.md) | 75 min |
| 2 | 8 | **[Throughput Engineering — Bulk Import, Batching & the Pattern Playbook](labs/lab08_throughput_engineering.md)** | 75 min |
| 3 | 9 | [Prometheus + Grafana with SLO Dashboards](labs/lab09_observability_slo.md) | 75 min |
| 3 | 10 | **[TPC-C Benchmark & Capacity Sizing](labs/lab10_tpcc_capacity_sizing.md)** | 75 min |
| 3 | 11 | [BACKUP / RESTORE / Schedules & Cross-Cluster DR](labs/lab11_backup_restore_dr.md) | 75 min |
| 3 | 12 | [Security Hardening End-to-End](labs/lab12_security_hardening.md) | 75 min |
| 4 | 13 | [CDC → Kafka → Frontier Consumer](labs/lab13_cdc_kafka.md) | 75 min |
| 4 | 14 | [Outbox Pattern + Idempotent Retry Loop](labs/lab14_outbox_idempotency.md) | 75 min |
| 4 | 15 | [Migrate a PostgreSQL Schema with MOLT](labs/lab15_molt_migration.md) | 90 min |
| 4 | 16 | [CockroachDB on Kubernetes with kind](labs/lab16_kubernetes_operator.md) | 90 min |

### The through-line: schema design and performance

The course is organized around one claim — **in a distributed SQL database, the primary key is a
distribution decision** — and then keeps cashing it out:

| Day | What that decision becomes |
| --- | --- |
| 1 | Range layout, and where the hotspot is (Lab 3) |
| 2 | Contention, plan shape, and **measured rows/sec across four PK designs** (Lab 8) |
| 3 | Write amplification → node count → hardware bill (Lab 10) |
| 4 | Outbox design (Lab 14), migration redesign (Lab 15), Kubernetes topology (Lab 16) |

The [**Schema Patterns Playbook**](labs/SCHEMA_PATTERNS_PLAYBOOK.md) is the take-home artifact:
ten named patterns, each with its canonical schema, the trap it avoids, the cost it charges, and
a **Measure it** block showing how to prove it works.

## Repository Layout

```
cockroachdb/
├── README.md                                  # this file
├── cockroachdb.txt                            # original 2-day outline
├── cockroachdb_4day.md / .html / .pdf / .txt  # the 4-day outline this course implements
├── presentations/
│   ├── cockroachdb_day1_presentation.html     # Reveal.js slides — Day 1
│   ├── cockroachdb_day2_presentation.html     # Day 2
│   ├── cockroachdb_day3_presentation.html     # Day 3
│   └── cockroachdb_day4_presentation.html     # Day 4
├── labs/
│   ├── SCHEMA_PATTERNS_PLAYBOOK.md            # take-home pattern catalog
│   └── lab01..lab16_*.md                      # 16 labs
├── scripts/
│   └── pull_latest.bat                        # Windows: pull the latest materials
├── setup/                                     # instructor: student VM provisioning
│   ├── INSTRUCTOR_SETUP.md                    # sizing, image build, launch, teardown
│   ├── provision_student_vm.sh                # builds the golden image
│   ├── verify_student_vm.sh                   # proves a VM can run every lab
│   ├── reset_labs.sh                          # clean state between labs
│   ├── run_on_all.sh / verify_all.sh          # fleet operations
│   ├── make_student_sheet.sh                  # connection sheet generator
│   ├── cloud-init-student.yaml                # per-instance setup
│   └── hosts.txt                              # VM inventory
├── tests/                                     # automated lab tests
│   ├── README.md
│   ├── Dockerfile                             # multi-arch test runner image
│   ├── run_all.sh                             # DAY=N for one day's labs
│   ├── lib/{common,cluster}.sh
│   └── lab01..lab16_test.sh
└── docker-compose.yml                         # `docker compose run --rm tests`
```

## Running the Automated Tests

Every lab ships with a paired test that drives its SQL and CLI non-interactively and asserts the
outcomes — row counts, plan shapes, range distribution, retry counts, restore checksums, and the
throughput orderings the labs claim.

```bash
# Containerized (recommended)
docker compose build
docker compose run --rm tests               # everything
docker compose run --rm -e DAY=2 tests      # one day
docker compose run --rm tests ./tests/lab08_test.sh

# On the host, against your own cockroach binary
./tests/run_all.sh
DAY=3 ./tests/run_all.sh
LABS_OVERRIDE="lab08_test.sh lab10_test.sh" ./tests/run_all.sh
KEEP_ON_FAIL=1 ./tests/lab11_test.sh
```

Tests with external dependencies (Docker for Labs 9/13/15/16, `psycopg2` for Lab 14) skip cleanly
with a warning when the dependency is missing. See [`tests/README.md`](tests/README.md).

The test suite is the spec — if a lab changes its commands or expected outputs, its test changes
in the same commit.

## Running the Slides

Each presentation is a single self-contained HTML file using Reveal.js from CDN.

```bash
open presentations/cockroachdb_day1_presentation.html      # macOS
xdg-open presentations/cockroachdb_day3_presentation.html  # Linux
```

Speaker notes: `S`. Overview: `O`. Print to PDF: append `?print-pdf` and use the browser's print dialog.

## Lab Conventions

- Each lab opens with **Learning Objectives**, **Prerequisites**, and a **Setup** block, and closes
  with **Cleanup**, **Deliverables**, **Challenge Exercises**, and a command **Reference** table.
- Labs are self-contained — you can drop into any lab after completing its Setup block.
- Commands assume a Unix-like shell; Windows variants are called out where the syntax differs.
- Between labs, `bash setup/reset_labs.sh` returns the machine to a known state.
- To pick up lab corrections during the course, run `git pull` — or on Windows,
  double-click [`scripts\pull_latest.bat`](scripts/pull_latest.bat), which stashes your own
  work first and does a fast-forward-only pull so you can't land in a merge conflict mid-lab.

## Running the 2-Day Version

Days 1–2 stand alone as the 2-day course described in [`cockroachdb.txt`](cockroachdb.txt), with one
change: Day 2 now ends with **Lab 8 — Throughput Engineering** instead of backup/CDC/security, which
moved to Days 3–4. If you are delivering the 2-day course and need backup and security coverage,
substitute Labs 11 and 12 for Lab 8 and cut the throughput section.

## Getting Help

- Official docs: <https://www.cockroachlabs.com/docs/>
- Community forum: <https://forum.cockroachlabs.com/>
- Outlines: [`cockroachdb_4day.md`](cockroachdb_4day.md) (current) and [`cockroachdb.txt`](cockroachdb.txt) (original 2-day)
