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
for tool in cast python3 timeout; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
ENV_FILE="${2:-${DEVNET_ENV:-chain.env}}"
source "$SCRIPT_DIR/../../lib/network-config.sh"
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
send_and_check() {
    local label="$1" receipt_rpc="$2"; shift 2
    local hash receipt status deadline
    log "$label: submitting transaction..."
    if ! hash=$(rpc_cast send "$@" --async); then
        fail "$label: submission failed or timed out. Check the wallet nonce before retrying; submission may have reached the RPC."
    fi
    [[ "$hash" =~ ^0x[[:xdigit:]]{64}$ ]] || fail "$label: unexpected transaction hash: $hash"
    LAST_TX="$hash"
    log "$label: sent (tx $hash)"
    deadline=$((SECONDS + TX_TIMEOUT))
    while (( SECONDS < deadline )); do
        if receipt=$(rpc_cast receipt "$hash" --rpc-url "$receipt_rpc" --async --json 2>/dev/null); then
            status=$(python3 -c 'import json,sys
r=json.load(sys.stdin)
s=r.get("status") if isinstance(r,dict) else None
print(int(s,0) if isinstance(s,str) else s)' <<< "$receipt") || fail "$label: could not parse receipt (tx $hash)"
            case "$status" in
                1) log "$label: confirmed (tx $hash)"; return 0 ;;
                0) fail "$label: transaction FAILED (tx $hash). Stopping setup; no L2 delivery wait." ;;
                None) ;;
                *) fail "$label: unexpected receipt status $status (tx $hash)" ;;
            esac
        fi
        log "$label: waiting for receipt (${SECONDS}s since script start; tx $hash)"
        sleep 5
    done
    fail "$label: receipt timeout (tx $hash). Check this transaction before rerunning."
}
log "Environment: $ENV_FILE"
TARGET_WEI=$(cast to-wei "${1:-0.1}" ether)
[[ "$TARGET_WEI" =~ ^[0-9]+$ && "$TARGET_WEI" != 0 ]] || { echo "Amount must be positive" >&2; exit 1; }
ADDR=$(cast wallet address --private-key "$SETUP_PK")
BALANCE=$(rpc_cast balance "$ADDR" --rpc-url "$L2_RPC")
MISSING=$(python3 -c 'import sys; print(max(0, int(sys.argv[1])-int(sys.argv[2])))' "$TARGET_WEI" "$BALANCE")
log "Source wallet: $ADDR"
log "L2 balance: $(cast from-wei "$BALANCE") ETH; target: $(cast from-wei "$TARGET_WEI") ETH"
if [[ "$MISSING" != 0 ]]; then
    PROXY=$(rpc_cast call "$ROLLUPS" 'computeCrossChainProxyAddress(address,uint64)(address)' "$ADDR" 1 --rpc-url "$L1_RPC")
    CODE=$(rpc_cast code "$PROXY" --rpc-url "$L1_RPC")
    if [[ "$CODE" == 0x ]]; then
        send_and_check "Proxy created" "$L1_RPC" "$ROLLUPS" 'createCrossChainProxy(address,uint64)' "$ADDR" 1 \
            --private-key "$SETUP_PK" --rpc-url "$L1_RPC"
    else
        log "Proxy already deployed: $PROXY"
    fi
    log "Bridging $(cast from-wei "$MISSING") ETH to the source wallet on L2..."
    send_and_check "Bridge" "$L1_RPC" "$PROXY" --value "$MISSING" --gas-limit 500000 \
        --private-key "$SETUP_PK" --rpc-url "$L1_FRONT"
    DEADLINE=$((SECONDS + BRIDGE_TIMEOUT))
    while true; do
        BALANCE=$(rpc_cast balance "$ADDR" --rpc-url "$L2_RPC") || fail "L2 balance query failed (bridge tx $LAST_TX). Check delivery before rerunning."
        log "L2 delivery: $(cast from-wei "$BALANCE") / $(cast from-wei "$TARGET_WEI") ETH (bridge tx $LAST_TX)"
        if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$BALANCE" "$TARGET_WEI"; then
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
