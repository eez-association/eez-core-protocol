#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Generic network mode e2e runner
# ═══════════════════════════════════════════════════════════════════════
#
# Deploys app contracts, sends ONE user trigger transaction (L1 or L2),
# then verifies that the system/sequencer did its job:
#   - Posted the batch on L1 (postBatch)
#   - Loaded the execution table on L2 (loadExecutionTable)
#   - Executed cross-chain calls on L2 (IncomingCrossChainCallExecuted event)
#
# The test only sends the user tx. Everything else is the system's job.
#
# ── Trigger chain auto-detection ──
#   If the .sol file contains "contract ExecuteNetworkL2" → L2 trigger
#   Otherwise → L1 trigger (ExecuteNetwork)
#
# ── Block flow ──
#
#   L1 trigger:
#     User tx on L1 → receipt gives L1_BLOCK
#       → same block should contain postBatch (system batches user tx + batch together)
#       → extract_l2_blocks_from_tx decodes postBatch callData → L2_BLOCKS
#       → verify L1 batch, L2 table, L2 calls using those blocks
#
#   L2 trigger:
#     Record L1_BLOCK_BEFORE
#     User tx on L2 → receipt gives L2_BLOCK
#     Record L1_BLOCK_AFTER
#       → search L1 range [BEFORE..AFTER] for BatchPosted → L1_BLOCK
#       → extract_l2_blocks_from_tx from that L1 block → L2_BLOCKS
#       → if no L2_BLOCKS from batch, fall back to L2_BLOCK from receipt
#       → verify L1 batch, L2 table, L2 calls
#
# ── Usage ──
#   bash script/e2e/shared/run-network.sh <E2E.s.sol> \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> \
#     --rollups <ROLLUPS> --manager-l2 <MANAGER_L2> [--l2-rollup-id <ID>]
#
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-network.sh <E2E.s.sol> --l1-rpc <RPC> --l2-rpc <RPC> --pk <PK> --rollups <ROLLUPS> --manager-l2 <ADDR>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

# ── Parse CLI args → export as env vars for forge scripts ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)          export RPC="$2"; export L1_RPC="$2"; shift 2;;
        --pk)           export PK="$2"; shift 2;;
        --rollups)      export ROLLUPS="$2"; shift 2;;
        --l1-rpc)       export L1_RPC="$2"; export RPC="$2"; shift 2;;
        --l2-rpc)       export L2_RPC="$2"; shift 2;;
        --manager-l2)   export MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) export L2_ROLLUP_ID="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

export L2_ROLLUP_ID="${L2_ROLLUP_ID:-1}"

for var in RPC PK ROLLUPS L2_RPC MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ══════════════════════════════════════════════
#  1. Deploy app contracts
#     Auto-discovers Deploy* contracts in file order.
#     "L2" in name → deployed on L2 RPC, else L1.
# ══════════════════════════════════════════════
echo "====== Deploy ======"
deploy_contracts "$SOL" "$RPC" "$L2_RPC" "$PK"

# ══════════════════════════════════════════════
#  2. Create signed raw transaction
#     Run ExecuteNetwork(L2) read-only to get target/value/calldata,
#     then create a signed raw tx with `cast mktx`.
#     This RLP-encoded tx is used for:
#       a) Action hashing (passed to ComputeExpected & L1 scripts via env)
#       b) Sending the user tx on-chain (via cast publish)
# ══════════════════════════════════════════════
echo ""
echo "====== Create Signed Transaction ======"

if grep -q 'contract ExecuteNetworkL2 ' "$SOL"; then
    _TRIGGER_CHAIN="L2"
    _TRIGGER_CONTRACT="ExecuteNetworkL2"
    _TRIGGER_RPC="$L2_RPC"
else
    _TRIGGER_CHAIN="L1"
    _TRIGGER_CONTRACT="ExecuteNetwork"
    _TRIGGER_RPC="$RPC"
fi

_EXEC_OUT=$(forge script "$SOL:$_TRIGGER_CONTRACT" --rpc-url "$_TRIGGER_RPC" 2>&1)
_TX_TARGET=$(extract "$_EXEC_OUT" "TARGET")
_TX_VALUE=$(extract "$_EXEC_OUT" "VALUE")
_TX_CALLDATA=$(extract "$_EXEC_OUT" "CALLDATA")

echo "target: $_TX_TARGET"
echo "calldata: $_TX_CALLDATA"
echo "value: $_TX_VALUE"

# cast mktx creates a signed raw tx (queries chain for nonce + gas price, does NOT broadcast)
export RLP_ENCODED_TX=$(cast mktx "$_TX_TARGET" "$_TX_CALLDATA" \
    --value "${_TX_VALUE}wei" \
    --gas-limit 2000000 \
    --private-key "$PK" \
    --rpc-url "$_TRIGGER_RPC")

# ══════════════════════════════════════════════
#  3. Compute expected entries
#     Runs ComputeExpected (read-only) to get the
#     action hashes we expect in the batch and L2 table.
#     Reads RLP_ENCODED_TX from env for action hashing.
# ══════════════════════════════════════════════
echo ""
echo "====== Compute Expected Entries ======"
_SENDER=$(cast wallet address --private-key "$PK")
COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$RPC" --sender "$_SENDER" 2>&1)

EXPECTED_L1_CALL_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L1_CALL_HASHES")
echo "L1 expected calls: $EXPECTED_L1_CALL_HASHES"

EXPECTED_L2_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_HASHES")
if [[ -n "$EXPECTED_L2_HASHES" ]]; then
    echo "L2 table expected: $EXPECTED_L2_HASHES"
fi

EXPECTED_L2_CALL_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_CALL_HASHES")
echo "L2 calls expected: $EXPECTED_L2_CALL_HASHES"

ABSENT_L2_HASHES=$(extract "$COMPUTE_OUT" "ABSENT_L2_HASHES")
if [[ -n "$ABSENT_L2_HASHES" && "$ABSENT_L2_HASHES" != "[]" ]]; then
    echo "L2 absent (must NOT appear): $ABSENT_L2_HASHES"
fi

# Print summary (extract lines between === EXPECTED SUMMARY === and next blank line)
SUMMARY=$(echo "$COMPUTE_OUT" | sed -n '/=== EXPECTED SUMMARY ===/,/^$/p' | head -20)
if [[ -n "$SUMMARY" ]]; then
    echo ""
    echo "$SUMMARY"
fi

# ══════════════════════════════════════════════
#  4. Send the pre-signed user tx
#     Publishes the raw tx created in step 2.
#     The system/sequencer intercepts it from the mempool, constructs
#     the matching batch, and includes it in a block.
# ══════════════════════════════════════════════
L1_BLOCK=""       # set below: L1 trigger = user tx block, L2 trigger = found via L2 block ref
L2_BLOCK=""       # set by L2 trigger receipt only
L1_BATCH_TX=""    # set by find_batch_block_by_l2_ref or VerifyL1Batch

if [[ "$_TRIGGER_CHAIN" == "L2" ]]; then
    # ── L2 trigger ──
    echo ""
    echo "====== Execute L2 (user tx) ======"

    # Snapshot L1 block before L2 tx — we'll search [before..after] for the batch
    L1_BLOCK_BEFORE=$(cast block-number --rpc-url "$RPC")

    publish_user_tx "$L2_RPC"
    L2_BLOCK="$TX_BLOCK_NUMBER"

    # Wait for the system to see our tx and post the batch on L1
    echo "Waiting for system to process..."
    sleep 5

    # Snapshot L1 block after — wait for +1 block to exist so the range is fully mined
    L1_BLOCK_AFTER=$(( $(cast block-number --rpc-url "$RPC") + 1 ))
    echo "Waiting for L1 block $L1_BLOCK_AFTER to appear..."
    for _i in $(seq 1 30); do
        _CURRENT=$(cast block-number --rpc-url "$RPC")
        [[ "$_CURRENT" -ge "$L1_BLOCK_AFTER" ]] && break
        sleep 1
    done
    echo "L1 block range: $L1_BLOCK_BEFORE..$L1_BLOCK_AFTER"
else
    # ── L1 trigger ──
    echo ""
    echo "====== Execute L1 (user tx) ======"

    publish_user_tx "$RPC"  # sets TX_HASH, TX_BLOCK_NUMBER
    L1_BLOCK="$TX_BLOCK_NUMBER"  # batch is always in the same block as the user tx

    # Wait for the system to process
    echo "Waiting for system to process..."
    sleep 5
fi

# ══════════════════════════════════════════════
#  4. Find & verify L1 batch (BatchPosted event)
#     L1 trigger: batch is in the same block as the user tx.
#     L2 trigger: find the batch whose callData references our L2 block.
#     Then verify that the batch entries match expected hashes.
# ══════════════════════════════════════════════
FAILED=false
L1_OK=true
L2_OK=true
L2_CALL_OK=true

# ── Find the L1 batch block ──
if [[ "$_TRIGGER_CHAIN" == "L2" ]]; then
    # L2 trigger: find batch by L2 block reference
    echo ""
    echo "====== Find L1 Batch (L2 block $L2_BLOCK in L1 range $L1_BLOCK_BEFORE..$L1_BLOCK_AFTER) ======"
    if find_batch_block_by_l2_ref "$L2_BLOCK" "$L1_BLOCK_BEFORE" "$L1_BLOCK_AFTER" "$ROLLUPS" "$RPC"; then
        L1_BLOCK="$FOUND_L1_BLOCK"
        L1_BATCH_TX="$FOUND_BATCH_TX"
        echo "Found batch in L1 block $L1_BLOCK (tx $L1_BATCH_TX)"
    else
        # This should not happen — we already waited for L1_BLOCK_AFTER (+1) to exist.
        # If we still can't find the batch, the system likely didn't process the L2 tx.
        # No L1 diagnostic info is available since we couldn't identify the batch block.
        echo "ERROR: No batch found referencing L2 block $L2_BLOCK in L1 range $L1_BLOCK_BEFORE..$L1_BLOCK_AFTER"
        echo "  (no L1 diagnostic info available — could not identify the batch block)"
        FAILED=true
        L1_OK=false
    fi
fi

# ── Verify L1 batch entries ──
echo ""
echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
if $L1_OK; then
    L1_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
        --rpc-url "$RPC" \
        --sig "run(uint256,address,bytes32[])" \
        "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_CALL_HASHES" 2>&1) \
        && L1_OK=true || L1_OK=false

    if $L1_OK; then
        echo "$L1_VERIFY" | grep "PASS"
        # For L1 trigger, extract batch tx from verify output
        [[ -z "${L1_BATCH_TX:-}" ]] && L1_BATCH_TX=$(extract "$L1_VERIFY" "L1_BATCH_TX")
    else
        FAILED=true
        echo "L1 VERIFICATION FAILED"
    fi
fi

# ══════════════════════════════════════════════
#  5. Determine L2 blocks to verify
#
#     Step A: Decode L2 blocks from the L1 postBatch tx callData
#             (uses extract_l2_blocks_from_tx in E2EBase.sh).
#
#     Step B: If empty + L2 trigger, use L2 block from user tx receipt.
#
#     Step C: If still empty, search recent L2 blocks for our call hashes.
#             Once we find the L2 block, search recent L1 blocks for
#             a postBatch whose callData references that L2 block.
#
#     If we can't find L2 blocks, it's an error.
# ══════════════════════════════════════════════
L2_BLOCKS="[]"

# Step A: extract L2 blocks from the L1 postBatch tx's callData
if [[ -n "$L1_BATCH_TX" ]]; then
    echo ""
    echo "====== Extract L2 Blocks from L1 Batch ======"
    L2_BLOCKS=$(extract_l2_blocks_from_tx "$L1_BATCH_TX" "$RPC")
    if [[ "$L2_BLOCKS" == "[]" ]]; then
        echo "WARNING: postBatch tx ($L1_BATCH_TX) has empty callData"
    else
        echo "L2 blocks (from batch callData): $L2_BLOCKS"
    fi
fi

# Step B: fallback for L2 trigger — use L2 block from user tx receipt
if [[ "$L2_BLOCKS" == "[]" && -n "$L2_BLOCK" ]]; then
    L2_BLOCKS="[$L2_BLOCK]"
    echo "L2 blocks (from receipt): $L2_BLOCKS"
fi

# Step C: search recent L2 blocks for our call hashes,
# then find the L1 postBatch that references that L2 block
if [[ "$L2_BLOCKS" == "[]" && -n "${EXPECTED_L2_CALL_HASHES:-}" ]]; then
    echo ""
    echo "====== Search L2 Blocks for Calls ======"
    L2_CURRENT=$(cast block-number --rpc-url "$L2_RPC")
    L2_SEARCH_START=$((L2_CURRENT > 20 ? L2_CURRENT - 20 : 0))
    echo "Searching L2 blocks $L2_SEARCH_START..$L2_CURRENT..."
    FOUND_L2_BLOCK=""
    for (( b=L2_CURRENT; b>=L2_SEARCH_START; b-- )); do
        forge script script/e2e/shared/Verify.s.sol:VerifyL2Calls \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256[],address,bytes32[])" "[$b]" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" 2>&1 \
            | grep -q "PASS" \
            && { FOUND_L2_BLOCK="$b"; break; } || true
    done

    if [[ -n "$FOUND_L2_BLOCK" ]]; then
        echo "Found L2 calls in block $FOUND_L2_BLOCK"
        L2_BLOCKS="[$FOUND_L2_BLOCK]"
    else
        echo "ERROR: Could not find L2 calls in recent blocks"
    fi
fi

# ══════════════════════════════════════════════
#  6. Verify L2 table (ExecutionTableLoaded event)
#     The system must have loaded the execution table on L2.
#     Missing EXPECTED_L2_HASHES or blocks is an error.
#     Empty [] = no L2 activity expected (e.g. terminal revert — skip verification).
# ══════════════════════════════════════════════
echo ""
echo "====== Verify L2 Table ======"
if [[ -z "${EXPECTED_L2_HASHES:-}" ]]; then
    echo "ERROR: No EXPECTED_L2_HASHES — add to ComputeExpected"
    FAILED=true
    L2_OK=false
elif [[ "$EXPECTED_L2_HASHES" == "[]" ]]; then
    echo "No L2 entries expected (terminal revert)"
    # If ABSENT_L2_HASHES provided, actively verify they're NOT on L2
    if [[ -n "${ABSENT_L2_HASHES:-}" && "$ABSENT_L2_HASHES" != "[]" ]]; then
        if [[ "$L2_BLOCKS" == "[]" ]]; then
            echo "PASS: no L2 blocks found (no L2 activity, as expected)"
            L2_OK=true
        else
            ABSENT_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Absent \
                --rpc-url "$L2_RPC" \
                --sig "run(uint256[],address,bytes32[])" "$L2_BLOCKS" "$MANAGER_L2" "$ABSENT_L2_HASHES" 2>&1) \
                && L2_OK=true || L2_OK=false
            if $L2_OK; then
                echo "$ABSENT_VERIFY" | grep "PASS"
            else
                FAILED=true
                echo "L2 ABSENT VERIFICATION FAILED — entries that should NOT be on L2 were found"
                echo "$ABSENT_VERIFY"
            fi
        fi
    else
        echo "SKIP: no absent hashes to verify"
        L2_OK=true
    fi
elif [[ "$L2_BLOCKS" == "[]" ]]; then
    echo "ERROR: No L2 blocks found"
    FAILED=true
    L2_OK=false
else
    L2_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Blocks \
        --rpc-url "$L2_RPC" \
        --sig "run(uint256[],address,bytes32[])" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_HASHES" 2>&1) \
        && L2_OK=true || L2_OK=false

    if $L2_OK; then
        echo "$L2_VERIFY" | grep "PASS"
    else
        FAILED=true
        echo "L2 TABLE VERIFICATION FAILED"
    fi
fi

# ══════════════════════════════════════════════
#  7. Verify L2 calls (IncomingCrossChainCallExecuted event)
#     The system must have executed the cross-chain calls on L2.
#     Missing blocks is an error.
# ══════════════════════════════════════════════
echo ""
echo "====== Verify L2 Calls ======"

if [[ -z "${EXPECTED_L2_CALL_HASHES:-}" || "${EXPECTED_L2_CALL_HASHES}" == "[]" ]]; then
    echo "SKIP: no L2 calls expected"
elif [[ "$L2_BLOCKS" == "[]" ]]; then
    echo "ERROR: No L2 blocks found"
    FAILED=true
    L2_CALL_OK=false
else
    L2_CALL_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Calls \
        --rpc-url "$L2_RPC" \
        --sig "run(uint256[],address,bytes32[])" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" 2>&1) \
        && L2_CALL_OK=true || L2_CALL_OK=false

    if $L2_CALL_OK; then
        echo "$L2_CALL_VERIFY" | grep "PASS"
    else
        FAILED=true
        echo "L2 CALL VERIFICATION FAILED"
    fi
fi

# ══════════════════════════════════════════════
#  8. On failure: show diagnostics
#     Prints actual vs expected tables for each
#     verification step that failed.
# ══════════════════════════════════════════════
if $FAILED; then
    if ! $L1_OK; then
        echo ""
        echo "--- L1 DIAGNOSTICS ---"
        echo "${L1_VERIFY:-no L1 verification output}" | strip_traces
    fi
    if ! $L2_OK; then
        echo ""
        echo "--- L2 TABLE DIAGNOSTICS ---"
        echo "${L2_VERIFY:-no L2 table verification output}" | strip_traces
    fi
    if ! $L2_CALL_OK; then
        echo ""
        echo "--- L2 CALL DIAGNOSTICS ---"
        echo "${L2_CALL_VERIFY:-no L2 call verification output}" | strip_traces
    fi
    echo ""
    echo "$COMPUTE_OUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

# ══════════════════════════════════════════════
#  9. Summary — tx hashes and block numbers
#      Extracted from verification output (no extra RPC calls)
# ══════════════════════════════════════════════
echo ""
echo "====== Summary ======"
echo ""
echo "User tx:        $TX_HASH  (block $TX_BLOCK_NUMBER)"

if [[ -n "$L1_BATCH_TX" ]]; then
    echo "L1 postBatch:   $L1_BATCH_TX  (block ${L1_BLOCK:-?})"
fi

L2_TABLE_TX=$(extract "${L2_VERIFY:-}" "L2_TABLE_TX")
if [[ -n "$L2_TABLE_TX" ]]; then
    L2_BLOCK_NUM=$(echo "$L2_BLOCKS" | tr -d '[]' | cut -d',' -f1)
    echo "L2 loadTable:   $L2_TABLE_TX  (block $L2_BLOCK_NUM)"
fi

L2_CALL_TX=$(extract "${L2_CALL_VERIFY:-}" "L2_CALL_TX")
if [[ -n "$L2_CALL_TX" ]]; then
    L2_BLOCK_NUM=$(echo "$L2_BLOCKS" | tr -d '[]' | cut -d',' -f1)
    echo "L2 call exec:   $L2_CALL_TX  (block $L2_BLOCK_NUM)"
fi

echo ""
echo "====== Done ======"
