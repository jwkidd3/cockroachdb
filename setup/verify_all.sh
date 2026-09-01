#!/usr/bin/env bash
# Run verify_student_vm.sh on every VM in setup/hosts.txt and summarize.
#
#   setup/verify_all.sh

set -uo pipefail
HOSTS="${HOSTS:-$(dirname "$0")/hosts.txt}"
SSH_USER="${SSH_USER:-student}"
SSH_KEY="${SSH_KEY:-}"
SCRIPT="$(dirname "$0")/verify_student_vm.sh"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")

READY=0; NOT_READY=0
while read -r name ip _; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    printf '%-20s ' "$name"
    if out=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'bash -s' < "$SCRIPT" 2>&1); then
        echo "READY   ($(echo "$out" | grep -E '^Pass:' | tail -1))"
        READY=$((READY+1))
    else
        echo "NOT READY"
        echo "$out" | grep -E '^FAIL' | sed 's/^/      /'
        NOT_READY=$((NOT_READY+1))
    fi
done < "$HOSTS"

echo
echo "Ready: $READY   Not ready: $NOT_READY"
[ "$NOT_READY" -eq 0 ]
