#!/usr/bin/env bash
# Run every lab test in sequence. Print a summary table at the end.
# Exit 0 iff all tests pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Day 1: labs 1-4   Day 2: labs 5-8   Day 3: labs 9-12   Day 4: labs 13-16
# Run a subset with DAY=3 ./run_all.sh, or LABS_OVERRIDE="lab08_test.sh lab10_test.sh" ./run_all.sh
ALL_LABS=(
    "lab01_test.sh" "lab02_test.sh" "lab03_test.sh" "lab04_test.sh"
    "lab05_test.sh" "lab06_test.sh" "lab07_test.sh" "lab08_test.sh"
    "lab09_test.sh" "lab10_test.sh" "lab11_test.sh" "lab12_test.sh"
    "lab13_test.sh" "lab14_test.sh" "lab15_test.sh" "lab16_test.sh"
)

case "${DAY:-all}" in
    1) LABS=("${ALL_LABS[@]:0:4}") ;;
    2) LABS=("${ALL_LABS[@]:4:4}") ;;
    3) LABS=("${ALL_LABS[@]:8:4}") ;;
    4) LABS=("${ALL_LABS[@]:12:4}") ;;
    all) LABS=("${ALL_LABS[@]}") ;;
    *) echo "DAY must be 1-4 or unset"; exit 2 ;;
esac

# Explicit override: LABS="lab08_test.sh lab13_test.sh" ./run_all.sh
if [ -n "${LABS_OVERRIDE:-}" ]; then
    read -r -a LABS <<< "$LABS_OVERRIDE"
fi

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
