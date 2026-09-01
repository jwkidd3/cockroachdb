# Containerized test runner for the CockroachDB course labs.
#
# Build:
#   docker build -t crdb-labs-tests -f tests/Dockerfile .
#
# Run the whole suite:
#   docker run --rm -m 10g crdb-labs-tests
#
# Run a single lab:
#   docker run --rm -m 10g crdb-labs-tests ./tests/lab07_test.sh
#
# Note: Lab 7 starts a 9-node cluster and Lab 11 runs two 3-node clusters —
# give the container at least 10 GB. Labs 1-6 are happy with 4 GB.
#
# The image has no nested Docker, so the Docker-dependent parts of Labs 9, 13,
# 15, and 16 skip inside it. Run those on the host for full coverage.

FROM ubuntu:24.04

ARG TARGETARCH
ARG CRDB_VERSION=v23.2.5

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# Dependencies the tests rely on:
#   bash 4+, awk, grep, sed              — assertion helpers
#   curl, ca-certificates                — install + (optional) cloud sinks
#   netcat-openbsd                       — Labs 12/13 sink and port checks
#   postgresql-client                    — Lab 1 Part F (psql connectivity)
#   python3, python3-psycopg2            — Lab 1 Part F, Lab 14 (retry/outbox/idempotency code)
#   python3-yaml                         — Lab 16 manifest validation
#   unzip                                — Lab 9 (inspecting `cockroach debug zip` output)
#   lsof, procps                         — lib/common.sh pick_free_port, pgrep/pkill
#   tini                                 — proper PID 1 signal handling for spawned crdb procs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash curl ca-certificates netcat-openbsd unzip \
        postgresql-client \
        python3 python3-psycopg2 python3-yaml \
        lsof procps tini \
        coreutils gawk grep sed \
 && rm -rf /var/lib/apt/lists/*

# Pin the cockroach version inside the image so test results are reproducible.
# Multi-arch: TARGETARCH is "amd64" or "arm64" on docker buildx.
RUN set -eux; \
    ARCH="${TARGETARCH:-amd64}"; \
    TARBALL="cockroach-${CRDB_VERSION}.linux-${ARCH}.tgz"; \
    curl -fSL -o /tmp/${TARBALL} "https://binaries.cockroachdb.com/${TARBALL}"; \
    tar -xz -C /usr/local/bin --strip-components=1 \
        -f /tmp/${TARBALL} \
        "cockroach-${CRDB_VERSION}.linux-${ARCH}/cockroach"; \
    rm /tmp/${TARBALL}; \
    cockroach version

WORKDIR /work
COPY . /work/

# Make every lab test script executable (idempotent — also ensures the bit is set
# even if the host filesystem stripped it on copy, e.g. Windows hosts).
RUN chmod +x /work/tests/*.sh /work/tests/run_all.sh

# tini handles signals and reaps zombie cockroach processes cleanly when a test
# leaves background processes during shutdown.
ENTRYPOINT ["/usr/bin/tini", "--"]

# Default command runs the whole suite. Override with any tests/lab0N_test.sh.
CMD ["/work/tests/run_all.sh"]
