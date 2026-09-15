#!/usr/bin/env bash
# Provision a WSL2 Ubuntu distro for the CockroachDB 4-day course.
#
#   sudo bash provision_wsl.sh
#
# Run this INSIDE WSL, after the Windows-side steps in SETUP_WSL.md.
# Idempotent — safe to re-run.
#
# ---------------------------------------------------------------------------
# What gets installed locally, and why it has to be
# ---------------------------------------------------------------------------
# The course runs in Docker. Nothing here installs CockroachDB, and the list
# below is deliberately short — if a tool can run in a container, it does:
#
#   INSTALLED   kind, kubectl   optional Kubernetes exercise. kind drives the Docker daemon to build
#                               Kubernetes nodes, so it cannot itself be in a
#                               container. kubectl follows it.
#   INSTALLED   psql            Labs 8 and 15 use client-side \copy against
#                               local files. ~1 MB.
#   INSTALLED   python3 +       Six labs run Python against the cluster.
#               psycopg2        WSL already has python3; only the driver is new.
#
#   CONTAINER   cockroach       docker/labs*.yml, via scripts/crdb
#   CONTAINER   molt            Lab 15   — cockroachdb/molt
#   CONTAINER   helm            optional Kubernetes exercise — alpine/helm
#   CONTAINER   prometheus,     Labs 9, 13, 15
#               grafana, kafka,
#               postgres
#
#   NOT NEEDED  Go              The Go in Lab 14 and Day 4 is illustrative
#                               snippets. Nothing compiles it.
#
# Docker itself is NOT installed here: Docker Desktop on Windows provides the
# daemon and WSL integration provides the client. Installing docker-ce inside
# the distro fights with that.

set -euo pipefail

KIND_VERSION="${KIND_VERSION:-v0.23.0}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.29.2}"
CRDB_VERSION="${CRDB_VERSION:-v23.2.5}"

log()  { echo -e "\033[34m==>\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash provision_wsl.sh"

if [ "${ALLOW_NON_WSL:-0}" != "1" ]; then
    grep -qi microsoft /proc/version 2>/dev/null \
      || die "this is not WSL. On a real Ubuntu VM use provision_student_vm.sh instead."
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
log "provisioning for user: $TARGET_USER ($TARGET_HOME)"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) K8S_ARCH="$ARCH" ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

# ---------------------------------------------------------------- base packages
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git jq bc unzip \
    netcat-openbsd lsof procps openssl \
    postgresql-client \
    python3 python3-pip

# ------------------------------------------------------------------ docker check
if ! command -v docker >/dev/null 2>&1; then
    die "docker not found in this distro.
    Docker Desktop -> Settings -> Resources -> WSL integration -> enable this distro,
    then Apply & Restart and re-run this script."
fi
if ! docker info >/dev/null 2>&1; then
    die "docker is installed but the daemon is unreachable.
    Start Docker Desktop on Windows, confirm WSL integration is on for this distro,
    then re-run."
fi
DOCKER_GB=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
log "docker reachable; WSL has ${DOCKER_GB} GB"
if [ "$DOCKER_GB" -lt 8 ]; then
    warn "WSL has only ${DOCKER_GB} GB. the optional Kubernetes exercise (kind) needs ~8 GB, Lab 7 needs ~6 GB."
    warn "On Windows create %UserProfile%\\.wslconfig containing:"
    warn "    [wsl2]"
    warn "    memory=9GB"
    warn "    processors=4"
    warn "then run 'wsl --shutdown' in PowerShell and reopen this shell."
fi

# --------------------------------------------------------------- kind + kubectl
# The only two binaries the course genuinely needs on the machine.
if ! command -v kind >/dev/null 2>&1; then
    log "installing kind $KIND_VERSION"
    curl -fsSLo /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${K8S_ARCH}"
    chmod +x /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null 2>&1; then
    # Match kubectl to the kind node image. stable.txt has drifted many minors
    # past it, and Kubernetes supports only +/-1.
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
    psycopg2-binary sqlalchemy sqlalchemy-cockroachdb 2>/dev/null \
  || pip3 install $PIP_FLAGS psycopg2-binary sqlalchemy sqlalchemy-cockroachdb

# ------------------------------------------------- systemd, limits and sysctls
# Without systemd, WSL2 ignores /etc/sysctl.d and /etc/security/limits.d — so
# kind hits vm.max_map_count=65530 and dies, and the file-handle ceiling stays
# at 1024. Turning systemd on makes both behave the way they do on a VM.
NEEDS_RESTART=0
if ! grep -qs 'systemd=true' /etc/wsl.conf 2>/dev/null; then
    log "enabling systemd in /etc/wsl.conf"
    touch /etc/wsl.conf
    if grep -q '^\[boot\]' /etc/wsl.conf; then
        sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
    else
        printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
    fi
    NEEDS_RESTART=1
fi

cat > /etc/security/limits.d/99-cockroach.conf <<'LIM'
*    soft    nofile    65536
*    hard    nofile    65536
root soft    nofile    65536
root hard    nofile    65536
LIM

cat > /etc/sysctl.d/99-cockroach.conf <<'SYS'
# kind / Kubernetes need a high map count and inotify limits
vm.max_map_count              = 262144
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 512
fs.file-max                   = 1000000
SYS
sysctl -q -p /etc/sysctl.d/99-cockroach.conf 2>/dev/null || true

mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=65536\n' > /etc/systemd/system.conf.d/99-nofile.conf

# ---------------------------------------------------- pre-pull container images
# This is what saves lab time: every tool the course uses, cached up front.
log "pre-pulling container images"
for img in \
    "cockroachdb/cockroach:${CRDB_VERSION}" \
    "cockroachdb/cockroach:v23.2.6" \
    "$KIND_NODE_IMAGE" \
    "prom/prometheus:latest" \
    "grafana/grafana:latest" \
    "apache/kafka:3.9.0" \
    "postgres:16" \
    "cockroachdb/molt:latest" \
    "alpine/helm:latest" ; do
    log "  pulling $img"
    docker pull -q "$img" >/dev/null || warn "failed to pull $img"
done

# ------------------------------------------------------------- class licence
# The class licence ships in the repo as .license.env. Exporting
# COCKROACH_LICENSE while provisioning overrides it — useful for a fresh key
# before the committed one has been updated.
if [ -n "${COCKROACH_LICENSE:-}" ]; then
    log "writing the class licence to $COURSE_DIR/.license.env"
    {
        echo "COCKROACH_LICENSE=${COCKROACH_LICENSE}"
        [ -n "${COCKROACH_ORG:-}" ] && echo "COCKROACH_ORG=${COCKROACH_ORG}"
    } > "$COURSE_DIR/.license.env"
    chown "$TARGET_USER:$TARGET_USER" "$COURSE_DIR/.license.env"
    chmod 600 "$COURSE_DIR/.license.env"
fi

# ------------------------------------------------------------ shell conveniences
# Where the course actually lives — derived from this script, not assumed, so
# the repo can sit in any directory on any machine. Override with COURSE_DIR=...
COURSE_DIR="${COURSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cat > "$TARGET_HOME/.crdb_course_env" <<ENVEOF
# CockroachDB course conveniences
export CRDB_INSECURE='postgresql://root@localhost:26257?sslmode=disable'
# WSL is Linux, so use the .sh wrapper — crdb.bat is for native cmd/PowerShell.
alias crdb='bash $COURSE_DIR/scripts/crdb.sh'
alias crup='bash $COURSE_DIR/scripts/crdb.sh up'
alias crsql='bash $COURSE_DIR/scripts/crdb.sh sql'
alias crnodes='bash $COURSE_DIR/scripts/crdb.sh status'
alias labreset='bash $COURSE_DIR/setup/reset_labs.sh'
# Tools that run in containers rather than being installed:
alias molt='docker run --rm --network crdb-labs_default -v /tmp/lab15:/tmp/lab15 cockroachdb/molt'
alias helm='docker run --rm -v "\$HOME/.config/helm:/root/.config/helm" -v "\$HOME/.cache/helm:/root/.cache/helm" alpine/helm'
ENVEOF
install -d -o "$TARGET_USER" -g "$TARGET_USER" \
    "$TARGET_HOME/.config/helm" "$TARGET_HOME/.cache/helm" /tmp/lab15
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.crdb_course_env"
grep -q crdb_course_env "$TARGET_HOME/.bashrc" 2>/dev/null || \
    echo '[ -f ~/.crdb_course_env ] && source ~/.crdb_course_env' >> "$TARGET_HOME/.bashrc"

# --------------------------------------------------------------------- warnings
case "$COURSE_DIR" in
  /mnt/*)
    warn "The course repo is on the Windows filesystem ($COURSE_DIR)."
    warn "Bind mounts and git are dramatically slower there, and ownership of the"
    warn "labs' mounted directories (lab9/, lab12/) behaves oddly."
    warn "Move it into the Linux filesystem:  git clone <repo> ~/cockroachdb-course"
    ;;
esac

log "done"
if [ "$NEEDS_RESTART" = "1" ]; then
    echo
    echo "  systemd was just enabled. Run this in PowerShell, then reopen the shell:"
    echo "      wsl --shutdown"
fi
echo
echo "  Then verify:  bash $COURSE_DIR/setup/verify_student_vm.sh"
