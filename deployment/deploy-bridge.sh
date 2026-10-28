#!/usr/bin/env bash
# Bash + cast deployment runner. jq reads compiled artifacts and RPC JSON.
set +x
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
ENV_FILE=chain.env
RUN_DIR=
SALT_PREFIX=eez.bridge
BROADCAST=false
EXPECTED_UPGRADER=
WAIT_SECONDS=120
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: bash deployment/deploy-bridge.sh [chain.env] [options]
  --broadcast            Deploy and configure (default: read-only plan)
  --env FILE             Environment file (default: chain.env)
  --run-dir DIR          Saved transactions (default: tmp/bridge-deploy/<env filename>)
  --salt-prefix PREFIX   CREATE2 salt prefix (default: eez.bridge)
  --upgrade-owner ADDR   Assert that both existing EEZ ProxyAdmins have this owner
  --wait SECONDS         Receipt wait limit (default: 120)

Requires Bash, cast, jq, flock and existing artifacts from `forge build`.
MAX_FEE_GWEI sets the EIP-1559 max-fee ceiling (default: 200).
Priority fee and gas limit use RPC values unchanged; only maxFeePerGas gets 10% headroom.
Loads RPCs and PK/SOURCE_PK from the env file. Discovers EEZ addresses and rollup ID.
Uses the signer as bridge admin and each EEZ ProxyAdmin's owner as bridge upgrader.
Installs missing Arachnid factories, deploys implementations and proxies, configures
once, and verifies results. No Python, Solidity deployment scripts or cross-chain triggers.
Keep the run directory: rerunning reuses deployments and the SAME signed transactions.
USAGE
}
while (($#)); do
    case "$1" in
        --env|--run-dir|--salt-prefix|--upgrade-owner|--wait)
            (($# >= 2)) || fail "$1 requires a value"
            case "$1" in
                --env) ENV_FILE=$2;; --run-dir) RUN_DIR=$2;; --salt-prefix) SALT_PREFIX=$2;;
                --upgrade-owner) EXPECTED_UPGRADER=$2;; --wait) WAIT_SECONDS=$2;;
            esac; shift 2;;
        --broadcast) BROADCAST=true; shift;;
        -h|--help) usage; exit 0;;
        --*) fail "Unknown option: $1";;
        *) ENV_FILE=$1; shift;;
    esac
done
for tool in cast jq flock; do command -v "$tool" >/dev/null || fail "Missing tool: $tool"; done
[[ $WAIT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'Invalid --wait value'
[[ -f $ENV_FILE ]] || fail "Missing environment file: $ENV_FILE"
source "$ENV_FILE"
set +x
MAX_FEE_GWEI=${MAX_FEE_GWEI:-200}
[[ $MAX_FEE_GWEI =~ ^[1-9][0-9]{0,8}$ ]] || fail 'MAX_FEE_GWEI must be a positive integer below 1000000000'
MAX_FEE_WEI=$((MAX_FEE_GWEI * 1000000000))
KEY=${PK:-${SOURCE_PK:-}}
[[ $KEY =~ ^(0x)?[[:xdigit:]]{64}$ ]] || fail 'Set SOURCE_PK or PK in the env file'
: "${L1_RPC:?Missing L1_RPC}" "${L2_RPC:?Missing L2_RPC}" "${L1_FRONT:?Missing L1_FRONT}"
# Never print a command's arguments. Sanitize errors before displaying them.
redact() { local line; while IFS= read -r line; do line=${line//"$KEY"/[REDACTED]}; printf '%s\n' "${line//"${KEY#0x}"/[REDACTED]}"; done; }
DEPLOYER=$(cast wallet address --private-key "$KEY" 2> >(redact >&2))
ZERO=0x0000000000000000000000000000000000000000
FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C
FACTORY_SIGNER=0x3fAB184622Dc19b6109349B94811493BF2a45362
FACTORY_HASH=0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
FACTORY_RAW=0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222
IMPLEMENTATION_SALT=$(cast keccak "$SALT_PREFIX.implementation.v1")
PROXY_SALT=$(cast keccak "$SALT_PREFIX.proxy.v1")
IMPL_ARTIFACT=out/Bridge.sol/Bridge.json
PROXY_ARTIFACT=out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json
[[ -f $IMPL_ARTIFACT && -f $PROXY_ARTIFACT ]] || fail 'Missing artifacts. Run forge build first.'
IMPL_CODE=$(jq -er '.bytecode.object' "$IMPL_ARTIFACT")
IMPL_RUNTIME=$(jq -er '.deployedBytecode.object' "$IMPL_ARTIFACT")
PROXY_CODE=$(jq -er '.bytecode.object' "$PROXY_ARTIFACT")
PROXY_RUNTIME=$(jq -er '.deployedBytecode.object' "$PROXY_ARTIFACT")
IMPL_HASH=$(cast keccak "$IMPL_RUNTIME")
PROXY_CODE_HASH=$(cast keccak "$PROXY_CODE")
# Preserve exact source bytes (including final newlines) when checking artifact freshness.
while IFS=$'\t' read -r path hash; do
    [[ -f $path ]] || fail "Artifact source is missing: $path. Rebuild."
    content=$(cat "$path"; printf .); content=${content%.}
    [[ $(cast keccak "$content") == "$hash" ]] || fail "Stale artifact: $path. Run forge build first."
done < <(jq -r '.metadata.sources | to_entries[] | [.key,.value.keccak256] | @tsv' "$IMPL_ARTIFACT" "$PROXY_ARTIFACT" | sort -u)
unset content

# cast versions may return plain JSON or a JSON envelope.
json() { jq -c 'if type=="object" and has("schema_version") then if .success then .data else error("cast request failed") end else . end | . as $v | if type=="string" then (try fromjson catch $v) else . end'; }
rpc() { local url=$1; shift; cast rpc "$@" --rpc-url "$url" --rpc-timeout 20 --json | json; }
call() { local url=$1; shift; cast call "$@" --rpc-url "$url" --rpc-timeout 20; }
code() { cast code "$2" --rpc-url "$1" --rpc-timeout 20; }
equal() { [[ ${1,,} == "${2,,}" ]]; }
address_ok() { [[ $1 =~ ^0x[[:xdigit:]]{40}$ && ${1,,} != "$ZERO" ]]; }
predict() { local hash; hash=$(cast keccak "0xff${FACTORY#0x}${1#0x}$(cast keccak "$2" | cut -c3-)"); printf '0x%s\n' "${hash: -40}"; }

info=$(rpc "$L1_FRONT" eez_composerInfo)
declare -A RPC CHAIN EEZ UPGRADER BRIDGE COUNTERPART PROXY_INIT
RPC[l1]=$L1_RPC; RPC[l2]=$L2_RPC
CHAIN[l1]=$(jq -er '.supportedNetworks.eezL1' <<<"$info")
CHAIN[l2]=$(jq -er '.supportedNetworks.eezL2' <<<"$info")
EEZ[l1]=$(jq -er '.eezContracts.eezRegistryAddress' <<<"$info")
EEZ[l2]=$(jq -er '.eezContracts.eezL2Address' <<<"$info")
ROLLUP_MANAGER=$(jq -er '.eezContracts.eezRollupManagerAddress' <<<"$info")
[[ -z ${ROLLUPS:-} ]] || equal "$ROLLUPS" "${EEZ[l1]}" || printf 'Using composer L1 EEZ address; env hint is outdated.\n'
[[ -z ${MANAGER_L2:-} ]] || equal "$MANAGER_L2" "${EEZ[l2]}" || printf 'Using composer L2 EEZ address; env hint is outdated.\n'
ROLLUP_ID=$(call "$L2_RPC" "${EEZ[l2]}" 'ROLLUP_ID()(uint64)')
[[ $ROLLUP_ID =~ ^[1-9][0-9]*$ ]] || fail 'Invalid L2 rollup ID'
[[ -z ${L2_ROLLUP_ID:-} || $L2_ROLLUP_ID == "$ROLLUP_ID" ]] || fail 'Env rollup ID differs from EEZL2'
registered=$(call "$L1_RPC" "${EEZ[l1]}" 'rollups(uint64)(address,bytes32,uint256)' "$ROLLUP_ID")
equal "${registered%%$'\n'*}" "$ROLLUP_MANAGER" || fail 'L1 registry/composer rollup mismatch'
[[ $(call "$L1_RPC" "$ROLLUP_MANAGER" 'rollupId()(uint64)') == "$ROLLUP_ID" ]] || fail 'Rollup manager ID mismatch'
equal "$(call "$L1_RPC" "$ROLLUP_MANAGER" 'EEZContract()(address)')" "${EEZ[l1]}" || fail 'Rollup registry mismatch'
IMPLEMENTATION=$(predict "$IMPLEMENTATION_SALT" "$IMPL_CODE")
for chain in l1 l2; do
    [[ $(cast chain-id --rpc-url "${RPC[$chain]}" --rpc-timeout 20) == "${CHAIN[$chain]}" ]] || fail "Wrong chain: $chain"
    address_ok "${EEZ[$chain]}" || fail "Invalid EEZ address: $chain"
    eez_admin=$(cast admin "${EEZ[$chain]}" --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
    UPGRADER[$chain]=$(call "${RPC[$chain]}" "$eez_admin" 'owner()(address)')
    address_ok "${UPGRADER[$chain]}" || fail "Invalid upgrade owner: $chain"
    [[ -z $EXPECTED_UPGRADER ]] || equal "${UPGRADER[$chain]}" "$EXPECTED_UPGRADER" || fail "Unexpected upgrade owner: $chain"
    init=$(cast calldata 'initialize(address)' "$DEPLOYER")
    args=$(cast abi-encode 'f(address,address,bytes)' "$IMPLEMENTATION" "${UPGRADER[$chain]}" "$init")
    PROXY_INIT[$chain]="$PROXY_CODE${args#0x}"
    BRIDGE[$chain]=$(predict "$PROXY_SALT" "${PROXY_INIT[$chain]}")
done
COUNTERPART[l1]=${BRIDGE[l2]}; COUNTERPART[l2]=${BRIDGE[l1]}
if equal "${BRIDGE[l1]}" "${BRIDGE[l2]}"; then COUNTERPART[l1]=$ZERO; COUNTERPART[l2]=$ZERO; fi
RUN_DIR=${RUN_DIR:-"$ROOT/tmp/bridge-deploy/$(basename "$ENV_FILE")"}
mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd)
exec 9>"$RUN_DIR/.lock"; flock -n 9 || fail 'This run directory is already in use'
# Stable public identity: a changed build, signer or owner cannot silently resume an old run.
plan=$(jq -n --arg deployer "$DEPLOYER" --arg implementation "$IMPLEMENTATION" \
    --arg implementationSalt "$IMPLEMENTATION_SALT" --arg proxySalt "$PROXY_SALT" \
    --arg implementationHash "$IMPL_HASH" --arg proxyCodeHash "$PROXY_CODE_HASH" \
    --arg l1Rpc "$L1_RPC" --arg l2Rpc "$L2_RPC" --arg l1Chain "${CHAIN[l1]}" --arg l2Chain "${CHAIN[l2]}" \
    --arg l1EEZ "${EEZ[l1]}" --arg l2EEZ "${EEZ[l2]}" --arg l1Upgrader "${UPGRADER[l1]}" --arg l2Upgrader "${UPGRADER[l2]}" \
    --arg l1Bridge "${BRIDGE[l1]}" --arg l2Bridge "${BRIDGE[l2]}" --arg rollupId "$ROLLUP_ID" \
    '{deployer:$deployer,implementation:$implementation,implementationSalt:$implementationSalt,proxySalt:$proxySalt,implementationHash:$implementationHash,proxyCodeHash:$proxyCodeHash,l1:{rpc:$l1Rpc,chainId:$l1Chain,eez:$l1EEZ,upgrader:$l1Upgrader,bridge:$l1Bridge,rollupId:"0"},l2:{rpc:$l2Rpc,chainId:$l2Chain,eez:$l2EEZ,upgrader:$l2Upgrader,bridge:$l2Bridge,rollupId:$rollupId}}')
if [[ -f $RUN_DIR/plan.json && $(jq -Sc . "$RUN_DIR/plan.json") != "$(jq -Sc . <<<"$plan")" ]]; then
    if compgen -G "$RUN_DIR/*.raw" >/dev/null; then
        fail 'Saved deployment differs. Preserve it; use a different run directory for a new deployment.'
    fi
    cp "$RUN_DIR/plan.json" "$RUN_DIR/plan.previous.json"
fi
printf '%s\n' "$plan" >"$RUN_DIR/plan.json"
printf 'Deployer/admin: %s\nImplementation: %s\nJournal: %s\n' "$DEPLOYER" "$IMPLEMENTATION" "$RUN_DIR"
for chain in l1 l2; do
    printf '%s: chain=%s EEZ=%s upgrader=%s bridge=%s\n' "$chain" "${CHAIN[$chain]}" "${EEZ[$chain]}" "${UPGRADER[$chain]}" "${BRIDGE[$chain]}"
    current=$(code "${RPC[$chain]}" "$FACTORY")
    if [[ $current == 0x ]]; then printf '%s: factory bootstrap needed (0.01 native units for its signer)\n' "$chain"
    else [[ $(cast keccak "$current") == "$FACTORY_HASH" ]] || fail "Unexpected factory code: $chain"; fi
done
if ! $BROADCAST; then printf 'Plan only. Add --broadcast to execute.\n'; exit 0; fi

# Save a signed transaction BEFORE sending it. Resume only republishes that same hash.
publish_saved() {
    local chain=$1 label=$2 raw=$3 hash result tx decoded block deadline=$((SECONDS + WAIT_SECONDS))
    hash=$(cast keccak "$raw")
    result=$(rpc "${RPC[$chain]}" eth_getTransactionReceipt "$hash")
    if [[ $result == null ]]; then
        printf 'Sending %s: %s\n' "$label" "$hash"
        cast publish "$raw" --async --rpc-url "${RPC[$chain]}" --rpc-timeout 20 >/dev/null 2> >(redact >&2) || \
            printf 'Submission uncertain; checking the saved transaction hash.\n'
    fi
    while [[ $result == null ]]; do
        ((SECONDS < deadline)) || fail "$label pending: $hash. Rerun with the same run directory."
        sleep 2
        result=$(rpc "${RPC[$chain]}" eth_getTransactionReceipt "$hash")
    done
    printf '%s\n' "$result" >"$RUN_DIR/$label.receipt.json"
    jq -e '.status=="0x1"' <<<"$result" >/dev/null || fail "Transaction reverted: $hash"
    block=$(rpc "${RPC[$chain]}" eth_getBlockByNumber "$(jq -r '.blockNumber' <<<"$result")" false)
    [[ $(jq -r '.hash' <<<"$block") == "$(jq -r '.blockHash' <<<"$result")" ]] || fail "Receipt is no longer canonical: $hash"
    tx=$(rpc "${RPC[$chain]}" eth_getTransactionByHash "$hash")
    printf '%s\n' "$tx" >"$RUN_DIR/$label.transaction.json"
    decoded=$(cast decode-transaction --json "$raw" | json)
    jq -en --argjson tx "$tx" --argjson signed "$decoded" \
        '$tx.hash==$signed.hash and ($tx.from|ascii_downcase)==($signed.signer|ascii_downcase) and (($tx.to // "")|ascii_downcase)==(($signed.to // "")|ascii_downcase) and $tx.input==$signed.input and $tx.value==$signed.value' >/dev/null || fail "Receipt transaction differs from signed intent: $label"
    printf 'Confirmed %s: %s\n' "$label" "$hash"
}
send() {
    local chain=$1 label=$2 to=$3 data=$4 value=${5:-0} gas base tip total max_fee nonce raw decoded
    if [[ -f $RUN_DIR/$label.raw ]]; then raw=$(cat "$RUN_DIR/$label.raw")
    else
        gas=$(cast estimate "$to" "$data" --from "$DEPLOYER" --value "$value" --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
        base=$(cast base-fee --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
        tip=$(cast to-dec "$(rpc "${RPC[$chain]}" eth_maxPriorityFeePerGas | jq -r .)")
        [[ $base =~ ^[0-9]{1,18}$ && $tip =~ ^[0-9]{1,18}$ ]] || fail "$label: invalid RPC fee values"
        total=$((base + tip))
        # Add 10% to the total max-fee allowance, rounded up to a whole wei.
        max_fee=$((total + (total + 9) / 10))
        ((max_fee <= MAX_FEE_WEI)) || fail "$label: max fee $max_fee wei exceeds cap $MAX_FEE_WEI"
        nonce=$(cast nonce "$DEPLOYER" --block pending --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
        printf '%s: gas limit %s, max fee %s wei, priority fee %s wei\n' "$label" "$gas" "$max_fee" "$tip"
        raw=$(cast mktx "$to" "$data" --value "$value" --chain "${CHAIN[$chain]}" \
            --nonce "$nonce" --gas-limit "$gas" --gas-price "$max_fee" --priority-gas-price "$tip" \
            --private-key "$KEY" --rpc-url "${RPC[$chain]}" --rpc-timeout 20 2> >(redact >&2))
        printf '%s\n' "$raw" >"$RUN_DIR/$label.raw.next"; mv "$RUN_DIR/$label.raw.next" "$RUN_DIR/$label.raw"
    fi
    decoded=$(cast decode-transaction --json "$raw" | json)
    [[ $(jq -r '.type' <<<"$decoded") == 0x2 ]] || fail "$label: expected EIP-1559; inspect the saved transaction before replacing it"
    max_fee=$(cast to-dec "$(jq -r '.maxFeePerGas' <<<"$decoded")")
    [[ $max_fee =~ ^[0-9]{1,18}$ ]] && ((max_fee <= MAX_FEE_WEI)) || fail "$label: saved max fee exceeds the current cap"
    jq -e --arg signer "${DEPLOYER,,}" --arg to "${to,,}" --arg data "$data" \
        --arg value "$(cast to-hex "$value")" --arg chain "$(cast to-hex "${CHAIN[$chain]}")" \
        '(.signer|ascii_downcase)==$signer and (.to|ascii_downcase)==$to and .input==$data and .value==$value and .chainId==$chain' <<<"$decoded" >/dev/null || fail "Saved transaction intent differs: $label"
    publish_saved "$chain" "$label" "$raw"
}
ensure_factory() {
    local chain=$1 current balance
    current=$(code "${RPC[$chain]}" "$FACTORY")
    if [[ $current == 0x ]]; then
        [[ $(cast nonce "$FACTORY_SIGNER" --rpc-url "${RPC[$chain]}" --rpc-timeout 20) == 0 ]] || fail "Factory signer nonce already used: $chain"
        balance=$(cast balance "$FACTORY_SIGNER" --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
        # Padded hexadecimal comparison avoids overflowing Bash on large balances.
        if [[ $(cast to-uint256 "$balance") < $(cast to-uint256 10000000000000000) ]]; then
            send "$chain" "factory-fund-$chain" "$FACTORY_SIGNER" 0x 10000000000000000
        fi
        printf '%s\n' "$FACTORY_RAW" >"$RUN_DIR/factory-create-$chain.raw"
        publish_saved "$chain" "factory-create-$chain" "$FACTORY_RAW"
        current=$(code "${RPC[$chain]}" "$FACTORY")
    fi
    [[ $(cast keccak "$current") == "$FACTORY_HASH" ]] || fail "Factory code mismatch: $chain"
}
verify_proxy() {
    local chain=$1 admin expected=$PROXY_RUNTIME start length word
    equal "$(cast implementation "${BRIDGE[$chain]}" --rpc-url "${RPC[$chain]}" --rpc-timeout 20)" "$IMPLEMENTATION" || fail "Implementation mismatch: $chain"
    admin=$(cast admin "${BRIDGE[$chain]}" --rpc-url "${RPC[$chain]}" --rpc-timeout 20)
    equal "$admin" "$(cast compute-address "${BRIDGE[$chain]}" --nonce 1)" || fail "ProxyAdmin address mismatch: $chain"
    equal "$(call "${RPC[$chain]}" "$admin" 'owner()(address)')" "${UPGRADER[$chain]}" || fail "Upgrade owner mismatch: $chain"
    equal "$(call "${RPC[$chain]}" "${BRIDGE[$chain]}" 'admin()(address)')" "$DEPLOYER" || fail "Bridge admin mismatch: $chain"
    [[ $(jq '.deployedBytecode.immutableReferences | length' "$PROXY_ARTIFACT") == 1 ]] || fail 'Unexpected proxy immutable layout'
    expected=${expected#0x}; word=$(cast to-uint256 "$admin"); word=${word#0x}
    while read -r start length; do
        [[ $length == 32 ]] || fail 'Unexpected proxy immutable width'
        expected="${expected:0:start*2}$word${expected:(start+length)*2}"
    done < <(jq -r '.deployedBytecode.immutableReferences[][] | "\(.start) \(.length)"' "$PROXY_ARTIFACT")
    equal "$(code "${RPC[$chain]}" "${BRIDGE[$chain]}")" "0x$expected" || fail "Proxy runtime mismatch: $chain"
}
for chain in l1 l2; do ensure_factory "$chain"; done
for chain in l1 l2; do
    if [[ $(code "${RPC[$chain]}" "$IMPLEMENTATION") == 0x ]]; then
        send "$chain" "implementation-$chain" "$FACTORY" "$IMPLEMENTATION_SALT${IMPL_CODE#0x}"
    fi
    [[ $(cast keccak "$(code "${RPC[$chain]}" "$IMPLEMENTATION")") == "$IMPL_HASH" ]] || fail "Implementation code mismatch: $chain"
done
for chain in l1 l2; do
    if [[ $(code "${RPC[$chain]}" "${BRIDGE[$chain]}") == 0x ]]; then
        send "$chain" "proxy-$chain" "$FACTORY" "$PROXY_SALT${PROXY_INIT[$chain]#0x}"
    fi
    verify_proxy "$chain"
done
for chain in l1 l2; do
    rid=0; [[ $chain == l1 ]] || rid=$ROLLUP_ID
    if equal "$(call "${RPC[$chain]}" "${BRIDGE[$chain]}" 'EEZContract()(address)')" "$ZERO"; then
        send "$chain" "configure-$chain" "${BRIDGE[$chain]}" "$(cast calldata 'initializeBridge(address,address,uint64)' "${EEZ[$chain]}" "${COUNTERPART[$chain]}" "$rid")"
    fi
    equal "$(call "${RPC[$chain]}" "${BRIDGE[$chain]}" 'EEZContract()(address)')" "${EEZ[$chain]}" || fail "EEZ mismatch: $chain"
    equal "$(call "${RPC[$chain]}" "${BRIDGE[$chain]}" 'canonicalBridgeAddress()(address)')" "${COUNTERPART[$chain]}" || fail "Counterpart mismatch: $chain"
    [[ $(call "${RPC[$chain]}" "${BRIDGE[$chain]}" 'rollupId()(uint64)') == "$rid" ]] || fail "Rollup ID mismatch: $chain"
    verify_proxy "$chain"
    printf '%s bridge verified: %s (rollup %s)\n' "$chain" "${BRIDGE[$chain]}" "$rid"
done
jq '. + {deploymentVerified:true}' "$RUN_DIR/plan.json" >"$RUN_DIR/result.json"
printf 'Complete. Public deployment report: %s/result.json\n' "$RUN_DIR"
