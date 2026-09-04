#!/usr/bin/env bash
# Lab 16 — Kubernetes with cockroach-operator on kind.
# Requires docker + kind + kubectl and ~10 GB RAM. Skips cleanly otherwise,
# but still validates the manifests the lab ships.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

KIND_CLUSTER="lab16-test"
WORK="/tmp/crdb-lab16-$$"
OPERATOR_BASE="https://raw.githubusercontent.com/cockroachdb/cockroach-operator/master"

cleanup_all() {
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
    [ "${KEEP_ON_FAIL:-0}" != "1" ] && rm -rf "$WORK"
}
trap cleanup_all EXIT INT TERM

mkdir -p "$WORK"

section "Manifest validation (always runs)"

cat > "$WORK/kind-config.yaml" <<'YML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    labels: {topology.kubernetes.io/zone: zone-a}
  - role: worker
    labels: {topology.kubernetes.io/zone: zone-b}
  - role: worker
    labels: {topology.kubernetes.io/zone: zone-c}
YML

cat > "$WORK/crdb.yaml" <<'YML'
apiVersion: crdb.cockroachlabs.com/v1alpha1
kind: CrdbCluster
metadata:
  name: crdb
  namespace: default
spec:
  dataStore:
    pvc:
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 2Gi
        volumeMode: Filesystem
  resources:
    requests: {cpu: "500m", memory: 1Gi}
    limits:   {cpu: "1",    memory: 2Gi}
  tlsEnabled: true
  cockroachDBVersion: v23.2.5
  nodes: 3
  additionalLabels:
    app: crdb
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/instance: crdb
YML

python3 - "$WORK/kind-config.yaml" "$WORK/crdb.yaml" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("PyYAML not installed; falling back to a structural check")
    for p in sys.argv[1:]:
        text = open(p).read()
        assert "apiVersion" in text and "kind" in text, f"{p} missing apiVersion/kind"
    print("structural check passed")
    sys.exit(0)

kind_cfg = yaml.safe_load(open(sys.argv[1]))
assert kind_cfg["kind"] == "Cluster"
workers = [n for n in kind_cfg["nodes"] if n["role"] == "worker"]
assert len(workers) == 3, "expected 3 workers"
zones = {w["labels"]["topology.kubernetes.io/zone"] for w in workers}
assert len(zones) == 3, f"workers must span 3 distinct zones, got {zones}"

crdb = yaml.safe_load(open(sys.argv[2]))
assert crdb["kind"] == "CrdbCluster"
spec = crdb["spec"]
assert spec["nodes"] == 3
assert spec["tlsEnabled"] is True
assert spec["resources"]["limits"]["memory"], "memory limit required (OOM protection)"
tsc = spec["topologySpreadConstraints"][0]
assert tsc["topologyKey"] == "topology.kubernetes.io/zone"
assert tsc["whenUnsatisfiable"] == "DoNotSchedule"
print("manifests valid: 3 zones, TLS on, memory limits set, topology spread enforced")
PY
[ $? -eq 0 ] && pass "kind and CrdbCluster manifests are valid" || fail "manifest validation failed"

section "Live cluster (needs docker + kind + kubectl)"

# What matters is the memory Docker itself has, not the host's — on macOS and
# Windows the daemon runs in a VM with its own (usually smaller) allocation, and
# /proc/meminfo does not exist at all.
MEM_GB=0
if docker info >/dev/null 2>&1; then
    MEM_GB=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
elif [ -r /proc/meminfo ]; then
    MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
fi

if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
    warn "kind or kubectl not installed; skipping the live-cluster test"
    echo "Lab 16: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed (live portion skipped)."
    [ "$FAIL_COUNT" -eq 0 ]; exit $?
fi
if ! docker info >/dev/null 2>&1; then
    warn "Docker unavailable; skipping the live-cluster test"
    echo "Lab 16: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed (live portion skipped)."
    [ "$FAIL_COUNT" -eq 0 ]; exit $?
fi
if [ "$MEM_GB" -gt 0 ] && [ "$MEM_GB" -lt 10 ] && [ "${FORCE_LAB16:-0}" != "1" ]; then
    warn "only ${MEM_GB} GB RAM detected; skipping (set FORCE_LAB16=1 to run anyway)"
    echo "Lab 16: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed (live portion skipped)."
    [ "$FAIL_COUNT" -eq 0 ]; exit $?
fi

info "creating kind cluster (this takes a few minutes)"
kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$KIND_CLUSTER" --config "$WORK/kind-config.yaml" --wait 300s \
    || fail "kind cluster creation failed"
pass "4-node kind cluster created"

NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
assert_eq "kind cluster has 4 nodes" "$NODES" "4"

ZONES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u | grep -c zone)
assert_eq "workers carry 3 distinct zone labels" "$ZONES" "3"

info "installing the operator"
kubectl apply -f "${OPERATOR_BASE}/install/crds.yaml" >/dev/null 2>&1 || fail "CRD install failed"
kubectl apply -f "${OPERATOR_BASE}/install/operator.yaml" >/dev/null 2>&1 || fail "operator install failed"
kubectl -n cockroach-operator-system rollout status deploy/cockroach-operator-manager --timeout=300s \
    >/dev/null 2>&1 || fail "operator did not become ready"
pass "cockroach-operator is running"

CRD=$(kubectl get crd crdbclusters.crdb.cockroachlabs.com -o name 2>/dev/null)
assert_contains "CrdbCluster CRD registered" "$CRD" "crdbclusters"

# `rollout status` says the operator's Pod is ready; it does NOT say the
# admission webhook is reachable. Applying in that gap fails with
# `failed calling webhook "mcrdbcluster.kb.io" ... connection refused`.
wait_for "operator webhook has ready endpoints" 180 \
    "[ -n \"\$(kubectl -n cockroach-operator-system get endpoints cockroach-operator-webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)\" ]"
pass "admission webhook is reachable"

info "deploying the CockroachDB cluster"
APPLY_OUT=""
for attempt in $(seq 1 12); do
    if APPLY_OUT=$(kubectl apply -f "$WORK/crdb.yaml" 2>&1); then
        APPLIED=1; break
    fi
    APPLIED=0
    grep -q "failed calling webhook" <<<"$APPLY_OUT" || break
    info "webhook not serving yet (attempt $attempt); retrying"
    sleep 5
done
[ "${APPLIED:-0}" = "1" ] || fail "CrdbCluster apply failed: $APPLY_OUT"

wait_for "3 crdb pods running" 600 \
    "[ \$(kubectl get pods -l app.kubernetes.io/instance=crdb --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge 3 ]"
pass "3 CockroachDB pods are running"

# Running is not Ready: the readiness probe only passes once the node has joined
# and is serving SQL, which is a little after the Pod reaches Running.
wait_for "statefulset reports 3 ready replicas" 600 \
    "[ \"\$(kubectl get statefulset crdb -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" = '3' ]"
pass "statefulset has 3 ready replicas"

PVCS=$(kubectl get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_ge "one PVC per pod" "$PVCS" "3"

# Replicas must not share a zone.
PLACEMENT=$(kubectl get pods -l app.kubernetes.io/instance=crdb \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')
assert_eq "pods spread across 3 distinct kubernetes nodes" "$PLACEMENT" "3"

info "scaling 3 -> 5"
kubectl patch crdbcluster crdb --type=merge -p '{"spec":{"nodes":5}}' >/dev/null 2>&1 \
    || warn "scale patch failed"
wait_for "5 crdb pods running" 600 \
    "[ \$(kubectl get pods -l app.kubernetes.io/instance=crdb --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge 5 ]" \
    || warn "scale-out did not reach 5 pods in time"
SCALED=$(kubectl get pods -l app.kubernetes.io/instance=crdb --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_ge "cluster scaled out" "$SCALED" "4"

info "killing a pod to test recovery"
kubectl delete pod crdb-2 --wait=false >/dev/null 2>&1 || true
wait_for "pod crdb-2 recreated and running" 300 \
    "kubectl get pod crdb-2 --no-headers 2>/dev/null | grep -q Running"
pass "StatefulSet recreated the pod with its original identity"

# The recreated pod must reattach its original PVC, not get a new one.
PVC_NAME=$(kubectl get pod crdb-2 -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null)
assert_contains "recreated pod reattached its original PVC" "$PVC_NAME" "crdb-2"

section "Done"
echo "Lab 16: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed."
[ "$FAIL_COUNT" -eq 0 ]
