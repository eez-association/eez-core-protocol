#!/usr/bin/env bash
# End-to-end: start 2 anvils, deploy everything, execute flash loan, decode events.
#
# Run from project root:
#   bash script/flash-loan-test/e2e.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SCRIPT_DIR="script/flash-loan-test"
L1_PORT=8545
L2_PORT=8546
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
L2_ROLLUP_ID=1
# On anvil the deployer is also the system address
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

cleanup() {
    [[ -n "${L1_PID:-}" ]] && kill "$L1_PID" 2>/dev/null || true
    [[ -n "${L2_PID:-}" ]] && kill "$L2_PID" 2>/dev/null || true
}
trap cleanup EXIT

extract() { echo "$1" | grep "$2=" | sed "s/.*$2=//" | awk '{print $1}'; }

# ══════════════════════════════════════════════
#  Start 2 anvils
# ══════════════════════════════════════════════
echo "Starting anvil L1 (port $L1_PORT)..."
anvil --port "$L1_PORT" --silent &
L1_PID=$!

echo "Starting anvil L2 (port $L2_PORT)..."
anvil --port "$L2_PORT" --silent &
L2_PID=$!

sleep 1
echo "Anvil L1 running (PID $L1_PID)"
echo "Anvil L2 running (PID $L2_PID)"

# ══════════════════════════════════════════════
#  Deploy EEZ on L1
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy EEZ (L1) ======"
ROLLUPS_OUTPUT=$(forge script "$SCRIPT_DIR/DeployInfra.s.sol:DeployEEZL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" 2>&1)
ROLLUPS=$(extract "$ROLLUPS_OUTPUT" "ROLLUPS")
echo "ROLLUPS=$ROLLUPS"

# ══════════════════════════════════════════════
#  Deploy EEZL2 on L2
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy EEZL2 (L2) ======"
MANAGER_OUTPUT=$(forge script "$SCRIPT_DIR/DeployInfra.s.sol:DeployManagerL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "run(uint64,address)" "$L2_ROLLUP_ID" "$SYSTEM_ADDRESS" 2>&1)
MANAGER_L2=$(extract "$MANAGER_OUTPUT" "MANAGER_L2")
echo "MANAGER_L2=$MANAGER_L2"

# ══════════════════════════════════════════════
#  Run deploy.sh (Bridge + FlashLoan contracts)
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy Bridge + FlashLoan ======"
DEPLOY_OUTPUT=$(bash "$SCRIPT_DIR/deploy.sh" \
    --l1-rpc "$L1_RPC" \
    --l2-rpc "$L2_RPC" \
    --pk "$PK" \
    --rollups "$ROLLUPS" \
    --manager-l2 "$MANAGER_L2" \
    --l2-rollup-id "$L2_ROLLUP_ID" 2>&1)
echo "$DEPLOY_OUTPUT"

TOKEN=$(extract "$DEPLOY_OUTPUT" "  TOKEN")
BRIDGE_L1=$(extract "$DEPLOY_OUTPUT" "  BRIDGE_L1")
BRIDGE_L2=$(extract "$DEPLOY_OUTPUT" "  BRIDGE_L2")
EXECUTOR_L1=$(extract "$DEPLOY_OUTPUT" "  EXECUTOR_L1")
EXECUTOR_L2=$(extract "$DEPLOY_OUTPUT" "  EXECUTOR_L2")
FLASH_LOANERS_NFT=$(extract "$DEPLOY_OUTPUT" "  FLASH_LOANERS_NFT")
WRAPPED_TOKEN_L2=$(extract "$DEPLOY_OUTPUT" "  WRAPPED_TOKEN_L2")

# ══════════════════════════════════════════════
#  Execute L2 phase
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L2 Phase ======"
# Read token metadata from L1 (token doesn't exist on L2)
TOKEN_NAME=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "name()(string)" | tr -d '"')
TOKEN_SYMBOL=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "symbol()(string)" | tr -d '"')
TOKEN_DECIMALS=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "decimals()(uint8)")
echo "Token: $TOKEN_NAME ($TOKEN_SYMBOL), decimals=$TOKEN_DECIMALS"

# ABI-encode args (forge --sig has trouble parsing strings)
L2_CALLDATA=$(cast abi-encode \
    "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
    "$MANAGER_L2" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" \
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS")
L2_SELECTOR=$(cast sig "run(address,address,address,address,address,address,address,address,string,string,uint8)")

forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "${L2_SELECTOR}${L2_CALLDATA#0x}" 2>&1 \
    | grep -E "complete|error|Error" || true

L2_BLOCK=$(cast block-number --rpc-url "$L2_RPC")
echo "L2 execution at block $L2_BLOCK"

# ══════════════════════════════════════════════
#  Execute L1 phase (postAndVerifyBatch + flash loan in same block)
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L1 Phase ======"
forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address,address,address,address,address)" \
    "$ROLLUPS" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" 2>&1 \
    | grep -E "complete|error|Error" || true

L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
echo "L1 execution at block $L1_BLOCK"

# ══════════════════════════════════════════════
#  Decode L2 executions
# ══════════════════════════════════════════════
echo ""
echo "====== DecodeExecutions L2 (block $L2_BLOCK, manager $MANAGER_L2) ======"
echo ""
forge script script/DecodeExecutions.s.sol:DecodeExecutions \
    --rpc-url "$L2_RPC" \
    --sig "runBlock(uint256,address)" "$L2_BLOCK" "$MANAGER_L2" 2>&1 \
    | sed -n '/^  /p'

# ══════════════════════════════════════════════
#  Decode L1 executions
# ══════════════════════════════════════════════
echo ""
echo "====== DecodeExecutions L1 (block $L1_BLOCK, rollups $ROLLUPS) ======"
echo ""
forge script script/DecodeExecutions.s.sol:DecodeExecutions \
    --rpc-url "$L1_RPC" \
    --sig "runBlock(uint256,address)" "$L1_BLOCK" "$ROLLUPS" 2>&1 \
    | sed -n '/^  /p'

echo ""
echo "====== Done ======"
