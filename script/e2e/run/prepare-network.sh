#!/usr/bin/env bash
# Prepare a devnet for network-mode e2e tests.
# Ensures CREATE2 factory on both chains and funds the test account on L2.
#
# Usage:
#   bash script/e2e/run/prepare-network.sh \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> --rollups <ROLLUPS>
source "$(dirname "$0")/../shared/E2EBase.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-rpc)   export L1_RPC="$2"; shift 2;;
        --l2-rpc)   export L2_RPC="$2"; shift 2;;
        --pk)       export PK="$2"; shift 2;;
        --rollups)  export ROLLUPS="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_RPC L2_RPC PK ROLLUPS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

SENDER_ADDRESS=$(cast wallet address --private-key "$PK")
echo "Sender address: $SENDER_ADDRESS"

echo ""
echo "====== Step 1: CREATE2 Factory (L1) ======"
ensure_create2_factory "$L1_RPC" "L1" "$PK"

echo ""
echo "====== Step 2: Fund L2 Account ======"
L2_BALANCE=$(cast balance "$SENDER_ADDRESS" --rpc-url "$L2_RPC")
echo "Current L2 balance: $L2_BALANCE wei"

MIN_BALANCE="10000000000000000"

if [[ "$L2_BALANCE" == "0" ]] || [[ $(echo "$L2_BALANCE < $MIN_BALANCE" | bc) -eq 1 ]]; then
    echo "L2 balance is insufficient, bridging 0.05 ETH from L1..."

    cast send "$ROLLUPS" "createCrossChainProxy(address,uint64)" \
        "$SENDER_ADDRESS" 1 \
        --private-key "$PK" --rpc-url "$L1_RPC" > /dev/null 2>&1 || true

    PROXY_ADDRESS=$(cast call "$ROLLUPS" \
        "computeCrossChainProxyAddress(address,uint64)(address)" \
        "$SENDER_ADDRESS" 1 \
        --rpc-url "$L1_RPC")
    echo "Proxy address: $PROXY_ADDRESS"

    echo "Sending 0.05 ETH to proxy on L1 (triggers bridge)..."
    cast send "$PROXY_ADDRESS" \
        --value 0.05ether \
        --gas-limit 500000 \
        --private-key "$PK" --rpc-url "$L1_RPC" > /dev/null 2>&1 || true

    echo "Waiting for bridge to complete..."
    sleep 10

    L2_BALANCE_AFTER=$(cast balance "$SENDER_ADDRESS" --rpc-url "$L2_RPC")
    echo "L2 balance after bridge: $L2_BALANCE_AFTER wei"

    if [[ "$L2_BALANCE_AFTER" == "0" ]] || [[ $(echo "$L2_BALANCE_AFTER < $MIN_BALANCE" | bc) -eq 1 ]]; then
        echo "WARNING: L2 balance is still low after bridging."
    else
        echo "L2 funding successful"
    fi
else
    echo "L2 balance is sufficient, skipping bridge"
fi

echo ""
echo "====== Step 3: CREATE2 Factory (L2) ======"
ensure_create2_factory "$L2_RPC" "L2" "$PK"

echo ""
echo "====== Network Prepared ======"
