# Lab Test Suite

Automated tests that exercise the executable commands and assertions in all sixteen labs. Each test drives the same Docker stacks the labs drive — `docker/labs*.yml` through `scripts/crdb` — runs the lab's SQL/CLI flow non-interactively, asserts the expected outcomes, and tears everything down.

## What "tested" means here

Tests cover **100% of the executable lab content**:

| Aspect | Covered? | How |
| --- | --- | --- |
| Every SQL statement runs without error | ✅ | Replayed via `scripts/crdb sql`, the command the lab gives |
| Every shell command runs without error | ✅ | Replayed via the same `bash` the learner uses |
| Expected row counts / sums / states | ✅ | Asserted with helpers in `lib/common.sh` |
| Lifecycle events (node down → recovery) | ✅ | `scripts/crdb stop/start/add-node` against the real compose cluster |
| TLS cert generation, rotation, secure startup (Lab 12) | ✅ | The `docker/labs-secure.yml` stack; rotation by `docker compose kill -s HUP`, verified on the wire |
| Multi-region row placement (Lab 7) | ✅ | The lab's own `docker run ... demo --global --nodes 9` |
| Throughput orderings (Lab 8) | ✅ | Batched beats single-row; hash-sharded spreads wider than `SERIAL`; sharded counter vs single-row |
| Cross-cluster DR (Lab 11) | ✅ | The `docker/labs-b.yml` standby; restore verified by row count **and** business checksum |
| Application code (Lab 14) | ✅ | The lab's Python is executed: retry loop, outbox atomicity, idempotency, OCC vs `FOR UPDATE` |
| Lecture / Web UI observation steps | ⚠️ | Not auto-tested (visual only) |
| Lab 7's `\demo shutdown 7/8/9` | ⚠️ | `\demo` is a client-side command of the *interactive* shell — piped in, it returns `ERROR: invalid syntax`. The test asserts the survival configuration that makes the outage survivable and prints a `WARN` naming the manual step. `\demo connect N` **is** covered: the test queries node N on its own port, which is the same thing. |

### Tests with external dependencies

These skip cleanly (with a `WARN`) when the dependency is absent, so the suite still passes on a
bare machine — but they only *prove* the lab when the dependency is present.

| Test | Needs | Without it |
| --- | --- | --- |
| `lab07_test.sh` | ~6 GB free for the 9-node `demo` | Whole test skips (`FORCE_LAB07=1` overrides the RAM check) |
| `lab09_test.sh` | Docker (Prometheus) | Metrics endpoint, log channels, and debug zip still tested |
| `lab13_test.sh` | Kafka on the `crdb-labs_default` network | Core changefeed still tested; Kafka sink and frontier consumer skipped |
| `lab14_test.sh` | `python3` + `psycopg2` | Whole test skips |
| `lab15_test.sh` | Docker (PostgreSQL) + `psql` | Schema redesign and plan comparison still tested against synthetic data |
| `lab16_test.sh` | `kind` + `kubectl` + 10 GB of Docker memory | Manifests still validated; live cluster skipped (`FORCE_LAB16=1` overrides the RAM check) |
| `lab_cluster_test.sh` | Docker daemon | Whole test skips |
| Enterprise features (BACKUP, IMPORT, enterprise changefeeds) | License | Detected at runtime; those assertions are skipped with a warning |

> **The tests are the student path.** Every lab test drives
> [`docker/labs.yml`](../docker/labs.yml), [`docker/labs-b.yml`](../docker/labs-b.yml) or
> [`docker/labs-secure.yml`](../docker/labs-secure.yml) through `scripts/crdb` — the exact
> commands the lab hands the student. Nothing in this course installs a `cockroach` binary,
> so nothing here uses one: `crdb_run` in [`lib/cluster.sh`](lib/cluster.sh) is
> `scripts/crdb run`, which executes inside a node container.
>
> [`lab_cluster_test.sh`](lab_cluster_test.sh) covers the wrapper and the compose files
> themselves — start, stop, restart, add-node, published ports, the shared backup volume, the
> TLS stack — so a broken compose file cannot ship green.

## How to run

The tests drive the **same Docker stacks the labs drive** — `docker/labs.yml`,
`docker/labs-b.yml`, `docker/labs-secure.yml`, through `scripts/crdb`. They run on
your machine, exactly where a student runs the labs.

```bash
# The student path end to end: compose files + scripts/crdb
./tests/lab_cluster_test.sh

# Every lab test (~60-90 minutes with all dependencies present)
./tests/run_all.sh

# One day's labs
DAY=3 ./tests/run_all.sh

# An explicit subset
LABS_OVERRIDE="lab08_test.sh lab10_test.sh" ./tests/run_all.sh

# A single lab
./tests/lab01_test.sh

# Leave the cluster up on failure for postmortem
KEEP_ON_FAIL=1 ./tests/lab11_test.sh
```

### Prerequisites

The same ones the course asks of a student:

- **Docker Desktop** (or Docker Engine) running — there is no `cockroach` binary to install
- `bash` 4+, plus `curl`, `awk`, `grep`, `sed` (preinstalled on macOS and Linux)
- `python3` + `psycopg2` — Lab 14, and Lab 1 Part F (which falls back to a container)
- `psql` — Lab 15 (Lab 1 Part F falls back to a container)
- `kind` + `kubectl` — Lab 16's live cluster
- [`setup/provision_student_vm.sh`](../setup/provision_student_vm.sh) installs all of it

### Memory

Docker needs headroom: Lab 7 runs a 9-node `demo` cluster and Lab 11 runs two
3-node clusters side by side.

> ⚠️ **Check what the Docker VM actually has** with
> `docker info --format '{{.MemTotal}}'`. Under-provision it and containers are
> OOM-killed mid-run — clients die with `Killed` and assertions fail in ways that
> look like product bugs. Raise Docker Desktop → Settings → Resources → Memory to
> **≥ 12 GB** before running the full suite. Labs 1-6 are happy with 4 GB.
>
> Related: the tests drive concurrency through a small pool of long-lived
> `scripts/crdb sql` processes piping many statements — never one process per
> statement. Each client is a full Go binary; 200 of them need ~20 GB and will
> thrash any laptop long before they stress the database.

### They are sequential on purpose

All tests share one Docker project per stack (`crdb-labs`, `crdb-labs-b`,
`crdb-labs-secure`), so they cannot run in parallel — `run_all.sh` runs them one at
a time, and each begins with `scripts/crdb reset` so it starts from empty stores no
matter how the previous one ended.


Exit code 0 = all assertions passed. Any non-zero exit code = at least one assertion failed; look at the last few lines of output for the specific failure.

## Layout

```
tests/
├── README.md                       # this file
├── run_all.sh                      # orchestrates lab01..lab16 (DAY=N for a subset)
├── lib/
│   ├── common.sh                   # assert_eq, fail, pass, log helpers
│   └── cluster.sh                  # drives docker/labs*.yml through scripts/crdb
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
├── lab_cluster_test.sh             # the student path: compose files + scripts/crdb
├── lab16_test.sh                   # Kubernetes operator on kind
└── scratch/                        # per-run temp data (auto-cleaned)
```

The `docker-compose.yml` in the repo root sets resource limits and bind-mounts
the source tree so edits don't require a rebuild.

## CI integration sketch

The suite needs a runner with a Docker daemon and a checkout — the same two things
a student needs:

```yaml
# .github/workflows/test.yml
name: lab-tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./tests/lab_cluster_test.sh      # the student path
      - run: ./tests/run_all.sh               # every lab
```

`ubuntu-latest` ships Docker, `psql`, and `python3`; add `psycopg2` and
`kind`/`kubectl` steps if you want Labs 14 and 16 to run rather than skip. For
GitLab, CircleCI, or Jenkins the shape is identical: check out, then run the
scripts.

## Test design

Each test is a self-contained bash script that:

1. `source`s `lib/common.sh` and `lib/cluster.sh`
2. Starts a cluster with `start_cluster N`, which is `scripts/crdb reset`
3. Runs the lab's SQL and CLI commands
4. Asserts row counts, plan shapes, error codes, audit log entries, etc.
5. Cleans up via a `trap` on exit (cluster stops even on failure unless `KEEP_ON_FAIL=1`)

## When to update tests

Touching a lab? Update its test. The CI rule: **lab edits without matching test updates fail review**. The tests are the spec — if a lab changes its commands or expected outputs, the test should change in the same commit.
