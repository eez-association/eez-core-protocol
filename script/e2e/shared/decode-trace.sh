#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Cross-chain trace decoder — schematic view
# ═══════════════════════════════════════════════════════════════════════
#
# Given a tx hash (L1 or L2), produces:
#   1. A schematic CALL FLOW showing contract→contract calls as a tree
#   2. A full decoded trace with smart hex trimming
#
# Uses local project artifacts (--la) for function/event/error decoding,
# plus explorer APIs for any remaining unknown addresses.
#
# Usage:
#   bash script/e2e/shared/decode-trace.sh \
#     --tx <HASH> --l1-rpc <RPC> --l2-rpc <RPC> \
#     --rollups <ADDR> --manager-l2 <ADDR> \
#     [--l1-explorer <URL>] [--l2-explorer <URL>] \
#     [--labels <FILE>] [--no-explorer] [--full-only]
#
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

source "$(dirname "$0")/E2EBase.sh"

# ── Colors (disabled when piped to file) ──
if [[ -t 1 ]]; then
    RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
    CYAN='\033[0;36m' DIM='\033[2m'       BOLD='\033[1m'
    NC='\033[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" DIM="" BOLD="" NC=""
fi

# ── Constants ──
L2_CONTEXT="0x5FbDB2315678afecb367f032d93F642f64180aa3"
SIG_BATCH_POSTED="0xd6f8d71ce42a799b91f399271f4b0e91f85eb87fac7bb2cedd4b3a52fad36182"

# ── Parse args ──
TX_HASH=""
LABELS_FILE=""
NO_EXPLORER=false
FULL_ONLY=false
L1_EXPLORER="https://l1.eez.dev"
L2_EXPLORER="https://l2.eez.dev"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tx)            TX_HASH="$2"; shift 2;;
        --l1-rpc)        L1_RPC="$2"; shift 2;;
        --l2-rpc)        L2_RPC="$2"; shift 2;;
        --rollups)       ROLLUPS="$2"; shift 2;;
        --manager-l2)    MANAGER_L2="$2"; shift 2;;
        --l1-explorer)   L1_EXPLORER="$2"; shift 2;;
        --l2-explorer)   L2_EXPLORER="$2"; shift 2;;
        --labels)        LABELS_FILE="$2"; shift 2;;
        --no-explorer)   NO_EXPLORER=true; shift;;
        --full-only)     FULL_ONLY=true; shift;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in TX_HASH L1_RPC L2_RPC ROLLUPS MANAGER_L2; do
    [[ -n "${!var:-}" ]] || { echo "Missing: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"; exit 1; }
done

# ══════════════════════════════════════════════
#  Label map: address → human name
# ══════════════════════════════════════════════

declare -A LABEL_MAP

# Core contracts
LABEL_MAP["$(echo "$ROLLUPS" | tr '[:upper:]' '[:lower:]')"]="EEZ"
LABEL_MAP["$(echo "$MANAGER_L2" | tr '[:upper:]' '[:lower:]')"]="EEZL2"
LABEL_MAP["$(echo "$L2_CONTEXT" | tr '[:upper:]' '[:lower:]')"]="L2Context"

# Auto-detect from env vars (any VAR=0x... address)
while IFS='=' read -r varname varval; do
    addr_lower=$(echo "$varval" | tr '[:upper:]' '[:lower:]')
    [[ -z "${LABEL_MAP[$addr_lower]:-}" ]] && LABEL_MAP["$addr_lower"]="$varname"
done < <(env | grep -E '^[A-Z][A-Z0-9_]*=0x[0-9a-fA-F]{40}$' || true)

# From --labels file
if [[ -n "$LABELS_FILE" && -f "$LABELS_FILE" ]]; then
    while IFS='=' read -r addr name; do
        [[ -z "$addr" || "$addr" == \#* ]] && continue
        LABEL_MAP["$(echo "$addr" | tr '[:upper:]' '[:lower:]')"]="$name"
    done < "$LABELS_FILE"
fi

# ══════════════════════════════════════════════
#  Explorer: name lookup + ABI fetching
# ══════════════════════════════════════════════

# Temp dir for downloaded ABIs (cleaned up on exit, chained with E2EBase cleanup)
ABI_DIR=$(mktemp -d)
_orig_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
trap "rm -rf '$ABI_DIR'; ${_orig_trap:-true}" EXIT

# selector → "functionName(type1,type2)" map (from fetched ABIs)
declare -A ABI_SELECTOR_MAP

# Lookup contract name via Blockscout v2 API.
# Returns "ContractName" | "EOA" | ""
explorer_lookup() {
    local addr="$1" url="$2"
    local r
    r=$(curl -sL --max-time 3 "${url}/api/v2/addresses/${addr}" 2>/dev/null) || { echo ""; return; }
    local is_contract name
    is_contract=$(echo "$r" | jq -r '.is_contract // false' 2>/dev/null)
    name=$(echo "$r" | jq -r '.name // empty' 2>/dev/null)
    if [[ "$is_contract" == "false" ]]; then echo "EOA"
    elif [[ -n "$name" && "$name" != "null" ]]; then echo "$name"
    else echo ""
    fi
}

# Fetch ABI from Blockscout (etherscan-compatible v1 API) and index selectors.
# Stores ABI in ABI_DIR and populates ABI_SELECTOR_MAP.
fetch_and_index_abi() {
    local addr="$1" explorer="$2"
    local addr_lower
    addr_lower=$(echo "$addr" | tr '[:upper:]' '[:lower:]')

    # Skip if already fetched
    [[ -f "${ABI_DIR}/${addr_lower}.json" ]] && return 0

    local result abi
    result=$(curl -sL --max-time 5 \
        "${explorer}/api?module=contract&action=getabi&address=${addr}" 2>/dev/null) || return 1
    abi=$(echo "$result" | jq -r '.result // empty' 2>/dev/null)

    # Validate: must be a JSON array with at least one entry
    if [[ -z "$abi" || "$abi" == "null" ]] || ! echo "$abi" | jq -e '.[0].type' >/dev/null 2>&1; then
        return 1
    fi

    echo "$abi" > "${ABI_DIR}/${addr_lower}.json"

    # Extract function + error signatures, compute their 4-byte selectors
    local sigs
    sigs=$(echo "$abi" | jq -r '
        .[] | select(.type=="function" or .type=="error") |
        .name + "(" + ([.inputs[].type] | join(",")) + ")"
    ' 2>/dev/null) || return 0

    while IFS= read -r sig; do
        [[ -z "$sig" ]] && continue
        local sel
        sel=$(cast sig "$sig" 2>/dev/null) || continue
        ABI_SELECTOR_MAP["$sel"]="$sig"
    done <<< "$sigs"

    return 0
}

discover_addresses() {
    [[ "$NO_EXPLORER" == true ]] && return
    local tx="$1" rpc="$2"
    echo -e "  ${DIM}Resolving unknown addresses via explorer...${NC}" >&2

    local raw addrs
    raw=$(cast run "$tx" --rpc-url "$rpc" --la 2>&1) || true
    addrs=$(echo "$raw" | grep -oE '0x[0-9a-fA-F]{40}' | sort -uf)

    local count=0 resolved=0 abis=0
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        local lo
        lo=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
        [[ -n "${LABEL_MAP[$lo]:-}" ]] && continue
        count=$((count + 1))

        local name="" found_explorer=""
        for url in "$L1_EXPLORER" "$L2_EXPLORER"; do
            name=$(explorer_lookup "$addr" "$url")
            if [[ -n "$name" && "$name" != "null" ]]; then
                found_explorer="$url"
                break
            fi
        done

        if [[ "$name" == "EOA" ]]; then
            LABEL_MAP["$lo"]="EOA_${addr:0:8}"; resolved=$((resolved + 1))
        elif [[ -n "$name" ]]; then
            LABEL_MAP["$lo"]="$name"; resolved=$((resolved + 1))
            # Verified contract → also fetch ABI for selector decoding
            if fetch_and_index_abi "$addr" "$found_explorer" 2>/dev/null; then
                abis=$((abis + 1))
            fi
        else
            # No name, but still try to fetch ABI (might be verified without name)
            for url in "$L1_EXPLORER" "$L2_EXPLORER"; do
                if fetch_and_index_abi "$addr" "$url" 2>/dev/null; then
                    abis=$((abis + 1)); break
                fi
            done
        fi
    done <<< "$addrs"
    echo -e "  ${DIM}Resolved $resolved/$count addresses, fetched $abis ABIs${NC}" >&2
}

# ══════════════════════════════════════════════
#  Build cast --label flags
# ══════════════════════════════════════════════

LABEL_ARGS=()
build_label_args() {
    LABEL_ARGS=()
    for addr in "${!LABEL_MAP[@]}"; do
        local safe
        safe=$(echo "${LABEL_MAP[$addr]}" | tr ' /:()' '_____')
        LABEL_ARGS+=("--label" "${addr}:${safe}")
    done
}

# ══════════════════════════════════════════════
#  Detect chain
# ══════════════════════════════════════════════

detect_chain() {
    cast tx "$1" blockNumber --rpc-url "$L1_RPC" >/dev/null 2>&1 && { echo "L1"; return; }
    cast tx "$1" blockNumber --rpc-url "$L2_RPC" >/dev/null 2>&1 && { echo "L2"; return; }
    echo "UNKNOWN"
}

echo -e "${DIM}Detecting chain for $TX_HASH...${NC}"
CHAIN=$(detect_chain "$TX_HASH")
[[ "$CHAIN" == "UNKNOWN" ]] && { echo -e "${RED}ERROR: tx not found on L1 or L2${NC}"; exit 1; }
echo -e "Chain: ${BOLD}$CHAIN${NC}"

# Discover addresses on primary chain
if [[ "$CHAIN" == "L1" ]]; then discover_addresses "$TX_HASH" "$L1_RPC"
else discover_addresses "$TX_HASH" "$L2_RPC"; fi
build_label_args

# ══════════════════════════════════════════════
#  Trace post-processing
# ══════════════════════════════════════════════

# Smart hex trimming: only truncate hex > 64 chars (longer than bytes32).
# Keeps first 8 + last 8 hex chars: 0xABCDEF01...89ABCDEF
trim_long_hex() {
    sed -E 's/0x([0-9a-fA-F]{8})[0-9a-fA-F]{50,}([0-9a-fA-F]{8})/0x\1...\2/g'
}

# Resolve selectors that --la couldn't decode.
# Priority: 1) ABI_SELECTOR_MAP (from fetched ABIs)  2) cast 4byte (online lookup)
declare -A SELECTOR_CACHE
resolve_unknown_selectors() {
    local trace="$1"

    # 1. Resolve unresolved function calls: ::0xABCDEF01( pattern
    #    (cast run shows these when it can't decode the function name)
    local fn_sels
    fn_sels=$(echo "$trace" | grep -oE '::[0-9a-fA-F]{8}\(' | grep -oE '[0-9a-fA-F]{8}' | sort -u || true)
    while IFS= read -r raw_sel; do
        [[ -z "$raw_sel" ]] && continue
        local sel="0x${raw_sel}"
        local decoded=""
        # Try fetched ABIs first
        if [[ -n "${ABI_SELECTOR_MAP[$sel]:-}" ]]; then
            decoded="${ABI_SELECTOR_MAP[$sel]%%(*}"   # extract name before (
        elif [[ -n "${SELECTOR_CACHE[$sel]:-}" ]]; then
            decoded="${SELECTOR_CACHE[$sel]%%(*}"
        else
            decoded=$(cast 4byte "$sel" 2>/dev/null | head -1) || true
            [[ -n "$decoded" ]] && SELECTOR_CACHE["$sel"]="$decoded"
            decoded="${decoded%%(*}"
        fi
        if [[ -n "$decoded" ]]; then
            trace=$(echo "$trace" | sed "s|::${raw_sel}(|::${decoded}(|g")
        fi
    done <<< "$fn_sels"

    # 2. Resolve custom errors: "custom error 0xABCDEF01"
    local err_sels
    err_sels=$(echo "$trace" | grep -oE 'custom error 0x[0-9a-fA-F]{8}' | grep -oE '0x[0-9a-fA-F]{8}' | sort -u || true)
    while IFS= read -r sel; do
        [[ -z "$sel" ]] && continue
        local decoded=""
        # Try fetched ABIs first
        if [[ -n "${ABI_SELECTOR_MAP[$sel]:-}" ]]; then
            decoded="${ABI_SELECTOR_MAP[$sel]}"
        elif [[ -n "${SELECTOR_CACHE[$sel]:-}" ]]; then
            decoded="${SELECTOR_CACHE[$sel]}"
        else
            decoded=$(cast 4byte "$sel" 2>/dev/null | head -1) || true
            [[ -n "$decoded" ]] && SELECTOR_CACHE["$sel"]="$decoded"
        fi
        if [[ -n "$decoded" ]]; then
            trace=$(echo "$trace" | sed "s|custom error ${sel}|${decoded}|g")
        fi
    done <<< "$err_sels"

    echo "$trace"
}

# Extract a schematic call-flow tree from raw trace.
# Shows only: calls (Contract::function) and reverts — no events, no returns.
print_call_flow() {
    local trace="$1" label="$2"

    # Collect call/revert lines
    local flow_lines
    flow_lines=$(echo "$trace" | grep -E '(\[[0-9]+\].*::|← \[(Revert|Stop)\])' || true)
    [[ -z "$flow_lines" ]] && return

    echo -e ""
    echo -e "${BOLD}┌─── $label: Call Flow ─────────────────────────────────────${NC}"
    echo -e "│"

    echo "$flow_lines" | while IFS= read -r line; do
        if [[ "$line" =~ ←.*\[Revert\] ]]; then
            # Revert line: extract prefix + error
            local prefix err
            prefix=$(echo "$line" | sed 's/←.*//')
            err=$(echo "$line" | sed 's/.*← \[Revert\] //')
            # Trim error if long
            [[ ${#err} -gt 80 ]] && err="${err:0:77}..."
            echo -e "│${prefix}${RED}✗ REVERT: ${err}${NC}"

        elif [[ "$line" =~ \[([0-9]+)\].*:: ]]; then
            # Call line: extract tree prefix, contract::function, gas, value
            local prefix contract_fn gas value_str=""

            # Tree prefix = everything before the [gas] bracket
            prefix=$(echo "$line" | sed -E 's/\[[0-9]+\].*//')

            # Contract::function (first match)
            contract_fn=$(echo "$line" | grep -oE '[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*' | head -1)
            [[ -z "$contract_fn" ]] && continue

            # Gas
            gas=$(echo "$line" | grep -oE '\[[0-9]+\]' | head -1 | tr -d '[]')

            # ETH value if present: {value: N}
            if [[ "$line" =~ \{value:\ ([0-9]+)\} ]]; then
                value_str=" ${YELLOW}{value: ${BASH_REMATCH[1]}}${NC}"
            fi

            echo -e "│${prefix}${CYAN}→${NC} ${BOLD}${contract_fn}${NC}${value_str} ${DIM}[${gas} gas]${NC}"
        fi
    done

    echo -e "│"
    echo -e "${BOLD}└──────────────────────────────────────────────────────────────${NC}"
}

# ══════════════════════════════════════════════
#  Run and display a trace
# ══════════════════════════════════════════════

run_trace() {
    local tx="$1" rpc="$2" label="$3"

    # Get tx status
    local status status_icon
    status=$(cast receipt "$tx" status --rpc-url "$rpc" 2>/dev/null || echo "?")
    # cast receipt returns "0x1", "1", or "1 (success)" depending on version/chain
    if [[ "$status" =~ ^(0x)?1([[:space:]]|$) ]]; then
        status_icon="${GREEN}✓ success${NC}"
    else
        status_icon="${RED}✗ reverted${NC}"
    fi

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}$label${NC}  ${status_icon}"
    echo -e "  ${DIM}$tx${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"

    # Run trace with local artifacts + internal function decoding
    local raw
    raw=$(cast run "$tx" --rpc-url "$rpc" --la --decode-internal "${LABEL_ARGS[@]}" 2>&1) || true

    # Resolve any selectors that --la couldn't decode (fallback to cast 4byte)
    raw=$(resolve_unknown_selectors "$raw")

    if [[ "$FULL_ONLY" != true ]]; then
        # Schematic call flow (filtered view)
        print_call_flow "$raw" "$label"
    fi

    # Full decoded trace (with smart hex trimming)
    echo ""
    echo -e "${DIM}── Full Trace ─────────────────────────────────────────────${NC}"
    echo "$raw" | trim_long_hex
}

# ══════════════════════════════════════════════
#  Cross-chain block correlation helpers
# ══════════════════════════════════════════════

find_l2_blocks_from_l1_block() {
    local l1_block="$1"
    local batch_tx
    batch_tx=$(cast logs \
        --from-block "$l1_block" --to-block "$l1_block" \
        --address "$ROLLUPS" \
        --rpc-url "$L1_RPC" --json 2>/dev/null \
        | jq -r "[.[] | select(.topics[0] == \"$SIG_BATCH_POSTED\")] | .[0].transactionHash // empty")

    if [[ -z "$batch_tx" ]]; then
        echo "[]"
        return
    fi
    extract_l2_blocks_from_tx "$batch_tx" "$L1_RPC"
}

find_l1_block_from_l2() {
    local l2_block="$1"
    local result
    result=$(cast call "$L2_CONTEXT" "contexts(uint256)(uint256,bytes32)" "$l2_block" \
        --rpc-url "$L2_RPC" 2>/dev/null) || { echo ""; return; }

    local l1_parent
    l1_parent=$(echo "$result" | head -1 | tr -d '[:space:]')
    [[ "$l1_parent" == "0" ]] && { echo ""; return; }
    echo $((l1_parent + 1))
}

find_l2_manager_txs() {
    local l2_block="$1"
    local manager_lower
    manager_lower=$(echo "$MANAGER_L2" | tr '[:upper:]' '[:lower:]')

    local block_json tx_hashes
    block_json=$(cast block "$l2_block" --json --rpc-url "$L2_RPC" 2>/dev/null) || return
    tx_hashes=$(echo "$block_json" | jq -r '.transactions[]' 2>/dev/null) || return

    while IFS= read -r tx; do
        [[ -z "$tx" ]] && continue
        local to
        to=$(cast tx "$tx" to --rpc-url "$L2_RPC" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
        [[ "$to" == "$manager_lower" ]] && echo "$tx"
    done <<< "$tx_hashes"
}

find_l1_batch_tx() {
    local l1_block="$1"
    cast logs \
        --from-block "$l1_block" --to-block "$l1_block" \
        --address "$ROLLUPS" \
        --rpc-url "$L1_RPC" --json 2>/dev/null \
        | jq -r "[.[] | select(.topics[0] == \"$SIG_BATCH_POSTED\")] | .[0].transactionHash // empty"
}

# Discover addresses from cross-chain txs and rebuild labels
discover_cross_chain_addresses() {
    local tx="$1" rpc="$2"
    discover_addresses "$tx" "$rpc"
    build_label_args
}

# ══════════════════════════════════════════════
#  Main: L1 tx flow
# ══════════════════════════════════════════════

if [[ "$CHAIN" == "L1" ]]; then
    L1_BLOCK=$(cast receipt "$TX_HASH" blockNumber --rpc-url "$L1_RPC" 2>/dev/null)
    L1_BLOCK_DEC=$(printf "%d" "$L1_BLOCK")
    TX_STATUS=$(cast receipt "$TX_HASH" status --rpc-url "$L1_RPC" 2>/dev/null)

    echo -e "L1 block: ${BOLD}$L1_BLOCK_DEC${NC} (status: $TX_STATUS)"

    # 1. L1 user tx trace
    run_trace "$TX_HASH" "$L1_RPC" "L1 User TX"

    # 2. L1 batch tx (if different from user tx)
    BATCH_TX=$(find_l1_batch_tx "$L1_BLOCK_DEC")
    if [[ -n "$BATCH_TX" && "$BATCH_TX" != "$TX_HASH" ]]; then
        run_trace "$BATCH_TX" "$L1_RPC" "L1 Batch (postAndVerifyBatch)"
    fi

    # 3. Find L2 blocks and show L2 traces
    L2_BLOCKS=$(find_l2_blocks_from_l1_block "$L1_BLOCK_DEC")
    echo ""
    echo -e "${BOLD}══ L2 Blocks from batch: $L2_BLOCKS ══${NC}"

    if [[ "$L2_BLOCKS" != "[]" && -n "$L2_BLOCKS" ]]; then
        BLOCKS_CSV=$(echo "$L2_BLOCKS" | tr -d '[] ')
        IFS=',' read -ra BLOCK_ARR <<< "$BLOCKS_CSV"
        for b in "${BLOCK_ARR[@]}"; do
            [[ -z "$b" ]] && continue
            echo ""
            echo -e "${BOLD}--- L2 Block $b ---${NC}"

            L2_TXS=$(find_l2_manager_txs "$b")
            if [[ -z "$L2_TXS" ]]; then
                echo -e "  ${DIM}(no EEZL2 txs in block $b)${NC}"
                continue
            fi

            # Discover L2 addresses from first tx
            first_l2_tx=$(echo "$L2_TXS" | head -1)
            [[ -n "$first_l2_tx" ]] && discover_cross_chain_addresses "$first_l2_tx" "$L2_RPC"

            while IFS= read -r l2_tx; do
                [[ -z "$l2_tx" ]] && continue
                run_trace "$l2_tx" "$L2_RPC" "L2 (block $b)"
            done <<< "$L2_TXS"
        done
    fi

# ══════════════════════════════════════════════
#  Main: L2 tx flow
# ══════════════════════════════════════════════

elif [[ "$CHAIN" == "L2" ]]; then
    L2_BLOCK=$(cast receipt "$TX_HASH" blockNumber --rpc-url "$L2_RPC" 2>/dev/null)
    L2_BLOCK_DEC=$(printf "%d" "$L2_BLOCK")
    TX_STATUS=$(cast receipt "$TX_HASH" status --rpc-url "$L2_RPC" 2>/dev/null)

    echo -e "L2 block: ${BOLD}$L2_BLOCK_DEC${NC} (status: $TX_STATUS)"

    # 1. L2 tx trace
    run_trace "$TX_HASH" "$L2_RPC" "L2 User TX"

    # 2. Find L1 batch block via L2Context (parent+1)
    L1_BATCH_BLOCK=$(find_l1_block_from_l2 "$L2_BLOCK_DEC")
    if [[ -n "$L1_BATCH_BLOCK" ]]; then
        echo ""
        echo -e "${BOLD}══ L2 block $L2_BLOCK_DEC → L1 batch block ~$L1_BATCH_BLOCK ══${NC}"

        L1_SEARCH_END=$((L1_BATCH_BLOCK + 4))
        if find_batch_block_by_l2_ref "$L2_BLOCK_DEC" "$L1_BATCH_BLOCK" "$L1_SEARCH_END" "$ROLLUPS" "$L1_RPC" 2>/dev/null; then
            echo -e "Found L1 batch in block ${BOLD}$FOUND_L1_BLOCK${NC} (tx $FOUND_BATCH_TX)"

            discover_cross_chain_addresses "$FOUND_BATCH_TX" "$L1_RPC"

            run_trace "$FOUND_BATCH_TX" "$L1_RPC" "L1 Batch (postAndVerifyBatch, block $FOUND_L1_BLOCK)"

            # Find other user txs in same L1 block
            BLOCK_JSON=$(cast block "$FOUND_L1_BLOCK" --json --rpc-url "$L1_RPC" 2>/dev/null)
            ALL_L1_TXS=$(echo "$BLOCK_JSON" | jq -r '.transactions[]' 2>/dev/null)

            while IFS= read -r l1_tx; do
                [[ -z "$l1_tx" || "$l1_tx" == "$FOUND_BATCH_TX" ]] && continue
                local_status=$(cast receipt "$l1_tx" status --rpc-url "$L1_RPC" 2>/dev/null || echo "?")
                run_trace "$l1_tx" "$L1_RPC" "L1 User TX (block $FOUND_L1_BLOCK, status $local_status)"
            done <<< "$ALL_L1_TXS"
        else
            echo -e "${YELLOW}Could not find L1 batch referencing L2 block $L2_BLOCK_DEC in blocks $L1_BATCH_BLOCK..$L1_SEARCH_END${NC}"
        fi
    else
        echo -e "${YELLOW}Could not resolve L1 parent block from L2Context${NC}"
    fi
fi

echo ""
echo -e "${BOLD}══════ Done ══════${NC}"
