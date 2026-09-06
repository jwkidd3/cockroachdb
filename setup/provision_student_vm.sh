#!/usr/bin/env bash
# Provision a student VM for the CockroachDB 4-day course.
#
#   sudo bash provision_student_vm.sh
#
# Target: Ubuntu 22.04 / 24.04 LTS, 4-8 vCPU / 12 GB RAM / 100 GB SSD.
# 12 GB is enough for every lab, but not for two heavy stacks at once:
# stop the compose cluster before Lab 7 (9-node demo) or Lab 16 (kind).
# Idempotent — safe to re-run.

set -euo pipefail

CRDB_VERSION="${CRDB_VERSION:-v23.2.5}"
KIND_VERSION="${KIND_VERSION:-v0.23.0}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.29.2}"
STUDENT_USER="${STUDENT_USER:-student}"
COURSE_REPO="${COURSE_REPO:-}"          # optional git URL; otherwise copy the repo in manually
# Derived from this script, not assumed, so the repo can sit in any directory.
# If COURSE_REPO is set below, this is repointed at the clone.
COURSE_DIR="${COURSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_CODE_SERVER="${INSTALL_CODE_SERVER:-0}"

log() { echo -e "\033[34m==>\033[0m $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

ARCH="$(dpkg --print-architecture)"          # amd64 | arm64
case "$ARCH" in
  amd64) CRDB_ARCH="amd64"; K8S_ARCH="amd64" ;;
  arm64) CRDB_ARCH="arm64"; K8S_ARCH="arm64" ;;
  *) echo "unsupported architecture: $ARCH"; exit 1 ;;
esac

# ---------------------------------------------------------------- base packages
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    git tmux htop jq bc unzip zip tree \
    netcat-openbsd lsof procps openssl \
    postgresql-client \
    python3 python3-pip python3-venv \
    build-essential

# ------------------------------------------------------------------- student user
if ! id "$STUDENT_USER" >/dev/null 2>&1; then
    log "creating user $STUDENT_USER"
    useradd -m -s /bin/bash "$STUDENT_USER"
    usermod -aG sudo "$STUDENT_USER"
    echo "$STUDENT_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-student
    chmod 440 /etc/sudoers.d/90-student
fi
STUDENT_HOME="$(getent passwd "$STUDENT_USER" | cut -d: -f6)"

# Copy the launching user's authorized_keys so the same SSH key works for `student`.
for src in /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys; do
    if [ -f "$src" ]; then
        install -d -m 700 -o "$STUDENT_USER" -g "$STUDENT_USER" "$STUDENT_HOME/.ssh"
        cat "$src" >> "$STUDENT_HOME/.ssh/authorized_keys"
        sort -u "$STUDENT_HOME/.ssh/authorized_keys" -o "$STUDENT_HOME/.ssh/authorized_keys"
        chown "$STUDENT_USER:$STUDENT_USER" "$STUDENT_HOME/.ssh/authorized_keys"
        chmod 600 "$STUDENT_HOME/.ssh/authorized_keys"
    fi
done

# ---------------------------------------------------------------------- cockroach
# NOT installed: every lab runs CockroachDB in Docker via docker/labs.yml.
# The image is pre-pulled below so the first `scripts/crdb up` is instant.

# ------------------------------------------------------------------------- docker
if ! command -v docker >/dev/null 2>&1; then
    log "installing docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$STUDENT_USER"
systemctl enable --now docker

# --------------------------------------------------------------- kind + kubectl
if ! command -v kind >/dev/null 2>&1; then
    log "installing kind $KIND_VERSION"
    curl -fsSLo /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${K8S_ARCH}"
    chmod +x /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null 2>&1; then
    # Match kubectl to the kind node image, do NOT take whatever stable.txt says
    # today. Kubernetes supports +/-1 minor of skew; stable.txt has already drifted
    # many minors past kindest/node:v1.29.2, and a mismatched kubectl fails Lab 16
    # in ways that look like operator bugs.
    KUBECTL_VERSION="${KUBECTL_VERSION:-v${KIND_NODE_IMAGE##*:v}}"
    log "installing kubectl $KUBECTL_VERSION (matched to $KIND_NODE_IMAGE)"
    curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${K8S_ARCH}/kubectl"
    chmod +x /usr/local/bin/kubectl
fi

# ------------------------------------------------------------------ python deps
log "installing python packages"
PIP_FLAGS="--quiet --no-cache-dir"
# PEP 668: Ubuntu 24.04 marks the system python as externally managed.
pip3 install $PIP_FLAGS --break-system-packages \
    psycopg2-binary sqlalchemy sqlalchemy-cockroachdb psycopg 2>/dev/null \
  || pip3 install $PIP_FLAGS psycopg2-binary sqlalchemy sqlalchemy-cockroachdb psycopg

# MOLT, helm and Go are NOT installed locally:
#   molt  -> cockroachdb/molt image  (Lab 15)
#   helm  -> alpine/helm image       (Lab 16 Part E)
#   go    -> not needed; the Go in Lab 14 and Day 4 is illustrative snippets
# Both images are pre-pulled below.

# ------------------------------------------------------------ kernel / ulimits
log "applying kernel and ulimit tuning"
cat > /etc/security/limits.d/99-cockroach.conf <<'LIM'
*    soft    nofile    65536
*    hard    nofile    65536
root soft    nofile    65536
root hard    nofile    65536
LIM

cat > /etc/sysctl.d/99-cockroach.conf <<'SYS'
# kind / Kubernetes need a high map count and inotify limits
vm.max_map_count           = 262144
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 512
# CockroachDB is happier with a large file-handle ceiling
fs.file-max                = 1000000
# Faster failure detection on a lossy network
net.ipv4.tcp_keepalive_time = 60
SYS
sysctl --system >/dev/null

mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=65536\n' > /etc/systemd/system.conf.d/99-nofile.conf
systemctl daemon-reexec || true

# --------------------------------------------------------------- course repo
if [ -n "$COURSE_REPO" ]; then
    log "cloning course repo"
    sudo -u "$STUDENT_USER" git clone --depth 1 "$COURSE_REPO" \
        "$STUDENT_HOME/cockroachdb-course" 2>/dev/null || \
        (cd "$STUDENT_HOME/cockroachdb-course" && sudo -u "$STUDENT_USER" git pull --ff-only)
    COURSE_DIR="$STUDENT_HOME/cockroachdb-course"
fi

# ---------------------------------------------------- pre-pull container images
log "pre-pulling container images (this is what saves lab time)"
for img in \
    "prom/prometheus:latest" \
    "grafana/grafana:latest" \
    "apache/kafka:3.9.0" \
    "postgres:16" \
    "$KIND_NODE_IMAGE" \
    "cockroachdb/cockroach:${CRDB_VERSION}" \
    "cockroachdb/molt:latest" \
    "alpine/helm:latest" ; do
    log "  pulling $img"
    docker pull -q "$img" || echo "WARN: failed to pull $img" >&2
done

# ------------------------------------------------------------ shell conveniences
cat > "$STUDENT_HOME/.crdb_course_env" <<ENVEOF
# CockroachDB course conveniences
export CRDB_INSECURE='postgresql://root@localhost:26257?sslmode=disable'
# Enterprise licence — free for training, request one from Cockroach Labs.
# Uncomment and fill in before snapshotting the golden image, and every student
# gets the Lab 11 and Lab 13 enterprise steps instead of the skipped versions.
#export COCKROACH_ORG='Your Organisation'
#export COCKROACH_LICENSE='crl-0-...'
# Everything runs in Docker; scripts/crdb drives the lab cluster.
alias crdb='bash $COURSE_DIR/scripts/crdb.sh'
alias crup='bash $COURSE_DIR/scripts/crdb.sh up'
alias crsql='bash $COURSE_DIR/scripts/crdb.sh sql'
alias crnodes='bash $COURSE_DIR/scripts/crdb.sh status'
alias labreset='bash $COURSE_DIR/setup/reset_labs.sh'
# Tools that run in containers rather than being installed:
alias molt='docker run --rm --network crdb-labs_default -v /tmp/lab15:/tmp/lab15 cockroachdb/molt'
alias helm='docker run --rm -v "\$HOME/.config/helm:/root/.config/helm" -v "\$HOME/.cache/helm:/root/.cache/helm" alpine/helm'
ENVEOF
install -d -o "$STUDENT_USER" -g "$STUDENT_USER" \
    "$STUDENT_HOME/.config/helm" "$STUDENT_HOME/.cache/helm" /tmp/lab15
chown "$STUDENT_USER:$STUDENT_USER" "$STUDENT_HOME/.crdb_course_env"
grep -q crdb_course_env "$STUDENT_HOME/.bashrc" 2>/dev/null || \
    echo '[ -f ~/.crdb_course_env ] && source ~/.crdb_course_env' >> "$STUDENT_HOME/.bashrc"

# --------------------------------------------------------------- code-server
if [ "$INSTALL_CODE_SERVER" = "1" ]; then
    log "installing code-server"
    curl -fsSL https://code-server.dev/install.sh | sh
    systemctl enable --now "code-server@${STUDENT_USER}"
fi

log "provisioning complete — now run setup/verify_student_vm.sh as $STUDENT_USER"
