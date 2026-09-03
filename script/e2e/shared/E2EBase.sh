#!/usr/bin/env bash
# Shared utilities for e2e test scripts.
# Source from test runners: source "$(dirname "$0")/../shared/E2EBase.sh"

set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# Default values
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# ── PIDs to clean up on exit ──
_E2E_PIDS=()
_E2E_AUTOMINE_RPCS=()

cleanup() {
    for pid in "${_E2E_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for rpc in "${_E2E_AUTOMINE_RPCS[@]}"; do
        cast rpc evm_setAutomine true --rpc-url "$rpc" > /dev/null 2>&1 || true
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
    contracts=$(grep -oE '^contract Deploy[A-Za-z0-9_]* ' "$sol" | awk '{print $2}')
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
        # Staged prepare: persist the outputs — the deferred verify stage runs in
        # a fresh process and reloads them from this file.
        if [[ -n "${E2E_JOB_DIR:-}" ]]; then
            _export_outputs "$out" --echo >> "$E2E_JOB_DIR/deploy-env.env"
        fi
    done <<< "$contracts"
}

# ── Pre-sign one Deploy* contract's txs from a DRY RUN (staged wave prepare) ──
# Runs the INDEX-th (1-based) Deploy* contract of SOL WITHOUT --broadcast. The
# simulation prints the same address outputs a real run would — CREATE addresses
# depend only on wallet+nonce, which stays truthful because the orchestrator
# mines each wave before the next one is dry-run — and forge writes the planned
# txs to <out_dir>/broadcast/<sol>/<chainid>/dry-run/run-latest.json (private
# per job via FOUNDRY_BROADCAST, so parallel jobs of the same scenario don't
# clobber each other). Each planned tx is re-signed with cast mktx and appended
# to OUT_DIR/deploytxs-wave<INDEX>.txt as "<L1|L2> <rawtx>"; exported env
# outputs accumulate in OUT_DIR/deploy-env.env for later waves and the finish
# step. Returns 2 when SOL has fewer than INDEX Deploy contracts (job done).
presign_deploy_contract() {
    local sol="$1" index="$2" l1_rpc="$3" l2_rpc="$4" pk="$5" out_dir="$6"
    local contract
    contract=$(grep -oE '^contract Deploy[A-Za-z0-9_]* ' "$sol" | awk '{print $2}' | sed -n "${index}p")
    [[ -n "$contract" ]] || return 2

    local rpc label
    if [[ "$contract" == *L2* ]]; then rpc="$l2_rpc"; label="L2"; else rpc="$l1_rpc"; label="L1"; fi

    # Earlier waves' outputs feed this wave's vm.env* reads.
    if [[ -f "$out_dir/deploy-env.env" ]]; then
        set -a
        # shellcheck disable=SC1091
        source "$out_dir/deploy-env.env"
        set +a
    fi

    # Forge only rewrites run-latest.json when the script plans txs; clear the
    # previous wave's file so a zero-tx contract reads as "nothing to sign"
    # instead of re-signing already-mined txs.
    local out rc=0 dry_json sender
    dry_json="$out_dir/broadcast/$(basename "$sol")/$(cast chain-id --rpc-url "$rpc")/dry-run/run-latest.json"
    rm -f "$dry_json"
    out=$(FOUNDRY_BROADCAST="$out_dir/broadcast" forge script "$sol:$contract" \
        --rpc-url "$rpc" --private-key "$pk" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "DRY RUN FAILED: $contract ($label) — forge output tail:"
        echo "$out" | tail -25
        return 1
    fi
    local vars
    vars=$(echo "$out" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true)
    if [[ -n "$vars" ]]; then
        echo "$vars"
        echo "$vars" >> "$out_dir/deploy-env.env"
        while IFS= read -r line; do export "$line"; done <<< "$vars"
    fi

    [[ -f "$dry_json" ]] || { echo "$contract ($label): no planned txs"; return 0; }

    # The dry-run nonces are correct as-is: earlier waves are mined before this
    # one is simulated, and the wallet is dedicated.
    local n
    n=$(_resign_planned_txs "$dry_json" "$rpc" "$pk" "$label" "$out_dir/deploytxs-wave$index.txt") || return 1
    echo "presigned $n tx(s) for $contract ($label) → deploytxs-wave$index.txt"
}

# ── Re-sign the txs of a forge run JSON with cast mktx ──
# Usage: _resign_planned_txs RUN_JSON RPC PK LABEL OUT_FILE  → tx count on stdout
# RUN_JSON is a forge run JSON (a dry-run's run-latest.json or one chain's slice
# of a multi-chain plan); every tx sent from PK's address is re-signed with its
# recorded nonce, value, input and gas (+25%) and appended to OUT_FILE as
# "<LABEL> <rawtx>". The addresses those txs create (CREATE/CREATE2 entries and
# any additionalContracts, e.g. the proxy a createCrossChainProxy call deploys)
# are appended to deploy-addrs.txt next to OUT_FILE as "<LABEL> <address>" for
# the orchestrator's per-chain liveness check.
_resign_planned_txs() {
    local json="$1" rpc="$2" pk="$3" label="$4" out_file="$5"
    local sender n i to nonce value gas input raw
    sender=$(cast wallet address --private-key "$pk" | tr '[:upper:]' '[:lower:]')
    n=$(jq -r --arg s "$sender" \
        '[.transactions[] | select(((.transaction.from // "") | ascii_downcase) == $s)] | length' "$json")
    (( n > 0 )) || { echo "No planned txs for $sender in $json" >&2; return 1; }
    jq -r --arg s "$sender" '.transactions[] | select(((.transaction.from // "") | ascii_downcase) == $s)
        | (select(.transactionType == "CREATE" or .transactionType == "CREATE2") | .contractAddress),
          (.additionalContracts[]? | .address)
        | select(. != null)' "$json" | sed "s/^/$label /" >> "$(dirname "$out_file")/deploy-addrs.txt"
    for ((i = 0; i < n; i++)); do
        IFS=$'\t' read -r to nonce value gas input < <(jq -r --arg s "$sender" --argjson i "$i" \
            '[.transactions[] | select(((.transaction.from // "") | ascii_downcase) == $s)][$i].transaction
             | "\(.to)\t\(.nonce)\t\(.value)\t\(.gas)\t\(.input)"' "$json") || true
        [[ -n "${input:-}" && "$input" != "null" ]] || { echo "Bad planned tx $i in $json" >&2; return 1; }
        gas=$(( $(printf "%d" "$gas") * 5 / 4 ))   # +25% over forge's estimate
        # Explicit rc checks: callers invoke this inside a condition, which
        # suspends set -e for the whole body — an unguarded mktx failure would
        # silently produce an empty raw tx. For --create the flags must PRECEDE
        # it: cast parses everything after <CODE> as [SIG] [ARGS].
        raw=""
        if [[ "$to" == "null" || -z "$to" ]]; then
            raw=$(cast mktx --value "$(printf "%d" "$value")wei" --nonce "$(printf "%d" "$nonce")" \
                --gas-limit "$gas" --private-key "$pk" --rpc-url "$rpc" \
                --create "$input") || raw=""
        else
            raw=$(cast mktx "$to" "$input" \
                --value "$(printf "%d" "$value")wei" --nonce "$(printf "%d" "$nonce")" \
                --gas-limit "$gas" --private-key "$pk" --rpc-url "$rpc") || raw=""
        fi
        [[ -n "$raw" ]] || { echo "cast mktx FAILED for planned tx $i ($label) in $json" >&2; return 1; }
        echo "$label $raw" >> "$out_file"
    done
    echo "$n"
}

# ── Planned-nonce check: INITIAL, then every planned nonce must be INITIAL, INITIAL+1, ... ──
# Usage: _check_contiguous_nonces INITIAL [NONCE ...] → 0 when contiguous (an empty list is)
# The trigger nonce is derived as INITIAL + count, which is only right when the
# wallet's planned deploy txs fill the nonces in between with no gap or repeat.
_check_contiguous_nonces() {
    local initial="$1" i=0 n
    shift
    for n in "$@"; do
        n=$(printf '%d' "$n" 2>/dev/null) || return 1
        (( n == initial + i )) || return 1
        i=$((i + 1))
    done
    return 0
}

# ── Plan every Deploy* contract of SOL in ONE forge run and pre-sign the txs (staged plan prepare) ──
# Usage: plan_job_deploys SOL L1_RPC L2_RPC PK OUT_DIR
# Env in: E2E_L1_NONCE E2E_L2_NONCE E2E_L1_BLOCK E2E_L2_BLOCK (network-staged.sh).
# PrepareJob.s.sol runs the contracts in file order against in-process forks of
# both chains with the wallet nonces injected, so the dry run plans exactly the
# txs the real chain will accept without anything being mined. Forge writes one
# multi-chain dry-run JSON (private per job via FOUNDRY_BROADCAST); each chain's
# txs are re-signed in nonce order into OUT_DIR/deploytxs.txt as "<L1|L2> <rawtx>"
# and the NAME=value outputs go to OUT_DIR/deploy-env.env. The same process also
# describes and signs the trigger, computes expectations, and writes a v2 manifest.
plan_job_deploys() {
    local sol="$1" l1_rpc="$2" l2_rpc="$3" pk="$4" out_dir="$5"
    local contracts l1_chain l2_chain trigger_contract has_compute sender
    contracts=$(grep -oE '^contract Deploy[A-Za-z0-9_]* ' "$sol" | awk '{print $2}' | paste -sd,)
    [[ -n "$contracts" ]] || { echo "No Deploy* contracts found"; return 1; }
    if grep -qE '^contract ExecuteNetworkL2\b' "$sol"; then trigger_contract=ExecuteNetworkL2; else trigger_contract=ExecuteNetwork; fi
    if grep -qE '^contract ComputeExpected\b' "$sol"; then
        has_compute=true
    else
        has_compute=false
        grep -qE '^contract VerifyNetwork(L2)?\b' "$sol" \
            || { echo "scenario has neither ComputeExpected nor VerifyNetwork*"; return 1; }
    fi
    sender=$(cast wallet address --private-key "$pk") || return 1
    l1_chain=$(cast chain-id --rpc-url "$l1_rpc") && l2_chain=$(cast chain-id --rpc-url "$l2_rpc") \
        || { echo "RPCs unreachable ($l1_rpc / $l2_rpc)"; return 1; }
    # The forge run is a dry run (nothing is sent), so a failure that is only the
    # RPC dropping the connection is retried (PLAN_RETRIES attempts, default 2).
    local out rc attempt
    for ((attempt = 1; attempt <= ${PLAN_RETRIES:-2}; attempt++)); do
        rm -rf "$out_dir/broadcast"
        rc=0
        out=$(E2E_SCENARIO_FILE="$(basename "$sol")" E2E_DEPLOY_CONTRACTS="$contracts" \
            E2E_TRIGGER_CONTRACT="$trigger_contract" E2E_HAS_COMPUTE="$has_compute" \
            E2E_WALLET="$sender" L1_RPC="$l1_rpc" L2_RPC="$l2_rpc" \
            FOUNDRY_BROADCAST="$out_dir/broadcast" \
            forge script script/e2e/shared/PrepareJob.s.sol:PrepareJob --private-key "$pk" 2>&1) || rc=$?
        [[ $rc -ne 0 ]] || break
        if grep -qiE 'error sending request|connection (reset|error|refused)|timed out|SendRequest' <<< "$out" \
            && (( attempt < ${PLAN_RETRIES:-2} )); then
            echo "plan attempt $attempt: RPC transport error - retrying"
            sleep 2
            continue
        fi
        echo "PLAN FAILED — forge output tail:"
        echo "$out" | tail -25
        return 1
    done
    local vars
    vars=$(echo "$out" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true)
    [[ -n "$vars" ]] && { echo "$vars"; echo "$vars" >> "$out_dir/deploy-env.env"; }

    local json="$out_dir/broadcast/multi/dry-run/PrepareJob.s.sol-latest/run.json"
    [[ -f "$json" ]] || { echo "planned-tx JSON missing: $json"; find "$out_dir/broadcast" -name '*.json' 2>/dev/null; return 1; }
    : > "$out_dir/deploytxs.txt"
    local label chain rpc n initial_nonce planned_n trigger_nonce="" i
    for label in L1 L2; do
        if [[ "$label" == "L1" ]]; then chain="$l1_chain"; rpc="$l1_rpc"; else chain="$l2_chain"; rpc="$l2_rpc"; fi
        jq --arg c "$chain" '{transactions: [.deployments[] | select((.chain | tostring) == $c) | .transactions[]]}' \
            "$json" > "$out_dir/plan-$label.json"
        [[ "$(jq '.transactions | length' "$out_dir/plan-$label.json")" -gt 0 ]] || { echo "no $label txs planned"; continue; }
        [[ "$label" == "L1" ]] && initial_nonce="$E2E_L1_NONCE" || initial_nonce="$E2E_L2_NONCE"
        local planned_nonces=()
        mapfile -t planned_nonces < <(jq -r --arg s "${sender,,}" \
            '.transactions[] | select(((.transaction.from // "") | ascii_downcase) == $s) | .transaction.nonce' \
            "$out_dir/plan-$label.json")
        planned_n=${#planned_nonces[@]}
        _check_contiguous_nonces "$initial_nonce" "${planned_nonces[@]}" \
            || { echo "non-contiguous planned $label nonces (${planned_nonces[*]} from $initial_nonce)"; return 1; }
        [[ "$trigger_contract" == *L2 && "$label" == L2 || "$trigger_contract" != *L2 && "$label" == L1 ]] \
            && trigger_nonce=$((initial_nonce + planned_n))
        n=$(_resign_planned_txs "$out_dir/plan-$label.json" "$rpc" "$pk" "$label" "$out_dir/deploytxs.txt") || return 1
        echo "presigned $n $label tx(s) → deploytxs.txt"
    done

    local target value calldata gas
    target=$(extract "$out" TARGET); value=$(extract "$out" VALUE); calldata=$(extract "$out" CALLDATA)
    _TX_COUNT=$(extract "$out" NUM_TXS); _TX_COUNT="${_TX_COUNT:-1}"
    gas=$(extract "$out" GAS); _TRIGGER_GAS="${gas:-${E2E_TRIGGER_GAS:-1000000}}"
    [[ "$target" =~ ^0x[0-9a-fA-F]{40}$ && "$target" != 0x0000000000000000000000000000000000000000 ]] \
        || { echo "invalid trigger TARGET: $target"; return 1; }
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "invalid trigger VALUE: $value"; return 1; }
    [[ "$calldata" =~ ^0x([0-9a-fA-F]{2})*$ ]] || { echo "invalid trigger CALLDATA"; return 1; }
    [[ "$_TX_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "invalid trigger NUM_TXS: $_TX_COUNT"; return 1; }
    [[ "$_TRIGGER_GAS" =~ ^[1-9][0-9]*$ ]] || { echo "invalid trigger GAS: $_TRIGGER_GAS"; return 1; }
    [[ -n "$trigger_nonce" ]] || { echo "could not determine trigger nonce"; return 1; }

    _TRIGGER_CHAIN=$([[ "$trigger_contract" == *L2 ]] && echo L2 || echo L1)
    _HAS_COMPUTE="$has_compute"; _SENDER="$sender"
    local trigger_rpc="$l1_rpc"; [[ "$_TRIGGER_CHAIN" == L2 ]] && trigger_rpc="$l2_rpc"
    : > "$out_dir/rawtxs.txt"
    local raw
    for ((i=0; i<_TX_COUNT; i++)); do
        raw=$(cast mktx "$target" "$calldata" --value "${value}wei" --gas-limit "$_TRIGGER_GAS" \
            --nonce "$((trigger_nonce + i))" --private-key "$pk" --rpc-url "$trigger_rpc") || return 1
        printf '%s\n' "$raw" >> "$out_dir/rawtxs.txt"
    done
    printf '%s\n' "$out" > "$out_dir/compute.out"
    if $has_compute; then
        extract_expected_outputs "$out"
    else
        EXPECTED_L1_CALL_HASHES="[]"; EXPECTED_L1_HASHES="[]"; EXPECTED_L2_CALL_HASHES="[]"; EXPECTED_L2_HASHES="[]"
        EXPECTED_L1_TABLE="0x"; EXPECTED_L1_STEPS="0x"; EXPECTED_L1_STATIC_TABLE="0x"; EXPECTED_L2_TABLE="0x"
        EVENTLESS_L2_HASHES="[]"; ABSENT_L2_HASHES="[]"
    fi
    E2E_MANIFEST_VERSION=2
    declare -p E2E_MANIFEST_VERSION _TRIGGER_CHAIN _TX_COUNT _HAS_COMPUTE _SENDER \
        EXPECTED_L1_CALL_HASHES EXPECTED_L1_HASHES EXPECTED_L2_CALL_HASHES EXPECTED_L2_HASHES \
        EXPECTED_L1_TABLE EXPECTED_L1_STEPS EXPECTED_L1_STATIC_TABLE EXPECTED_L2_TABLE \
        EVENTLESS_L2_HASHES ABSENT_L2_HASHES > "$out_dir/manifest.env"
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

# Usage: verify_l1_calldata RPC BLOCK ROLLUPS EXPECTED_TABLE EXPECTED_STEPS EXPECTED_STATIC_TABLE
# Content-addressed L1 check for entries that leave no usable event: a
# success=false entry unwinds its events with its revert and a top-level static
# entry never emits one. Lists the settlement txs of BLOCK
# (VerifyL1SettlementTxsInRange) and decodes each one's postAndVerifyBatch
# calldata (VerifyL1BatchCalldata, pinned at BLOCK) until one holds the expected
# entries and static entries. Fills VERIFY_OUT; rc 1 when none matched.
verify_l1_calldata() {
    local rpc="$1" block="$2" rollups="$3" table="${4:-0x}" steps="${5:-0x}" static_table="${6:-0x}"
    local list tx input last="" rc
    _run_verifier VerifyL1SettlementTxsInRange "$rpc" "run(uint256,uint256,address)" "$block" "$block" "$rollups" || return 1
    list=$(echo "$VERIFY_OUT" | grep -oE 'L1_BATCH_TX_CANDIDATE=0x[0-9a-fA-F]{64}' | cut -d= -f2 | sort -u)
    for tx in $list; do
        input=$(cast tx "$tx" input --rpc-url "$rpc" 2>/dev/null) || continue
        rc=0
        VERIFY_OUT=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1BatchCalldata --rpc-url "$rpc" \
            --fork-block-number "$block" --sig "run(bytes,address,bytes,bytes,bytes,bool)" \
            "$input" "$rollups" "$table" "$steps" "$static_table" false 2>&1) || rc=$?
        if [[ $rc -eq 0 ]]; then
            VERIFY_OUT="NOTE: matched settlement tx $tx"$'\n'"$VERIFY_OUT"
            return 0
        fi
        last="$VERIFY_OUT"
    done
    VERIFY_OUT="${last:-no settlement tx with decodable calldata in block $block}"
    return 1
}

# Usage: verify_l2_table RPC BLOCKS_ARRAY MANAGER_L2 EXPECTED_ENTRY_HASHES [EXPECTED_TABLE] [EVENTLESS_ENTRY_HASHES]
verify_l2_table() { _run_verifier VerifyL2Blocks "$1" "run(uint256[],address,bytes32[],bytes,bytes32[])" "$2" "$3" "$4" "${5:-0x}" "${6:-[]}"; }

# Usage: verify_l2_calls RPC BLOCKS_ARRAY MANAGER_L2 EXPECTED_CALL_HASHES [EXPECTED_TABLE]
verify_l2_calls() { _run_verifier VerifyL2Calls "$1" "run(uint256[],address,bytes32[],bytes)" "$2" "$3" "$4" "${5:-0x}"; }

# Usage: verify_l2_absent RPC FROM_BLOCK TO_BLOCK MANAGER_L2 ABSENT_KEYS
# Active proof that a lookup was never delivered: none of the call keys may appear
# in the L2 manager's logs over the range (delivery / consumption events, loaded
# entries or static entries).
verify_l2_absent() { _run_verifier VerifyL2Absent "$1" "run(uint256,uint256,address,bytes32[])" "$2" "$3" "$4" "$5"; }

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

# ── L1/L2 settlement correlation RPC (eez_getSettlementByL2Block & co.) ──
# Composer/follower L2 nodes can expose the canonical mapping between L2 blocks
# and the L1 postAndVerifyBatch tx that settled them. When present, one lookup
# replaces the L1 range scans (and bounds the L2 scans); when absent (older
# nodes, other networks) the verifiers keep scanning. E2E_CORRELATION=off forces
# the scan path. Both methods answer with the same settlement object:
#   { l1BlockNumber, l1BlockHash, l1TransactionHash, l1TransactionIndex,
#     l2Range: { firstBlockNumber, lastBlockNumber, blockCount, first/lastBlockHash },
#     l2Blocks: [{ number, hash }], matchedL2Block, canonicalL2, l2Finalized }
# (one object for a settled L2 block, an array of them for an L1 block); an
# unrecognised answer is reported on stderr and the caller falls back to scanning.
_eez_rpc() {  # $1=rpc $2=method $3=params-json → response body (rc 1 on transport error)
    curl -s --max-time 15 -X POST "$1" -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}"
}
_eez_settlement_line() {  # $1=settlement object → "l1Block firstL2 lastL2 l1TxHash" (decimal), rc 1 if malformed
    local blk f t tx canon
    read -r blk f t tx canon < <(jq -r '[.l1BlockNumber, .l2Range.firstBlockNumber, .l2Range.lastBlockNumber,
        .l1TransactionHash, .canonicalL2] | map(. // "-") | join(" ")' <<< "$1" 2>/dev/null) || true
    [[ "${blk:-}" == 0x* && "${f:-}" == 0x* && "${t:-}" == 0x* && "${tx:-}" == 0x* ]] || {
        echo "eez settlement: unrecognised shape: $1" >&2; return 1; }
    [[ "$canon" == "true" ]] || { echo "eez settlement: non-canonical L2 blocks reported: $1" >&2; return 1; }
    echo "$(printf '%d' "$blk") $(printf '%d' "$f") $(printf '%d' "$t") $tx"
}
eez_correlation_detect() {  # $1=L2 rpc; sets EEZ_CORR_RPC ("" = unavailable)
    EEZ_CORR_RPC=""
    if [[ "${E2E_CORRELATION:-auto}" == "off" ]]; then
        echo "settlement correlation RPC: off (E2E_CORRELATION=off)"; return 0
    fi
    local out
    out=$(_eez_rpc "$1" eez_getSettlementByL2Block '["0x1"]') || out=""
    # a "result" key (even null) means the method exists; -32601 / no answer means it does not
    if jq -e 'has("result")' <<< "$out" >/dev/null 2>&1; then
        EEZ_CORR_RPC="$1"
        echo "settlement correlation RPC: available on $1"
    else
        echo "settlement correlation RPC: not available on $1 - using range scans"
    fi
}
# eez_settlement_by_l2_block RPC L2_BLOCK → "l1Block firstL2 lastL2 l1TxHash" (decimal) on stdout.
# rc 2 = not settled yet (null result); rc 1 = transport error or unrecognised shape.
eez_settlement_by_l2_block() {
    local out res
    out=$(_eez_rpc "$1" eez_getSettlementByL2Block "[\"$(printf '0x%x' "$2")\"]") || return 1
    res=$(jq -c '.result' <<< "$out" 2>/dev/null) || return 1
    [[ -n "$res" && "$res" != "null" ]] || return 2
    _eez_settlement_line "$res"
}
# eez_l2_ranges_by_l1_block RPC L1_BLOCK → one "l1Block firstL2 lastL2 l1TxHash" line per accepted batch.
# rc 2 = no accepted batch in that block ([]); rc 1 = transport error or unrecognised shape.
eez_l2_ranges_by_l1_block() {
    local out item
    out=$(_eez_rpc "$1" eez_getSettledL2RangesByL1Block "[\"$(printf '0x%x' "$2")\"]") || return 1
    jq -e '.result | type == "array"' <<< "$out" >/dev/null 2>&1 || {
        echo "eez_getSettledL2RangesByL1Block: unrecognised response: $out" >&2; return 1; }
    jq -e '.result | length > 0' <<< "$out" >/dev/null || return 2
    while IFS= read -r item; do
        _eez_settlement_line "$item" || return 1
    done < <(jq -c '.result[]' <<< "$out")
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
    local tmpfile discovery_file sender dry_json expected_txs
    tmpfile=$(mktemp)
    discovery_file=$(mktemp)
    sender=$(cast wallet address --private-key "$pk" | tr '[:upper:]' '[:lower:]')

    # Discover the exact bundle size from a DRY RUN (no --broadcast): the whole
    # bundle simulates at one fork height, so the managers' same-block gates hold
    # — a real rehearsal under automine would split the bundle across blocks and
    # revert at those gates. The dry run writes the planned tx list to
    # broadcast/<sol>/<chainid>/dry-run/run-latest.json; its length removes all
    # timing guesses from the real mine.
    if ! forge script "$sol:$contract" --rpc-url "$rpc" --isolate --private-key "$pk" \
        > "$discovery_file" 2>&1; then
        cat "$discovery_file"
        rm -f "$tmpfile" "$discovery_file"
        return 1
    fi
    rm -f "$discovery_file"
    dry_json="broadcast/$(basename "$sol")/$(cast chain-id --rpc-url "$rpc")/dry-run/run-latest.json"
    # Sender-filtered on purpose: the pending-pool poll below counts only THIS
    # broadcaster's txs, so the expected count must use the same scope.
    expected_txs=$(jq -r --arg sender "$sender" \
        '[.transactions[] | select(((.transaction.from // "") | ascii_downcase) == $sender)] | length' \
        "$dry_json" 2>/dev/null || echo 0)
    if ((expected_txs <= 0)); then
        echo "ERROR: could not discover a non-empty broadcast bundle ($dry_json)" >&2
        rm -f "$tmpfile"
        return 1
    fi

    if ! cast rpc evm_setAutomine false --rpc-url "$rpc" > /dev/null 2>&1; then
        rm -f "$tmpfile"
        return 1
    fi
    _E2E_AUTOMINE_RPCS+=("$rpc")

    # --isolate: simulate each broadcast call as its OWN transaction (fresh
    # transient storage), matching on-chain execution — without it, scenarios
    # that make multiple system deliveries in one script (multi-call) fail the
    # pre-broadcast simulation with a false RollingHashMismatch.
    forge script "$sol:$contract" --rpc-url "$rpc" --broadcast --isolate --private-key "$pk" > "$tmpfile" 2>&1 &
    local forge_pid=$!
    _E2E_PIDS+=("$forge_pid")

    # Count only executable pending transactions from THIS broadcaster. Queued
    # transactions and sibling jobs must neither trigger nor suppress our mine.
    local deadline=$((SECONDS + 60))
    local pending=0 content tx_hashes=""
    while ((SECONDS < deadline)); do
        content=$(cast rpc txpool_content --rpc-url "$rpc" 2>/dev/null || true)
        pending=$(jq -r --arg sender "$sender" '
            [.pending // {} | to_entries[] | select((.key | ascii_downcase) == $sender) | .value | keys[]] | length
        ' <<< "$content" 2>/dev/null || echo 0)

        if ((pending == expected_txs)); then
            tx_hashes=$(jq -r --arg sender "$sender" '
                .pending // {} | to_entries[] | select((.key | ascii_downcase) == $sender) | .value[] | .hash
            ' <<< "$content" 2>/dev/null)
            [[ $(wc -w <<< "$tx_hashes") -eq $expected_txs ]] && break
        elif ((pending > expected_txs)); then
            break
        fi

        kill -0 "$forge_pid" 2>/dev/null || break
        sleep 0.25
    done

    if ((pending != expected_txs)) || [[ $(wc -w <<< "$tx_hashes") -ne $expected_txs ]]; then
        echo "ERROR: broadcaster queued $pending executable tx(s), expected exactly $expected_txs" >> "$tmpfile"
        kill "$forge_pid" 2>/dev/null || true
        wait "$forge_pid" 2>/dev/null || true
        cast rpc evm_setAutomine true --rpc-url "$rpc" > /dev/null 2>&1 || true
        cat "$tmpfile"
        rm -f "$tmpfile"
        return 1
    fi

    if ! cast rpc evm_mine --rpc-url "$rpc" > /dev/null 2>&1; then
        cast rpc evm_setAutomine true --rpc-url "$rpc" > /dev/null 2>&1 || true
        kill "$forge_pid" 2>/dev/null || true
        wait "$forge_pid" 2>/dev/null || true
        cat "$tmpfile"
        rm -f "$tmpfile"
        return 1
    fi
    # Cleanup precedes wait: if the pending-set inference was ever wrong, forge
    # can still submit and finish instead of deadlocking behind disabled automine.
    cast rpc evm_setAutomine true --rpc-url "$rpc" > /dev/null 2>&1

    local wait_deadline=$((SECONDS + 60))
    while kill -0 "$forge_pid" 2>/dev/null && ((SECONDS < wait_deadline)); do sleep 0.25; done
    if kill -0 "$forge_pid" 2>/dev/null; then
        echo "ERROR: forge broadcaster did not finish after mining" >> "$tmpfile"
        kill "$forge_pid" 2>/dev/null || true
    fi
    wait "$forge_pid" 2>/dev/null
    local exit_code=$?

    local tx receipt_block mined_block=""
    for tx in $tx_hashes; do
        receipt_block=$(cast receipt "$tx" blockNumber --rpc-url "$rpc" 2>/dev/null || true)
        [[ -n "$receipt_block" && -z "$mined_block" ]] && mined_block="$receipt_block"
        if [[ -z "$receipt_block" || "$receipt_block" != "$mined_block" ]]; then
            echo "ERROR: intended tx $tx was not included in the common block ${mined_block:-<missing>}" >> "$tmpfile"
            exit_code=1
        fi
    done

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
# the contract read-only for TARGET/VALUE/CALLDATA/NUM_TXS/GAS, and pre-signs
# NUM_TXS txs with consecutive nonces via cast mktx (queries chain for gas
# price, does NOT broadcast). Sets _TRIGGER_CHAIN, _TRIGGER_CONTRACT,
# _TRIGGER_RPC, _TX_COUNT, _TRIGGER_GAS, RLP_ENCODED_TXS; exports
# RLP_ENCODED_TX (the first tx — ComputeExpected reads it from env for action
# hashing).
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
    # Gas limit. A trigger cannot be estimated: its entry exists only once the
    # composer's batch lands in the same block, so the limit is fixed. The node
    # reserves gasLimit × gasPrice of wallet balance per trigger even at value
    # 0, so it stays tight — measured usage: flash-loan 503k, deepNested 181k,
    # counter 133k. A scenario needing more prints GAS=<limit> from
    # ExecuteNetwork*; E2E_TRIGGER_GAS overrides the default for a run.
    _TRIGGER_GAS=$(extract "$exec_out" "GAS")
    _TRIGGER_GAS="${_TRIGGER_GAS:-${E2E_TRIGGER_GAS:-1000000}}"

    local sender nonce_rpc nonce_front tx_nonce
    sender=$(cast wallet address --private-key "$PK")
    nonce_rpc=$(cast nonce "$sender" --rpc-url "$_TRIGGER_RPC" 2>/dev/null || echo 0)
    if [[ "$nonce_mode" == "local" ]]; then
        tx_nonce=$((nonce_rpc + 1))
    else
        echo "target: $target"
        echo "calldata: $calldata"
        echo "value: $value"
        echo "gas limit: $_TRIGGER_GAS"
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
            --gas-limit "$_TRIGGER_GAS" \
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
# EXPECTED_L1_STATIC_TABLE (top-level static entries the L1 batch must carry,
# matched from the posted calldata; "0x" = none),
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
    EXPECTED_L1_STATIC_TABLE=$(extract "$out" "EXPECTED_L1_STATIC_TABLE")
    EXPECTED_L1_STATIC_TABLE="${EXPECTED_L1_STATIC_TABLE:-0x}"
    if [[ "$EXPECTED_L1_STATIC_TABLE" != "0x" ]]; then
        echo "L1 expected static table: $((${#EXPECTED_L1_STATIC_TABLE} / 2 - 1)) bytes (posted static entries matched from calldata)"
    fi
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
        echo "L2 absent keys (must leave NO trace on L2 - lookup): $ABSENT_L2_HASHES"
    fi

    # Print summary (lines between === EXPECTED SUMMARY === and the next blank line)
    local summary
    summary=$(echo "$out" | sed -n '/=== EXPECTED SUMMARY ===/,/^$/p' | head -20)
    if [[ -n "$summary" ]]; then
        echo ""
        echo "$summary"
    fi
}

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
