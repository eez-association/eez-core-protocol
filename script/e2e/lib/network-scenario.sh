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
# Refresh every trigger by transaction hash. Composer-front correlation uses its
# exact block hash to discover posting transactions and all settled L2 blocks.
# Posted calldata, call identities, rolling-hash replay and execution events
# independently verify the scenario. Unsupported fronts retain content scans.
# All observed inclusions are checked again before success or a semantic failure;
# changed/unavailable evidence restarts verification within one fixed deadline.
#
# ── Usage ──
#   bash script/e2e/lib/network-scenario.sh <E2E.s.sol> \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> \
#     --rollups <ROLLUPS> --manager-l2 <MANAGER_L2> [--l2-rollup-id <ID>]
#
# Workers pass resolved addresses explicitly. Standalone runs read chain.env,
# then apply command-line overrides and discover current deployment addresses.
case "${E2E_PREPARE_STEP:-}" in
    ""|plan) ;;
    *) echo "Unsupported E2E_PREPARE_STEP: use plan or leave unset for classic" >&2; exit 1 ;;
esac
source "$(dirname "$0")/network-config.sh"
_CLI_ROLLUPS=false
_CLI_MANAGER_L2=false
for _arg in "$@"; do
    case "$_arg" in
        --rollups) _CLI_ROLLUPS=true ;;
        --manager-l2) _CLI_MANAGER_L2=true ;;
    esac
done
if [[ "$_CLI_ROLLUPS" != true || "$_CLI_MANAGER_L2" != true ]]; then
    load_network_env "${DEVNET_ENV:-}" || exit 1
fi
source "$(dirname "$0")/E2EBase.sh"
source "$(dirname "$0")/settlement-target.sh"
source "$(dirname "$0")/network-links.sh"

SOL="$1"; shift || { echo "Usage: network-scenario.sh <E2E.s.sol> --l1-rpc <RPC> --l2-rpc <RPC> --pk <PK> --rollups <ROLLUPS> --manager-l2 <ADDR>"; exit 1; }
# Accept paths recorded by staged runs before scenarios/ was introduced.
if [[ ! -f "$SOL" && "$SOL" == script/e2e/* ]]; then
    _MOVED_SOL="script/e2e/scenarios/${SOL#script/e2e/}"
    [[ ! -f "$_MOVED_SOL" ]] || SOL="$_MOVED_SOL"
fi
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

# ── Parse CLI args → export as env vars for forge scripts ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)          export RPC="$2"; export L1_RPC="$2"; shift 2;;
        --pk)           export PK="$2"; shift 2;;
        --rollups)      export ROLLUPS="$2"; shift 2;;
        --eez-post-batcher) export EEZ_POST_BATCHER="$2"; shift 2;;
        --l1-rpc)       export L1_RPC="$2"; export RPC="$2"; shift 2;;
        --l2-rpc)       export L2_RPC="$2"; shift 2;;
        --manager-l2)   export MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) export L2_ROLLUP_ID="$2"; shift 2;;
        # Cross-chain fronts publish triggers and expose Composer correlation/status.
        # Deploys/reads must go to the normal chain RPCs: the fronts intercept
        # cross-chain triggers and silently swallow ordinary transactions.
        --l1-front)     export L1_FRONT="$2"; shift 2;;
        --l2-front)     export L2_FRONT="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

if [[ "$_CLI_ROLLUPS" != true || "$_CLI_MANAGER_L2" != true ]]; then
    load_composer_info || exit 1
fi
export RPC="${L1_RPC:-${RPC:-}}"

export L2_ROLLUP_ID="${L2_ROLLUP_ID:-1}"

for var in RPC PK ROLLUPS L2_RPC MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ── Stage split (driven by staged.sh) ──
#   E2E_STAGE=prepare → steps 1–3 only: deploy, pre-sign the trigger tx(s), run
#     ComputeExpected, persist everything in E2E_JOB_DIR, exit without sending.
#   E2E_STAGE=verify  → reload that manifest plus the mined trigger receipts
#     (E2E_JOB_DIR/txs.txt, written by the staged sender) and run only the
#     verification steps (5+).
#   E2E_STAGE=full (default) → the classic single-run behavior.
E2E_STAGE="${E2E_STAGE:-full}"

if [[ "$E2E_STAGE" == "verify" ]]; then
# ══════════════════════════════════════════════
#  Verify stage: rebuild the state steps 1–4 would have produced.
# ══════════════════════════════════════════════
[[ -n "${E2E_JOB_DIR:-}" && -f "$E2E_JOB_DIR/manifest.env" ]] || {
    echo "E2E_STAGE=verify needs E2E_JOB_DIR containing manifest.env"; exit 1; }
# shellcheck disable=SC1091
source "$E2E_JOB_DIR/manifest.env"
EXPECTED_L1_STATIC_TABLE="${EXPECTED_L1_STATIC_TABLE:-0x}"   # manifests written before the static table existed
COMPUTE_OUT=$(cat "$E2E_JOB_DIR/compute.out")
_REFRESH_EXPECTATIONS=false
[[ -v EXPECTED_L2_STATIC_TABLE ]] || _REFRESH_EXPECTATIONS=true
EXPECTED_L2_STATIC_TABLE="${EXPECTED_L2_STATIC_TABLE:-$(extract "$COMPUTE_OUT" EXPECTED_L2_STATIC_TABLE)}"
EXPECTED_L2_STATIC_TABLE="${EXPECTED_L2_STATIC_TABLE:-0x}"
# Deploy* outputs (COUNTER_PROXY, READER_L1, ...) — the VerifyNetwork* self-checks
# read them from the environment, same as in a full run.
if [[ -f "$E2E_JOB_DIR/deploy-env.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$E2E_JOB_DIR/deploy-env.env"
    set +a
fi
# ComputeExpected is a read-only function of saved deployment addresses. Older
# manifests predate static exports and the repeated-call fix; refresh them without
# sending, deploying, or silently changing their saved mutable table expectations.
if $_REFRESH_EXPECTATIONS && $_HAS_COMPUTE; then
    echo 'Refreshing expectations from saved deployment addresses'
    _CURRENT_EXPECTED=$(forge script "$SOL:ComputeExpected" --sender "$_SENDER" 2>&1) || {
        echo "$_CURRENT_EXPECTED" | strip_traces; exit 1; }
    for _field in EXPECTED_L1_TABLE EXPECTED_L2_TABLE; do
        _current=$(extract "$_CURRENT_EXPECTED" "$_field"); _current="${_current:-0x}"
        [[ "$_current" == "${!_field}" ]] || { echo "ERROR: $_field changed since preparation"; exit 1; }
    done
    printf '%s\n' "$_CURRENT_EXPECTED" > "$E2E_JOB_DIR/compute-verification.out"
    EXPECTED_L2_STATIC_TABLE=$(extract "$_CURRENT_EXPECTED" EXPECTED_L2_STATIC_TABLE)
    EXPECTED_L2_STATIC_TABLE="${EXPECTED_L2_STATIC_TABLE:-0x}"
    _current=$(extract "$_CURRENT_EXPECTED" EXPECTED_L2_CALL_HASHES)
    if [[ "$_current" != "$EXPECTED_L2_CALL_HASHES" ]]; then
        echo "NOTE: refreshed EXPECTED_L2_CALL_HASHES: $EXPECTED_L2_CALL_HASHES -> $_current (saved in compute-verification.out)"
    fi
    EXPECTED_L2_CALL_HASHES="$_current"
fi
# Pre-send block snapshot, recorded ONCE by the orchestrator right before its
# send phase — it bounds every job's scan ranges (the per-run analogue of the
# per-job *_BLOCK_BEFORE snapshots the full run takes).
# shellcheck disable=SC1090
source "${E2E_SNAPSHOT:-$E2E_JOB_DIR/../../snapshot.env}"

mapfile -t TX_HASHES < "$E2E_JOB_DIR/txs.txt"
[[ ${#TX_HASHES[@]} -gt 0 ]] || { echo "ERROR: no sent txs in $E2E_JOB_DIR/txs.txt"; exit 1; }
# Every pre-signed trigger must have gone out — a partial multi-tx send is an
# orchestration failure, not something the protocol checks below should judge.
[[ ${#TX_HASHES[@]} -eq "${_TX_COUNT:-1}" ]] || {
    echo "ERROR: ${#TX_HASHES[@]} sent tx(s) but the manifest expects ${_TX_COUNT:-1} - partial send (see the run's send-failed.log)"; exit 1; }
echo "reloaded $E2E_JOB_DIR: ${#TX_HASHES[@]} trigger tx(s) ($_TRIGGER_CHAIN trigger)"

else
# ══ full + prepare stages: steps 1–4 (the `fi` closing this block sits after step 4) ══

# ══════════════════════════════════════════════
#  1. Deploy app contracts
#     Auto-discovers Deploy* contracts in file order.
#     "L2" in name → deployed on L2 RPC, else L1.
# ══════════════════════════════════════════════
# L1 read-consistency barrier: the load-balanced public RPC can lag behind txs
# we just mined (previous runs' deploys). A stale nonce at forge's simulation
# step computes an already-occupied CREATE address → CreateCollision. Wait until
# the public RPC reports at least the front's (fresh node's) nonce. Skipped in
# the staged plan prepare: the orchestrator ran one batched barrier for every
# wallet.
if [[ -n "${L1_FRONT:-}" && "${E2E_PREPARE_STEP:-}" != "plan" ]]; then
    _SENDER_ADDR=$(cast wallet address --private-key "$PK")
    _NONCE_DEADLINE=$(( $(date +%s) + 120 ))
    _FRONT_N=$(network_checked_nonce "$_SENDER_ADDR" "$L1_FRONT" "$_NONCE_DEADLINE")
    for _i in $(seq 1 60); do
        _RPC_N=$(network_checked_nonce "$_SENDER_ADDR" "$RPC" "$_NONCE_DEADLINE")
        [[ "$_RPC_N" -ge "$_FRONT_N" ]] && break
        echo "waiting for L1 RPC to catch up (rpc nonce $_RPC_N < front nonce $_FRONT_N)..."
        sleep 2
    done
    [[ "$_RPC_N" -ge "$_FRONT_N" ]] || { echo 'L1 nonce consistency timeout' >&2; exit 1; }
fi

# Staged prepare steps (E2E_PREPARE_STEP, set by staged.sh):
#   plan       → run every Deploy* contract in one forge process against
#                in-process forks of both chains with the wallet nonces
#                injected, pre-sign the planned deploy txs, then exit (0 = txs
#                written, 1 = failure); the orchestrator fires and mines them.
# Unset → classic one-pass prepare/full behavior.
if [[ "$E2E_STAGE" == "prepare" && "${E2E_PREPARE_STEP:-}" == "plan" ]]; then
    [[ -n "${E2E_JOB_DIR:-}" ]] || { echo "E2E_PREPARE_STEP=plan needs E2E_JOB_DIR"; exit 1; }
    mkdir -p "$E2E_JOB_DIR"
    _RC=0
    plan_job_deploys "$SOL" "$RPC" "$L2_RPC" "$PK" "$E2E_JOB_DIR" || _RC=$?
    exit "$_RC"
fi
network_trigger_front "$SOL" >/dev/null || exit 1
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
#     A pure function of the deploy outputs in env (no chain reads, no
#     dependence on the pre-signed trigger) — which is what lets the staged
#     plan step run it in the same forge process as the deploy simulation.
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
    EXPECTED_L1_TABLE="0x"; EXPECTED_L1_STEPS="0x"; EXPECTED_L1_STATIC_TABLE="0x"; EXPECTED_L2_TABLE="0x"; EXPECTED_L2_STATIC_TABLE="0x"
    EVENTLESS_L2_HASHES="[]"; ABSENT_L2_HASHES="[]"
    if ! grep -qE '^contract VerifyNetwork(L2)? ' "$SOL"; then
        echo "ERROR: scenario has neither ComputeExpected nor a VerifyNetwork/VerifyNetworkL2 contract - nothing would be verified"
        exit 1
    fi
    echo "no ComputeExpected - event verification off; VerifyNetwork* asserts are the proof"
fi

if [[ "$E2E_STAGE" == "prepare" ]]; then
    # Persist everything the staged send + verify phases need, broadcast nothing.
    [[ -n "${E2E_JOB_DIR:-}" ]] || { echo "E2E_STAGE=prepare needs E2E_JOB_DIR"; exit 1; }
    mkdir -p "$E2E_JOB_DIR"
    printf '%s\n' "${RLP_ENCODED_TXS[@]}" > "$E2E_JOB_DIR/rawtxs.txt"
    echo "$COMPUTE_OUT" > "$E2E_JOB_DIR/compute.out"
    E2E_MANIFEST_VERSION=2
    declare -p E2E_MANIFEST_VERSION _TRIGGER_CHAIN _TX_COUNT _HAS_COMPUTE _SENDER \
        EXPECTED_L1_CALL_HASHES EXPECTED_L1_HASHES EXPECTED_L2_CALL_HASHES EXPECTED_L2_HASHES \
        EXPECTED_L1_TABLE EXPECTED_L1_STEPS EXPECTED_L1_STATIC_TABLE EXPECTED_L2_TABLE EXPECTED_L2_STATIC_TABLE EVENTLESS_L2_HASHES ABSENT_L2_HASHES \
        > "$E2E_JOB_DIR/manifest.env"
    touch "$E2E_JOB_DIR/.deploys-done"
    echo ""
    echo "====== Prepared ($_TX_COUNT pre-signed tx, $_TRIGGER_CHAIN trigger) → $E2E_JOB_DIR ======"
    exit 0
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

    publish_l2_user_tx
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

fi  # ── end of the full/prepare-stage block (steps 1–4); verification below is stage-shared ──

# ══════════════════════════════════════════════
#  5. Find & verify L1 batch (BatchPosted event)
#     L1 trigger: batch is in the same block as the user tx.
#     L2 trigger: resolve each receipt block hash to its posting transaction.
#     Then verify that the batch entries match expected hashes.
# ══════════════════════════════════════════════
# One deadline covers rediscovery, verification and reorg retries. Sending and
# deployment remain outside this loop; retrying evidence never rebroadcasts.
[[ "${E2E_VERIFY_TIMEOUT:-600}" =~ ^[1-9][0-9]*$ ]] || { echo "E2E_VERIFY_TIMEOUT must be positive seconds"; exit 1; }
NETWORK_VERIFY_DEADLINE=$(( $(date +%s) + ${E2E_VERIFY_TIMEOUT:-600} ))
[[ -n "${TX_HASHES[0]:-}" ]] || TX_HASHES=("$TX_HASH")
forge() {
    local left
    left=$(network_time_left) || return 124
    timeout "$left" forge "$@"
}
cast() {
    local left
    left=$(network_time_left) || return 124
    timeout "$left" cast "$@"
}
while true; do
NETWORK_BLOCKS=(); NETWORK_RECEIPTS=(); NETWORK_UNSTABLE=false
VERIFY_STEP_OUT=()
FAILED=false; L1_OK=true; L2_OK=true; L2_CALL_OK=true; RETRY_OUT=""
L1_BATCH_TXS=()
_CORR_TX=""; _CORR_BLOCK=""; _CORR_LAST=""; _CORRELATIONS='[]'
_Batch_RC=0
network_links_capture || _Batch_RC=$?
if (( _Batch_RC != 0 )); then
    (( _Batch_RC != 1 )) || exit 1
    network_retry "transaction links pending or unavailable" || exit 1
    continue
fi
_Batch_RC=0
network_refresh_triggers || _Batch_RC=$?
if (( _Batch_RC != 0 )); then
    if (( _Batch_RC == 1 )) && network_evidence_check; then exit 1; fi
    network_retry "trigger receipt unavailable or changed" || exit 1
    continue
fi
echo "trigger blocks: $_UNIQ_BLOCKS"
_Batch_RC=0
eez_correlation_detect || _Batch_RC=$?
if (( _Batch_RC != 0 )); then
    (( _Batch_RC != 1 )) || { echo "ERROR: malformed correlation RPC response"; exit 1; }
    network_retry "Composer correlation RPC unavailable" || exit 1
    continue
fi
if $_HAS_COMPUTE; then
    _Batch_RC=0
    network_resolve_correlations || _Batch_RC=$?
    if (( _Batch_RC == 3 )); then
        EEZ_CORR_RPC=""; _CORR_TX=""; _CORRELATIONS='[]'
    elif (( _Batch_RC != 0 )); then
        (( _Batch_RC != 1 )) || { echo "ERROR: malformed settlement correlation"; exit 1; }
        network_retry "settlement pending, index catching up, or inclusion changed" || exit 1
        continue
    fi
fi

_Batch_RC=0
network_links_resolve || _Batch_RC=$?
if (( _Batch_RC != 0 )); then
    if (( _Batch_RC == 1 )) && network_evidence_check; then exit 1; fi
    network_retry "linked transaction evidence unavailable or changed" || exit 1
    continue
fi
if $NETWORK_LINKS_ACTIVE; then
    _CORR_TX="$NETWORK_LINK_POSTS"
    _CORR_BLOCK=$(jq -r '[.[].references[]|select(.role=="l1-post-batch")|.blockNumber]|first' <<< "$NETWORK_LINKS")
    _CORR_BLOCK=$((_CORR_BLOCK))
fi

_l1_scan() {
    if [[ "$_L1_CONTRACT" == VerifyL1SettlementTxsInRange ]]; then
        forge script "script/e2e/scenarios/shared/Verify.s.sol:$_L1_CONTRACT" \
            --rpc-url "$RPC" --sig "run(uint256,uint256,address)" \
            "$1" "$2" "$ROLLUPS" 2>&1
    else
        forge script "script/e2e/scenarios/shared/Verify.s.sol:$_L1_CONTRACT" \
            --rpc-url "$RPC" --sig "run(uint256,uint256,address,bytes32[],bytes)" \
            "$1" "$2" "$ROLLUPS" "$EXPECTED_L1_CALL_HASHES" 0x 2>&1
    fi
}
if ! $_HAS_COMPUTE; then
    echo "SKIP: no ComputeExpected; scenario self-verification follows"
elif $NETWORK_LINKS_ACTIVE; then
    _L1_CONTRACT=VerifyL1BatchCalldata
    L1_BATCH_TX=$(head -1 <<< "$NETWORK_LINK_POSTS")
    L1_BLOCK="$_CORR_BLOCK"
    L1_OK=true
else
    _L1_CONTRACT=VerifyL1BatchInRange
    if [[ -z "$EXPECTED_L1_CALL_HASHES" || "$EXPECTED_L1_CALL_HASHES" == '[]' ]]; then
        _L1_CONTRACT=VerifyL1SettlementTxsInRange
        if [[ "$EXPECTED_L1_TABLE" == 0x && "$EXPECTED_L1_STATIC_TABLE" == 0x ]]; then
            echo "ERROR: eventless L1 entries require expected posted tables"
            FAILED=true
        fi
    fi
    _l1_scan_latest() {
        network_evidence_check || return 75
        if [[ -n "$_CORR_TX" ]]; then
            local first="$_CORR_BLOCK" last="$_CORR_LAST" n
            if [[ "$_TRIGGER_CHAIN" == L1 ]]; then
                for n in "${TX_BLOCK_NUMBERS[@]}"; do
                    (( n < first )) && first="$n"
                    (( n > last )) && last="$n"
                done
            fi
            _l1_scan "$first" "$last"
        elif [[ "$_TRIGGER_CHAIN" == L2 ]]; then
            _l1_scan "$L1_BLOCK_BEFORE" "$(cast block-number --rpc-url "$RPC")"
        else
            _l1_scan "$TX_BLOCK_NUMBER" "$(cast block-number --rpc-url "$RPC")"
        fi
    }
    L1_OK=false
    _Batch_RC=0
    if [[ "$FAILED" != true ]]; then
        retry_until_deadline "${L1_SETTLE_TIMEOUT:-120}" 5 _l1_scan_latest || _Batch_RC=$?
        if (( _Batch_RC == 75 )); then
            network_retry "L1 inclusion changed during discovery" || exit 1
            continue
        fi
        L1_VERIFY="$RETRY_OUT"
        if (( _Batch_RC == 0 )); then
            L1_OK=true
            echo "$L1_VERIFY" | grep -E "PASS|NOTE" || true
            L1_BATCH_TX=$(extract "$L1_VERIFY" L1_BATCH_TX | head -1)
            if [[ -n "$_CORR_TX" ]]; then L1_BATCH_TX=$(head -1 <<< "$_CORR_TX"); fi
            L1_BLOCK=$(extract "$L1_VERIFY" L1_MATCH_BLOCK | head -1)
        else
            FAILED=true
            echo "L1 VERIFICATION FAILED"
        fi
    fi
fi

# ══════════════════════════════════════════════
#  5b. Compare the POSTED batch against the expected L1 table(s).
#      L1 events never carry the entries, but the settlement tx's
#      postAndVerifyBatch calldata does: decode it and field-match every
#      expected entry (the L1 analogue of the L2 table comparison) and every
#      expected top-level static entry (whose only on-chain trace this is).
#
#      Call hashes are not unique across runs — parallel or repeated jobs of
#      the same scenario can emit identical rolling hashes — so the pinned
#      L1_BATCH_TX may be a sibling job's batch. Try every candidate tx the
#      range scan emitted, and (L2 trigger) re-scan the growing range for
#      late settlements until the deadline.
# ══════════════════════════════════════════════
_L1_TABLES_PRESENT=false
[[ "$EXPECTED_L1_TABLE" != "0x" || "$EXPECTED_L1_STATIC_TABLE" != "0x" ]] && _L1_TABLES_PRESENT=true
if $_HAS_COMPUTE && [[ -n "${EXPECTED_L1_CALL_HASHES:-}" && "$EXPECTED_L1_CALL_HASHES" != "[]" && "$EXPECTED_L1_TABLE" == "0x" ]]; then
    echo "ERROR: L1 consumption checks require EXPECTED_L1_TABLE to verify posted content and exact completions"
    FAILED=true
fi
if [[ "${FAILED:-false}" != true && -z "${L1_BATCH_TX:-}" ]] && $_L1_TABLES_PRESENT; then
    echo ""
    echo "ERROR: no settlement tx identified - required posted-batch calldata verification cannot run"
    FAILED=true
fi
if [[ "${FAILED:-false}" != true && -n "${L1_BATCH_TX:-}" ]] && $_L1_TABLES_PRESENT; then
    # `|| true`: no CANDIDATE lines (e.g. L1-trigger verifiers don't emit them) must
    # not kill the script under set -e — the fallback below pins the single tx.
    _CANDIDATES=$(echo "${L1_VERIFY:-}" | grep -oE 'L1_BATCH_TX_CANDIDATE=0x[0-9a-fA-F]{64}' | cut -d= -f2 | sort -u || true)
    [[ -z "$_CANDIDATES" ]] && _CANDIDATES="$L1_BATCH_TX"
    [[ -n "$_CORR_TX" ]] && _CANDIDATES="$_CORR_TX"   # the node named the settlement tx: decode only that one

    # Calldata is immutable by transaction hash. Inclusion metadata is always
    # refreshed; an old .meta file from a resumed run is never trusted.
    _cand_input() {  # $1=txhash → calldata on stdout
        local cf="${E2E_L1TX_CACHE:-}/$1.input" inp
        if $NETWORK_LINKS_ACTIVE; then
            jq -r --arg key "L1:$1" '.[$key].transaction.input' <<< "$NETWORK_LINK_EVIDENCE"
            return
        fi
        [[ -n "${E2E_L1TX_CACHE:-}" && -s "$cf" ]] && { cat "$cf"; return 0; }
        inp=$(network_transaction_input L1 "$1" "$_BATCH_RECEIPT") || return 1
        if [[ -n "${E2E_L1TX_CACHE:-}" ]]; then
            mkdir -p "$E2E_L1TX_CACHE"
            printf '%s' "$inp" > "$cf.$$" && mv "$cf.$$" "$cf"   # tmp+mv: concurrent jobs write the same file
        fi
        printf '%s' "$inp"
    }

    # Prefilter: the expected table's 32-byte words shaped like ABI-encoded
    # addresses are job-distinctive (every job deploys its own app contracts) and
    # appear verbatim in the posted calldata (addresses are never neutralized).
    # A candidate containing none of them cannot hold our entries — skip it
    # without a forge decode. Words below 2^48 (52+ leading zero chars) are
    # excluded: ABI offsets/lengths/ids match the address shape but are small
    # numbers, and one of those in the filter would match every batch. Real
    # addresses keep high bytes non-zero (a zero top-12-hex-digit address is a
    # 2^-48 event). No qualifying words → filter off, try all candidates. Both
    # blobs are whole ABI words, so their concatenation stays word-aligned.
    _ADDR_FILTER=$(echo "${EXPECTED_L1_TABLE#0x}${EXPECTED_L1_STATIC_TABLE#0x}" | fold -w64 \
        | grep -iE '^0{24}[0-9a-f]{40}$' | grep -vE '^0{52}' | sort -u | paste -sd'|' - || true)

    echo ""
    echo "====== Verify L1 Posted Batch Calldata ($(echo "$_CANDIDATES" | wc -l) candidate tx$([[ -n "$_ADDR_FILTER" ]] && echo ", address prefilter on")) ======"
    # L1 trigger: the candidate set is known up front (no late settlement) — 60 s covers
    # the decodes; L2 trigger: the range keeps growing while the composer settles.
    _CD_DEFAULT_TIMEOUT=60; [[ "$_TRIGGER_CHAIN" == "L2" ]] && _CD_DEFAULT_TIMEOUT=180
    _CD_DEADLINE=$(( $(date +%s) + ${L1_CALLDATA_TIMEOUT:-$_CD_DEFAULT_TIMEOUT} ))
    (( _CD_DEADLINE > NETWORK_VERIFY_DEADLINE )) && _CD_DEADLINE="$NETWORK_VERIFY_DEADLINE"
    _CALLDATA_OK=false
    _LAST_FAIL=""
    _REJECTED=""   # memo of rejected candidates: skip silently on re-scan iterations
    # Multi-trigger jobs can span several batches in either direction. Their
    # matched expected-entry indices must cover the complete table exactly once.
    _CD_PARTIAL=false; _CD_MATCHED=","; _CD_EXPECTED=""; _L1_FIRST_BLOCK=""; _CD_DONE=","
    if [[ "${_TX_COUNT:-1}" -gt 1 ]] &&
        { [[ "${_UNIQ_BLOCKS:-}" == *,* ]] || [[ $(wc -w <<< "$_CORR_TX") -gt 1 ]]; }; then
        _CD_PARTIAL=true
    fi
    while true; do
        for _TX in $_CANDIDATES; do
            # Deadline inside the pass too: with the prefilter off (address-less
            # tables) a big range means hundreds of forge decodes — candidates
            # come in block order, so the true batch is early and a timeout here
            # is a genuine miss, not impatience.
            [[ $(date +%s) -ge $_CD_DEADLINE ]] && break
            [[ ",$_REJECTED," == *",$_TX,"* || "$_CD_DONE" == *",$_TX,"* ]] && continue
            _hint=$(jq -r --arg tx "$_TX" '.[]|select(.l1TransactionHash==$tx)|.l1BlockHash' <<< "${_CORRELATIONS:-[]}")
            _BATCH_RECEIPT="${NETWORK_RECEIPTS[L1:$_TX]:-}"
            if [[ -z "$_BATCH_RECEIPT" ]] && ! _BATCH_RECEIPT=$(network_receipt L1 "$_TX" "$_hint"); then
                network_retry "settlement receipt unavailable: $_TX" || exit 1
                continue 3
            fi
            if ! network_track_receipt L1 "$_TX" "$_BATCH_RECEIPT"; then
                network_retry "settlement inclusion changed: $_TX" || exit 1
                continue 3
            fi
            if [[ $(jq -r .status <<< "$_BATCH_RECEIPT") != 0x1 ]]; then
                _LAST_FAIL="FAIL: settlement transaction reverted: $_TX"
                _REJECTED="$_REJECTED,$_TX"
                continue
            fi
            _BATCH_TO=$(jq -r '.to|ascii_downcase' <<< "$_BATCH_RECEIPT")
            _BATCH_BLOCK=$(( $(jq -r .blockNumber <<< "$_BATCH_RECEIPT") ))
            if ! _BATCH_INPUT=$(_cand_input "$_TX"); then
                network_retry "settlement transaction input unavailable: $_TX" || exit 1
                continue 3
            fi
            [[ -z "$_BATCH_INPUT" || "$_BATCH_INPUT" == "0x" ]] && continue
            if [[ -n "$_ADDR_FILTER" ]] && ! grep -qiE "$_ADDR_FILTER" <<< "$_BATCH_INPUT"; then
                _REJECTED="$_REJECTED,$_TX"   # holds none of our app addresses → not our batch
                continue
            fi
            if ! _TARGET_CHECK=$(verify_settlement_target "$RPC" "$_BATCH_BLOCK" "$_BATCH_TO" "$ROLLUPS"); then
                echo "NOTE: candidate $_TX rejected: $_TARGET_CHECK"
                _REJECTED="$_REJECTED,$_TX"
                continue
            fi
            [[ -z "$_TARGET_CHECK" ]] || echo "NOTE: $_TARGET_CHECK"
            _batch_args=(--sig "run(bytes,address,bytes,bytes,bytes,bool)"
                "$_BATCH_INPUT" "$ROLLUPS" "$EXPECTED_L1_TABLE" "$EXPECTED_L1_STEPS" "$EXPECTED_L1_STATIC_TABLE" "$_CD_PARTIAL")
            if $NETWORK_LINKS_ACTIVE; then
                _batch_args=(--sig "runLinked(string,bytes32,address,bool)" "$E2E_LINK_EVIDENCE" "$_TX" "$ROLLUPS" "$_CD_PARTIAL")
            fi
            if BATCH_VERIFY=$(forge script script/e2e/scenarios/shared/Verify.s.sol:VerifyL1BatchCalldata \
                --rpc-url "$RPC" --fork-block-number "$((_BATCH_BLOCK))" "${_batch_args[@]}" 2>&1); then
                echo "Matched settlement tx $_TX"
                echo "$BATCH_VERIFY" | grep -E "PASS|NOTE|Posted batch"
                L1_BATCH_TXS+=("$_TX")
                _CD_DONE="$_CD_DONE$_TX,"
                if $_CD_PARTIAL; then
                    # union the matched indices; an index seen twice means two batches
                    # both claim the same entry — not a valid split
                    _CD_EXPECTED=$(extract "$BATCH_VERIFY" "L1_CALLDATA_EXPECTED")
                    for _ix in $(extract "$BATCH_VERIFY" "L1_CALLDATA_MATCHED" | tr -d '[]' | tr ',' ' '); do
                        if [[ "$_CD_MATCHED" == *",$_ix,"* ]]; then
                            echo "FAIL: expected entry $_ix matched by two settlement txs"
                            _LAST_FAIL="$BATCH_VERIFY"; _CD_MATCHED=","; break 3
                        fi
                        _CD_MATCHED="$_CD_MATCHED$_ix,"
                    done
                    # Retain a representative tx for legacy diagnostics; all matches are kept.
                    if [[ -z "$_L1_FIRST_BLOCK" || "$_BATCH_BLOCK" -lt "$_L1_FIRST_BLOCK" ]]; then
                        L1_BATCH_TX="$_TX"; _L1_FIRST_BLOCK="$_BATCH_BLOCK"
                    fi
                    _n_matched=$(( $(tr -cd ',' <<< "$_CD_MATCHED" | wc -c) - 1 ))
                    echo "matched $_n_matched of ${_CD_EXPECTED:-?} expected entries so far"
                    if [[ -n "$_CD_EXPECTED" && "$_n_matched" -ge "$_CD_EXPECTED" ]]; then
                        _CALLDATA_OK=true
                        break 2
                    fi
                    continue
                fi
                L1_BATCH_TX="$_TX"
                _CALLDATA_OK=true
                break 2
            fi
            _LAST_FAIL="$BATCH_VERIFY"
        done
        # No candidate contained our entries. For L2 triggers our entry may
        # simply not have settled yet — re-scan the growing range for new
        # settlement txs until the deadline.
        [[ $(date +%s) -ge $_CD_DEADLINE || "$_L1_CONTRACT" != "VerifyL1SettlementTxsInRange" || -n "$_CORR_TX" ]] && break
        network_retry "waiting for matching settlement calldata" || exit 1
        _L1_CUR=$(cast block-number --rpc-url "$RPC")
        _L1_SCAN_FROM="${L1_BLOCK_BEFORE:-$L1_BLOCK}"
        L1_RESCAN=$(_l1_scan "$_L1_SCAN_FROM" "$_L1_CUR") || continue
        _NEW=$(echo "$L1_RESCAN" | grep -oE 'L1_BATCH_TX_CANDIDATE=0x[0-9a-fA-F]{64}' | cut -d= -f2 | sort -u || true)
        [[ -n "$_NEW" ]] && _CANDIDATES="$_NEW"
    done
    if ! $_CALLDATA_OK; then
        if $_CD_PARTIAL; then
            FAILED=true
            [[ -n "$_LAST_FAIL" ]] && echo "$_LAST_FAIL" | grep -E "FAIL|NOTE|Error|call\[" | head -30
            echo "L1 BATCH CALLDATA VERIFICATION FAILED (matched $(( $(tr -cd ',' <<< "$_CD_MATCHED" | wc -c) - 1 )) of ${_CD_EXPECTED:-?} expected entries across the trigger blocks' settlement txs)"
        else
            # Both trigger directions require a posted-content match. Missing input
            # or a rejected destination must not silently skip this check.
            FAILED=true
            if [[ -n "$_LAST_FAIL" ]]; then
                echo "$_LAST_FAIL" | grep -E "FAIL|NOTE|Error|call\[" | head -30 || true
            fi
            echo "L1 BATCH CALLDATA VERIFICATION FAILED (no candidate settlement tx contained the expected entries)"
        fi
    fi
fi

# ══════════════════════════════════════════════
#  6. Discover L2 blocks by expected call hashes, using the original range scan.
#     Correlation bounds the search and pins every candidate block's hash;
#     only matching blocks (plus L2 trigger blocks) need detailed event checks.
# ══════════════════════════════════════════════
L2_BLOCKS="[]"
_CORRELATED_L2_BLOCKS="[]"
_SCAN_FROM="${L2_BLOCK_BEFORE:-${L2_BLOCK:-0}}"
_SCAN_TO=""
if [[ "$_CORRELATIONS" != '[]' && ${#L1_BATCH_TXS[@]} -gt 0 ]]; then
    if ! network_correlated_l2_blocks; then
        network_retry "correlated L2 blocks unavailable or replaced" || exit 1
        continue
    fi
    _CORRELATED_L2_BLOCKS="$L2_BLOCKS"
    read -r _SCAN_FROM _SCAN_TO < <(jq -r '[min,max]|map(tostring)|join(" ")' <<< "$_CORRELATED_L2_BLOCKS")
fi
L2_BLOCKS="[]"
if [[ "$_TRIGGER_CHAIN" == L2 ]]; then
    L2_BLOCKS=$(printf '%s\n' "${TX_BLOCK_NUMBERS[@]}" | jq -sc 'unique')
fi
if $NETWORK_LINKS_ACTIVE; then
    L2_BLOCKS=$(jq -r '[.[].references[]|select(.chain=="L2")|.blockNumber]|unique[]' <<< "$NETWORK_LINKS" |
        while read -r number; do echo "$((number))"; done | jq -sc 'unique')
elif [[ -n "${EXPECTED_L2_CALL_HASHES:-}" && "$EXPECTED_L2_CALL_HASHES" != '[]' ]]; then
    _l2_calls_scan_latest() {
        network_evidence_check || return 75
        local to="$_SCAN_TO"
        [[ -n "$to" ]] || to=$(cast block-number --rpc-url "$L2_RPC") || return 1
        forge script script/e2e/scenarios/shared/Verify.s.sol:VerifyL2CallsInRange \
            --rpc-url "$L2_RPC" --sig "run(uint256,uint256,address,bytes32[])" \
            "$_SCAN_FROM" "$to" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES"
    }
    _Batch_RC=0
    retry_until_deadline "${L2_SETTLE_TIMEOUT:-180}" 5 _l2_calls_scan_latest || _Batch_RC=$?
    if (( _Batch_RC == 75 )); then
        network_retry "inclusion changed during L2 discovery" || exit 1
        continue
    elif (( _Batch_RC == 0 )); then
        _FOUND_LIST=$(extract "$RETRY_OUT" L2_MATCH_BLOCKS)
        if ! jq -e 'type=="array" and length>0 and all(.[]; type=="number" and .>=0 and floor==.)' \
            <<< "$_FOUND_LIST" >/dev/null 2>&1; then
            FAILED=true
            echo "L2 VERIFICATION FAILED: invalid matching-block list"
        elif [[ "$_CORRELATED_L2_BLOCKS" != '[]' ]] && \
            ! jq -e --argjson allowed "$_CORRELATED_L2_BLOCKS" '.-$allowed|length==0' \
                <<< "$_FOUND_LIST" >/dev/null; then
            FAILED=true
            echo "L2 VERIFICATION FAILED: matching blocks fall outside the matched settlements"
        else
            L2_BLOCKS=$(jq -cn --argjson old "$L2_BLOCKS" --argjson new "$_FOUND_LIST" '$old+$new|unique')
        fi
    else
        FAILED=true
        echo "L2 VERIFICATION FAILED: expected calls not found"
    fi
elif [[ "${EXPECTED_L2_HASHES:-[]}" != '[]' && "$_CORRELATED_L2_BLOCKS" != '[]' ]]; then
    # A table with no expected call events cannot be located by call hashes.
    # Preserve the existing exact-block coverage for this case.
    L2_BLOCKS="$_CORRELATED_L2_BLOCKS"
fi
if ! network_pin_l2_blocks; then
    network_retry "L2 verification blocks unavailable or replaced" || exit 1
    continue
fi
echo "L2 blocks to verify: $L2_BLOCKS"

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
elif [[ "$EXPECTED_L2_HASHES" == "[]" && "${EXPECTED_L2_STATIC_TABLE:-0x}" == 0x && "${NETWORK_LINK_HAS_L2_TABLES:-false}" != true ]]; then
    echo "No L2 entry events expected (lookup, terminal revert, or an eventless static pool)"
    # ABSENT_L2_HASHES: call keys that must have left NO trace on L2 — the active proof
    # that a lookup (a call that reverts on L2, a top-level static read) was never
    # delivered. Correlated blocks have already been checked against the chain.
    # Without correlation retain the grace period; pin the scan's upper block
    # so a replacement invalidates a negative result as well as a positive one.
    if [[ -n "${ABSENT_L2_HASHES:-}" && "$ABSENT_L2_HASHES" != "[]" ]]; then
        _ABS_FROM="${L2_BLOCK_BEFORE:-${L2_BLOCK:-0}}"
        if [[ "$_CORRELATIONS" == '[]' ]]; then
            _grace="${L2_ABSENT_GRACE:-60}"
            _left=$(network_time_left) || exit 1
            (( _grace > _left )) && _grace="$_left"
            sleep "$_grace"
        fi
        _abs_header=$(network_header L2 latest) || {
            network_retry "L2 absence-check head unavailable" || exit 1
            continue
        }
        _ABS_TO=$(( $(jq -r .number <<< "$_abs_header") ))
        if ! network_track_block L2 "$_ABS_TO" "$(jq -r .hash <<< "$_abs_header")"; then
            network_retry "L2 absence-check head changed" || exit 1
            continue
        fi
        echo ""
        echo "====== Verify L2 Absent (keys must not appear in blocks $_ABS_FROM..$_ABS_TO) ======"
        run_verify_step "L2 ABSENT" full verify_l2_absent "$L2_RPC" "$_ABS_FROM" "$_ABS_TO" "$MANAGER_L2" "$ABSENT_L2_HASHES"
        L2_OK=$VERIFY_STEP_OK
    else
        echo "SKIP: no absent keys to verify"
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
#      They assert PERSISTED on-chain state (reader counters, cached read
#      values) read at latest, with a retry for RPC lag. They must not re-issue
#      a pool lookup (a static entry's root pin is only live until the next tx
#      that moves the root, possibly in the same block) — a posted static entry
#      is matched from the batch calldata in 5b instead.
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

# Record the actual table/delivery transactions selected by the semantic verifiers.
if [[ "$FAILED" != true && "$NETWORK_LINKS_ACTIVE" != true ]]; then
    _receipts_ready=true
    _l2_receipt_hints=""
    while read -r _number; do
        _l2_receipt_hints+="${NETWORK_BLOCKS[L2:$_number]}"$'\n'
    done < <(jq -r '.[]' <<< "$L2_BLOCKS")
    _l2_receipt_txs=$(printf '%s\n' "${VERIFY_STEP_OUT[L2 TABLE]:-}" "${VERIFY_STEP_OUT[L2 CALL]:-}" |
        sed -nE 's/.*L2_(TABLE|CALL)_TX=(0x[0-9a-fA-F]{64}).*/\2/p' | sort -u |
        jq -Rsc 'split("\n")|map(select(length>0))')
    _l2_block_receipts='[]'
    if [[ "$_l2_receipt_txs" != '[]' ]]; then
        _l2_block_receipts=$(network_receipts_from_blocks L2 "$_l2_receipt_txs" "${_l2_receipt_hints%$'\n'}") || _l2_block_receipts='[]'
    fi
    while read -r _tx; do
        [[ -n "$_tx" ]] || continue
        if [[ "$_l2_block_receipts" != '[]' ]]; then
            _receipt=$(jq -c --arg tx "$_tx" '.[]|select(.transactionHash==$tx)' <<< "$_l2_block_receipts")
        elif ! _receipt=$(network_receipt L2 "$_tx" "${_l2_receipt_hints%$'\n'}"); then
            _receipts_ready=false; break
        fi
        if ! network_track_receipt L2 "$_tx" "$_receipt"; then _receipts_ready=false; break; fi
        if [[ $(jq -r .status <<< "$_receipt") != 0x1 ]]; then
            echo "FAIL: matched L2 transaction reverted: $_tx"
            FAILED=true
        fi
    done < <(jq -r '.[]' <<< "$_l2_receipt_txs")
    if ! $_receipts_ready; then
        network_retry "matched L2 receipt unavailable or changed" || exit 1
        continue
    fi
fi
if ! network_evidence_check; then
    network_retry "canonical inclusion changed or could not be revalidated; discarding this pass" || exit 1
    continue
fi
if ! network_links_recheck; then
    network_retry "transaction links or attempt changed; discarding this pass" || exit 1
    continue
fi
network_time_left >/dev/null || { echo "ERROR: network verification deadline expired"; exit 1; }

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

for _tx in "${L1_BATCH_TXS[@]}"; do
    _receipt="${NETWORK_RECEIPTS[L1:$_tx]}"
    echo "L1 postBatch:   $_tx  (block $(( $(jq -r .blockNumber <<< "$_receipt") )))"
done

if $NETWORK_LINKS_ACTIVE; then
    network_links_finish || exit 1
else
for _kind in TABLE CALL; do
    _label="L2 loadTable"; [[ "$_kind" != CALL ]] || _label="L2 call exec"
    while read -r _tx; do
        [[ -n "$_tx" ]] || continue
        _receipt="${NETWORK_RECEIPTS[L2:$_tx]}"
        echo "$_label:   $_tx  (block $(( $(jq -r .blockNumber <<< "$_receipt") )))"
    done < <(printf '%s\n' "${VERIFY_STEP_OUT[L2 $_kind]:-}" |
        sed -nE "s/.*L2_${_kind}_TX=(0x[0-9a-fA-F]{64}).*/\\1/p" | sort -u)
done
fi

echo ""
echo "====== Done ======"
break
done # verification attempts
