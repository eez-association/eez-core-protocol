#!/usr/bin/env bash
# Cross-chain block decoder.
#
# NOTE: Post-multi-prover-refactor, the orchestrator no longer encodes L2 block
# numbers in postAndVerifyBatch callData. The cross-chain block correlation that was the
# main feature of this script is no longer available on-chain. The single-block
# decoder still works (decodes events on the given chain at the given block) —
# if you only need that, just call:
#   forge script script/DecodeExecutions.s.sol:DecodeExecutions \
#     --rpc-url <RPC> --sig "runBlock(uint256,address)" <BLOCK> <ADDR>
#
# Usage:
#   bash script/e2e/shared/decode-block.sh \
#     --l1-block <N> --l1-rpc <RPC> --l2-rpc <RPC> \
#     --rollups <ADDR> --manager-l2 <ADDR>
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

source "$(dirname "$0")/E2EBase.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-block)     L1_BLOCK="$2"; shift 2;;
        --l1-rpc)       L1_RPC="$2"; shift 2;;
        --l2-rpc)       L2_RPC="$2"; shift 2;;
        --rollups)      ROLLUPS="$2"; shift 2;;
        --manager-l2)   MANAGER_L2="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_BLOCK L1_RPC L2_RPC ROLLUPS MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

DECODE_SCRIPT="script/DecodeExecutions.s.sol:DecodeExecutions"

# 1. Decode L1 block
echo ""
echo "====== L1 Block $L1_BLOCK (EEZ @ $ROLLUPS) ======"
echo ""
forge script "$DECODE_SCRIPT" \
    --rpc-url "$L1_RPC" \
    --sig "runBlock(uint256,address)" "$L1_BLOCK" "$ROLLUPS" 2>&1 \
    | sed -n '/^  /p'

echo ""
echo "(L2-block correlation no longer available post-refactor — see header comment)"

# Post-refactor event sig — kept for documentation/callers that grep this file.
SIG_BATCH_POSTED=$(cast keccak 'BatchPosted(bytes32,uint64[])')
: "$SIG_BATCH_POSTED"

echo ""
echo "====== Done ======"
