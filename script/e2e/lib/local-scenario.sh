#!/usr/bin/env bash
# Generic local mode e2e runner.
# Starts two anvils (L1 + L2), deploys infra + app, executes L2 then L1, decodes events.
#
# Usage (from project root):
#   bash script/e2e/lib/local-scenario.sh <E2E.s.sol>
#
# Standard contracts in E2E.s.sol (all read args from env vars):
#   Deploy* contracts  → auto-discovered, run in file order (L2 suffix → L2 RPC)
#   ExecuteL2          → L2 execution (load table on L2 and trigger any L2 user tx)
#   Execute            → L1 execution (postAndVerifyBatch + user action, same-block)
source "$(dirname "$0")/E2EBase.sh"

[[ $# -ge 1 ]] || { echo "Usage: local-scenario.sh <E2E.s.sol>"; exit 1; }
SOL="$1"
shift
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

L1_PORT="${L1_PORT:-8545}"
L2_PORT="${L2_PORT:-8546}"
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
# Optional anvil --chain-id overrides. Use unique chain ids per parallel run
# so forge's broadcast/<basename>/<chain_id>/ directories don't collide.
L1_CHAIN_ID="${L1_CHAIN_ID:-}"
L2_CHAIN_ID="${L2_CHAIN_ID:-}"
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Stress fixtures may need room for Forge's padded delivery gas limits.
LOCAL_L2_BLOCK_GAS_LIMIT=$(sed -n 's|^// E2E_LOCAL_L2_BLOCK_GAS_LIMIT:[[:space:]]*||p' "$SOL")
if [[ -n "$LOCAL_L2_BLOCK_GAS_LIMIT" && ! "$LOCAL_L2_BLOCK_GAS_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: E2E_LOCAL_L2_BLOCK_GAS_LIMIT must be one positive decimal integer"
    exit 1
fi

# 1. Start anvils
start_anvil "$L1_PORT" L1_PID "$L1_CHAIN_ID"
start_anvil "$L2_PORT" L2_PID "$L2_CHAIN_ID" "$LOCAL_L2_BLOCK_GAS_LIMIT"

# 2. Deploy infrastructure
deploy_infra "$L1_RPC" "$PK" "$L2_RPC" "" "$SYSTEM_ADDRESS"
export ROLLUPS
export PROOF_SYSTEM
export L2_MANAGER
export RPC="$L1_RPC"
export MANAGER_L2
export L2_RPC

# 3. Deploy app contracts
echo ""
echo "====== Deploy App ======"
deploy_contracts "$SOL" "$L1_RPC" "$L2_RPC" "$PK"

# 4. For L2-starting tests: create signed raw tx (RLP_ENCODED_TX)
if scenario_has_contract "$SOL" ExecuteNetworkL2; then
    echo ""
    echo "====== Create Signed Transaction ======"
    build_trigger_txs "$SOL" local
fi

# 5. Execute (L2 first, then L1) — each is optional based on contract presence
FAILED=false
L2_BLOCK=""
L1_BLOCK=""

if scenario_has_contract "$SOL" ExecuteL2; then
    echo ""
    echo "====== Execute L2 (same-block) ======"
    set +e
    EXEC_L2=$(execute_l2_same_block "$SOL" "$L2_RPC" "$PK")
    L2_EXIT=$?
    set -e
    if [[ $L2_EXIT -eq 0 ]]; then
        echo "L2 execution succeeded"
        echo "$EXEC_L2" | grep -E "complete|done|counter" || true
        print_broadcast_txs "$SOL" "$L2_RPC" "L2"
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

if scenario_has_contract "$SOL" Execute; then
    echo ""
    echo "====== Execute L1 (same-block) ======"
    set +e
    EXEC_L1=$(execute_l1_same_block "$SOL" "$L1_RPC" "$PK")
    L1_EXIT=$?
    set -e
    if [[ $L1_EXIT -eq 0 ]]; then
        echo "L1 execution succeeded"
        echo "$EXEC_L1" | grep -E "complete|done|counter" || true
        print_broadcast_txs "$SOL" "$L1_RPC" "L1"
        # Auto-export any KEY=VALUE lines so ComputeExpected can read them.
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

# 6. Decode events (only for chains that ran)
[[ -n "$L2_BLOCK" ]] && decode_block "$L2_RPC" "$L2_BLOCK" "$MANAGER_L2" "L2 "
[[ -n "$L1_BLOCK" ]] && decode_block "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "L1 "

_SENDER=$(cast wallet address --private-key "$PK")

# 7. Verify on-chain events match expected hashes from ComputeExpected.
#    Asserts the cryptographic tie between off-chain prediction and on-chain reality.
#    Skipped (with a notice) if the scenario has no ComputeExpected contract.
if scenario_has_contract "$SOL" ComputeExpected; then
    echo ""
    echo "====== Compute Expected Entries ======"
    COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$L1_RPC" --sender "$_SENDER" 2>&1)

    extract_expected_outputs "$COMPUTE_OUT" || exit 1
    require_eventless_l1_state_check "$SOL" || exit 1

    VERIFIERS_RUN=0

    # ── Verify L1 batch consumption ──
    # Proxy-consumed entries (EXPECTED_L1_CALL_HASHES): ExecutionConsumed carries the call
    # hash — verify_l1_batch checks those identities only. With an expected table,
    # the calldata verifier below owns completion checks, including erased entries.
    # Scenarios with only zero-hash L2Tx entries check their declared hashes, even
    # with a table. Mixed scenarios rely on the calldata verifier for those entries.
    if [[ -n "$L1_BLOCK" && -n "$EXPECTED_L1_CALL_HASHES" && "$EXPECTED_L1_CALL_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L1" inline verify_l1_batch "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_CALL_HASHES" 0x
    elif [[ -n "$L1_BLOCK" && -n "$EXPECTED_L1_HASHES" && "$EXPECTED_L1_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L1 Zero-Hash Entries (block $L1_BLOCK) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L1" inline verify_l1_zero_hash "$L1_RPC" "$L1_BLOCK" "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_HASHES" 0x
    else
        echo ""
        echo "====== Verify L1 Events (SKIP: no event-only check needed) ======"
    fi

    # ── Compare all expected L1 content with the posted batch ──
    # Completion logs no longer carry call counts. Compare the arrays themselves,
    # replay expected hash steps when available, and require a distinct completion
    # for each committing posted entry. Reverting/static entries retain their
    # input checks even though their receipt events are absent.
    if [[ -n "$L1_BLOCK" && ( "$EXPECTED_L1_TABLE" != "0x" || "$EXPECTED_L1_STATIC_TABLE" != "0x" ) ]]; then
        echo ""
        echo "====== Verify L1 Posted Batch Calldata (block $L1_BLOCK) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L1 CALLDATA" inline verify_l1_calldata "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_TABLE" "$EXPECTED_L1_STEPS" "$EXPECTED_L1_STATIC_TABLE" "$EVENTLESS_L1_CALL_HASHES"
    fi

    # ── Verify L2 ExecutionTableLoaded entries ──
    if [[ -n "$L2_BLOCK" && -n "$EXPECTED_L2_HASHES" && ( "$EXPECTED_L2_HASHES" != "[]" || "${EXPECTED_L2_STATIC_TABLE:-0x}" != 0x ) ]]; then
        echo ""
        echo "====== Verify L2 Table (block $L2_BLOCK) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L2 TABLE" inline verify_l2_table "$L2_RPC" "[$L2_BLOCK]" "$MANAGER_L2" "$EXPECTED_L2_HASHES" "$EXPECTED_L2_TABLE" "$EVENTLESS_L2_HASHES"
    else
        echo ""
        echo "====== Verify L2 Table (SKIP: no L2 block or no EXPECTED_L2_HASHES printed) ======"
    fi

    # ── Verify L2 CrossChainCallExecuted events ──
    if [[ -n "$L2_BLOCK" && -n "$EXPECTED_L2_CALL_HASHES" && "$EXPECTED_L2_CALL_HASHES" != "[]" ]]; then
        echo ""
        echo "====== Verify L2 Calls (block $L2_BLOCK) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L2 CALL" inline verify_l2_calls "$L2_RPC" "[$L2_BLOCK]" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" "$EXPECTED_L2_TABLE"
    else
        echo ""
        echo "====== Verify L2 Calls (SKIP: no L2 block or no EXPECTED_L2_CALL_HASHES printed) ======"
    fi

    # ── Verify L2 absence (lookups) ──
    # ABSENT_L2_HASHES are call keys that must have left NO trace on L2 (a call that
    # reverts on L2, a top-level static read: never delivered). The local L2 anvil is
    # fresh per run, so the whole chain is the range.
    if [[ -n "${ABSENT_L2_HASHES:-}" && "$ABSENT_L2_HASHES" != "[]" ]]; then
        _L2_TIP=$(cast block-number --rpc-url "$L2_RPC")
        echo ""
        echo "====== Verify L2 Absent (keys must not appear in blocks 0..$_L2_TIP) ======"
        VERIFIERS_RUN=$((VERIFIERS_RUN + 1))
        run_verify_step "L2 ABSENT" inline verify_l2_absent "$L2_RPC" 0 "$_L2_TIP" "$MANAGER_L2" "$ABSENT_L2_HASHES"
    fi

    # A ComputeExpected that drives zero verifiers means the run asserted nothing on-chain.
    if [[ "$VERIFIERS_RUN" -eq 0 ]]; then
        echo ""
        echo "ERROR: ComputeExpected present but 0 verifiers ran - nothing was verified"
        FAILED=true
    fi
else
    echo ""
    echo "====== Verify (skipped — no contract ComputeExpected) ======"
fi

# 8. Check persisted state on both chains, including sides with no delivery.
# Execute assertions run during simulation; these checks read the mined state.
_verify_local_state() {
    VERIFY_OUT=$(forge script "$SOL:$1" --rpc-url "$2" --sender "$_SENDER" 2>&1)
}
for _VN_NAME in VerifyNetwork VerifyNetworkL2; do
    scenario_has_contract "$SOL" "$_VN_NAME" || continue
    _VN_RPC="$L1_RPC"
    [[ "$_VN_NAME" != VerifyNetworkL2 ]] || _VN_RPC="$L2_RPC"
    echo ""
    echo "====== Scenario Self-Verification ($_VN_NAME) ======"
    run_verify_step "$_VN_NAME" inline _verify_local_state "$_VN_NAME" "$_VN_RPC"
done

if $FAILED; then
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
