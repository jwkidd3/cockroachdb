#!/usr/bin/env bash
# Generate the student connection sheet from setup/hosts.txt.
#
#   setup/make_student_sheet.sh > student-sheet.md

set -uo pipefail
HOSTS="${HOSTS:-$(dirname "$0")/hosts.txt}"
SSH_USER="${SSH_USER:-student}"
KEY_NAME="${KEY_NAME:-course_key}"

cat <<HDR
# CockroachDB Course — Your Machine

Each of you has a dedicated VM. Everything for all four days is pre-installed.

## Connecting

\`\`\`bash
chmod 600 ~/Downloads/${KEY_NAME}.pem
ssh -i ~/Downloads/${KEY_NAME}.pem ${SSH_USER}@<YOUR-IP>
\`\`\`

To reach the DB Console, Grafana, and Prometheus in **your own browser**, connect with
tunnels instead:

\`\`\`bash
ssh -i ~/Downloads/${KEY_NAME}.pem \\
    -L 8080:localhost:8080 \\
    -L 8081:localhost:8081 \\
    -L 8082:localhost:8082 \\
    -L 3000:localhost:3000 \\
    -L 9090:localhost:9090 \\
    ${SSH_USER}@<YOUR-IP>
\`\`\`

Then open <http://localhost:8080> (DB Console), <http://localhost:3000> (Grafana),
<http://localhost:9090> (Prometheus).

## Your assignment

| Student | Hostname | SSH |
| --- | --- | --- |
HDR

while read -r name ip _; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    echo "| $name | \`$ip\` | \`ssh -i ${KEY_NAME}.pem ${SSH_USER}@${ip}\` |"
done < "$HOSTS"

cat <<'FTR'

## First thing, every morning

```bash
cd ~/cockroachdb-course
git pull                       # pick up any lab corrections
bash setup/reset_labs.sh       # clean state
```

## If a lab goes sideways

```bash
bash ~/cockroachdb-course/setup/reset_labs.sh --all
```

That stops every cluster, removes lab data, deletes lab containers and kind clusters, and
confirms the ports are free. Then start the lab's Setup block again from the top.
FTR
