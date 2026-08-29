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
# ── How L1 and L2 are linked ──
#
# The correlation is CONTENT-ADDRESSED, never block numbers (batches carry no
# L2 block refs on-chain):
#   1. Call identity — both chains fold the same crossChainCallHash preimage,
#      emitted indexed in L1 ExecutionConsumed and L2 (Incoming)CrossChainCallExecuted.
#   2. Entry identity — keccak(proxyEntryHash, rollingHash); the rolling hash folds
#      every call result (returnData included), binding the source side's cached
#      returns to the destination side's actual execution.
#   3. Time windows — a block snapshot taken right before publishing the trigger
#      bounds every scan range, so identical hashes from earlier runs can't
#      satisfy the checks; deadlines bound the wait.
#
# ── Block flow ──
#
#   L1 trigger:
#     Record L2_BLOCK_BEFORE, user tx on L1 → receipt gives L1_BLOCK
#       → batch normally lands in the same block; if not, fall back to a content
#         scan of [L1_BLOCK..latest] (the composer may bundle later)
#       → L2 sync block via content scan of [L2_BLOCK_BEFORE..latest]
#
#   L2 trigger:
#     Record L1_BLOCK_BEFORE, user tx on L2 → receipt gives L2_BLOCK (candidate)
#       → VerifyL1BatchInRange / VerifyL1ZeroHashEntriesInRange scan
#         [L1_BLOCK_BEFORE..latest] for the settlement → L1_BLOCK
#       → L2 content scan confirms or extends the receipt block
#       → verify L1 batch (+ posted calldata), L2 table, L2 calls
#
# ── Usage ──
#   bash script/e2e/run/network.sh <E2E.s.sol> \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> \
#     --rollups <ROLLUPS> --manager-l2 <MANAGER_L2> [--l2-rollup-id <ID>]
#
source "$(dirname "$0")/../shared/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: network.sh <E2E.s.sol> --l1-rpc <RPC> --l2-rpc <RPC> --pk <PK> --rollups <ROLLUPS> --manager-l2 <ADDR>"; exit 1; }
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
        # Cross-chain "front" endpoints — used ONLY to publish the trigger tx.
        # Deploys/reads must go to the normal chain RPCs: the fronts intercept
        # cross-chain triggers and silently swallow ordinary transactions.
        --l1-front)     export L1_FRONT="$2"; shift 2;;
        --l2-front)     export L2_FRONT="$2"; shift 2;;
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
# L1 read-consistency barrier: the load-balanced public RPC can lag behind txs
# we just mined (previous runs' deploys). A stale nonce at forge's simulation
# step computes an already-occupied CREATE address → CreateCollision. Wait until
# the public RPC reports at least the front's (fresh node's) nonce.
if [[ -n "${L1_FRONT:-}" ]]; then
    _SENDER_ADDR=$(cast wallet address --private-key "$PK")
    _FRONT_N=$(cast nonce "$_SENDER_ADDR" --rpc-url "$L1_FRONT" 2>/dev/null || echo 0)
    for _i in $(seq 1 60); do
        _RPC_N=$(cast nonce "$_SENDER_ADDR" --rpc-url "$RPC" 2>/dev/null || echo 0)
        [[ "$_RPC_N" -ge "$_FRONT_N" ]] && break
        echo "waiting for L1 RPC to catch up (rpc nonce $_RPC_N < front nonce $_FRONT_N)..."
        sleep 2
    done
fi

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

build_trigger_txs "$SOL" network

# ══════════════════════════════════════════════
#  3. Compute expected entries
#     Runs ComputeExpected (read-only) to get the
#     action hashes we expect in the batch and L2 table.
#     Reads RLP_ENCODED_TX from env for action hashing.
# ══════════════════════════════════════════════
echo ""
echo "====== Compute Expected Entries ======"
_SENDER=$(cast wallet address --private-key "$PK")
if grep -qE '^contract ComputeExpected\b' "$SOL"; then
    _HAS_COMPUTE=true
    COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$RPC" --sender "$_SENDER" 2>&1)
    extract_expected_outputs "$COMPUTE_OUT"
else
    # Self-verifying scenario: a pure view-path flow (e.g. a top-level static
    # read) resolves without emitting events, so there are no expected entries
    # to match — the proof is the trigger tx plus the scenario's VerifyNetwork*
    # asserts (step 8b), which are mandatory here.
    _HAS_COMPUTE=false
    COMPUTE_OUT=""
    EXPECTED_L1_CALL_HASHES="[]"; EXPECTED_L1_HASHES="[]"
    EXPECTED_L2_CALL_HASHES="[]"; EXPECTED_L2_HASHES="[]"
    EXPECTED_L1_TABLE="0x"; EXPECTED_L1_STEPS="0x"; EXPECTED_L2_TABLE="0x"
    EVENTLESS_L2_HASHES="[]"; ABSENT_L2_HASHES="[]"
    if ! grep -qE '^contract VerifyNetwork(L2)? ' "$SOL"; then
        echo "ERROR: scenario has neither ComputeExpected nor a VerifyNetwork/VerifyNetworkL2 contract - nothing would be verified"
        exit 1
    fi
    echo "no ComputeExpected - event verification off; VerifyNetwork* asserts are the proof"
fi

# ══════════════════════════════════════════════
#  4. Send the pre-signed user tx
#     Publishes the raw tx created in step 2.
#     The system/sequencer intercepts it from the mempool, constructs
#     the matching batch, and includes it in a block.
# ══════════════════════════════════════════════
L1_BLOCK=""       # set below: L1 trigger = user tx block, L2 trigger = found via L2 block ref
L2_BLOCK=""       # set by L2 trigger receipt only
L1_BATCH_TX=""    # set by VerifyL1BatchInRange (L2 trigger: real range; L1 trigger: single-block range)

if [[ "$_TRIGGER_CHAIN" == "L2" ]]; then
    # ── L2 trigger ──
    echo ""
    echo "====== Execute L2 (user tx) ======"

    # Snapshot L1 block before the trigger — L1 settlement is verified over
    # [L1_BLOCK_BEFORE..latest] with a deadline (see step 5).
    L1_BLOCK_BEFORE=$(cast block-number --rpc-url "$RPC")

    publish_user_tx "${L2_FRONT:-$L2_RPC}"
    L2_BLOCK="$TX_BLOCK_NUMBER"
else
    # ── L1 trigger ──
    echo ""
    echo "====== Execute L1 (user tx) ======"

    # Snapshot L2 block before the trigger — the L2 sync block is discovered by
    # scanning [L2_BLOCK_BEFORE..latest] with a deadline (see step 6).
    L2_BLOCK_BEFORE=$(cast block-number --rpc-url "$L2_RPC")

    if [[ "$_TX_COUNT" -gt 1 ]]; then
        # Multi-tx: fire every pre-signed tx before any of them is mined, so the
        # composer holds several triggers at once — then poll all receipts.
        publish_user_txs_nowait "${L1_FRONT:-$RPC}"
        echo "all $_TX_COUNT txs fired — polling receipts"
        wait_user_txs "${L1_FRONT:-$RPC}"  # sets TX_HASHES/TX_BLOCK_NUMBERS + min TX_BLOCK_NUMBER
        _UNIQ_BLOCKS=$(printf "%s\n" "${TX_BLOCK_NUMBERS[@]}" | sort -un | paste -sd, -)
        echo "trigger blocks: $_UNIQ_BLOCKS"
        [[ "$_UNIQ_BLOCKS" == *,* ]] && echo "NOTE: composer split the triggers across blocks - single-batch verification below may fail; use the tx hashes above with decode-block.sh"
    else
        publish_user_tx "${L1_FRONT:-$RPC}"  # sets TX_HASH, TX_BLOCK_NUMBER
    fi
    L1_BLOCK="$TX_BLOCK_NUMBER"  # batch lands with the (first) user tx; later blocks via range scan
fi

# ══════════════════════════════════════════════
#  5. Find & verify L1 batch (BatchPosted event)
#     L1 trigger: batch is in the same block as the user tx.
#     L2 trigger: find the batch whose callData references our L2 block.
#     Then verify that the batch entries match expected hashes.
# ══════════════════════════════════════════════
FAILED=false
L1_OK=true
L2_OK=true
L2_CALL_OK=true
RETRY_OUT=""

# One range wrapper serves both trigger directions. The settlement lister has
# no expected arguments; content-addressed verification takes the expected
# hashes/table. Keeping this in one place also makes calldata re-scans behave
# identically for L1- and L2-triggered eventless entries.
_l1_scan() {  # $1=fromBlock $2=toBlock
    if [[ "$_L1_CONTRACT" == "VerifyL1SettlementTxsInRange" ]]; then
        forge script "script/e2e/shared/Verify.s.sol:$_L1_CONTRACT" \
            --rpc-url "$RPC" --sig "run(uint256,uint256,address)" \
            "$1" "$2" "$ROLLUPS" 2>&1
    else
        forge script "script/e2e/shared/Verify.s.sol:$_L1_CONTRACT" \
            --rpc-url "$RPC" --sig "run(uint256,uint256,address,bytes32[],bytes)" \
            "$1" "$2" "$ROLLUPS" "$_L1_EXPECTED" "$EXPECTED_L1_TABLE" 2>&1
    fi
}

# ── Verify L1 batch entries ──
# L1 trigger: the batch is in the SAME block as the user tx — verify that block.
# L2 trigger: the settlement block is unknown a priori (batches no longer encode
# L2 block references), so scan the recorded L1 range for ExecutionConsumed events.
if ! $_HAS_COMPUTE; then
    echo ""
    echo "====== Verify L1 Batch ======"
    echo "SKIP: no ComputeExpected - no expected entries/events to match (self-verifying scenario)"
elif [[ "$_TRIGGER_CHAIN" == "L2" ]]; then
    # Two settlement signals, depending on the scenario's L1 entry shape:
    #  - proxy-consumed entries (proxyEntryHash != 0): ExecutionConsumed carries the
    #    call hash → VerifyL1BatchInRange with EXPECTED_L1_CALL_HASHES.
    #  - system-driven entries (proxyEntryHash == 0, drained via executeL2Txs): no
    #    call hash exists, and the entry hash is root-dependent → list settlement txs
    #    via VerifyL1SettlementTxsInRange and pin ours by posted-calldata content.
    if [[ -n "$EXPECTED_L1_CALL_HASHES" && "$EXPECTED_L1_CALL_HASHES" != "[]" ]]; then
        _L1_CONTRACT="VerifyL1BatchInRange"
        _L1_EXPECTED="$EXPECTED_L1_CALL_HASHES"
    else
        # Zero-hash entries: EXPECTED_L1_HASHES fold placeholder roots, but the
        # on-chain rolling-hash seed folds the REAL roots the composer settles — the
        # event-level hash match can never fire on a live devnet. Discover settlement
        # txs root-agnostically; the posted-calldata comparison (roots neutralized)
        # is what pins our entries, so the expected table is mandatory here.
        if [[ "$EXPECTED_L1_TABLE" == "0x" ]]; then
            echo "ERROR: zero-hash L1 entries need EXPECTED_L1_TABLE for network verification - add _printL1Table to ComputeExpected"
            FAILED=true
        fi
        _L1_CONTRACT="VerifyL1SettlementTxsInRange"
        _L1_EXPECTED="$EXPECTED_L1_HASHES"
    fi
    echo ""
    echo "====== Verify L1 Batch ($_L1_CONTRACT, range $L1_BLOCK_BEFORE.., deadline ${L1_SETTLE_TIMEOUT:-300}s) ======"
    # Settlement (batch post + entry consumption) can take a while — retry the
    # range scan against a growing [before..latest] window until the deadline.
    _l1_scan_latest() { _l1_scan "$L1_BLOCK_BEFORE" "$(cast block-number --rpc-url "$RPC")"; }
    L1_OK=false
    if [[ "${FAILED:-false}" != true ]]; then
        if retry_until_deadline "${L1_SETTLE_TIMEOUT:-300}" 10 _l1_scan_latest; then
            L1_OK=true
        fi
        L1_VERIFY="$RETRY_OUT"
    fi

    if $L1_OK; then
        echo "$L1_VERIFY" | grep -E "PASS|NOTE"
        L1_BLOCK=$(extract "$L1_VERIFY" "L1_MATCH_BLOCK")
        L1_BATCH_TX=$(extract "$L1_VERIFY" "L1_BATCH_TX")
        [[ -n "$L1_BLOCK" ]] && echo "Batch found at L1 block $L1_BLOCK"
    else
        FAILED=true
        echo "L1 VERIFICATION FAILED (no settlement in $L1_BLOCK_BEFORE..$(cast block-number --rpc-url "$RPC") within ${L1_SETTLE_TIMEOUT:-300}s)"
    fi
else
    echo ""
    echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
    # Retry with a deadline: a load-balanced public RPC can briefly serve nodes
    # that don't have the just-mined block yet (eth_getLogs comes back empty).
    # Eventless L1 entries (e.g. a success=false entry, whose consumption unwinds
    # ExecutionConsumed with its revert) leave no call hash to match — list the
    # settlement txs root-agnostically via VerifyL1SettlementTxsInRange and let the
    # posted-calldata stage below pin the exact entries; the expected table is
    # mandatory there.
    if [[ -z "$EXPECTED_L1_CALL_HASHES" || "$EXPECTED_L1_CALL_HASHES" == "[]" ]]; then
        _L1_CONTRACT="VerifyL1SettlementTxsInRange"
        _L1_EXPECTED="$EXPECTED_L1_HASHES"
        if [[ "$EXPECTED_L1_TABLE" == "0x" ]]; then
            echo "ERROR: eventless L1 entries need EXPECTED_L1_TABLE for network verification - add _printL1Table to ComputeExpected"
            FAILED=true
        fi
        _l1_verify_block() {
            _l1_scan "$L1_BLOCK" "$L1_BLOCK"
        }
        _l1_range_scan_latest() {
            _l1_scan "$L1_BLOCK" "$(cast block-number --rpc-url "$RPC")"
        }
    else
        _L1_CONTRACT="VerifyL1BatchInRange"
        _L1_EXPECTED="$EXPECTED_L1_CALL_HASHES"
        _l1_verify_block() {
            _l1_scan "$L1_BLOCK" "$L1_BLOCK"
        }
        _l1_range_scan_latest() {
            _l1_scan "$L1_BLOCK" "$(cast block-number --rpc-url "$RPC")"
        }
    fi
    L1_OK=false
    if [[ "${FAILED:-false}" != true ]] && retry_until_deadline "${L1_VERIFY_TIMEOUT:-90}" 10 _l1_verify_block; then
        L1_OK=true
    fi
    L1_VERIFY="$RETRY_OUT"

    # Fallback: the composer may post the settlement batch in a LATER L1 block than
    # the trigger tx (the front holds the trigger; batching is asynchronous), so a
    # single-block miss is not yet a failure. The correlation is CONTENT, not block
    # numbers — range-scan [receipt block..latest] for the same expected hashes.
    if ! $L1_OK; then
        echo "batch not in the trigger block — scanning [$L1_BLOCK..latest] (deadline ${L1_SETTLE_TIMEOUT:-300}s)"
        if [[ "${FAILED:-false}" != true ]] && retry_until_deadline "${L1_SETTLE_TIMEOUT:-300}" 10 _l1_range_scan_latest; then
            L1_OK=true
        fi
        L1_VERIFY="$RETRY_OUT"
        if $L1_OK; then
            _L1_MATCH=$(extract "$L1_VERIFY" "L1_MATCH_BLOCK")
            [[ -n "$_L1_MATCH" ]] && { L1_BLOCK="$_L1_MATCH"; echo "Batch found at L1 block $L1_BLOCK"; }
        fi
    fi

    if $L1_OK; then
        echo "$L1_VERIFY" | grep -E "PASS|NOTE"
        [[ -z "${L1_BATCH_TX:-}" ]] && L1_BATCH_TX=$(extract "$L1_VERIFY" "L1_BATCH_TX")
    else
        FAILED=true
        echo "L1 VERIFICATION FAILED"
    fi
fi

# ══════════════════════════════════════════════
#  5b. Compare the POSTED batch against the expected L1 table.
#      L1 events never carry the entries, but the settlement tx's
#      postAndVerifyBatch calldata does: decode it and field-match every
#      expected entry (the L1 analogue of the L2 table comparison).
#
#      Call hashes are not unique across runs — parallel or repeated jobs of
#      the same scenario can emit identical rolling hashes — so the pinned
#      L1_BATCH_TX may be a sibling job's batch. Try every candidate tx the
#      range scan emitted, and (L2 trigger) re-scan the growing range for
#      late settlements until the deadline.
# ══════════════════════════════════════════════
if [[ "${FAILED:-false}" != true && -z "${L1_BATCH_TX:-}" && "$EXPECTED_L1_TABLE" != "0x" ]]; then
    echo ""
    echo "NOTE: no settlement tx identified (no BatchPosted in the scanned logs) - skipping posted-batch calldata comparison"
fi
if [[ "${FAILED:-false}" != true && -n "${L1_BATCH_TX:-}" && "$EXPECTED_L1_TABLE" != "0x" ]]; then
    # `|| true`: no CANDIDATE lines (e.g. L1-trigger verifiers don't emit them) must
    # not kill the script under set -e — the fallback below pins the single tx.
    _CANDIDATES=$(echo "${L1_VERIFY:-}" | grep -oE 'L1_BATCH_TX_CANDIDATE=0x[0-9a-fA-F]{64}' | cut -d= -f2 | sort -u || true)
    [[ -z "$_CANDIDATES" ]] && _CANDIDATES="$L1_BATCH_TX"
    echo ""
    echo "====== Verify L1 Posted Batch Calldata ($(echo "$_CANDIDATES" | wc -l) candidate tx) ======"
    _CD_DEADLINE=$(( $(date +%s) + ${L1_CALLDATA_TIMEOUT:-180} ))
    _CALLDATA_OK=false
    _LAST_FAIL=""
    _REJECTED=""   # memo of non-registry candidates: skip silently on re-scan iterations
    while true; do
        for _TX in $_CANDIDATES; do
            [[ ",$_REJECTED," == *",$_TX,"* ]] && continue
            _BATCH_TO=$(cast tx "$_TX" to --rpc-url "$RPC" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            _BATCH_INPUT=$(cast tx "$_TX" input --rpc-url "$RPC" 2>/dev/null)
            if [[ "$_BATCH_TO" != "$(echo "$ROLLUPS" | tr '[:upper:]' '[:lower:]')" ]]; then
                # consumption happened outside postAndVerifyBatch (e.g. a separate proxy tx)
                echo "NOTE: candidate $_TX targets ${_BATCH_TO:-<unknown>} (not the registry) - skipped"
                _REJECTED="$_REJECTED,$_TX"
                continue
            fi
            [[ -z "$_BATCH_INPUT" || "$_BATCH_INPUT" == "0x" ]] && continue
            _BATCH_BLOCK=$(cast receipt "$_TX" blockNumber --rpc-url "$RPC" 2>/dev/null)
            [[ -z "$_BATCH_BLOCK" ]] && continue
            if BATCH_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1BatchCalldata \
                --rpc-url "$RPC" \
                --fork-block-number "$((_BATCH_BLOCK))" \
                --sig "run(bytes,address,bytes,bytes)" \
                "$_BATCH_INPUT" "$ROLLUPS" "$EXPECTED_L1_TABLE" "$EXPECTED_L1_STEPS" 2>&1); then
                echo "Matched settlement tx $_TX"
                echo "$BATCH_VERIFY" | grep -E "PASS|NOTE|Posted batch"
                L1_BATCH_TX="$_TX"   # step 6 decodes L2 blocks from this tx
                _CALLDATA_OK=true
                break 2
            fi
            _LAST_FAIL="$BATCH_VERIFY"
        done
        # No candidate contained our entries. For L2 triggers our entry may
        # simply not have settled yet — re-scan the growing range for new
        # settlement txs until the deadline.
        [[ $(date +%s) -ge $_CD_DEADLINE || "$_L1_CONTRACT" != "VerifyL1SettlementTxsInRange" ]] && break
        sleep 10
        _L1_CUR=$(cast block-number --rpc-url "$RPC")
        _L1_SCAN_FROM="${L1_BLOCK_BEFORE:-$L1_BLOCK}"
        L1_RESCAN=$(_l1_scan "$_L1_SCAN_FROM" "$_L1_CUR") || continue
        _NEW=$(echo "$L1_RESCAN" | grep -oE 'L1_BATCH_TX_CANDIDATE=0x[0-9a-fA-F]{64}' | cut -d= -f2 | sort -u || true)
        [[ -n "$_NEW" ]] && _CANDIDATES="$_NEW"
    done
    if ! $_CALLDATA_OK; then
        if [[ "${_L1_CONTRACT:-}" == "VerifyL1SettlementTxsInRange" ]]; then
            # Root-agnostic path: the calldata content match is the ONLY check that
            # pins our entries to a settlement — not finding one is a failure.
            FAILED=true
            [[ -n "$_LAST_FAIL" ]] && echo "$_LAST_FAIL" | grep -E "FAIL|NOTE|Error|call\[" | head -30
            echo "L1 BATCH CALLDATA VERIFICATION FAILED (no candidate settlement tx contained the expected entries)"
        elif [[ -z "$_LAST_FAIL" ]]; then
            echo "NOTE: no comparable settlement tx (non-registry target or missing input) - skipping calldata comparison"
        else
            FAILED=true
            echo "$_LAST_FAIL" | grep -E "FAIL|NOTE|Error|call\[" | head -30
            echo "L1 BATCH CALLDATA VERIFICATION FAILED (no candidate settlement tx contained the expected entries)"
        fi
    fi
fi

# ══════════════════════════════════════════════
#  6. Determine L2 blocks to verify
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

# (The old "Step A: decode L2 blocks from the postBatch callData" is gone —
# batches no longer encode L2 block references on-chain. Correlation is
# inferred from the user-tx receipt or by scanning L2 events.)

# Step B: L2 trigger — the user-tx receipt block is a CANDIDATE. The composer may
# bundle the actual consumption (table load + call execution) in a LATER block, so
# the content scan in Step C always runs to confirm or extend it.
if [[ "$L2_BLOCKS" == "[]" && -n "$L2_BLOCK" ]]; then
    L2_BLOCKS="[$L2_BLOCK]"
    echo "L2 blocks (from receipt): $L2_BLOCKS"
fi

# Step C: discover the L2 sync block by content — scan for the expected call hashes
# (single eth_getLogs range per attempt), retrying until the deadline.
#   L1 trigger: scan from the pre-trigger snapshot (L2_BLOCK_BEFORE).
#   L2 trigger: scan from the receipt block (consumption can land blocks later).
if [[ -n "${EXPECTED_L2_CALL_HASHES:-}" && "$EXPECTED_L2_CALL_HASHES" != "[]" ]]; then
    _SCAN_FROM="${L2_BLOCK_BEFORE:-${L2_BLOCK:-0}}"
    echo ""
    echo "====== Search L2 Blocks for Calls (from $_SCAN_FROM, deadline ${L2_SETTLE_TIMEOUT:-180}s) ======"
    _l2_calls_scan_latest() {
        forge script script/e2e/shared/Verify.s.sol:VerifyL2CallsInRange \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256,uint256,address,bytes32[])" \
            "$_SCAN_FROM" "$(cast block-number --rpc-url "$L2_RPC")" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES"
    }
    FOUND_L2_BLOCK=""
    if retry_until_deadline "${L2_SETTLE_TIMEOUT:-180}" 5 _l2_calls_scan_latest; then
        FOUND_L2_BLOCK=$(extract "$RETRY_OUT" "L2_MATCH_BLOCK")
    fi
    _L2_OUT="$RETRY_OUT"

    if [[ -n "$FOUND_L2_BLOCK" ]]; then
        # One delivery tx per top-level call — matches may span several blocks.
        # L2_MATCH_BLOCKS=[b1,b2,...] carries all of them (fallback: the single block).
        _FOUND_LIST=$(extract "$_L2_OUT" "L2_MATCH_BLOCKS" | tr -d '[]')
        [[ -z "$_FOUND_LIST" ]] && _FOUND_LIST="$FOUND_L2_BLOCK"
        echo "Found L2 calls in block(s) $_FOUND_LIST"
        if [[ -n "${L2_BLOCK:-}" && ",$_FOUND_LIST," != *",$L2_BLOCK,"* ]]; then
            L2_BLOCKS="[$L2_BLOCK,$_FOUND_LIST]"
        else
            L2_BLOCKS="[$_FOUND_LIST]"
        fi
        echo "L2 blocks to verify: $L2_BLOCKS"
    elif [[ "$L2_BLOCKS" == "[]" ]]; then
        echo "ERROR: no L2 sync block with the expected calls in $_SCAN_FROM..$(cast block-number --rpc-url "$L2_RPC") within ${L2_SETTLE_TIMEOUT:-180}s"
    else
        echo "WARNING: expected calls not found by scan; falling back to receipt block $L2_BLOCKS"
    fi
fi

# ══════════════════════════════════════════════
#  7. Verify L2 table (ExecutionTableLoaded event)
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
    echo "No L2 entry events expected (terminal revert, or an eventless static pool)"
    # If ABSENT_L2_HASHES provided, actively verify they're NOT on L2
    if [[ -n "${ABSENT_L2_HASHES:-}" && "$ABSENT_L2_HASHES" != "[]" ]]; then
        if [[ "$L2_BLOCKS" == "[]" ]]; then
            echo "PASS: no L2 blocks found (no L2 activity, as expected)"
            L2_OK=true
        else
            # (failure = entries that should NOT be on L2 were found)
            run_verify_step "L2 ABSENT" full verify_l2_absent "$L2_RPC" "$L2_BLOCKS" "$MANAGER_L2" "$ABSENT_L2_HASHES"
            L2_OK=$VERIFY_STEP_OK
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
    run_verify_step "L2 TABLE" defer verify_l2_table "$L2_RPC" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_HASHES" "$EXPECTED_L2_TABLE" "$EVENTLESS_L2_HASHES"
    L2_OK=$VERIFY_STEP_OK
fi

# ══════════════════════════════════════════════
#  8. Verify L2 calls (IncomingCrossChainCallExecuted event)
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
    run_verify_step "L2 CALL" defer verify_l2_calls "$L2_RPC" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" "$EXPECTED_L2_TABLE"
    L2_CALL_OK=$VERIFY_STEP_OK
fi

# ══════════════════════════════════════════════
#  8b. Scenario self-verification (optional)
#      If the scenario defines VerifyNetwork (checked on L1) and/or
#      VerifyNetworkL2 (checked on L2), run them read-only after the trigger.
#      They assert live on-chain state (reader counters, cached read values,
#      no-tx queries) — the only proof layer for view-path resolutions that
#      emit no events, and an extra state check for any other scenario.
# ══════════════════════════════════════════════
_run_verify_network() {  # $1=contract $2=rpc $3=chain label
    local _VN_NAME="$1" _VN_RPC="$2" _VN_LABEL="$3"
    grep -qE "^contract $_VN_NAME " "$SOL" || return 0
    echo ""
    echo "====== Scenario Self-Verification ($_VN_NAME, $_VN_LABEL) ======"
    if retry_until_deadline "${VERIFY_NETWORK_TIMEOUT:-60}" 5 \
        forge script "$SOL:$_VN_NAME" --rpc-url "$_VN_RPC" --sender "$_SENDER"; then
        echo "$RETRY_OUT" | grep -E "VERIFY_PASS|PASS" || echo "PASS: $_VN_NAME asserts held"
    else
        FAILED=true
        echo ""
        echo "--- $_VN_NAME DIAGNOSTICS ---"
        echo "$RETRY_OUT" | strip_traces
        echo "$_VN_NAME FAILED"
    fi
}
_run_verify_network VerifyNetwork "$RPC" L1
_run_verify_network VerifyNetworkL2 "$L2_RPC" L2

# ══════════════════════════════════════════════
#  9. On failure: show diagnostics
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
        # L2_OK is shared by the table check and the absent check — print whichever ran.
        echo "${VERIFY_STEP_OUT[L2 TABLE]:-${VERIFY_STEP_OUT[L2 ABSENT]:-no L2 table verification output}}" | strip_traces
    fi
    if ! $L2_CALL_OK; then
        echo ""
        echo "--- L2 CALL DIAGNOSTICS ---"
        echo "${VERIFY_STEP_OUT[L2 CALL]:-no L2 call verification output}" | strip_traces
    fi
    echo ""
    echo "$COMPUTE_OUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

# ══════════════════════════════════════════════
#  10. Summary — tx hashes and block numbers
#      Extracted from verification output (no extra RPC calls)
# ══════════════════════════════════════════════
echo ""
echo "====== Summary ======"
echo ""
if [[ "${_TX_COUNT:-1}" -gt 1 ]]; then
    for _i in "${!TX_HASHES[@]}"; do
        echo "User tx[$(( _i + 1 ))]:     ${TX_HASHES[$_i]}  (block ${TX_BLOCK_NUMBERS[$_i]})"
    done
else
    echo "User tx:        $TX_HASH  (block $TX_BLOCK_NUMBER)"
fi

if [[ -n "$L1_BATCH_TX" ]]; then
    echo "L1 postBatch:   $L1_BATCH_TX  (block ${L1_BLOCK:-?})"
fi

L2_TABLE_TX=$(extract "${VERIFY_STEP_OUT[L2 TABLE]:-}" "L2_TABLE_TX")
if [[ -n "$L2_TABLE_TX" ]]; then
    L2_BLOCK_NUM=$(echo "$L2_BLOCKS" | tr -d '[]' | cut -d',' -f1)
    echo "L2 loadTable:   $L2_TABLE_TX  (block $L2_BLOCK_NUM)"
fi

L2_CALL_TX=$(extract "${VERIFY_STEP_OUT[L2 CALL]:-}" "L2_CALL_TX")
if [[ -n "$L2_CALL_TX" ]]; then
    L2_BLOCK_NUM=$(echo "$L2_BLOCKS" | tr -d '[]' | cut -d',' -f1)
    echo "L2 call exec:   $L2_CALL_TX  (block $L2_BLOCK_NUM)"
fi

echo ""
echo "====== Done ======"
