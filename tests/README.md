# Lab Test Suite

Automated tests that exercise the executable commands and assertions in all sixteen labs. Each test starts an isolated CockroachDB cluster, runs the lab's SQL/CLI flow non-interactively, asserts the expected outcomes, and tears everything down.

## What "tested" means here

Tests cover **100% of the executable lab content**:

| Aspect | Covered? | How |
| --- | --- | --- |
| Every SQL statement runs without error | ✅ | Replayed via `cockroach sql --execute` |
| Every shell command runs without error | ✅ | Replayed via the same `bash` the learner uses |
| Expected row counts / sums / states | ✅ | Asserted with helpers in `lib/common.sh` |
| Lifecycle events (node down → recovery) | ✅ | Real multi-process clusters started with `cockroach start` |
| TLS cert generation, rotation, secure startup (Lab 12) | ✅ | Full cert-create-ca / create-node / create-client + SIGHUP rotation verified on the wire |
| Multi-region row placement (Lab 7) | ✅ | `cockroach demo --global` with 9 nodes |
| Throughput orderings (Lab 8) | ✅ | Batched beats single-row; hash-sharded spreads wider than `SERIAL`; sharded counter vs single-row |
| Cross-cluster DR (Lab 11) | ✅ | Two real clusters; restore verified by row count **and** business checksum |
| Application code (Lab 14) | ✅ | The lab's Python is executed: retry loop, outbox atomicity, idempotency, OCC vs `FOR UPDATE` |
| Lecture / Web UI observation steps | ⚠️ | Not auto-tested (visual only) |

### Tests with external dependencies

These skip cleanly (with a `WARN`) when the dependency is absent, so the suite still passes on a
bare machine — but they only *prove* the lab when the dependency is present.

| Test | Needs | Without it |
| --- | --- | --- |
| `lab09_test.sh` | Docker (Prometheus) | Metrics endpoint, log channels, and debug zip still tested |
| `lab13_test.sh` | Docker (Kafka) | Core changefeed still tested; Kafka sink and frontier consumer skipped |
| `lab14_test.sh` | `python3` + `psycopg2` | Whole test skips |
| `lab15_test.sh` | Docker (PostgreSQL) + `psql` | Schema redesign and plan comparison still tested against synthetic data |
| `lab16_test.sh` | Docker + `kind` + `kubectl` + 10 GB RAM | Manifests still validated; live cluster skipped (`FORCE_LAB16=1` overrides the RAM check) |
| Enterprise features (BACKUP, IMPORT, enterprise changefeeds) | License | Detected at runtime; those assertions are skipped with a warning |

> **Labs vs tests.** The *labs* now run CockroachDB in Docker via
> [`docker/labs.yml`](../docker/labs.yml) and `scripts/crdb`. This *test
> suite* is separate: it starts its own throwaway clusters with the `cockroach` binary
> inside the test image. Same binary, same SQL, but the tests do not exercise the
> `scripts/crdb` wrappers — they verify the SQL and the behaviour the labs teach.

## Two ways to run

### A. Containerized (recommended for CI and "works on every machine")

A `Dockerfile` and `docker-compose.yml` ship in the repo. The image pins a
specific CockroachDB version and pre-installs every tool the suite touches
(`bash`, `psql`, `python3 + psycopg2`, `nc`, `tini`, etc.), so you don't need
anything but Docker on the host.

```bash
# One-time: build the image (~280 MB cockroach + ~150 MB deps = ~500 MB)
docker compose build

# Run the whole suite
docker compose run --rm tests

# Run one day's labs
docker compose run --rm -e DAY=2 tests

# Run a single lab's test
docker compose run --rm tests ./tests/lab08_test.sh

# Keep the container alive on failure for postmortem
docker compose run --rm -e KEEP_ON_FAIL=1 tests ./tests/lab07_test.sh
```

Memory: the compose file requests **10 GB** because Lab 7 starts a 9-node
in-memory cluster and Lab 11 runs two 3-node clusters side by side. Drop to
4 GB by editing `mem_limit:` if you're only running Labs 1–6.

> ⚠️ **On Docker Desktop, `mem_limit` cannot exceed the Docker VM's own memory.**
> Check it with `docker info --format '{{.MemTotal}}'`. If the VM is smaller than the
> limit, containers are silently capped and multi-node tests get OOM-killed mid-run —
> clients die with `Killed` and assertions fail in ways that look like product bugs.
> Raise Docker Desktop → Settings → Resources → Memory to ≥ 12 GB before running the
> full suite.
>
> Related: the tests drive concurrency through a small pool of long-lived
> `cockroach sql` processes piping many statements — never one process per statement.
> Each client is a full Go binary; 200 of them need ~20 GB and will thrash any laptop
> long before they stress the database.

The container has no nested Docker, so the Docker-dependent parts of Labs 9,
13, 15, and 16 skip inside it. Run those on the host (or a VM built with
[`setup/provision_student_vm.sh`](../setup/provision_student_vm.sh)) for full
coverage.

Multi-arch: the Dockerfile uses `TARGETARCH`, so `docker compose build` picks
the right cockroach binary automatically on both Intel Linux and Apple Silicon.

### B. Direct on the host

Run the same tests against your local `cockroach` binary — useful while
iterating on a single test or for debugging.

Prerequisites:

- `cockroach` on `PATH` (any v23+ release)
- `bash` 4+
- `nc`, `curl`, `awk`, `grep`, `sed` — preinstalled on macOS and most Linux
- Optional: `psql`, `python3 + psycopg2` (Lab 1 Part F skips them cleanly if absent)

Ports used: `26257-26490` (SQL) and `8080-8230` (HTTP), plus `9090` (Prometheus,
Lab 9), `9092` (Kafka, Lab 13), and `54329` (PostgreSQL, Lab 15). The runner
picks non-overlapping ranges per lab so tests can run in parallel without
colliding.

```bash
# Run every test (~45-60 minutes with all dependencies present)
./tests/run_all.sh

# Run one day's labs
DAY=3 ./tests/run_all.sh

# Run an explicit subset
LABS_OVERRIDE="lab08_test.sh lab10_test.sh" ./tests/run_all.sh

# Run a single lab's test
./tests/lab01_test.sh

# Keep cluster artifacts after failure for postmortem
KEEP_ON_FAIL=1 ./tests/lab03_test.sh

# Stop on first failure
STOP_ON_FAIL=1 ./tests/run_all.sh
```

Exit code 0 = all assertions passed. Any non-zero exit code = at least one assertion failed; look at the last few lines of output for the specific failure.

## Layout

```
tests/
├── README.md                       # this file
├── Dockerfile                      # pinned-version test runner image
├── run_all.sh                      # orchestrates lab01..lab16 (DAY=N for a subset)
├── lib/
│   ├── common.sh                   # assert_eq, fail, pass, log helpers
│   └── cluster.sh                  # start/stop multi-node clusters
├── lab01_test.sh                   # cluster bootstrap & node lifecycle
├── lab02_test.sh                   # DB Console & SQL tour
├── lab03_test.sh                   # schema design & hotspots
├── lab04_test.sh                   # indexing strategies
├── lab05_test.sh                   # transactions & contention
├── lab06_test.sh                   # EXPLAIN ANALYZE & tuning
├── lab07_test.sh                   # multi-region & survival goals
├── lab08_test.sh                   # throughput engineering
├── lab09_test.sh                   # observability & log channels
├── lab10_test.sh                   # TPC-C & capacity sizing
├── lab11_test.sh                   # backup / restore / cross-cluster DR
├── lab12_test.sh                   # security hardening & cert rotation
├── lab13_test.sh                   # CDC, Kafka, resolved frontier
├── lab14_test.sh                   # outbox & idempotent retries
├── lab15_test.sh                   # PostgreSQL migration
├── lab16_test.sh                   # Kubernetes operator on kind
└── scratch/                        # per-run temp data (auto-cleaned)
```

The `docker-compose.yml` in the repo root sets resource limits and bind-mounts
the source tree so edits don't require a rebuild.

## CI integration sketch

The suite is single-command — drop it into any CI runner that has Docker:

```yaml
# .github/workflows/test.yml
name: lab-tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose build
      - run: docker compose run --rm tests
```

For GitLab, CircleCI, Jenkins, etc., the equivalent is one `docker compose build && docker compose run --rm tests` step.

## Test design

Each test is a self-contained bash script that:

1. `source`s `lib/common.sh` and `lib/cluster.sh`
2. Starts an isolated cluster (`start_cluster N` or `start_demo`)
3. Runs the lab's SQL and CLI commands
4. Asserts row counts, plan shapes, error codes, audit log entries, etc.
5. Cleans up via a `trap` on exit (cluster stops even on failure unless `KEEP_ON_FAIL=1`)

## When to update tests

Touching a lab? Update its test. The CI rule: **lab edits without matching test updates fail review**. The tests are the spec — if a lab changes its commands or expected outputs, the test should change in the same commit.
