#!/usr/bin/env bash
# Run a command on every student VM listed in setup/hosts.txt.
#
#   setup/run_on_all.sh 'docker pull postgres:16'
#   HOSTS=setup/hosts.txt SSH_USER=student setup/run_on_all.sh 'uptime'
#
# hosts.txt format: one "name ip" per line, '#' comments allowed.

set -uo pipefail
HOSTS="${HOSTS:-$(dirname "$0")/hosts.txt}"
SSH_USER="${SSH_USER:-student}"
SSH_KEY="${SSH_KEY:-}"
PARALLEL="${PARALLEL:-8}"
CMD="${1:?usage: run_on_all.sh '<command>'}"

[ -f "$HOSTS" ] || { echo "no host list at $HOSTS (create it, or set HOSTS=)"; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")

run_one() {
    local name="$1" ip="$2"
    local out
    if out=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$CMD" 2>&1); then
        printf '\033[32m[OK]\033[0m %-20s %s\n' "$name" "$(echo "$out" | tail -1)"
    else
        printf '\033[31m[FAIL]\033[0m %-20s %s\n' "$name" "$(echo "$out" | tail -3 | tr '\n' ' ')"
    fi
}
n=0
while read -r name ip _; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    run_one "$name" "$ip" &
    n=$((n+1))
    [ $((n % PARALLEL)) -eq 0 ] && wait
done < "$HOSTS"
wait
echo "==> done across $n hosts"
