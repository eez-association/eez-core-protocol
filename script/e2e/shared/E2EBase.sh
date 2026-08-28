#!/usr/bin/env bash
# Shared utilities for e2e test scripts.
# Source from test runners: source "$(dirname "$0")/../shared/E2EBase.sh"

set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# Default values
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# ── PIDs to clean up on exit ──
_E2E_PIDS=()

cleanup() {
    for pid in "${_E2E_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Extract KEY=VALUE from forge script output (returns "" if not found) ──
extract() { echo "$1" | grep "$2=" | sed "s/.*$2=//" | awk '{print $1}' || true; }

# ── Start an anvil instance, return PID via variable name ──
# Usage: start_anvil PORT PID_VAR [CHAIN_ID]
# If CHAIN_ID is omitted, anvil's default (31337) is used.
start_anvil() {
    local port="$1"
    local pid_var="$2"
    local chain_id="${3:-}"
    local chain_arg=()
    if [[ -n "$chain_id" ]]; then
        chain_arg=(--chain-id "$chain_id")
        echo "Starting anvil (port $port, chain-id $chain_id)..."
    else
        echo "Starting anvil (port $port)..."
    fi
    anvil --port "$port" "${chain_arg[@]}" --silent &
    local pid=$!
    _E2E_PIDS+=("$pid")
    eval "$pid_var=$pid"
    sleep 1
    echo "Anvil running (PID $pid)"
}

# ── Deploy infrastructure (EEZ on L1, optionally CCManagerL2 on L2) ──
# Sets ROLLUPS (and MANAGER_L2 if L2_RPC provided)
deploy_infra() {
    local l1_rpc="$1"
    local pk="$2"
    local l2_rpc="${3:-}"
    local l2_rollup_id="${4:-1}"
    local system_address="${5:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

    echo ""
    echo "====== Deploy EEZ (L1) ======"
    local output
    output=$(forge script script/e2e/shared/DeployInfra.s.sol:DeployEEZL1 \
        --rpc-url "$l1_rpc" --broadcast --private-key "$pk" 2>&1)
    ROLLUPS=$(extract "$output" "ROLLUPS")
    PROOF_SYSTEM=$(extract "$output" "PROOF_SYSTEM")
    L2_MANAGER=$(extract "$output" "L2_MANAGER")
    echo "ROLLUPS=$ROLLUPS"
    echo "PROOF_SYSTEM=$PROOF_SYSTEM"
    echo "L2_MANAGER=$L2_MANAGER"

    if [[ -n "$l2_rpc" ]]; then
        echo ""
        echo "====== Deploy EEZL2 (L2) ======"
        output=$(forge script script/e2e/shared/DeployInfra.s.sol:DeployManagerL2 \
            --rpc-url "$l2_rpc" --broadcast --private-key "$pk" \
            --sig "run(uint64,address)" "$l2_rollup_id" "$system_address" 2>&1)
        MANAGER_L2=$(extract "$output" "MANAGER_L2")
        echo "MANAGER_L2=$MANAGER_L2"
    fi
}

# ── Decode events from a block ──
# Usage: decode_block RPC BLOCK_NUMBER TARGET_CONTRACT [LABEL]
decode_block() {
    local rpc="$1"
    local block="$2"
    local target="$3"
    local label="${4:-}"

    echo ""
    echo "====== DecodeExecutions ${label}(block $block, target $target) ======"
    echo ""
    forge script script/DecodeExecutions.s.sol:DecodeExecutions \
        --rpc-url "$rpc" \
        --sig "runBlock(uint256,address)" "$block" "$target" 2>&1 \
        | sed -n '/^  /p'
}

# ── Auto-export KEY=VALUE lines from forge script output as env vars ──
# Usage: _export_outputs OUTPUT [--echo]  (--echo also prints the exported lines)
_export_outputs() {
    local output="$1" echo_flag="${2:-}"
    local vars
    vars=$(echo "$output" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true)
    if [[ -n "$vars" ]]; then
        [[ "$echo_flag" == "--echo" ]] && echo "$vars"
        while IFS= read -r line; do
            export "$line"
        done <<< "$vars"
    fi
}

# ── Auto-discover and run Deploy* contracts in file order ──
# Contracts with "L2" in name → L2 RPC, others → L1 RPC
deploy_contracts() {
    local sol="$1" l1_rpc="$2" l2_rpc="$3" pk="$4"
    local contracts
    contracts=$(grep -oE 'contract Deploy[A-Za-z0-9_]* ' "$sol" | awk '{print $2}')
    [[ -z "$contracts" ]] && { echo "No Deploy* contracts found"; return 1; }
    while IFS= read -r contract; do
        local rpc label
        if [[ "$contract" == *L2* ]]; then
            rpc="$l2_rpc"; label="L2"
        else
            rpc="$l1_rpc"; label="L1"
        fi
        echo "--- $contract ($label) ---"
        local out
        if ! out=$(forge script "$sol:$contract" --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1); then
            echo "DEPLOY FAILED: $contract ($label) — forge output tail:"
            echo "$out" | tail -25
            return 1
        fi
        _export_outputs "$out" --echo
    done <<< "$contracts"
}

# ── Strip forge execution traces ──
strip_traces() {
    grep -v '├─\|└─\|│ \|→ new\|\[staticcall\]\|\[Return\]\|\[Stop\]\|\[Revert\]\|::run(' | sed -n '/^  /p'
}

# ── Verify-step wrappers around script/e2e/shared/Verify.s.sol ──
# Each runs the given verifier contract, captures its combined output in the
# global VERIFY_OUT, and returns forge's exit status. Callers own the failure
# plumbing (FAILED flags, PASS-grep, diagnostics), which differs per runner.
_run_verifier() {
    local contract="$1" rpc="$2" sig="$3"
    shift 3
    local rc=0
    VERIFY_OUT=$(forge script "script/e2e/shared/Verify.s.sol:$contract" \
        --rpc-url "$rpc" --sig "$sig" "$@" 2>&1) || rc=$?
    return "$rc"
}

# The optional trailing EXPECTED_TABLE arg is the abi-encoded expected-entries blob
# from ComputeExpected ("0x" = hash-only checks, field-level comparison off).

# Usage: verify_l1_batch RPC BLOCK ROLLUPS EXPECTED_CALL_HASHES [EXPECTED_TABLE]
# A single known block is the from == to degenerate range.
verify_l1_batch() { _run_verifier VerifyL1BatchInRange "$1" "run(uint256,uint256,address,bytes32[],bytes)" "$2" "$2" "$3" "$4" "${5:-0x}"; }

# Usage: verify_l1_zero_hash RPC FROM_BLOCK TO_BLOCK ROLLUPS EXPECTED_ENTRY_HASHES [EXPECTED_TABLE]
# For system-driven L1 entries (proxyEntryHash == 0, no ExecutionConsumed call hash):
# matches EntryExecuted rolling hashes as keccak(0, rollingHash) entry identities.
verify_l1_zero_hash() { _run_verifier VerifyL1ZeroHashEntriesInRange "$1" "run(uint256,uint256,address,bytes32[],bytes)" "$2" "$3" "$4" "$5" "${6:-0x}"; }

# Usage: verify_l2_table RPC BLOCKS_ARRAY MANAGER_L2 EXPECTED_ENTRY_HASHES [EXPECTED_TABLE] [EVENTLESS_ENTRY_HASHES]
verify_l2_table() { _run_verifier VerifyL2Blocks "$1" "run(uint256[],address,bytes32[],bytes,bytes32[])" "$2" "$3" "$4" "${5:-0x}" "${6:-[]}"; }

# Usage: verify_l2_calls RPC BLOCKS_ARRAY MANAGER_L2 EXPECTED_CALL_HASHES [EXPECTED_TABLE]
verify_l2_calls() { _run_verifier VerifyL2Calls "$1" "run(uint256[],address,bytes32[],bytes)" "$2" "$3" "$4" "${5:-0x}"; }

# Usage: verify_l2_absent RPC BLOCKS_ARRAY MANAGER_L2 ABSENT_ENTRY_HASHES
verify_l2_absent() { _run_verifier VerifyL2Absent "$1" "run(uint256[],address,bytes32[])" "$2" "$3" "$4"; }

# ── Run one verification step end-to-end ──
# Usage: run_verify_step LABEL DIAG FN ARGS...
# Runs FN (a verify_* wrapper — it must fill VERIFY_OUT), prints the PASS/NOTE
# lines on success; on failure prints "<LABEL> VERIFICATION FAILED" and sets
# FAILED=true. DIAG picks the failure diagnostics: inline (stripped output),
# full (raw output), defer (nothing — caller reprints later from
# VERIFY_STEP_OUT[LABEL]). The raw output is stashed in VERIFY_STEP_OUT[LABEL]
# either way, and the step's status in VERIFY_STEP_OK; the function itself
# always returns 0 so plain calls are set -e safe.
declare -A VERIFY_STEP_OUT
run_verify_step() {
    local label="$1" diag="$2"
    shift 2
    local rc=0
    "$@" || rc=$?
    VERIFY_STEP_OUT["$label"]="$VERIFY_OUT"
    if [[ $rc -eq 0 ]]; then
        VERIFY_STEP_OK=true
        echo "$VERIFY_OUT" | grep -E "^\s*(PASS|NOTE)" || echo "  PASS"
    else
        VERIFY_STEP_OK=false
        FAILED=true
        echo "$label VERIFICATION FAILED"
        case "$diag" in
            inline) echo "$VERIFY_OUT" | strip_traces 2>/dev/null || echo "$VERIFY_OUT";;
            full)   echo "$VERIFY_OUT";;
        esac
    fi
}

# ── Retry a command until it succeeds or a deadline passes ──
# Usage: retry_until_deadline TIMEOUT SLEEP CMD [ARGS...]
# The last attempt's combined output lands in RETRY_OUT (like _run_verifier's
# VERIFY_OUT). Returns 0 on the first success; once TIMEOUT seconds have
# passed, the last attempt's status. Sleeps SLEEP seconds between attempts.
retry_until_deadline() {
    local deadline=$(( $(date +%s) + $1 ))
    local pause="$2"
    shift 2
    local rc
    while true; do
        rc=0
        RETRY_OUT=$("$@" 2>&1) || rc=$?
        [[ $rc -eq 0 ]] && return 0
        [[ $(date +%s) -ge $deadline ]] && return "$rc"
        sleep "$pause"
    done
}

# ── Trace failed transactions from forge output ──
trace_failed_txs() {
    local output="$1"
    local rpc="$2"
    local txs
    txs=$(echo "$output" | grep "Transaction Failure:" | sed 's/.*Transaction Failure: //' | awk '{print $1}' || true)
    if [[ -n "$txs" ]]; then
        while IFS= read -r tx; do
            echo ""
            echo "--- Tracing failed tx $tx ---"
            cast run "$tx" --rpc-url "$rpc" 2>&1 || true
        done <<< "$txs"
    fi
}

# ── Run one Execute contract with a same-block guarantee (local mode only) ──
# All txs the contract broadcasts (e.g. postAndVerifyBatch + the user trigger, or
# loadExecutionTable + the proxy call) land in ONE mined block, satisfying the
# managers' same-block consumption gates without any helper contract on-chain.
execute_same_block() {
    local sol="$1" contract="$2" rpc="$3" pk="$4"
    local tmpfile
    tmpfile=$(mktemp)

    cast rpc evm_setAutomine false --rpc-url "$rpc" > /dev/null 2>&1

    # --isolate: simulate each broadcast call as its OWN transaction (fresh
    # transient storage), matching on-chain execution — without it, scenarios
    # that make multiple system deliveries in one script (multi-call) fail the
    # pre-broadcast simulation with a false RollingHashMismatch.
    forge script "$sol:$contract" --rpc-url "$rpc" --broadcast --isolate --private-key "$pk" > "$tmpfile" 2>&1 &
    local forge_pid=$!
    _E2E_PIDS+=("$forge_pid")

    # Forge simulates the script before submitting its transaction bundle. A
    # fixed sleep races that simulation: slower scenarios can enqueue after the
    # mine and then wait forever because automine is disabled. Wait until the
    # pool is non-empty and its size has settled instead.
    local last_pending=-1
    local stable_polls=0
    local deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        local pool pending_hex queued_hex pending
        pool=$(cast rpc txpool_status --rpc-url "$rpc" 2>/dev/null || true)
        pending_hex=$(jq -r '.pending // "0x0"' <<< "$pool" 2>/dev/null || echo "0x0")
        queued_hex=$(jq -r '.queued // "0x0"' <<< "$pool" 2>/dev/null || echo "0x0")
        pending=$((pending_hex + queued_hex))

        if ((pending > 0)); then
            if ((pending == last_pending)); then
                stable_polls=$((stable_polls + 1))
            else
                last_pending=$pending
                stable_polls=0
            fi
            ((stable_polls >= 4)) && break
        fi

        kill -0 "$forge_pid" 2>/dev/null || break
        sleep 0.25
    done

    cast rpc evm_mine --rpc-url "$rpc" > /dev/null 2>&1

    wait "$forge_pid" 2>/dev/null
    local exit_code=$?

    cast rpc evm_setAutomine true --rpc-url "$rpc" > /dev/null 2>&1

    cat "$tmpfile"
    rm -f "$tmpfile"
    return "$exit_code"
}

execute_l2_same_block() {
    execute_same_block "$1" "ExecuteL2" "$2" "$3"
}

execute_l1_same_block() {
    execute_same_block "$1" "Execute" "$2" "$3"
}

# ── Path of the latest forge broadcast JSON for a script + chain ──
_broadcast_json() {
    local sol="$1" rpc="$2"
    local chain_id
    chain_id=$(cast chain-id --rpc-url "$rpc" 2>/dev/null) || return 1
    echo "broadcast/$(basename "$sol")/${chain_id}/run-latest.json"
}

# ── Get block number from forge broadcast JSON ──
get_block_from_broadcast() {
    local sol="$1" rpc="$2"
    local json
    json=$(_broadcast_json "$sol" "$rpc") || return 1
    if [[ ! -f "$json" ]]; then
        echo "ERROR: Broadcast file not found: $json" >&2
        return 1
    fi
    local tx_hash
    tx_hash=$(jq -r '.receipts[-1].transactionHash' "$json")
    echo "tx: $tx_hash" >&2
    printf "%d\n" "$(jq -r '.receipts[-1].blockNumber' "$json")"
}

# ── Build the pre-signed trigger tx(s) from an ExecuteNetwork(L2) contract ──
# Usage: build_trigger_txs SOL NONCE_MODE
#   NONCE_MODE local   → rpc nonce + 1, quiet: the trigger follows one same-key
#                        tx that ExecuteL2 broadcasts in the same block
#              network → max(rpc, front) nonce, verbose: a load-balanced public
#                        RPC can lag behind blocks we just mined (deploys), and
#                        a cross-chain front does its own on-chain+held nonce
#                        accounting — query both instead of trusting mktx's default
# Detects the trigger chain ("contract ExecuteNetworkL2" → L2, else L1), runs
# the contract read-only for TARGET/VALUE/CALLDATA/NUM_TXS, and pre-signs
# NUM_TXS txs with consecutive nonces via cast mktx (queries chain for gas
# price, does NOT broadcast). Sets _TRIGGER_CHAIN, _TRIGGER_CONTRACT,
# _TRIGGER_RPC, _TX_COUNT, RLP_ENCODED_TXS; exports RLP_ENCODED_TX (the first
# tx — ComputeExpected reads it from env for action hashing).
build_trigger_txs() {
    local sol="$1" nonce_mode="$2"

    if grep -q 'contract ExecuteNetworkL2 ' "$sol"; then
        _TRIGGER_CHAIN="L2"
        _TRIGGER_CONTRACT="ExecuteNetworkL2"
        _TRIGGER_RPC="$L2_RPC"
    else
        _TRIGGER_CHAIN="L1"
        _TRIGGER_CONTRACT="ExecuteNetwork"
        _TRIGGER_RPC="$RPC"
    fi

    local exec_out target value calldata
    exec_out=$(forge script "$sol:$_TRIGGER_CONTRACT" --rpc-url "$_TRIGGER_RPC" 2>&1)
    target=$(extract "$exec_out" "TARGET")
    value=$(extract "$exec_out" "VALUE")
    calldata=$(extract "$exec_out" "CALLDATA")
    # Multi-tx scenarios (optional NUM_TXS output): the SAME tx shape is pre-signed
    # NUM_TXS times with consecutive nonces and fired without waiting between sends.
    _TX_COUNT=$(extract "$exec_out" "NUM_TXS")
    _TX_COUNT="${_TX_COUNT:-1}"

    local sender nonce_rpc nonce_front tx_nonce
    sender=$(cast wallet address --private-key "$PK")
    nonce_rpc=$(cast nonce "$sender" --rpc-url "$_TRIGGER_RPC" 2>/dev/null || echo 0)
    if [[ "$nonce_mode" == "local" ]]; then
        tx_nonce=$((nonce_rpc + 1))
    else
        echo "target: $target"
        echo "calldata: $calldata"
        echo "value: $value"
        [[ "$_TX_COUNT" -gt 1 ]] && echo "trigger txs: $_TX_COUNT (consecutive nonces, fire-and-forget)"
        if [[ "$_TRIGGER_CHAIN" == "L2" && -n "${L2_FRONT:-}" ]]; then
            nonce_front=$(cast nonce "$sender" --rpc-url "$L2_FRONT" 2>/dev/null || echo 0)
        elif [[ "$_TRIGGER_CHAIN" == "L1" && -n "${L1_FRONT:-}" ]]; then
            nonce_front=$(cast nonce "$sender" --rpc-url "$L1_FRONT" 2>/dev/null || echo 0)
        else
            nonce_front=0
        fi
        tx_nonce=$(( nonce_rpc > nonce_front ? nonce_rpc : nonce_front ))
        echo "nonce: $tx_nonce (rpc=$nonce_rpc front=$nonce_front)"
    fi

    RLP_ENCODED_TXS=()
    local i
    for (( i = 0; i < _TX_COUNT; i++ )); do
        RLP_ENCODED_TXS+=("$(cast mktx "$target" "$calldata" \
            --value "${value}wei" \
            --gas-limit 2000000 \
            --nonce "$(( tx_nonce + i ))" \
            --private-key "$PK" \
            --rpc-url "$_TRIGGER_RPC")")
    done
    export RLP_ENCODED_TX="${RLP_ENCODED_TXS[0]}"
}

# ── Extract every EXPECTED_* output of a ComputeExpected run ──
# Usage: extract_expected_outputs COMPUTE_OUT
# Sets EXPECTED_L1_HASHES / EXPECTED_L2_HASHES / EXPECTED_L1_CALL_HASHES /
# EXPECTED_L2_CALL_HASHES, the abi-encoded EXPECTED_L1_TABLE / EXPECTED_L2_TABLE
# blobs ("0x" = hash-only checks, field-level comparison off), EXPECTED_L1_STEPS
# (recorded fold steps for the calldata verifier; "0x" = content-match only),
# EVENTLESS_L2_HASHES (loaded entries whose enclosing frame's revert unwinds their
# EntryExecuted event) and ABSENT_L2_HASHES; prints the field-level ON/OFF notes
# and the scenario's EXPECTED SUMMARY block if present.
extract_expected_outputs() {
    local out="$1"

    EXPECTED_L1_CALL_HASHES=$(extract "$out" "EXPECTED_L1_CALL_HASHES")
    echo "L1 expected calls: $EXPECTED_L1_CALL_HASHES"

    EXPECTED_L1_HASHES=$(extract "$out" "EXPECTED_L1_HASHES")
    [[ -n "$EXPECTED_L1_HASHES" ]] && echo "L1 expected entries: $EXPECTED_L1_HASHES"

    EXPECTED_L2_HASHES=$(extract "$out" "EXPECTED_L2_HASHES")
    if [[ -n "$EXPECTED_L2_HASHES" ]]; then
        echo "L2 table expected: $EXPECTED_L2_HASHES"
    fi

    EXPECTED_L2_CALL_HASHES=$(extract "$out" "EXPECTED_L2_CALL_HASHES")
    echo "L2 calls expected: $EXPECTED_L2_CALL_HASHES"

    EXPECTED_L1_TABLE=$(extract "$out" "EXPECTED_L1_TABLE")
    EXPECTED_L1_TABLE="${EXPECTED_L1_TABLE:-0x}"
    EXPECTED_L1_STEPS=$(extract "$out" "EXPECTED_L1_STEPS")
    EXPECTED_L1_STEPS="${EXPECTED_L1_STEPS:-0x}"
    if [[ "$EXPECTED_L1_TABLE" != "0x" ]]; then
        echo "L1 expected table: $((${#EXPECTED_L1_TABLE} / 2 - 1)) bytes (field-level checks ON)"
    else
        echo "NOTE: no EXPECTED_L1_TABLE printed - L1 field-level checks OFF (hash-only)"
    fi
    EXPECTED_L2_TABLE=$(extract "$out" "EXPECTED_L2_TABLE")
    EXPECTED_L2_TABLE="${EXPECTED_L2_TABLE:-0x}"
    if [[ "$EXPECTED_L2_TABLE" != "0x" ]]; then
        echo "L2 expected table: $((${#EXPECTED_L2_TABLE} / 2 - 1)) bytes (field-level checks ON)"
    else
        echo "NOTE: no EXPECTED_L2_TABLE printed - L2 field-level checks OFF (hash-only)"
    fi

    EVENTLESS_L2_HASHES=$(extract "$out" "EVENTLESS_L2_HASHES")
    EVENTLESS_L2_HASHES="${EVENTLESS_L2_HASHES:-[]}"
    if [[ "$EVENTLESS_L2_HASHES" != "[]" ]]; then
        echo "L2 eventless after enclosing rollback: $EVENTLESS_L2_HASHES"
    fi

    ABSENT_L2_HASHES=$(extract "$out" "ABSENT_L2_HASHES")
    if [[ -n "$ABSENT_L2_HASHES" && "$ABSENT_L2_HASHES" != "[]" ]]; then
        echo "L2 absent (must NOT appear): $ABSENT_L2_HASHES"
    fi

    # Print summary (lines between === EXPECTED SUMMARY === and the next blank line)
    local summary
    summary=$(echo "$out" | sed -n '/=== EXPECTED SUMMARY ===/,/^$/p' | head -20)
    if [[ -n "$summary" ]]; then
        echo ""
        echo "$summary"
    fi
}

# ── Publish a pre-signed raw tx ──
# ── Send one pre-signed raw tx; echoes the accepted hash (errors → stderr) ──
_send_raw_tx() {
    local rpc="$1" raw="$2"
    local rpc_out tx_hash
    if ! rpc_out=$(cast rpc eth_sendRawTransaction "$raw" --rpc-url "$rpc" 2>&1); then
        echo "ERROR: eth_sendRawTransaction failed" >&2
        echo "$rpc_out" >&2
        return 1
    fi
    tx_hash=$(echo "$rpc_out" | tr -d '"[:space:]')
    if [[ -z "$tx_hash" || "$tx_hash" == "null" ]]; then
        echo "ERROR: Could not extract tx hash from RPC response: $rpc_out" >&2
        return 1
    fi
    echo "$tx_hash"
}

# ── Poll one receipt until a deadline (epoch seconds); echoes the receipt JSON ──
# Bounded on purpose — a blocking `cast receipt` never returns for a tx that a
# cross-chain front HOLDS but the composer never bundles.
_poll_receipt() {
    local rpc="$1" tx_hash="$2" deadline="$3"
    local receipt
    while [[ $(date +%s) -lt $deadline ]]; do
        receipt=$(curl -s --max-time 10 -X POST "$rpc" -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$tx_hash\"],\"id\":1}" \
            | jq -c '.result // empty' 2>/dev/null)
        [[ -n "$receipt" ]] && { echo "$receipt"; return 0; }
        sleep 5
    done
    echo "ERROR: no receipt for tx $tx_hash after ${RECEIPT_TIMEOUT:-300}s." >&2
    echo "  If this tx went to a cross-chain front, it is HELD until the composer" >&2
    echo "  bundles it — no receipt means the pipeline did not process it in time." >&2
    return 1
}

# ── Publish RLP_ENCODED_TX and wait for its receipt ──
# Sets TX_HASH and TX_BLOCK_NUMBER. Override the wait with RECEIPT_TIMEOUT (seconds).
publish_user_tx() {
    local rpc="$1"
    local tx_hash receipt block_number status
    tx_hash=$(_send_raw_tx "$rpc" "$RLP_ENCODED_TX") || return 1
    receipt=$(_poll_receipt "$rpc" "$tx_hash" $(( $(date +%s) + ${RECEIPT_TIMEOUT:-300} ))) || return 1

    block_number=$(echo "$receipt" | jq -r '.blockNumber // empty')
    status=$(echo "$receipt" | jq -r '.status // empty')
    if [[ -z "$block_number" ]]; then
        echo "ERROR: could not get block number from receipt (tx: $tx_hash)"
        return 1
    fi

    echo "tx: $tx_hash"
    echo "block: $block_number (status: $status)"
    TX_HASH="$tx_hash"
    TX_BLOCK_NUMBER=$(printf "%d" "$block_number")
}

# ── Fire every tx in RLP_ENCODED_TXS WITHOUT waiting for receipts ──
# Back-to-back sends so all are in flight before any is mined — the point of the
# multi-tx scenarios: the composer sees several held triggers at once. Prints each
# accepted hash immediately; sets TX_HASHES (send order). Pair with wait_user_txs.
publish_user_txs_nowait() {
    local rpc="$1"
    TX_HASHES=()
    local raw tx_hash
    for raw in "${RLP_ENCODED_TXS[@]}"; do
        tx_hash=$(_send_raw_tx "$rpc" "$raw") || {
            echo "ERROR: send failed at tx $(( ${#TX_HASHES[@]} + 1 ))/${#RLP_ENCODED_TXS[@]}"
            return 1
        }
        TX_HASHES+=("$tx_hash")
        echo "fired tx[${#TX_HASHES[@]}]: $tx_hash"
    done
}

# ── Wait for the receipts of every fired tx (after publish_user_txs_nowait) ──
# One shared RECEIPT_TIMEOUT deadline; prints each tx's mined block. Sets
# TX_BLOCK_NUMBERS (aligned with TX_HASHES), TX_HASH (first tx) and
# TX_BLOCK_NUMBER (lowest mined block — the earliest block entries can settle in).
wait_user_txs() {
    local rpc="$1"
    TX_BLOCK_NUMBERS=()
    local deadline=$(( $(date +%s) + ${RECEIPT_TIMEOUT:-300} ))
    local i receipt block_number status
    for i in "${!TX_HASHES[@]}"; do
        receipt=$(_poll_receipt "$rpc" "${TX_HASHES[$i]}" "$deadline") || return 1
        block_number=$(printf "%d" "$(echo "$receipt" | jq -r '.blockNumber')")
        status=$(echo "$receipt" | jq -r '.status // empty')
        TX_BLOCK_NUMBERS+=("$block_number")
        echo "tx[$(( i + 1 ))]: ${TX_HASHES[$i]}  mined in block $block_number (status: $status)"
    done

    TX_HASH="${TX_HASHES[0]}"
    TX_BLOCK_NUMBER="${TX_BLOCK_NUMBERS[0]}"
    for block_number in "${TX_BLOCK_NUMBERS[@]}"; do
        if [[ "$block_number" -lt "$TX_BLOCK_NUMBER" ]]; then
            TX_BLOCK_NUMBER="$block_number"
        fi
    done
}

# ── Print every tx hash + mined block from the latest broadcast JSON ──
# Local-mode visibility: forge's broadcast receipts already hold hash + block for
# each tx the Execute contract sent; surface them so runs are auditable later.
print_broadcast_txs() {
    local sol="$1" rpc="$2" label="$3"
    local json hash blk
    json=$(_broadcast_json "$sol" "$rpc") || return 0
    [[ -f "$json" ]] || return 0
    while read -r hash blk; do
        printf "  %s tx %s  (block %d)\n" "$label" "$hash" "$blk"
    done < <(jq -r '.receipts[] | "\(.transactionHash) \(.blockNumber)"' "$json")
}

# ── Ensure CREATE2 factory exists on a chain ──
ensure_create2_factory() {
    local rpc="$1"
    local label="$2"
    local pk="$3"
    local CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"
    local code
    code=$(cast code "$CREATE2_FACTORY" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    if [[ "$code" != "0x" && ${#code} -gt 2 ]]; then
        echo "$label: CREATE2 factory already deployed"
        return
    fi
    echo "$label: Deploying CREATE2 factory..."
    # Run twice on purpose (see DeployBridge.s.sol): the first run funds the
    # keyless factory signer, the second publishes the pre-signed deployment tx
    # (forge can't fund + send a pre-signed raw tx atomically).
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
}
