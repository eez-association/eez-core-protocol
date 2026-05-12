#!/usr/bin/env bash
# Generic local mode e2e runner.
# Starts two anvils (L1 + L2), deploys infra + app, executes L2 then L1, decodes events.
#
# Usage (from project root):
#   bash script/e2e/shared/run-local.sh <E2E.s.sol>
#
# Standard contracts in E2E.s.sol (all read args from env vars):
#   Deploy* contracts  → auto-discovered, run in file order (L2 suffix → L2 RPC)
#   ExecuteL2          → L2 execution (load table on L2 and trigger any L2 user tx)
#   Execute            → L1 execution (postVerifyAndExecuteOrSaveExecutionsFromBatch + user action via Batcher)
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-local.sh <E2E.s.sol>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

L1_PORT="${L1_PORT:-8545}"
L2_PORT="${L2_PORT:-8546}"
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
export L2_ROLLUP_ID=1
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# 1. Start anvils
start_anvil "$L1_PORT" L1_PID
start_anvil "$L2_PORT" L2_PID

# 2. Deploy infrastructure
deploy_infra "$L1_RPC" "$PK" "$L2_RPC" "$L2_ROLLUP_ID" "$SYSTEM_ADDRESS"
export ROLLUPS
export PROOF_SYSTEM
export L2_MANAGER
export RPC="$L1_RPC"
export MANAGER_L2
export L2_RPC

# 3. CREATE2 factories
ensure_create2_factory "$L1_RPC" "L1" "$PK"
ensure_create2_factory "$L2_RPC" "L2" "$PK"

# 4. Deploy app contracts
echo ""
echo "====== Deploy App ======"
deploy_contracts "$SOL" "$L1_RPC" "$L2_RPC" "$PK"

# 5. For L2-starting tests: create signed raw tx (RLP_ENCODED_TX)
if grep -q 'contract ExecuteNetworkL2 ' "$SOL"; then
    echo ""
    echo "====== Create Signed Transaction ======"
    _EXEC_OUT=$(forge script "$SOL:ExecuteNetworkL2" --rpc-url "$L2_RPC" 2>&1)
    _TX_TARGET=$(extract "$_EXEC_OUT" "TARGET")
    _TX_CALLDATA=$(extract "$_EXEC_OUT" "CALLDATA")
    _TX_VALUE=$(extract "$_EXEC_OUT" "VALUE")

    _SENDER=$(cast wallet address --private-key "$PK")
    _NONCE=$(cast nonce "$_SENDER" --rpc-url "$L2_RPC")
    _USER_NONCE=$((_NONCE + 1))

    export RLP_ENCODED_TX=$(cast mktx "$_TX_TARGET" "$_TX_CALLDATA" \
        --value "${_TX_VALUE}wei" \
        --gas-limit 2000000 \
        --nonce "$_USER_NONCE" \
        --private-key "$PK" \
        --rpc-url "$L2_RPC")
fi

# 6. Execute (L2 first, then L1) — each is optional based on contract presence
FAILED=false
L2_BLOCK=""
L1_BLOCK=""

if grep -q 'contract ExecuteL2 ' "$SOL"; then
    echo ""
    echo "====== Execute L2 (same-block) ======"
    set +e
    EXEC_L2=$(execute_l2_same_block "$SOL" "$L2_RPC" "$PK")
    L2_EXIT=$?
    set -e
    if [[ $L2_EXIT -eq 0 ]]; then
        echo "L2 execution succeeded"
        echo "$EXEC_L2" | grep -E "complete|done|counter" || true
    else
        echo "L2 execution FAILED (exit=$L2_EXIT) — full output below:"
        echo "$EXEC_L2"
        FAILED=true
    fi
    trace_failed_txs "$EXEC_L2" "$L2_RPC"
    L2_BLOCK=$(cast block-number --rpc-url "$L2_RPC")
    echo "L2 execution at block $L2_BLOCK"
else
    echo ""
    echo "====== Execute L2 (skipped — no contract ExecuteL2) ======"
fi

if grep -q 'contract Execute ' "$SOL"; then
    echo ""
    echo "====== Execute L1 ======"
    set +e
    EXEC_L1=$(forge script "$SOL:Execute" --rpc-url "$L1_RPC" --broadcast --private-key "$PK" 2>&1)
    L1_EXIT=$?
    set -e
    if [[ $L1_EXIT -eq 0 ]]; then
        echo "L1 execution succeeded"
        echo "$EXEC_L1" | grep -E "complete|done|counter" || true
    else
        echo "L1 execution FAILED (exit=$L1_EXIT) — full output below:"
        echo "$EXEC_L1"
        FAILED=true
    fi
    trace_failed_txs "$EXEC_L1" "$L1_RPC"
    L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
    echo "L1 execution at block $L1_BLOCK"
else
    echo ""
    echo "====== Execute L1 (skipped — no contract Execute) ======"
fi

# 7. Decode events (only for chains that ran)
[[ -n "$L2_BLOCK" ]] && decode_block "$L2_RPC" "$L2_BLOCK" "$MANAGER_L2" "L2 "
[[ -n "$L1_BLOCK" ]] && decode_block "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "L1 "

if $FAILED; then
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
