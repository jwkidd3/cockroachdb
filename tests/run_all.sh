#!/usr/bin/env bash
# Run every lab test in sequence. Print a summary table at the end.
# Exit 0 iff all tests pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LABS=(
    "lab01_test.sh"
    "lab02_test.sh"
    "lab03_test.sh"
    "lab04_test.sh"
    "lab05_test.sh"
    "lab06_test.sh"
    "lab07_test.sh"
    "lab08_test.sh"
)

RESULTS=()
START_TIME=$(date +%s)

for lab in "${LABS[@]}"; do
    if [ ! -x "$lab" ]; then
        echo "SKIP: $lab not executable"
        RESULTS+=("$lab|SKIP|0")
        continue
    fi

    echo
    echo "============================================================"
    echo " Running $lab"
    echo "============================================================"

    lab_start=$(date +%s)
    if bash "$lab"; then
        lab_end=$(date +%s)
        RESULTS+=("$lab|PASS|$((lab_end - lab_start))")
    else
        lab_end=$(date +%s)
        RESULTS+=("$lab|FAIL|$((lab_end - lab_start))")
        if [ "${STOP_ON_FAIL:-0}" = "1" ]; then
            echo "STOP_ON_FAIL=1; aborting remaining tests"
            break
        fi
    fi
done

END_TIME=$(date +%s)

echo
echo "============================================================"
echo " Summary"
echo "============================================================"
printf '%-30s %-6s %s\n' "Lab" "Status" "Duration"
printf '%-30s %-6s %s\n' "------------------------------" "------" "--------"
PASS=0; FAIL=0; SKIP=0
for r in "${RESULTS[@]}"; do
    lab="${r%%|*}"; rest="${r#*|}"
    status="${rest%%|*}"; dur="${rest#*|}"
    printf '%-30s %-6s %ss\n' "$lab" "$status" "$dur"
    case "$status" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        SKIP) SKIP=$((SKIP+1)) ;;
    esac
done
echo
echo "Pass: $PASS   Fail: $FAIL   Skip: $SKIP   Total wallclock: $((END_TIME - START_TIME))s"

[ "$FAIL" -eq 0 ]
