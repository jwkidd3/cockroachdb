# CockroachDB — Distributed SQL in Practice

A 2-day introductory + intermediate course on CockroachDB's distributed SQL architecture, operations, multi-region resilience, and production readiness.

## Course Objectives

By the end of this course, attendees will be able to:

- Explain CockroachDB's distributed SQL architecture and how it achieves survivability, consistency, and horizontal scale.
- Deploy, configure, and operate single-region and multi-region CockroachDB clusters.
- Design schemas, choose primary keys, and tune indexes for a distributed SQL workload.
- Reason about serializable transactions, contention, and retries; use EXPLAIN ANALYZE to diagnose query plans.
- Apply multi-region topologies, geo-partitioning, survival goals, and node recovery procedures.
- Implement security hardening (TLS, RBAC, audit logging), monitoring (DB Console, Prometheus/Grafana), and CI/CD-friendly schema migrations.

**Course Length:** 2 Days

## Audience & Prerequisites

This course is appropriate for backend engineers, DBAs, SREs, and platform engineers who are comfortable with SQL and have some experience with PostgreSQL or another relational database. Familiarity with the command line and basic Docker concepts is helpful but not required.

Required on each learner's machine:

- A modern macOS, Linux, or Windows machine with at least 8 GB of free RAM.
- The `cockroach` binary (free, single-binary install) — see the install section below.
- A terminal and your preferred SQL client (the bundled `cockroach sql` shell works for every lab).

## Quick Start — Install the `cockroach` Binary

All labs in this course run against in-memory clusters started via `cockroach demo` and `cockroach start-single-node`. Nothing else needs to be installed — no Docker, no Kubernetes, no cloud accounts.

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

Download the latest Windows zip from <https://www.cockroachlabs.com/docs/releases/> and add the extracted folder to `PATH`. Then in PowerShell:

```powershell
cockroach version
```

### Verify

```bash
cockroach demo --no-example-database --empty
```

You should land at a `defaultdb>` prompt. Type `\q` to exit. If you see the prompt, you're ready for Day 1.

## Course Structure

| Day | Module | Topics |
| --- | --- | --- |
| **Day 1** | Module 1 — Architecture & Foundations | Distributed SQL intro, Raft & ranges, KV layer, installation, DB Console, SQL dialect, schema design |
| **Day 2** | Module 2 — Distributed Operations | Transactions, MVCC, EXPLAIN ANALYZE, multi-region, backup/restore, CDC |
| **Day 2** | Module 3 — Production Readiness | Security, TLS, RBAC, monitoring, schema migrations, deployment models, app integration |

### Day 1 Labs (~70-90 min each)

| # | Lab | Duration |
| --- | --- | --- |
| 1 | Cluster Bootstrap & Lifecycle | 75 min |
| 2 | DB Console & SQL Operational Tour | 70 min |
| 3 | Schema Design — High-Volume Patterns & Hotspot Avoidance | 90 min |
| 4 | Indexing Strategies — Every Index Type That Matters | 70 min |

### Day 2 Labs (~70-75 min each)

| # | Lab | Duration |
| --- | --- | --- |
| 5 | Transactions, Contention & Retry Loops | 75 min |
| 6 | EXPLAIN ANALYZE & Query Tuning | 70 min |
| 7 | Multi-Region Topologies & Survival Goals | 75 min |
| 8 | Backup, Restore, Changefeeds & Security Hardening | 75 min |

The course is paced at **~30% lecture / 70% hands-on labs**. Plan for ~9 hours of lab work over the two days, broken up with the lecture segments in the presentations.

## Repository Layout

```
cockroachdb/
├── README.md                                  # this file
├── cockroachdb.txt                            # original course outline
├── presentations/
│   ├── cockroachdb_day1_presentation.html     # Reveal.js slides — Day 1
│   └── cockroachdb_day2_presentation.html     # Reveal.js slides — Day 2
├── labs/
│   ├── SCHEMA_PATTERNS_PLAYBOOK.md          # take-home pattern catalog
│   ├── lab01_cluster_bootstrap.md
│   ├── lab02_db_console_sql_tour.md
│   ├── lab03_schema_design_hotspots.md
│   ├── lab04_indexing_strategies.md
│   ├── lab05_transactions_contention.md
│   ├── lab06_explain_analyze_tuning.md
│   ├── lab07_multiregion_survival.md
│   └── lab08_backup_cdc_security.md
├── tests/                                     # automated lab tests
│   ├── README.md
│   ├── Dockerfile                             # multi-arch test runner image
│   ├── run_all.sh                             # runs every lab test in sequence
│   ├── lib/
│   │   ├── common.sh                          # assertion helpers
│   │   └── cluster.sh                         # multi-node cluster start/stop
│   └── lab0{1..8}_test.sh                     # one test script per lab
├── docker-compose.yml                         # `docker compose run --rm tests`
└── .dockerignore
```

## Running the Automated Tests

Every lab ships with a paired test script under `tests/` that drives the lab's SQL and CLI commands non-interactively and asserts the expected outcomes — row counts, plan shapes, error codes, audit log entries, range placement, etc.

### Option 1: Containerized (recommended)

A multi-arch `Dockerfile` ships with the repo. The image pins CockroachDB and pre-installs `psql`, `python3 + psycopg2`, `nc`, and `tini`, so the only host requirement is Docker.

```bash
# Build once (~500 MB image, multi-arch via TARGETARCH)
docker compose build

# Run the whole suite
docker compose run --rm tests

# Run a single lab's test
docker compose run --rm tests ./tests/lab03_test.sh

# Keep the container alive on failure for postmortem
docker compose run --rm -e KEEP_ON_FAIL=1 tests ./tests/lab07_test.sh
```

The compose file requests **8 GB** RAM to comfortably run Lab 7's 9-node cluster. Drop to 4 GB if you only intend to run Labs 1-6.

### Option 2: Direct on the host

If you already have `cockroach` installed (which you do if you've been doing the labs), you can run the tests against your host binary:

```bash
# Run the entire suite (~10-15 minutes on a laptop)
./tests/run_all.sh

# Run a single lab's test
./tests/lab03_test.sh

# Keep the cluster running on failure (for postmortem)
KEEP_ON_FAIL=1 ./tests/lab07_test.sh

# Stop on first failure instead of continuing
STOP_ON_FAIL=1 ./tests/run_all.sh
```

The test suite is the spec — if a lab changes its commands or expected outputs, its test should change in the same commit. See `tests/README.md` for the full design.

## Running the Slides

Each presentation is a single self-contained HTML file using Reveal.js loaded from CDN — open it in any modern browser.

```bash
open presentations/cockroachdb_day1_presentation.html   # macOS
xdg-open presentations/cockroachdb_day1_presentation.html  # Linux
start presentations\cockroachdb_day1_presentation.html  # Windows
```

Speaker mode: press `S` to open speaker notes. Overview mode: press `O`. Print to PDF: append `?print-pdf` to the URL and use the browser's print dialog.

## Lab Conventions

- Each lab begins with **Learning Objectives**, **Prerequisites**, and a **Setup** block.
- Commands assume a Unix-like shell (bash/zsh). Windows-specific variants (PowerShell) are called out where the syntax differs.
- Labs are designed to be self-contained — you can drop into any lab without having finished the previous one, provided you complete its Setup block.
- Each lab finishes with a **Cleanup** block that tears down the demo cluster so you start the next lab from a known state.

## Quick Reference — `cockroach demo` Flags Used in This Course

| Flag | Purpose |
| --- | --- |
| `--no-example-database` | Skip the `movr` sample dataset (faster startup) |
| `--empty` | Combine with `--no-example-database` to drop into an empty cluster |
| `--nodes N` | Spin up N nodes in a single demo process |
| `--global` | Simulate multi-region latencies across 9 nodes in 3 regions |
| `--insecure` | Disable TLS (used in some labs; real deployments should NOT use this) |
| `--http-port 0` | Auto-pick a free DB Console port |

## Getting Help

- Official docs: <https://www.cockroachlabs.com/docs/>
- Community forum: <https://forum.cockroachlabs.com/>
- Source for the original course outline: `cockroachdb.txt` in this repo.
