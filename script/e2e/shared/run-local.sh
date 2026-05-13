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
#   Execute            → L1 execution (postAndVerifyBatch + user action via Batcher)
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
        # Auto-export any KEY=VALUE lines (e.g. BATCHER_L1=<addr>) so ComputeExpected can read them.
        _export_outputs "$EXEC_L1"
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

# 8. Verify on-chain events match expected hashes from ComputeExpected.
#    Asserts the cryptographic tie between off-chain prediction and on-chain reality.
#    Skipped (with a notice) if the scenario has no ComputeExpected contract.
if grep -q 'contract ComputeExpected ' "$SOL"; then
    echo ""
    echo "====== Compute Expected Entries ======"
    _SENDER=$(cast wallet address --private-key "$PK")
    COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$L1_RPC" --sender "$_SENDER" 2>&1)

    EXPECTED_L1_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L1_HASHES")
    EXPECTED_L2_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_HASHES")
    EXPECTED_L1_CALL_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L1_CALL_HASHES")
    EXPECTED_L2_CALL_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_CALL_HASHES")
    [[ -n "$EXPECTED_L1_HASHES"      ]] && echo "EXPECTED_L1_HASHES=$EXPECTED_L1_HASHES"
    [[ -n "$EXPECTED_L2_HASHES"      ]] && echo "EXPECTED_L2_HASHES=$EXPECTED_L2_HASHES"
    [[ -n "$EXPECTED_L1_CALL_HASHES" ]] && echo "EXPECTED_L1_CALL_HASHES=$EXPECTED_L1_CALL_HASHES"
    [[ -n "$EXPECTED_L2_CALL_HASHES" ]] && echo "EXPECTED_L2_CALL_HASHES=$EXPECTED_L2_CALL_HASHES"

    # ── Verify L1 batch consumption ──
    # VerifyL1Batch takes the list of crossChainCallHashes that should have been consumed
    # (BatchPosted no longer carries entries on this branch; ExecutionConsumed is the
    # primary signal). For scenarios with proxyEntryHash==0 (executeL2TX path) there's no
    # L1-side call hash to check — skip in that case.
    if [[ -n "$L1_BLOCK" && -n "$EXPECTED_L1_CALL_HASHES" && "$EXPECTED_L1_CALL_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
        set +e
        L1_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
            --rpc-url "$L1_RPC" \
            --sig "run(uint256,address,bytes32[])" \
            "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_CALL_HASHES" 2>&1)
        L1_VERIFY_EXIT=$?
        set -e
        if [[ $L1_VERIFY_EXIT -eq 0 ]]; then
            echo "$L1_VERIFY" | grep -E "^\s*PASS" || echo "  PASS"
        else
            echo "L1 VERIFICATION FAILED"
            echo "$L1_VERIFY" | strip_traces 2>/dev/null || echo "$L1_VERIFY"
            FAILED=true
        fi
    fi

    # ── Verify L2 ExecutionTableLoaded entries ──
    if [[ -n "$L2_BLOCK" && -n "$EXPECTED_L2_HASHES" && "$EXPECTED_L2_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L2 Table (block $L2_BLOCK) ======"
        set +e
        L2_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Blocks \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256[],address,bytes32[])" \
            "[$L2_BLOCK]" "$MANAGER_L2" "$EXPECTED_L2_HASHES" 2>&1)
        L2_VERIFY_EXIT=$?
        set -e
        if [[ $L2_VERIFY_EXIT -eq 0 ]]; then
            echo "$L2_VERIFY" | grep -E "^\s*PASS" || echo "  PASS"
        else
            echo "L2 TABLE VERIFICATION FAILED"
            echo "$L2_VERIFY" | strip_traces 2>/dev/null || echo "$L2_VERIFY"
            FAILED=true
        fi
    fi

    # ── Verify L2 CrossChainCallExecuted events ──
    if [[ -n "$L2_BLOCK" && -n "$EXPECTED_L2_CALL_HASHES" && "$EXPECTED_L2_CALL_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L2 Calls (block $L2_BLOCK) ======"
        set +e
        L2_CALL_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Calls \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256[],address,bytes32[])" \
            "[$L2_BLOCK]" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" 2>&1)
        L2_CALL_VERIFY_EXIT=$?
        set -e
        if [[ $L2_CALL_VERIFY_EXIT -eq 0 ]]; then
            echo "$L2_CALL_VERIFY" | grep -E "^\s*PASS" || echo "  PASS"
        else
            echo "L2 CALL VERIFICATION FAILED"
            echo "$L2_CALL_VERIFY" | strip_traces 2>/dev/null || echo "$L2_CALL_VERIFY"
            FAILED=true
        fi
    fi
else
    echo ""
    echo "====== Verify (skipped — no contract ComputeExpected) ======"
fi

if $FAILED; then
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
