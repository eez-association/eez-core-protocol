#!/usr/bin/env bash
# Run every script/e2e/<scenario>/E2E.s.sol via run-local.sh in parallel.
# Each scenario gets a unique (L1_PORT, L2_PORT, L1_CHAIN_ID, L2_CHAIN_ID) quadruple
# so anvil instances and forge broadcast/ dirs don't collide.
#
# Bad-script caveats:
#   - No retry, no resource throttling. If your machine can't host 17 anvil pairs,
#     pass MAX_PARALLEL to cap the worker count.
#   - Each test gets its own log under tmp/e2e-parallel/<scenario>.log.
#   - Success logs are kept in tmp/e2e-success/, failures in tmp/e2e-failures/.
#
# Usage:
#   bash script/e2e/shared/run-all-parallel.sh                # all scenarios
#   MAX_PARALLEL=4 bash script/e2e/shared/run-all-parallel.sh # at most 4 concurrent
#   bash script/e2e/shared/run-all-parallel.sh counter bridge # subset

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

# Default ordered list (mirrors .claude/commands/run-e2e.md).
DEFAULT_TESTS=(
    counter
    counterL2
    bridge
    helloWorld
    multi-call-twice
    multi-call-two-diff
    nestedCounter
    nestedCounterL2
    revertCounter
    revertCounterL2
    revertContinue
    revertContinueL2
    nestedCallRevert
    deepNested
    multi-call-nested
    multi-call-nestedL2
    reentrant
)

if [[ $# -gt 0 ]]; then
    TESTS=("$@")
else
    TESTS=("${DEFAULT_TESTS[@]}")
fi

MAX_PARALLEL="${MAX_PARALLEL:-${#TESTS[@]}}"
BASE_PORT="${BASE_PORT:-18545}"      # leave 8545/8546 alone for ad-hoc dev
BASE_CHAIN_ID="${BASE_CHAIN_ID:-41337}"

mkdir -p tmp/e2e-parallel tmp/e2e-success tmp/e2e-failures
rm -f tmp/e2e-parallel/*.log tmp/e2e-parallel/*.status

run_one() {
    local idx="$1" name="$2"
    local sol="script/e2e/$name/E2E.s.sol"
    local log="tmp/e2e-parallel/$name.log"
    local status="tmp/e2e-parallel/$name.status"
    if [[ ! -f "$sol" ]]; then
        echo "SKIP" > "$status"
        echo "  [$name] SKIP (missing $sol)" >&2
        return 0
    fi
    local l1_port=$((BASE_PORT + idx * 2))
    local l2_port=$((BASE_PORT + idx * 2 + 1))
    local l1_chain=$((BASE_CHAIN_ID + idx * 2))
    local l2_chain=$((BASE_CHAIN_ID + idx * 2 + 1))
    echo "  [$name] starting (L1=$l1_port chain=$l1_chain, L2=$l2_port chain=$l2_chain)" >&2
    if L1_PORT="$l1_port" L2_PORT="$l2_port" \
       L1_CHAIN_ID="$l1_chain" L2_CHAIN_ID="$l2_chain" \
       bash script/e2e/shared/run-local.sh "$sol" > "$log" 2>&1; then
        echo "PASS" > "$status"
        cp "$log" "tmp/e2e-success/$name.log"
        echo "  [$name] PASS" >&2
    else
        echo "FAIL" > "$status"
        cp "$log" "tmp/e2e-failures/$name.log"
        echo "  [$name] FAIL — see tmp/e2e-failures/$name.log" >&2
    fi
}

PIDS=()
ACTIVE=0
for i in "${!TESTS[@]}"; do
    name="${TESTS[$i]}"
    run_one "$i" "$name" &
    PIDS+=("$!")
    ACTIVE=$((ACTIVE + 1))
    if (( ACTIVE >= MAX_PARALLEL )); then
        wait -n 2>/dev/null || wait "${PIDS[0]}"
        ACTIVE=$((ACTIVE - 1))
    fi
done
wait

PASS=0; FAIL=0; SKIP=0
FAILED_LIST=()
for name in "${TESTS[@]}"; do
    s="$(cat "tmp/e2e-parallel/$name.status" 2>/dev/null || echo MISSING)"
    case "$s" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)); FAILED_LIST+=("$name") ;;
        SKIP) SKIP=$((SKIP+1)) ;;
        *)    FAIL=$((FAIL+1)); FAILED_LIST+=("$name (no status)") ;;
    esac
done

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed, $SKIP skipped ====="
for t in "${FAILED_LIST[@]}"; do echo "  FAILED: $t"; done
[[ $FAIL -eq 0 ]]
