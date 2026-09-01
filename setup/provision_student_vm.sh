#!/usr/bin/env bash
# Provision a student VM for the CockroachDB 4-day course.
#
#   sudo bash provision_student_vm.sh
#
# Target: Ubuntu 22.04 / 24.04 LTS, 8 vCPU / 32 GB RAM / 150 GB SSD.
# Idempotent — safe to re-run.

set -euo pipefail

CRDB_VERSION="${CRDB_VERSION:-v23.2.5}"
KIND_VERSION="${KIND_VERSION:-v0.23.0}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.29.2}"
MOLT_VERSION="${MOLT_VERSION:-latest}"
STUDENT_USER="${STUDENT_USER:-student}"
COURSE_REPO="${COURSE_REPO:-}"          # optional git URL; otherwise copy the repo in manually
INSTALL_GO="${INSTALL_GO:-1}"
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
if ! command -v cockroach >/dev/null 2>&1 || [ "$(cockroach version --build-tag 2>/dev/null)" != "$CRDB_VERSION" ]; then
    log "installing cockroach $CRDB_VERSION ($CRDB_ARCH)"
    TARBALL="cockroach-${CRDB_VERSION}.linux-${CRDB_ARCH}.tgz"
    SRCDIR="/tmp/cockroach-${CRDB_VERSION}.linux-${CRDB_ARCH}"
    curl -fsSL "https://binaries.cockroachdb.com/${TARBALL}" -o "/tmp/${TARBALL}"
    rm -rf "$SRCDIR"
    tar -xz -C /tmp -f "/tmp/${TARBALL}"
    install -m 755 "${SRCDIR}/cockroach" /usr/local/bin/cockroach
    # Geo libraries enable the spatial features surveyed on Day 4.
    if [ -d "${SRCDIR}/lib" ]; then
        mkdir -p /usr/local/lib/cockroach
        cp -f "${SRCDIR}/lib/"* /usr/local/lib/cockroach/ 2>/dev/null || true
    fi
    rm -rf "/tmp/${TARBALL}" "$SRCDIR"
fi
cockroach version | head -2

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
    log "installing kubectl"
    KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${K8S_ARCH}/kubectl"
    chmod +x /usr/local/bin/kubectl
fi
if ! command -v helm >/dev/null 2>&1; then
    log "installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ------------------------------------------------------------------ python deps
log "installing python packages"
PIP_FLAGS="--quiet --no-cache-dir"
# PEP 668: Ubuntu 24.04 marks the system python as externally managed.
pip3 install $PIP_FLAGS --break-system-packages \
    psycopg2-binary sqlalchemy sqlalchemy-cockroachdb psycopg 2>/dev/null \
  || pip3 install $PIP_FLAGS psycopg2-binary sqlalchemy sqlalchemy-cockroachdb psycopg

# ---------------------------------------------------------------------- MOLT
if ! command -v molt >/dev/null 2>&1; then
    log "installing MOLT (Lab 15)"
    MOLT_URL="https://molt.cockroachdb.com/molt/cli/molt-${MOLT_VERSION}.linux-${CRDB_ARCH}.tgz"
    if curl -fsSL "$MOLT_URL" -o /tmp/molt.tgz 2>/dev/null; then
        rm -rf /tmp/molt-extract && mkdir -p /tmp/molt-extract
        tar -xz -C /tmp/molt-extract -f /tmp/molt.tgz 2>/dev/null || true
        find /tmp/molt-extract -type f -name 'molt*' -exec install -m 755 {} /usr/local/bin/ \; 2>/dev/null || true
        rm -rf /tmp/molt.tgz /tmp/molt-extract
    else
        echo "WARN: MOLT download failed — Lab 15 has a documented pure-SQL fallback path" >&2
    fi
fi

# ------------------------------------------------------------------------- Go
if [ "$INSTALL_GO" = "1" ] && ! command -v go >/dev/null 2>&1; then
    log "installing Go (optional, Lab 14 Go variants)"
    GO_VERSION="1.22.5"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${K8S_ARCH}.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
fi

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
fi

# ---------------------------------------------------- pre-pull container images
log "pre-pulling container images (this is what saves lab time)"
for img in \
    "prom/prometheus:latest" \
    "grafana/grafana:latest" \
    "bitnami/kafka:3.7" \
    "postgres:16" \
    "$KIND_NODE_IMAGE" \
    "cockroachdb/cockroach:${CRDB_VERSION}" ; do
    log "  pulling $img"
    docker pull -q "$img" || echo "WARN: failed to pull $img" >&2
done

# ------------------------------------------------------------ shell conveniences
cat > "$STUDENT_HOME/.crdb_course_env" <<'ENVEOF'
# CockroachDB course conveniences
export CRDB_INSECURE='postgresql://root@localhost:26257?sslmode=disable'
alias crsql='cockroach sql --insecure --host=localhost:26257'
alias crdemo='cockroach demo --nodes 3 --no-example-database --empty'
alias crnodes='cockroach node status --insecure --host=localhost:26257'
alias labreset='bash ~/cockroachdb-course/setup/reset_labs.sh'
ENVEOF
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
