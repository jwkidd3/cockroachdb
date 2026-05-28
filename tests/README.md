# Lab Test Suite

Automated tests that exercise every executable command and assertion in the eight labs. Each test starts an isolated CockroachDB cluster, runs the lab's SQL/CLI flow non-interactively, asserts the expected outcomes, and tears everything down.

## What "tested" means here

Tests cover **100% of the executable lab content**:

| Aspect | Covered? | How |
| --- | --- | --- |
| Every SQL statement runs without error | ✅ | Replayed via `cockroach sql --execute` |
| Every shell command runs without error | ✅ | Replayed via the same `bash` the learner uses |
| Expected row counts / sums / states | ✅ | Asserted with helpers in `lib/common.sh` |
| Lifecycle events (node down → recovery) | ✅ | Real multi-process clusters started with `cockroach start` |
| TLS cert generation and secure startup (Lab 8) | ✅ | Full cert-create-ca / create-node / create-client flow |
| Multi-region row placement (Lab 7) | ✅ | `cockroach demo --global` with 9 nodes |
| Lecture / Web UI observation steps | ⚠️ | Not auto-tested (visual only) — flagged in each test as `SKIP_REASON=visual` |

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

# Run a single lab's test
docker compose run --rm tests ./tests/lab03_test.sh

# Keep the container alive on failure for postmortem
docker compose run --rm -e KEEP_ON_FAIL=1 tests ./tests/lab07_test.sh
```

Memory: the compose file requests **8 GB** because Lab 7 starts a 9-node
in-memory cluster. Drop to 4 GB by editing `mem_limit:` if you're only running
Labs 1–6.

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

Ports used: `26257-26399` (SQL) and `8080-8146` (HTTP). The runner picks
non-overlapping ranges per lab so tests can run in parallel without colliding.

```bash
# Run every test
./tests/run_all.sh

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
├── run_all.sh                      # orchestrates lab01..lab08, prints summary
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
├── lab08_test.sh                   # backup, CDC, security
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
