#!/usr/bin/env bash
# Run a SET of e2e scenarios against the configured devnet, SEQUENTIALLY
# (shared deployer nonce — never parallelize network runs).
#
# Args are scenario names, categories, or category/direction paths:
#   bash script/e2e/shared/run-network-set.sh one_way            # whole category
#   bash script/e2e/shared/run-network-set.sh multi_call/L1_to_L2
#   bash script/e2e/shared/run-network-set.sh counter bridge     # specific scenarios
#   bash script/e2e/shared/run-network-set.sh all                # every scenario
#
# Devnet endpoints/addresses/key come from an env file (default:
# chain.env in the repo root; override with DEVNET_ENV=<file>). Required vars:
#   L1_RPC L1_FRONT L2_RPC L2_FRONT ROLLUPS MANAGER_L2 PK
#
# Example chain.env:
#   L1_RPC=https://l1-rpc.example.net                     # L1 read/deploy RPC
#   L1_FRONT=http://x.x.x.x:18999                         # L1 x-chain front (L1→L2 trigger txs ONLY)
#   L2_RPC=http://x.x.x.x:18688                           # L2 read/deploy RPC
#   L2_FRONT=http://x.x.x.x:18998                         # L2 x-chain front (L2→L1 trigger txs ONLY)
#   ROLLUPS=0x0000000000000000000000000000000000000000    # EEZ — L1 rollup registry
#   MANAGER_L2=0x4200000000000000000000000000000000000007 # EEZL2 — L2 manager (genesis predeploy)
#   PK=0x...                                              # test key, funded on BOTH chains
#
# Per-scenario logs: tmp/e2e-network/<scenario>.log. Exit 1 if any scenario fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

DEVNET_ENV="${DEVNET_ENV:-chain.env}"
[[ -f "$DEVNET_ENV" ]] || { echo "Missing devnet env file: $DEVNET_ENV (set DEVNET_ENV=<file>)"; exit 1; }
# shellcheck disable=SC1090
source "$DEVNET_ENV"

for var in L1_RPC L1_FRONT L2_RPC L2_FRONT ROLLUPS MANAGER_L2 PK; do
    [[ -n "${!var:-}" ]] || { echo "Missing $var (check $DEVNET_ENV)"; exit 1; }
done

[[ $# -gt 0 ]] || { echo "Usage: run-network-set.sh <scenario|category|all> ..."; exit 1; }

# ── Resolve args to scenario script paths ──
SOLS=()
for arg in "$@"; do
    if [[ "$arg" == "all" ]]; then
        while IFS= read -r sol; do SOLS+=("$sol"); done \
            < <(find script/e2e -mindepth 3 -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    elif [[ -d "script/e2e/$arg" ]]; then
        while IFS= read -r sol; do SOLS+=("$sol"); done \
            < <(find "script/e2e/$arg" -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    else
        sol=$(find script/e2e -mindepth 3 -path "*/$arg/E2E*.s.sol" -not -path '*/shared/*' | head -1)
        [[ -n "$sol" ]] && SOLS+=("$sol") || echo "  WARNING: no scenario matches '$arg' — skipping"
    fi
done
[[ ${#SOLS[@]} -gt 0 ]] || { echo "Nothing to run."; exit 1; }

mkdir -p tmp/e2e-network

PASS=0; FAIL=0; FAILED_LIST=()
for sol in "${SOLS[@]}"; do
    name=$(basename "$(dirname "$sol")")
    echo "════════════ RUNNING $name ($sol) ════════════"
    if RECEIPT_TIMEOUT="${RECEIPT_TIMEOUT:-420}" bash script/e2e/shared/run-network.sh "$sol" \
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
echo "===== NETWORK RESULT: $PASS passed, $FAIL failed ====="
for t in "${FAILED_LIST[@]:-}"; do [[ -n "$t" ]] && echo "  FAILED: $t"; done
[[ $FAIL -eq 0 ]]
