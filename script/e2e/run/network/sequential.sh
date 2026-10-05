#!/usr/bin/env bash
# Run a SET of e2e scenarios against the configured devnet, SEQUENTIALLY
# (shared deployer nonce — never parallelize network runs).
#
# Args are scenario names, categories, or category/direction paths:
#   bash script/e2e/run/network/sequential.sh one_way            # whole category
#   bash script/e2e/run/network/sequential.sh multi_call/L1_to_L2
#   bash script/e2e/run/network/sequential.sh counter bridge     # specific scenarios
#   bash script/e2e/run/network/sequential.sh all                # every scenario
#
# Endpoint URLs and PK come from the environment or optional chain.env
# (override with DEVNET_ENV=<file>). Addresses come from L2 eez_composerInfo.
# Required settings: L1_RPC L1_FRONT L2_RPC L2_FRONT PK.
#
# Per-scenario logs: tmp/e2e-network/<scenario>.log. Exit 1 if any scenario fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

source "$SCRIPT_DIR/../../lib/network-config.sh"
load_network_config "${DEVNET_ENV:-}" || exit 1
DEVNET_ENV="${DEVNET_ENV:-chain.env}"
for var in L1_RPC L1_FRONT L2_RPC L2_FRONT ROLLUPS MANAGER_L2 PK; do
    [[ -n "${!var:-}" ]] || { echo "Missing $var (check $DEVNET_ENV)"; exit 1; }
done

[[ $# -gt 0 ]] || { echo "Usage: sequential.sh <scenario|category|all> ..."; exit 1; }

# ── Resolve args to scenario script paths ──
SOLS=()
for arg in "$@"; do
    if [[ "$arg" == "all" ]]; then
        while IFS= read -r sol; do
            if grep -q '^// E2E_EXCLUDE_FROM_ALL:' "$sol"; then
                echo "SKIP $sol: NOT LIVE YET (excluded from all)" >&2
                continue
            fi
            SOLS+=("$sol")
        done < <(find script/e2e/scenarios -mindepth 3 -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    elif [[ -d "script/e2e/scenarios/$arg" ]]; then
        while IFS= read -r sol; do SOLS+=("$sol"); done \
            < <(find "script/e2e/scenarios/$arg" -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    else
        sol=$(find script/e2e/scenarios -mindepth 3 -path "*/$arg/E2E*.s.sol" -not -path '*/shared/*' | head -1)
        [[ -n "$sol" ]] && SOLS+=("$sol") || echo "  WARNING: no scenario matches '$arg' — skipping"
    fi
done
[[ ${#SOLS[@]} -gt 0 ]] || { echo "Nothing to run."; exit 1; }

mkdir -p tmp/e2e-network

PASS=0; FAIL=0; FAILED_LIST=()
SKIPPED=0
for sol in "${SOLS[@]}"; do
    name=$(basename "$(dirname "$sol")")
    # Local-only scenarios (e.g. multi-tx triggers) carry no network driver contract.
    if ! grep -qE 'contract ExecuteNetwork(L2)? ' "$sol"; then
        SKIPPED=$((SKIPPED+1)); echo "RESULT $name: SKIP (local-only — no ExecuteNetwork contract)"
        continue
    fi
    echo "════════════ RUNNING $name ($sol) ════════════"
    if RECEIPT_TIMEOUT="${RECEIPT_TIMEOUT:-420}" bash script/e2e/lib/network-scenario.sh "$sol" \
        --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
        --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
        --pk "$PK" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        > "tmp/e2e-network/$name.log" 2>&1; then
        PASS=$((PASS+1)); echo "RESULT $name: PASS"
    else
        FAIL=$((FAIL+1)); FAILED_LIST+=("$name"); echo "RESULT $name: FAIL"
        grep -E "DEPLOY FAILED|ERROR|VERIFICATION FAILED|missing" "tmp/e2e-network/$name.log" | head -3
        echo "  full log: tmp/e2e-network/$name.log"
    fi
done

echo ""
echo "===== NETWORK RESULT: $PASS passed, $FAIL failed, $SKIPPED skipped (local-only) ====="
for t in "${FAILED_LIST[@]:-}"; do [[ -n "$t" ]] && echo "  FAILED: $t"; done
[[ $FAIL -eq 0 ]]
