#!/usr/bin/env bash
# Fund the source wallet on L2. E2E scenarios deploy their own contracts.
# Usage: bash script/e2e/run/network/setup.sh [L2-target-ETH] [env-file] (default: 0.1, chain.env)
# Override the environment file with DEVNET_ENV=other.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../../.."
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bash script/e2e/run/network/setup.sh [L2-target-ETH] [env-file] (default: 0.1, chain.env)"
    echo "Uses DEVNET_ENV (default chain.env); bridges only the missing balance."
    exit 0
fi
[[ $# -le 2 ]] || { echo "Expected an ETH amount and optional env file" >&2; exit 1; }
for tool in cast timeout jq bc flock; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
ENV_FILE="${2:-${DEVNET_ENV:-chain.env}}"
source "$SCRIPT_DIR/../../lib/network-config.sh"
source "$SCRIPT_DIR/../../lib/network-fees.sh"
load_network_config "${2:-${DEVNET_ENV:-}}" || exit 1
SETUP_PK="${SOURCE_PK:-${PK:-}}"
for name in L1_RPC L1_FRONT L2_RPC ROLLUPS SETUP_PK; do
    [[ -n "${!name:-}" ]] || { echo "Missing $name in $ENV_FILE" >&2; exit 1; }
done
log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
LAST_TX=""
trap 'log "Interrupted. Last transaction: ${LAST_TX:-none}. Check its status before rerunning." >&2; exit 130' INT TERM
RPC_TIMEOUT="${SETUP_RPC_TIMEOUT:-30}"
TX_TIMEOUT="${SETUP_TX_TIMEOUT:-300}"
BRIDGE_TIMEOUT="${SETUP_BRIDGE_TIMEOUT:-300}"
for setting in RPC_TIMEOUT TX_TIMEOUT BRIDGE_TIMEOUT; do
    [[ "${!setting}" =~ ^[1-9][0-9]*$ ]] || fail "$setting must be a positive number of seconds"
done
rpc_cast() { timeout "$RPC_TIMEOUT" cast "$@"; }
read_l2_balance() {
    local balance
    balance=$(rpc_cast balance "$ADDR" --rpc-url "$L2_RPC") || return 1
    [[ "$balance" =~ ^[0-9]+$ ]] || { echo "Invalid L2 balance: $balance" >&2; return 1; }
    printf '%s\n' "$balance"
}
send_and_check() {
    local label="$1" receipt_rpc="$2"; shift 2
    local hash
    log "$label: submitting transaction..."
    if ! hash=$(rpc_cast send "$@" --async); then
        fail "$label: submission failed or timed out. Check the wallet nonce before retrying; submission may have reached the RPC."
    fi
    wait_receipt "$label" "$receipt_rpc" "$hash"
}
# The bridge is a cross-chain trigger: it needs an eez_quoteFee quote for its exact intent.
publish_raw() { rpc_cast publish "$2" --async --rpc-url "$1"; }
send_quoted_and_check() { # label, front, read RPC, target, value in wei
    local label="$1" front="$2" read_rpc="$3" target="$4" value="$5"
    local chain_id nonce front_nonce gas_price raw hash
    network_fee_cache_pair "$front" "$read_rpc" "" chain_id || fail "$label: front/read chain ID check failed"
    nonce=$(rpc_cast nonce "$ADDR" --block pending --rpc-url "$read_rpc") || fail "$label: nonce query failed"
    front_nonce=$(rpc_cast nonce "$ADDR" --block pending --rpc-url "$front") || fail "$label: front nonce query failed"
    (( front_nonce <= nonce )) || nonce=$front_nonce
    gas_price=$(rpc_cast gas-price --rpc-url "$read_rpc") || fail "$label: gas price query failed"
    # Offline legacy candidate; the quote supplies the gas and gas price actually signed.
    raw=$(cast mktx "$target" 0x --legacy --value "${value}wei" --gas-limit 500000 \
        --gas-price "$gas_price" --chain-id "$chain_id" --nonce "$nonce" --private-key "$SETUP_PK") ||
        fail "$label: could not build the candidate transaction"
    log "$label: quoting fee and submitting transaction (nonce $nonce)..."
    hash=$(EEZ_FRESH_SEND=1 network_send_quoted_trigger "$raw" "$SETUP_PK" "$front" "$read_rpc" \
        "tmp/e2e-network/setup-fee-quote-$nonce.json" publish_raw) ||
        fail "$label: quote/sign/send failed. Check the wallet nonce before retrying; submission may have reached the RPC."
    wait_receipt "$label" "$read_rpc" "$hash"
}
wait_receipt() { # label, receipt RPC, hash
    local label="$1" receipt_rpc="$2" hash="$3"
    local receipt status deadline
    [[ "$hash" =~ ^0x[[:xdigit:]]{64}$ ]] || fail "$label: unexpected transaction hash: $hash"
    LAST_TX="$hash"
    log "$label: sent (tx $hash)"
    deadline=$((SECONDS + TX_TIMEOUT))
    while (( SECONDS < deadline )); do
        if receipt=$(rpc_cast receipt "$hash" --rpc-url "$receipt_rpc" --async --json 2>/dev/null); then
            status=$(jq -r 'if type == "object" then .status else null end' <<< "$receipt") ||
                fail "$label: could not parse receipt (tx $hash)"
            case "$status" in
                1|0x1|0x01) log "$label: confirmed (tx $hash)"; return 0 ;;
                0|0x0|0x00) fail "$label: transaction FAILED (tx $hash). Stopping setup; no L2 delivery wait." ;;
                null) ;;
                *) fail "$label: unexpected receipt status $status (tx $hash)" ;;
            esac
        fi
        log "$label: waiting for receipt (${SECONDS}s since script start; tx $hash)"
        sleep 5
    done
    fail "$label: receipt timeout (tx $hash). Check this transaction before rerunning."
}
log "Environment: $ENV_FILE"
log "L2 rollup ID: $L2_ROLLUP_ID"
TARGET_WEI=$(cast to-wei "${1:-0.1}" ether)
[[ "$TARGET_WEI" =~ ^[0-9]+$ && "$TARGET_WEI" != 0 ]] || { echo "Amount must be positive" >&2; exit 1; }
ADDR=$(cast wallet address --private-key "$SETUP_PK")
BALANCE=$(read_l2_balance) || fail "L2 balance query failed"
# Wei amounts can exceed Bash's signed integer range; bc keeps exact precision.
MISSING=$(BC_LINE_LENGTH=0 bc <<< "$TARGET_WEI - $BALANCE")
if [[ "$MISSING" == -* ]]; then MISSING=0; fi
log "Source wallet: $ADDR"
log "L2 balance: $(cast from-wei "$BALANCE") ETH; target: $(cast from-wei "$TARGET_WEI") ETH"
if [[ "$MISSING" != 0 ]]; then
    PROXY=$(rpc_cast call "$ROLLUPS" 'computeCrossChainProxyAddress(address,uint64)(address)' "$ADDR" "$L2_ROLLUP_ID" --rpc-url "$L1_RPC")
    CODE=$(rpc_cast code "$PROXY" --rpc-url "$L1_RPC")
    if [[ "$CODE" == 0x ]]; then
        send_and_check "Proxy created" "$L1_RPC" "$ROLLUPS" 'createCrossChainProxy(address,uint64)' "$ADDR" "$L2_ROLLUP_ID" \
            --private-key "$SETUP_PK" --rpc-url "$L1_RPC"
    else
        log "Proxy already deployed: $PROXY"
    fi
    log "Bridging $(cast from-wei "$MISSING") ETH to the source wallet on L2..."
    send_quoted_and_check "Bridge" "$L1_FRONT" "$L1_RPC" "$PROXY" "$MISSING"
    DEADLINE=$((SECONDS + BRIDGE_TIMEOUT))
    while true; do
        BALANCE=$(read_l2_balance) || fail "L2 balance query failed (bridge tx $LAST_TX). Check delivery before rerunning."
        log "L2 delivery: $(cast from-wei "$BALANCE") / $(cast from-wei "$TARGET_WEI") ETH (bridge tx $LAST_TX)"
        if [[ "$(bc <<< "$BALANCE >= $TARGET_WEI")" == 1 ]]; then
            break
        fi
        if (( SECONDS >= DEADLINE )); then
            fail "L2 delivery timed out (bridge tx $LAST_TX). Check delivery before rerunning."
        fi
        sleep 5
    done
else
    log "L2 target already reached; skipping bridge."
fi
log "Network ready. Next run these in order (wait for bridge:1 to pass):"
printf 'DEVNET_ENV=%q bash script/e2e/run/network/staged.sh bridge:1\n' "$ENV_FILE"
printf 'DEVNET_ENV=%q bash script/e2e/run/network/staged.sh all\n' "$ENV_FILE"
