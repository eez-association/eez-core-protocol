#!/usr/bin/env bash
# Foundry owns deployment/simulation; only the L2 trigger is signed and submitted with cast.
set +x
set -euo pipefail

BALANCER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Copied from E2EBase.sh; keep the original E2E scripts unchanged.
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

SCRIPT_PATH=script/balancer/Mainnet.s.sol:Mainnet
SCRIPT_FILE=Mainnet.s.sol
L1_CHAIN_ID=1
L2_CHAIN_ID=696990
TOKEN_SYMBOL=USDC
MINIMUM=10000000000
USDC=${BALANCER_TOKEN:-}
VAULT=${BALANCER_VAULT:-}
L1_BRIDGE=${BALANCER_L1_BRIDGE:-}
L2_BRIDGE=${BALANCER_L2_BRIDGE:-}
CREATE2_FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C

fail() { echo "ERROR: $*" >&2; return 1; }
# Do not expose signer arguments or credential-bearing RPC URLs in errors/logs.
safe_run() {
    local logfile=$1 output rc=0 secret; shift
    output=$("$@" 2>&1) || rc=$?
    for secret in "${PK:-}" "${L1_RPC:-}" "${L2_RPC:-}" "${L1_FRONT:-}" "${L2_FRONT:-}"; do
        [[ -z "$secret" ]] || output=${output//"$secret"/[redacted]}
    done
    printf '%s\n' "$output" > "$logfile"
    (( rc == 0 )) || { echo "Command failed; sanitized details: $logfile" >&2; return "$rc"; }
}
field() { jq -er ".$1" "$RUN_DIR/state.json"; }
set_field() {
    jq --arg key "$1" --arg value "$2" '.[$key]=$value' "$RUN_DIR/state.json" > "$RUN_DIR/state.next"
    mv "$RUN_DIR/state.next" "$RUN_DIR/state.json"
}
read_call() { cast call "$@" 2>/dev/null || fail "Contract read failed"; }
verify() {
    local completed=${1:-false} token_id=${2:-0}
    safe_run "$RUN_DIR/verify-l1.log" forge script "$SCRIPT_PATH" \
        --rpc-url "$L1_RPC" --sig 'verifyL1(address,address,address,bool)' "$(field borrower)" "$(field executor)" "$WALLET" "$completed"
    safe_run "$RUN_DIR/verify-l2.log" forge script "$SCRIPT_PATH" \
        --rpc-url "$L2_RPC" --sig 'verifyL2(address,address,address,bool,uint256)' "$(field executor)" "$(field borrower)" "$WALLET" true "$token_id"
}

# Deployment addresses live only in the selected ignored environment file.
load_balancer_addresses() {
    local name
    for name in BALANCER_TOKEN BALANCER_VAULT BALANCER_L1_BRIDGE BALANCER_L2_BRIDGE; do
        [[ "${!name:-}" =~ ^0x[0-9a-fA-F]{40}$ && "${!name}" != 0x0000000000000000000000000000000000000000 ]] || fail "Set $name in the selected environment file"
        export "$name"
    done
    USDC=$BALANCER_TOKEN VAULT=$BALANCER_VAULT
    L1_BRIDGE=$BALANCER_L1_BRIDGE L2_BRIDGE=$BALANCER_L2_BRIDGE
}

fee_check() {
    local gas=$1 price=$2 balance=$3
    [[ "$gas" =~ ^[0-9]+$ && "$price" =~ ^[0-9]+$ && "$MAX_FEE_WEI" =~ ^[0-9]+$ ]] || fail 'Invalid fee input'
    (( price > 0 && price <= 1000000000000 && gas > 0 && gas <= 16777216 && MAX_FEE_WEI > 0 && MAX_FEE_WEI <= 1000000000000000000 )) || fail 'Fee bounds exceeded'
    (( gas <= MAX_FEE_WEI / price )) || fail 'Maximum transaction fee exceeded'
    # Compare wei as exact integers (jq number arithmetic would lose precision).
    [[ "$balance" =~ ^(0|[1-9][0-9]*)$ ]] || fail 'Invalid wallet balance'
    local needed=$((gas * price))
    if (( ${#balance} < ${#needed} )) || { (( ${#balance} == ${#needed} )) && [[ "$balance" < "$needed" ]]; }; then
        fail 'Insufficient wallet ETH for maximum gas cost'
    fi
    echo "Maximum transaction gas cost: $needed wei"
}
preflight() {
    [[ $(cast chain-id --rpc-url "$L1_RPC" 2>/dev/null) == "$L1_CHAIN_ID" ]] || fail 'L1_RPC has unexpected chain ID'
    [[ $(cast chain-id --rpc-url "$L1_FRONT" 2>/dev/null) == "$L1_CHAIN_ID" ]] || fail 'L1_FRONT has unexpected chain ID'
    [[ $(cast chain-id --rpc-url "$L2_RPC" 2>/dev/null) == "$L2_CHAIN_ID" ]] || fail 'Unexpected L2_RPC chain'
    [[ $(cast chain-id --rpc-url "$L2_FRONT" 2>/dev/null) == "$L2_CHAIN_ID" ]] || fail 'L2_FRONT must serve the L2 trigger chain'
    safe_run "$RUN_DIR/preflight-l1.log" forge script "$SCRIPT_PATH" \
        --rpc-url "$L1_RPC" --sig 'preflightL1(address)' "$ROLLUPS"
    safe_run "$RUN_DIR/preflight-l2.log" forge script "$SCRIPT_PATH" \
        --rpc-url "$L2_RPC" --sig 'preflightL2(address)' "$MANAGER_L2"
    echo "Verified chain IDs, existing bridges and composer managers. Wallet: $WALLET"
}
# Each deployment/configuration script plans exactly one wallet transaction.
# Mark before broadcast: an uncertain submission must be inspected, never blindly repeated.
stage() {
    local label=$1 rpc=$2 chain=$3 signature=$4; shift 4
    [[ ! -f "$RUN_DIR/$label.done" ]] || return 0
    [[ ! -f "$RUN_DIR/$label.started" ]] || fail "$label was already attempted; inspect its Foundry broadcast journal before recovery"
    local price plan gas nonce balance actual_nonce hash receipt
    price=$(cast gas-price --rpc-url "$rpc" 2>/dev/null); price=$((price * 2))
    local stage_broadcast="$FOUNDRY_BROADCAST/$label"
    local entrypoint=${signature%%(*}
    local flags=(--rpc-url "$rpc" --sender "$WALLET" --legacy --with-gas-price "$price" --gas-estimate-multiplier 120 --non-interactive)
    safe_run "$RUN_DIR/$label-plan.log" env FOUNDRY_BROADCAST="$stage_broadcast" forge script "$SCRIPT_PATH" "${flags[@]}" --sig "$signature" "$@"
    plan="$stage_broadcast/$SCRIPT_FILE/$chain/dry-run/$entrypoint-latest.json"
    [[ $(jq '.transactions | length' "$plan") == 1 ]] || fail 'Expected exactly one planned wallet transaction'
    [[ $(jq -r '.transactions[0].transaction.from | ascii_downcase' "$plan") == "${WALLET,,}" ]] || fail 'Unexpected planned signer'
    gas=$(cast to-dec "$(jq -r '.transactions[0].transaction.gas' "$plan")")
    nonce=$(cast to-dec "$(jq -r '.transactions[0].transaction.nonce' "$plan")")
    balance=$(cast balance "$WALLET" --rpc-url "$rpc" 2>/dev/null)
    fee_check "$gas" "$price" "$balance"
    actual_nonce=$(cast nonce "$WALLET" --block pending --rpc-url "$rpc" 2>/dev/null)
    [[ "$actual_nonce" == "$nonce" ]] || fail 'Nonce changed since simulation; no broadcast'
    cp "$plan" "$RUN_DIR/$label.started"
    # Sign the exact checked Foundry plan, as the E2E staged runner does.
    # Do not re-run forge --broadcast: that could change the gas after the fee check.
    local target input planned_address
    target=$(jq -r '.transactions[0].transaction.to // ""' "$plan")
    input=$(jq -er '.transactions[0].transaction.input' "$plan")
    [[ $(cast to-dec "$(jq -r '.transactions[0].transaction.chainId' "$plan")") == "$chain" ]] || fail 'Planned chain mismatch'
    [[ $(cast to-dec "$(jq -r '.transactions[0].transaction.value' "$plan")") == 0 ]] || fail 'Unexpected planned ETH transfer'
    case "$label" in
        deploy-l1|deploy-l2)
            [[ -z "$target" && $(jq -r '.transactions[0].transactionType' "$plan") == CREATE ]] || fail 'Expected contract creation'
            planned_address=$(jq -er '.transactions[0].contractAddress' "$plan") ;;
        configure)
            [[ "${target,,}" == "$(field executor | tr '[:upper:]' '[:lower:]')" ]] || fail 'Configuration target mismatch'
            [[ "$input" == "$(cast calldata 'configure(address)' "$(field borrower)")" ]] || fail 'Configuration calldata mismatch' ;;
        factory-proxy)
            [[ "${target,,}" == "${MANAGER_L2,,}" ]] || fail 'Factory proxy manager mismatch'
            [[ "$input" == "$(cast calldata 'createCrossChainProxy(address,uint64)' "$CREATE2_FACTORY" 0)" ]] || fail 'Factory proxy calldata mismatch' ;;
        *) fail 'Unknown deployment stage' ;;
    esac
    local sign_flags=(--private-key "$PK" --legacy --chain "$chain" --nonce "$nonce" --gas-limit "$gas" --gas-price "$price" --value 0)
    if [[ -z "$target" ]]; then
        safe_run "$RUN_DIR/$label.raw" cast mktx "${sign_flags[@]}" --create "$input"
    else
        safe_run "$RUN_DIR/$label.raw" cast mktx "${sign_flags[@]}" "$target" "$input"
    fi
    local raw
    raw=$(cat "$RUN_DIR/$label.raw")
    validate_signed "$raw" "$target" "$input" "$chain" "$nonce" "$gas" "$price"
    hash=$(cast keccak "$raw")
    printf '%s\n' "$hash" > "$RUN_DIR/$label.hash"
    safe_run "$RUN_DIR/$label-submit.log" _send_raw_tx "$rpc" "$raw"
    [[ $(cat "$RUN_DIR/$label-submit.log") == "$hash" ]] || fail 'Unexpected submitted deployment hash'
    receipt=$(wait_receipt "$rpc" "$hash")
    [[ $(jq -r '.status' <<< "$receipt") == 0x1 ]] || fail "$label is not confirmed successful"
    [[ $(jq -r '.transactionHash' <<< "$receipt") == "$hash" ]] || fail 'Deployment receipt hash mismatch'
    if [[ -z "$target" ]]; then
        [[ $(jq -r '.contractAddress | ascii_downcase' <<< "$receipt") == "${planned_address,,}" ]] || fail 'Unexpected deployed contract address'
    fi
    printf '%s\n' "$receipt" > "$RUN_DIR/$label.receipt.json"
    case "$label" in
        deploy-l2) set_field executor "$(jq -er '.contractAddress' <<< "$receipt")" ;;
        deploy-l1) set_field borrower "$(jq -er '.contractAddress' <<< "$receipt")"; set_field loan_mode fixed ;;
    esac
    printf '%s\n' "$hash" > "$RUN_DIR/$label.done"
    echo "$label confirmed: $hash"
}
deploy() {
    local mode=${1:-direct}
    stage deploy-l2 "$L2_RPC" "$L2_CHAIN_ID" 'deployL2(address)' "$WALLET"
    safe_run "$RUN_DIR/check-l2.log" forge script "$SCRIPT_PATH" --rpc-url "$L2_RPC" \
        --sig 'verifyL2(address,address,address,bool,uint256)' "$(field executor)" 0x0000000000000000000000000000000000000000 "$WALLET" false 0
    if [[ "$mode" == via-l2 ]]; then
        deploy_l1_via_l2
    else
        [[ ! -f "$RUN_DIR/deploy-l1-via-l2.hash" || -f "$RUN_DIR/deploy-l1.done" ]] || fail 'Remote deployment already submitted; resume deploy-via-l2'
        stage deploy-l1 "$L1_RPC" "$L1_CHAIN_ID" 'deployL1(address,address)' "$WALLET" "$(field executor)"
    fi
    safe_run "$RUN_DIR/check-l1.log" forge script "$SCRIPT_PATH" --rpc-url "$L1_RPC" \
        --sig 'verifyL1(address,address,address,bool)' "$(field borrower)" "$(field executor)" "$WALLET" false
    stage configure "$L2_RPC" "$L2_CHAIN_ID" 'configureL2(address,address,address)' "$(field executor)" "$(field borrower)" "$WALLET"
    verify
    cat "$RUN_DIR/state.json"
}
# One-time alternative: same L1 borrower, paid/submitted as an L2-originating call.
deploy_l1_via_l2() {
    [[ ! -f "$RUN_DIR/deploy-l1.done" ]] || return 0
    [[ ! -f "$RUN_DIR/deploy-l1.started" ]] || fail 'Direct L1 deployment was attempted; reconcile it before switching paths'
    safe_run "$RUN_DIR/create2-factory-check.log" forge script "$SCRIPT_PATH" \
        --rpc-url "$L1_RPC" --sig 'checkL1Factory()'

    # Pure local recipe generation; stderr is kept separate from machine-readable JSON.
    forge script "$SCRIPT_PATH" --json --sig 'prepareL1Create2(address,address)' \
        "$WALLET" "$(field executor)" > "$RUN_DIR/create2-recipe-output.json" 2> "$RUN_DIR/create2-recipe.log"
    jq -e '{predicted:.returns.predicted.value,payload:.returns.payload.value}' \
        "$RUN_DIR/create2-recipe-output.json" > "$RUN_DIR/create2-recipe.next"
    if [[ -f "$RUN_DIR/create2-recipe.json" ]]; then
        cmp -s "$RUN_DIR/create2-recipe.json" "$RUN_DIR/create2-recipe.next" || fail 'CREATE2 recipe changed; preserve the old run and inspect before proceeding'
    else
        cp "$RUN_DIR/create2-recipe.next" "$RUN_DIR/create2-recipe.json"
    fi
    local predicted payload proxy code raw hash receipt nonce front_nonce price balance gas
    predicted=$(jq -er '.predicted' "$RUN_DIR/create2-recipe.json")
    payload=$(jq -er '.payload' "$RUN_DIR/create2-recipe.json")
    [[ "$predicted" =~ ^0x[0-9a-fA-F]{40}$ && "$payload" =~ ^0x[0-9a-fA-F]+$ ]] || fail 'Invalid CREATE2 recipe'
    proxy=$(read_call "$MANAGER_L2" 'computeCrossChainProxyAddress(address,uint64)(address)' "$CREATE2_FACTORY" 0 --rpc-url "$L2_RPC")
    code=$(cast code "$proxy" --rpc-url "$L2_RPC" 2>/dev/null)
    if [[ "$code" == 0x ]]; then
        stage factory-proxy "$L2_RPC" "$L2_CHAIN_ID" 'ensureFactoryProxy(address)' "$WALLET"
    fi
    [[ $(cast code "$proxy" --rpc-url "$L2_RPC" 2>/dev/null) != 0x ]] || fail 'Factory proxy missing after setup'
    if [[ ! -f "$RUN_DIR/deploy-l1-via-l2.hash" ]]; then
        [[ $(cast code "$predicted" --rpc-url "$L1_RPC" 2>/dev/null) == 0x ]] || fail 'CREATE2 address already occupied; inspect instead of redeploying'
        nonce=$(cast nonce "$WALLET" --block pending --rpc-url "$L2_RPC" 2>/dev/null)
        front_nonce=$(cast nonce "$WALLET" --block pending --rpc-url "$L2_FRONT" 2>/dev/null)
        [[ "$nonce" =~ ^[0-9]+$ && "$front_nonce" =~ ^[0-9]+$ ]] || fail 'Invalid nonce response'
        nonce=$((nonce > front_nonce ? nonce : front_nonce))
        gas=${BALANCER_CREATE2_GAS:-3500000}
        price=$(cast gas-price --rpc-url "$L2_RPC" 2>/dev/null); price=$((price * 2))
        balance=$(cast balance "$WALLET" --rpc-url "$L2_RPC" 2>/dev/null)
        fee_check "$gas" "$price" "$balance"
        # Do not estimate or locally simulate the cross-chain factory call.
        safe_run "$RUN_DIR/deploy-l1-via-l2.raw" cast mktx "$proxy" "$payload" --private-key "$PK" --legacy \
            --chain "$L2_CHAIN_ID" --nonce "$nonce" --gas-limit "$gas" --gas-price "$price" --value 0
        raw=$(cat "$RUN_DIR/deploy-l1-via-l2.raw")
        validate_signed "$raw" "$proxy" "$payload" "$L2_CHAIN_ID" "$nonce" "$gas" "$price"
        hash=$(cast keccak "$raw")
        printf '%s\n' "$hash" > "$RUN_DIR/deploy-l1-via-l2.hash"
        safe_run "$RUN_DIR/deploy-l1-via-l2-submit.log" _send_raw_tx "$L2_FRONT" "$raw"
        [[ $(cat "$RUN_DIR/deploy-l1-via-l2-submit.log") == "$hash" ]] || fail 'Unexpected CREATE2 submission hash'
        echo "L1 CREATE2 deployment submitted through L2_FRONT: $hash"
    fi
    hash=$(cat "$RUN_DIR/deploy-l1-via-l2.hash")
    receipt=$(wait_receipt "$L2_FRONT" "$hash" "$L2_RPC")
    [[ $(jq -r '.status' <<< "$receipt") == 0x1 && $(jq -r '.transactionHash' <<< "$receipt") == "$hash" ]] || fail 'Remote deployment reverted or receipt mismatched'
    [[ $(jq -r '.to | ascii_downcase' <<< "$receipt") == "${proxy,,}" ]] || fail 'Wrong remote deployment target'
    [[ $(jq -r '.from | ascii_downcase' <<< "$receipt") == "${WALLET,,}" ]] || fail 'Wrong remote deployment sender'
    printf '%s\n' "$receipt" > "$RUN_DIR/deploy-l1-via-l2.receipt.json"
    verify_remote_deployment "$predicted"
}
verify_remote_deployment() {
    local predicted=$1 correlation block hash settlement receipt deadline=$((SECONDS + ${RECEIPT_TIMEOUT:-180}))
    block=$(jq -er '.blockNumber' "$RUN_DIR/deploy-l1-via-l2.receipt.json")
    hash=$(jq -er '.blockHash' "$RUN_DIR/deploy-l1-via-l2.receipt.json")
    while :; do
        correlation=$(cast rpc --rpc-timeout 10 --rpc-url "$L2_RPC" eez_getSettlementByL2Block "$block" 2>/dev/null)
        [[ "$correlation" == null ]] || break
        ((SECONDS < deadline)) || fail 'CREATE2 settlement pending; rerun deploy-via-l2 to verify without resending'
        sleep 3
    done
    jq -e --arg number "$block" --arg hash "$hash" '.canonicalL2==true and .matchedL2Block.number==$number and .matchedL2Block.hash==$hash' \
        <<< "$correlation" >/dev/null || fail 'CREATE2 settlement does not match its L2 block'
    settlement=$(jq -er '.l1TransactionHash' <<< "$correlation")
    receipt=$(cast rpc --rpc-url "$L1_RPC" eth_getTransactionReceipt "$settlement" 2>/dev/null)
    jq -e --arg tx "$settlement" --arg block "$(jq -r '.l1BlockNumber' <<< "$correlation")" --arg hash "$(jq -r '.l1BlockHash' <<< "$correlation")" \
        '.status=="0x1" and .transactionHash==$tx and .blockNumber==$block and .blockHash==$hash' <<< "$receipt" >/dev/null || fail 'Invalid CREATE2 L1 settlement receipt'
    [[ $(cast rpc --rpc-url "$L1_RPC" eth_getBlockByNumber "$(jq -r '.l1BlockNumber' <<< "$correlation")" false 2>/dev/null | jq -r '.hash') == "$(jq -r '.l1BlockHash' <<< "$correlation")" ]] || fail 'CREATE2 settlement is no longer canonical'
    safe_run "$RUN_DIR/create2-deployment-check.log" forge script "$SCRIPT_PATH" --rpc-url "$L1_RPC" \
        --sig 'verifyL1(address,address,address,bool)' "$predicted" "$(field executor)" "$WALLET" false
    printf '%s\n' "$receipt" > "$RUN_DIR/deploy-l1.receipt.json"
    printf '%s\n' "$correlation" > "$RUN_DIR/deploy-l1-via-l2-correlation.json"
    set_field borrower "$predicted"
    set_field l1_deployment_mode create2-via-l2
    set_field loan_mode fixed
    printf '%s\n' "$settlement" > "$RUN_DIR/deploy-l1.done"
    echo "Verified borrower on L1: $predicted (settlement $settlement)"
}
validate_signed() {
    local raw=$1 target=$2 data=$3 chain=$4 nonce=$5 gas=$6 price=$7 signed
    signed=$(cast decode-transaction "$raw" | jq 'if type=="string" then fromjson else . end')
    [[ $(jq -r '.signer | ascii_downcase' <<< "$signed") == "${WALLET,,}" ]] || fail 'Signed sender mismatch'
    [[ $(jq -r '(.to // "") | ascii_downcase' <<< "$signed") == "${target,,}" ]] || fail 'Signed target mismatch'
    [[ $(cast to-dec "$(jq -r '.chainId' <<< "$signed")") == "$chain" && $(jq -r '.value' <<< "$signed") == 0x0 ]] || fail 'Signed chain/value mismatch'
    [[ $(jq -r '.input' <<< "$signed") == "$data" ]] || fail 'Signed calldata mismatch'
    [[ $(cast to-dec "$(jq -r '.nonce' <<< "$signed")") == "$nonce" ]] || fail 'Signed nonce mismatch'
    [[ $(cast to-dec "$(jq -r '.gas' <<< "$signed")") == "$gas" ]] || fail 'Signed gas mismatch'
    [[ $(cast to-dec "$(jq -r '.gasPrice' <<< "$signed")") == "$price" ]] || fail 'Signed gas price mismatch'
}
wait_receipt() {
    local rpc=$1 hash=$2 fallback=${3:-} receipt deadline=$((SECONDS + ${RECEIPT_TIMEOUT:-180}))
    while (( SECONDS < deadline )); do
        receipt=$(cast rpc --rpc-timeout 10 --rpc-url "$rpc" eth_getTransactionReceipt "$hash" 2>/dev/null) || {
            [[ -n "$fallback" ]] || return 1
            receipt=null
        }
        if [[ "$receipt" == null && -n "$fallback" && "$fallback" != "$rpc" ]]; then
            receipt=$(cast rpc --rpc-timeout 10 --rpc-url "$fallback" eth_getTransactionReceipt "$hash" 2>/dev/null) || return 1
        fi
        if [[ "$receipt" != null ]]; then printf '%s\n' "$receipt"; return 0; fi
        sleep 2
    done
    fail "Receipt pending for $hash; preserve the journal and inspect before recovery"
}
trigger() {
    local mode=${1:-fixed} price_floor=${2:-0} require_idle=${3:-false}
    [[ "$mode" == fixed || "$mode" == legacy ]] || fail "Unknown loan mode"
    [[ ! -f "$RUN_DIR/trigger.hash" ]] || fail 'Trigger already signed/submitted; use status, do not submit again'
    verify
    local executor borrower nft loan requested nonce front_nonce gas=${E2E_TRIGGER_GAS:-2500000} price balance data raw hash
    executor=$(field executor); borrower=$(field borrower)
    nft=$(read_call "$executor" 'nft()(address)' --rpc-url "$L2_RPC")
    [[ $(read_call "$nft" 'hasClaimed(address)(bool)' "$WALLET" --rpc-url "$L2_RPC") == false ]] || fail 'Wallet already claimed'
    loan=$(read_call "$borrower" 'availableLoan()(uint256)' --rpc-url "$L1_RPC"); loan=${loan%% *}
    [[ "$loan" =~ ^(0|[1-9][0-9]*)$ ]] || fail 'Invalid available loan'
    set_field loan_mode "$mode"
    set_field observed_available_loan "$loan"
    if [[ "$mode" == legacy ]]; then
        requested=$MINIMUM
        [[ $(bc <<< "$loan >= $requested") == 1 ]] || fail 'Available loan is below NFT minimum'
        set_field requested_minimum "$requested"
        echo "Legacy loan minimum: $requested $TOKEN_SYMBOL base units; the old borrower chooses its live amount"
    else
        # Choose once, using exact arithmetic rather than Bash signed 64-bit integers.
        requested=$(BC_LINE_LENGTH=0 bc <<< "$loan * 80 / 100")
        [[ $(bc <<< "$requested >= $MINIMUM") == 1 ]] || fail '80% loan request is below NFT minimum'
        set_field requested_amount "$requested"
        echo "Fixed loan request: $requested $TOKEN_SYMBOL base units (80% of observed $loan)"
    fi
    nonce=$(cast nonce "$WALLET" --block pending --rpc-url "$L2_RPC" 2>/dev/null)
    front_nonce=$(cast nonce "$WALLET" --block pending --rpc-url "$L2_FRONT" 2>/dev/null)
    [[ "$nonce" =~ ^[0-9]+$ && "$front_nonce" =~ ^[0-9]+$ ]] || fail 'Invalid nonce response'
    if [[ "$mode" == legacy || "$require_idle" == true ]]; then
        local latest_nonce
        latest_nonce=$(cast nonce "$WALLET" --block latest --rpc-url "$L2_RPC" 2>/dev/null)
        [[ "$latest_nonce" == "$nonce" && "$latest_nonce" == "$front_nonce" ]] || fail 'Pending wallet transaction; reconcile it before starting another loan'
    fi
    nonce=$(( nonce > front_nonce ? nonce : front_nonce ))
    price=$(cast gas-price --rpc-url "$L2_RPC" 2>/dev/null); price=$((price * 2))
    [[ "$price_floor" =~ ^(0|[1-9][0-9]*)$ && $(bc <<< "$price_floor <= 1000000000000") == 1 ]] || fail 'Invalid replacement gas price'
    price=$((price > price_floor ? price : price_floor))
    balance=$(cast balance "$WALLET" --rpc-url "$L2_RPC" 2>/dev/null)
    fee_check "$gas" "$price" "$balance"
    data=$(cast calldata 'start(uint256)' "$requested")
    # All fields are explicit: signing happens offline; the send goes ONLY to L2_FRONT.
    safe_run "$RUN_DIR/trigger.raw" cast mktx "$executor" "$data" --private-key "$PK" --legacy \
        --chain "$L2_CHAIN_ID" --nonce "$nonce" --gas-limit "$gas" --gas-price "$price" --value 0
    raw=$(cat "$RUN_DIR/trigger.raw")
    validate_signed "$raw" "$executor" "$data" "$L2_CHAIN_ID" "$nonce" "$gas" "$price"
    hash=$(cast keccak "$raw")
    cast block-number --rpc-url "$L1_RPC" > "$RUN_DIR/l1-before-trigger"
    printf '%s\n' "$hash" > "$RUN_DIR/trigger.hash"
    safe_run "$RUN_DIR/trigger-submit.log" _send_raw_tx "$L2_FRONT" "$raw"
    [[ $(cat "$RUN_DIR/trigger-submit.log") == "$hash" ]] || fail 'Unexpected submitted transaction hash'
    echo "Submitted through L2_FRONT: $hash"
    echo 'Run status to check L2 execution and L1 repayment; no automatic replacement transactions.'
}
# Verify actual transfers from receipts instead of comparing unrelated latest Vault balances.
require_transfer() {
    local receipt=$1 token=$2 from=$3 to=$4 amount=$5 topic
    topic=$(cast keccak 'Transfer(address,address,uint256)')
    jq -e --arg token "${token,,}" --arg from "${from,,}" --arg to "${to,,}" --arg amount "$amount" --arg topic "$topic" '
        any(.logs[]; (.address|ascii_downcase)==$token and .topics[0]==$topic and (.topics|length)==3
            and ("0x"+(.topics[1][-40:]|ascii_downcase))==$from and ("0x"+(.topics[2][-40:]|ascii_downcase))==$to
            and .data==$amount)' "$receipt" >/dev/null || fail 'Expected token transfer missing from receipt'
}
status() {
    [[ -f "$RUN_DIR/trigger.hash" ]] || { echo 'No trigger recorded.'; return; }
    local hash receipt executor borrower event amount token_id settlement wrapped topic zero
    hash=$(cat "$RUN_DIR/trigger.hash"); executor=$(field executor); borrower=$(field borrower)
    receipt=$(cast rpc --rpc-url "$L2_FRONT" eth_getTransactionReceipt "$hash" 2>/dev/null) || receipt=null
    if [[ "$receipt" == null && "$L2_RPC" != "$L2_FRONT" ]]; then
        receipt=$(cast rpc --rpc-url "$L2_RPC" eth_getTransactionReceipt "$hash" 2>/dev/null) || receipt=null
    fi
    if [[ "$receipt" == null ]]; then
        local details
        if ! details=$(cast rpc --rpc-timeout 10 --rpc-url "$L2_RPC" eez_getCrossChainTransaction "$hash" 2>/dev/null) || [[ "$details" == null ]]; then
            echo "No L2 receipt; composer status unavailable: $hash"
            return
        fi
        jq -e --arg hash "$hash" '.hash==$hash' <<< "$details" >/dev/null || fail 'Composer status hash mismatch'
        printf '%s\n' "$details" > "$RUN_DIR/cross-chain-status.json"
        jq . <<< "$details"
        if jq -e '.lifecycle=="terminal" or .ownership.state=="terminal"' <<< "$details" >/dev/null; then
            fail "L2 trigger terminal without a receipt: $hash"
            return 1
        fi
        echo "L2 trigger pending: $hash"
        return
    fi
    [[ $(jq -r '.status' <<< "$receipt") == 0x1 ]] || fail "L2 trigger reverted: $hash"
    printf '%s\n' "$receipt" > "$RUN_DIR/trigger.receipt.json"
    topic=$(cast keccak 'FlashLoanCompleted(address,uint256,uint256)')
    event=$(jq -ce --arg executor "${executor,,}" --arg topic "$topic" '[.logs[] | select((.address|ascii_downcase)==$executor and .topics[0]==$topic)] | if length==1 then .[0] else error("Missing/ambiguous completion") end' <<< "$receipt")
    amount=$(jq -r '.data' <<< "$event"); token_id=$(cast to-dec "$(jq -r '.topics[2]' <<< "$event")")
    local correlation l2_block l2_hash l1_block l1_hash requested
    requested=$(jq -r '.requested_amount // empty' "$RUN_DIR/state.json")
    if [[ $(jq -r '.loan_mode // "fixed"' "$RUN_DIR/state.json") == legacy ]]; then
        requested=$(field requested_minimum)
        [[ "$requested" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid recorded legacy minimum'
        [[ $(bc <<< "$(cast to-dec "$amount") >= $requested") == 1 ]] || fail 'Completed amount is below signed legacy minimum'
    elif [[ -n "$requested" ]]; then
        [[ "$amount" == "$(cast abi-encode 'f(uint256)' "$requested")" ]] || fail 'Completed amount differs from signed request'
    fi
    l2_block=$(jq -er '.blockNumber' <<< "$receipt")
    l2_hash=$(jq -er '.blockHash' <<< "$receipt")
    [[ $(jq -r '.transactionHash' <<< "$receipt") == "$hash" ]] || fail 'L2 receipt hash mismatch'
    local wallet_lower=${WALLET,,}
    [[ $(jq -r '.topics[1][-40:] | ascii_downcase' <<< "$event") == "${wallet_lower:2}" ]] || fail 'Completion belongs to another wallet'
    correlation=$(cast rpc --rpc-url "$L2_RPC" eez_getSettlementByL2Block "$l2_block" 2>/dev/null) || fail 'Cannot verify settlement mapping; no amount-only fallback'
    [[ "$correlation" != null ]] || { echo 'L2 NFT minted; its canonical L1 settlement is pending.'; return; }
    jq -e --arg number "$l2_block" --arg hash "$l2_hash" '
        .canonicalL2==true and .matchedL2Block.number==$number and .matchedL2Block.hash==$hash
        and (.l1TransactionHash | test("^0x[0-9a-fA-F]{64}$"))
        and (.l1BlockHash | test("^0x[0-9a-fA-F]{64}$"))' <<< "$correlation" >/dev/null || fail 'Settlement does not match this canonical L2 block'
    settlement=$(jq -r '.l1TransactionHash' <<< "$correlation")
    l1_block=$(jq -er '.l1BlockNumber' <<< "$correlation")
    l1_hash=$(jq -r '.l1BlockHash' <<< "$correlation")
    cast rpc --rpc-url "$L1_RPC" eth_getTransactionReceipt "$settlement" > "$RUN_DIR/settlement.receipt.json" 2>/dev/null
    jq -e --arg hash "$settlement" --arg block "$l1_block" --arg blockHash "$l1_hash" '
        .status=="0x1" and .transactionHash==$hash and .blockNumber==$block and .blockHash==$blockHash
        ' "$RUN_DIR/settlement.receipt.json" >/dev/null || fail 'Correlated L1 receipt is missing, failed or changed'
    [[ $(cast rpc --rpc-url "$L1_RPC" eth_getBlockByNumber "$l1_block" false 2>/dev/null | jq -r '.hash') == "$l1_hash" ]] || fail 'L1 settlement is no longer canonical'
    topic=$(cast keccak 'FlashLoanExecuted(address,uint256)')
    jq -e --arg borrower "${borrower,,}" --arg amount "$amount" --arg token "${USDC,,}" --arg topic "$topic" '
        any(.logs[]; (.address|ascii_downcase)==$borrower and .topics[0]==$topic and .data==$amount
            and ("0x"+(.topics[1][-40:]|ascii_downcase))==$token)
        ' "$RUN_DIR/settlement.receipt.json" >/dev/null || fail 'Borrower repayment is absent from the correlated settlement'
    printf '%s\n' "$correlation" > "$RUN_DIR/settlement-correlation.json"
    verify true "$token_id"
    require_transfer "$RUN_DIR/settlement.receipt.json" "$USDC" "$VAULT" "$borrower" "$amount"
    require_transfer "$RUN_DIR/settlement.receipt.json" "$USDC" "$borrower" "$L1_BRIDGE" "$amount"
    require_transfer "$RUN_DIR/settlement.receipt.json" "$USDC" "$L1_BRIDGE" "$borrower" "$amount"
    require_transfer "$RUN_DIR/settlement.receipt.json" "$USDC" "$borrower" "$VAULT" "$amount"
    wrapped=$(read_call "$L2_BRIDGE" 'getWrappedToken(address,uint64)(address)' "$USDC" 0 --rpc-url "$L2_RPC")
    zero=0x0000000000000000000000000000000000000000
    require_transfer "$RUN_DIR/trigger.receipt.json" "$wrapped" "$zero" "$executor" "$amount"
    require_transfer "$RUN_DIR/trigger.receipt.json" "$wrapped" "$executor" "$zero" "$amount"
    echo "Verified: $TOKEN_SYMBOL base units $(cast to-dec "$amount"), NFT #$token_id owned by $WALLET"
    echo "L2 transaction: $hash"
    echo "L1 repayment: $settlement"
}
main() {
    local action=${1:-help}
    case "$action" in preflight|deploy|deploy-via-l2|trigger|status) ;; *) echo 'Usage: bash script/balancer/run.sh {preflight|deploy|deploy-via-l2|trigger|status}'; return;; esac
    cd "$BALANCER_ROOT"
    umask 077
    RUN_DIR=${BALANCER_RUN_DIR:-$BALANCER_ROOT/tmp-balancer-mainnet}
    mkdir -p "$RUN_DIR"
    RUN_DIR=$(cd "$RUN_DIR" && pwd)
    exec 9>"$RUN_DIR/run.lock"
    flock -n 9 || fail 'Another runner holds this journal lock'
    source script/e2e/lib/network-config.sh
    load_network_config
    load_balancer_addresses
    set +x
    : "${PK:?Set PK or SOURCE_PK in chain.env}" "${L2_FRONT:?Set L2_FRONT}"
    WALLET=$(cast wallet address --private-key "$PK" 2>/dev/null)
    MAX_FEE_WEI=${BALANCER_MAX_FEE_WEI:-2000000000000000}
    export FOUNDRY_BROADCAST="$RUN_DIR/broadcast"
    if [[ -f "$RUN_DIR/state.json" ]]; then
        [[ $(field wallet) == "$WALLET" ]] || fail 'Journal belongs to another wallet'
    else
        jq -n --arg wallet "$WALLET" '{wallet:$wallet}' > "$RUN_DIR/state.json"
    fi
    preflight
    case "$action" in deploy) deploy;; deploy-via-l2) deploy via-l2;; trigger) trigger;; status) status;; esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
