#!/usr/bin/env bash
# Read-only network evidence. Return codes: 2 pending/changed, 3 unsupported,
# 4 transport/index unavailable, 1 malformed. Only -32601 disables correlation.
declare -A NETWORK_BLOCKS=()
declare -A NETWORK_RECEIPTS=()

network_time_left() {
    local left=$(( ${NETWORK_VERIFY_DEADLINE:-$(( $(date +%s) + 15 ))} - $(date +%s) ))
    (( left > 0 )) || return 1
    echo "$left"
}
network_retry() {
    local left
    left=$(network_time_left) || { echo "ERROR: network verification deadline expired: $*" >&2; return 1; }
    echo "Waiting for fresh network evidence: $*" >&2
    (( left > 2 )) && left=2
    sleep "$left"
}
_eez_rpc() {
    local left
    left=$(network_time_left) || return 1
    (( left > 15 )) && left=15
    curl -fsS --connect-timeout "$left" --max-time "$left" -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1"
}
network_rpc() {
    local out code
    out=$(_eez_rpc "$1" "$2" "$3" 2>/dev/null) || return 4
    [[ -z "${NETWORK_RPC_CAPTURE:-}" ]] || printf '%s\n' "$out" > "$NETWORK_RPC_CAPTURE" || return 1
    jq -e 'type=="object" and .jsonrpc=="2.0" and .id==1' <<< "$out" >/dev/null 2>&1 || return 1
    if jq -e '.error!=null' <<< "$out" >/dev/null; then
        code=$(jq -r '.error.code' <<< "$out")
        case "$code" in
            -32601) return 3 ;;
            -32001) return 2 ;;
            -32602) echo "Invalid parameters for $2" >&2; return 1 ;;
            *) return 4 ;;
        esac
    fi
    jq -e 'has("result")' <<< "$out" >/dev/null || return 1
    jq -c '.result' <<< "$out"
}
# Requests are bounded and identified independently; servers may reorder replies.
network_batch_rpc() { # RPC, method, array of positional-parameter arrays -> ordered results
    local rpc="$1" method="$2" params="$3" count offset chunk payload out results='[]' part left code item
    count=$(jq -er 'if type=="array" then length else error("params must be an array") end' <<< "$params") || return 1
    for ((offset=0; offset<count; offset+=100)); do
        chunk=$(jq -c --argjson start "$offset" '.[$start:$start+100]' <<< "$params") || return 1
        payload=$(jq -c --arg method "$method" 'to_entries|map({
            jsonrpc:"2.0",id:(.key+1),method:$method,params:.value})' <<< "$chunk") || return 1
        left=$(network_time_left) || return 4
        (( left > 15 )) && left=15
        out=$(printf '%s' "$payload" | curl -fsS --connect-timeout "$left" --max-time "$left" \
            -H 'Content-Type: application/json' --data @- "$rpc" 2>/dev/null) || return 4
        if jq -e 'type=="object" and .error.code==-32600' <<< "$out" >/dev/null 2>&1; then
            # A transport that explicitly rejects batches can still serve ordinary RPCs.
            part='[]'
            while read -r item; do
                item=$(network_rpc "$rpc" "$method" "$item") || return $?
                part=$(printf '%s\n%s\n' "$part" "$item" | jq -cs '.[0]+[.[1]]') || return 1
            done < <(jq -c '.[]' <<< "$chunk")
        else
            jq -e --argjson requests "$payload" 'type=="array" and
                (map(.id)|sort)==($requests|map(.id)|sort) and
                all(.[]; .jsonrpc=="2.0" and (has("result") or .error!=null))' \
                <<< "$out" >/dev/null 2>&1 || return 1
            if jq -e 'any(.[]; .error!=null)' <<< "$out" >/dev/null; then
                code=$(jq -r '[.[]|select(.error!=null)|.error.code][0]' <<< "$out")
                case "$code" in
                    -32601) return 3 ;;
                    -32001) return 2 ;;
                    -32602) return 1 ;;
                    *) return 4 ;;
                esac
            fi
            part=$(jq -c 'sort_by(.id)|map(.result)' <<< "$out") || return 1
        fi
        # Keep response bodies on stdin when combining chunks, avoiding the
        # shell's per-argument size limit.
        results=$(printf '%s\n%s\n' "$results" "$part" | jq -cs 'add') || return 1
    done
    echo "$results"
}
network_headers() { # chain, array of [hex block number, false] -> validated headers
    local chain="$1" params="$2" rpc headers number hash
    [[ "$params" != '[]' ]] || { echo '[]'; return 0; }
    while read -r rpc; do
        headers=$(network_batch_rpc "$rpc" eth_getBlockByNumber "$params") || continue
        if jq -e --argjson params "$params" 'length==($params|length) and
            all(to_entries[]; .key as $i | .value |
                type=="object" and .number==$params[$i][0] and
                (.hash|test("^0x[0-9a-fA-F]{64}$")))' <<< "$headers" >/dev/null 2>&1; then
            echo "$headers"; return 0
        fi
        # A partial primary response must not hide a known reorg behind a
        # complete but stale fallback. Check every usable header before trying it.
        while read -r number hash; do
            network_track_block "$chain" "$number" "$hash" || return 75
        done < <(jq -r --argjson params "$params" 'to_entries[] |
            .key as $i | .value | select(type=="object") |
            select(.number==$params[$i][0] and (.hash|type)=="string") |
            select(.hash|test("^0x[0-9a-fA-F]{64}$")) | [.number,.hash]|join(" ")' <<< "$headers")
    done < <(network_urls "$chain")
    return 2
}

network_urls() {
    if [[ "$1" == L1 ]]; then
        printf '%s\n' "${L1_RPC:-$RPC}" "${L1_FRONT:-${L1_RPC:-$RPC}}"
    else
        printf '%s\n' "$L2_RPC" "${L2_FRONT:-$L2_RPC}"
    fi | awk '!seen[$0]++'
}
network_header() {
    local chain="$1" selector="$2" rpc header
    while read -r rpc; do
        header=$(network_rpc "$rpc" eth_getBlockByNumber "[\"$selector\",false]") || continue
        if jq -e 'type=="object" and (.hash|test("^0x[0-9a-fA-F]{64}$")) and
            (.number|test("^0x[0-9a-fA-F]+$"))' <<< "$header" >/dev/null 2>&1; then
            echo "$header"; return 0
        fi
    done < <(network_urls "$chain")
    return 2
}
network_track_block() {
    local chain="$1" number="$2" hash="$3" key
    number=$((number)); key="$chain:$number"
    if [[ -n "${NETWORK_BLOCKS[$key]:-}" && "${NETWORK_BLOCKS[$key]}" != "$hash" ]]; then
        NETWORK_UNSTABLE=true
        return 2
    fi
    NETWORK_BLOCKS[$key]="$hash"
}
network_track_receipt() {
    local chain="$1" tx="$2" receipt="$3" number hash
    read -r number hash < <(jq -r '[.blockNumber,.blockHash]|join(" ")' <<< "$receipt")
    network_track_block "$chain" "$number" "$hash" || return 2
    NETWORK_RECEIPTS["$chain:$tx"]="$receipt"
}
network_evidence_check() {
    local chain key number expected params headers
    [[ "${NETWORK_UNSTABLE:-false}" == false ]] || return 75
    for chain in L1 L2; do
        expected=$(
            for key in "${!NETWORK_BLOCKS[@]}"; do
                [[ "$key" == "$chain:"* ]] || continue
                number="${key#*:}"
                printf '0x%x %s\n' "$number" "${NETWORK_BLOCKS[$key]}"
            done | jq -Rsc 'split("\n")|map(select(length>0)|split(" ")|{number:.[0],hash:.[1]})'
        ) || return 75
        [[ "$expected" != '[]' ]] || continue
        params=$(jq -c 'map([.number,false])' <<< "$expected") || return 75
        headers=$(network_headers "$chain" "$params") || return 75
        jq -e --argjson expected "$expected" 'map({number,hash})==$expected' <<< "$headers" >/dev/null || return 75
    done
}
_network_valid_receipt() {
    jq -e --arg tx "$1" 'type=="object" and .transactionHash==$tx and
        (.blockHash|test("^0x[0-9a-fA-F]{64}$")) and
        (.blockNumber|test("^0x[0-9a-fA-F]+$")) and
        (.status=="0x0" or .status=="0x1")' <<< "$2" >/dev/null 2>&1
}
_network_canonical_receipt() {
    local header
    _network_valid_receipt "$2" "$3" || return 2
    header=$(network_header "$1" "$(jq -r .blockNumber <<< "$3")") || return 2
    [[ $(jq -r .hash <<< "$header") == "$(jq -r .blockHash <<< "$3")" ]] || return 2
    echo "$3"
}
network_receipt() { # chain, tx hash, optional exact block hint; one bounded sweep
    local chain="$1" tx="$2" hint="${3:-}" rpc receipt obj block receipts
    local urls=() hints=()
    mapfile -t urls < <(network_urls "$chain")
    [[ -z "$hint" ]] || mapfile -t hints <<< "$hint"
    for rpc in "${urls[@]}"; do
        receipt=$(network_rpc "$rpc" eth_getTransactionReceipt "[\"$tx\"]") || continue
        if _network_canonical_receipt "$chain" "$tx" "$receipt"; then return 0; fi
    done
    # Some providers serve canonical blocks but have incomplete tx-hash indexes.
    for rpc in "${urls[@]}"; do
        obj=$(network_rpc "$rpc" eth_getTransactionByHash "[\"$tx\"]") || continue
        block=$(jq -r --arg tx "$tx" 'select(.hash==$tx)|.blockHash // empty' <<< "$obj")
        [[ "$block" =~ ^0x[0-9a-fA-F]{64}$ ]] && hints+=("$block")
    done
    # The status reference is L1 even for an L2 source, so only use it on L1.
    if [[ "$chain" == L1 && ${#hints[@]} -eq 0 && -n "${L1_FRONT:-}" ]]; then
        obj=$(network_rpc "$L1_FRONT" eez_getCrossChainTransaction "[\"$tx\"]") || obj=null
        block=$(jq -r --arg tx "$tx" 'select(.hash==$tx)|.ownership.canonical.hash // empty' <<< "$obj")
        [[ "$block" =~ ^0x[0-9a-fA-F]{64}$ ]] && hints+=("$block")
    fi
    for block in "${hints[@]}"; do
        for rpc in "${urls[@]}"; do
            receipts=$(network_rpc "$rpc" eth_getBlockReceipts "[\"$block\"]") || continue
            receipt=$(jq -ce --arg tx "$tx" --arg block "$block" '
                [ .[] | select(.transactionHash==$tx and .blockHash==$block) ] |
                select(length==1) | .[0]' <<< "$receipts" 2>/dev/null) || continue
            if _network_canonical_receipt "$chain" "$tx" "$receipt"; then return 0; fi
        done
    done
    return 2
}
# Read known delivery blocks once per pass instead of rereading the same header
# for every transaction. Failure leaves the individual receipt path available.
network_receipts_from_blocks() { # chain, JSON tx hashes, newline-delimited block hashes
    local chain="$1" wanted="$2" hints="$3" full="${4:-false}" block rpc out receipts header found='[]'
    [[ "$wanted" != '[]' && -n "$hints" ]] || return 2
    while read -r block; do
        [[ -n "$block" ]] || continue
        while read -r rpc; do
            out=$(network_rpc "$rpc" eth_getBlockReceipts "[\"$block\"]") || continue
            receipts=$(jq -ce --argjson wanted "$wanted" --arg block "$block" --argjson full "$full" '
                select(type=="array") |
                [.[] | select(.transactionHash as $tx | $wanted | index($tx))] |
                select(all(.[]; .blockHash==$block and
                    (.blockNumber|test("^0x[0-9a-fA-F]+$")) and
                    (.status=="0x0" or .status=="0x1"))) |
                select((map(.transactionHash)|unique|length)==length) |
                map(if $full then . else {transactionHash,blockHash,blockNumber,transactionIndex,status,to} end)' \
                <<< "$out" 2>/dev/null) || continue
            [[ "$receipts" != '[]' ]] || break
            header=$(network_header "$chain" "$(jq -r '.[0].blockNumber' <<< "$receipts")") || return 2
            jq -e --arg block "$block" --argjson header "$header" '
                $header.hash==$block and all(.[]; .blockNumber==$header.number)' \
                <<< "$receipts" >/dev/null || return 2
            found=$(printf '%s\n%s\n' "$found" "$receipts" | jq -cs 'add') || return 2
            break
        done < <(network_urls "$chain")
    done <<< "$hints"
    # Every requested transaction must occur exactly once, even across blocks.
    jq -e --argjson wanted "$wanted" '(map(.transactionHash)|sort)==($wanted|sort)' \
        <<< "$found" >/dev/null || return 2
    echo "$found"
}
network_transaction() { # chain, hash, canonical receipt -> transaction tied to that inclusion
    local chain="$1" tx="$2" receipt="$3" rpc obj block index
    block=$(jq -r .blockHash <<< "$receipt"); index=$(jq -r .transactionIndex <<< "$receipt")
    while read -r rpc; do
        obj=$(network_rpc "$rpc" eth_getTransactionByHash "[\"$tx\"]") || obj=null
        if ! jq -e --arg tx "$tx" '.hash==$tx and (.input|type)=="string"' <<< "$obj" >/dev/null 2>&1; then
            obj=$(network_rpc "$rpc" eth_getTransactionByBlockHashAndIndex "[\"$block\",\"$index\"]") || continue
        fi
        jq -e --arg tx "$tx" --arg block "$block" --arg index "$index" \
            '.hash==$tx and .blockHash==$block and .transactionIndex==$index and
             (.input|test("^0x([0-9a-fA-F]{2})*$"))' <<< "$obj" >/dev/null 2>&1 || continue
        echo "$obj"; return 0
    done < <(network_urls "$chain")
    return 2
}
network_transaction_input() {
    local tx
    tx=$(network_transaction "$@") || return $?
    jq -r .input <<< "$tx"
}
eez_correlation_detect() {
    local rpc rc found=false transient=false
    EEZ_CORR_RPC=""
    [[ "${E2E_CORRELATION:-auto}" != off ]] || return 0
    for rpc in "${L2_FRONT:-}" "${L1_FRONT:-}"; do
        [[ -n "$rpc" ]] || continue
        rc=0
        network_rpc "$rpc" eez_getSettlementByL2Block '["0x1"]' >/dev/null || rc=$?
        case "$rc" in
            0|2) EEZ_CORR_RPC="$rpc"; return 0 ;;
            3) found=true ;;
            4) transient=true ;;
            *) return 1 ;;
        esac
    done
    if $transient; then return 2; fi
    if $found; then echo "Settlement correlation unsupported on Composer fronts; using content scans"; fi
}
eez_settlement_by_l2_block() { # RPC, exact block hash -> JSON
    local out rc=0
    out=$(network_rpc "$1" eez_getSettlementByL2Block "[{\"blockHash\":\"$2\"}]") || rc=$?
    (( rc == 0 )) || return "$rc"
    [[ "$out" != null ]] || return 2
    jq -e --arg hash "$2" '.matchedL2Block.hash==$hash and .canonicalL2==true' <<< "$out" >/dev/null || return 2
    echo "$out"
}
eez_l2_ranges_by_l1_block() { # RPC, exact block hash -> JSON array
    local out rc=0
    out=$(network_rpc "$1" eez_getSettledL2RangesByL1Block "[{\"blockHash\":\"$2\"}]") || rc=$?
    (( rc == 0 )) || return "$rc"
    jq -e 'type=="array"' <<< "$out" >/dev/null || return 1
    jq -e 'length>0' <<< "$out" >/dev/null || return 2
    jq -e --arg hash "$2" 'all(.[]; .l1BlockHash==$hash)' <<< "$out" >/dev/null || return 1
    echo "$out"
}
network_refresh_triggers() {
    local tx receipt number hash
    TX_BLOCK_NUMBERS=(); TX_BLOCK_HASHES=()
    for tx in "${TX_HASHES[@]}"; do
        receipt=$(network_receipt "$_TRIGGER_CHAIN" "$tx") || return 2
        network_track_receipt "$_TRIGGER_CHAIN" "$tx" "$receipt" || return 2
        [[ $(jq -r .status <<< "$receipt") == 0x1 ]] || {
            echo "ERROR: trigger reverted: $tx" >&2; return 1; }
        read -r number hash < <(jq -r '[.blockNumber,.blockHash]|join(" ")' <<< "$receipt")
        TX_BLOCK_NUMBERS+=("$((number))"); TX_BLOCK_HASHES+=("$hash")
    done
    TX_HASH="${TX_HASHES[0]}"
    TX_BLOCK_NUMBER=$(printf '%s\n' "${TX_BLOCK_NUMBERS[@]}" | sort -n | head -1)
    _UNIQ_BLOCKS=$(printf '%s\n' "${TX_BLOCK_NUMBERS[@]}" | sort -un | paste -sd,)
    L1_BLOCK=""; L2_BLOCK=""; L1_BATCH_TX=""
    if [[ "$_TRIGGER_CHAIN" == L1 ]]; then L1_BLOCK="$TX_BLOCK_NUMBER"; else L2_BLOCK="$TX_BLOCK_NUMBER"; fi
}
network_resolve_correlations() {
    local block out item receipt tx number hash i
    _CORRELATIONS='[]'; _CORR_TX=""; _CORR_BLOCK=""; _CORR_LAST=""
    [[ -n "$EEZ_CORR_RPC" ]] || return 0
    for i in "${!TX_BLOCK_HASHES[@]}"; do
        block="${TX_BLOCK_HASHES[$i]}"
        if [[ "$_TRIGGER_CHAIN" == L2 ]]; then
            out=$(eez_settlement_by_l2_block "$EEZ_CORR_RPC" "$block") || return $?
            jq -e '.matchedL2Block.number|test("^0x[0-9a-fA-F]+$")' <<< "$out" >/dev/null 2>&1 || return 1
            [[ $(( $(jq -r .matchedL2Block.number <<< "$out") )) == "${TX_BLOCK_NUMBERS[$i]}" ]] || return 1
            out="[$out]"
        else
            out=$(eez_l2_ranges_by_l1_block "$EEZ_CORR_RPC" "$block") || return $?
        fi
        # Historical non-canonical records can coexist with the current batch.
        out=$(jq -c '[.[]|select(.canonicalL2==true)]' <<< "$out") || return 1
        [[ "$out" != '[]' ]] || return 2
        _CORRELATIONS=$(jq -cn --argjson old "$_CORRELATIONS" --argjson new "$out" '$old+$new|unique_by(.l1TransactionHash)')
    done
    jq -e 'all(.[]; (.l1TransactionHash|test("^0x[0-9a-fA-F]{64}$")) and
        (.l1BlockHash|test("^0x[0-9a-fA-F]{64}$")) and
        (.l1BlockNumber|test("^0x[0-9a-fA-F]+$")) and
        (.l2Blocks|type)=="array" and (.l2Blocks|length)>0 and
        all(.l2Blocks[]; (.hash|test("^0x[0-9a-fA-F]{64}$")) and (.number|test("^0x[0-9a-fA-F]+$"))))' \
        <<< "$_CORRELATIONS" >/dev/null 2>&1 || return 1
    while read -r item; do
        tx=$(jq -r .l1TransactionHash <<< "$item")
        receipt=$(network_receipt L1 "$tx" "$(jq -r .l1BlockHash <<< "$item")") || return 2
        jq -e --argjson corr "$item" '.status=="0x1" and .blockHash==$corr.l1BlockHash and
            .blockNumber==$corr.l1BlockNumber' <<< "$receipt" >/dev/null || return 2
        network_track_receipt L1 "$tx" "$receipt" || return 2
    done < <(jq -c '.[]' <<< "$_CORRELATIONS")
    _CORR_TX=$(jq -r '.[].l1TransactionHash' <<< "$_CORRELATIONS")
    local numbers=()
    while read -r number; do numbers+=("$((number))"); done < <(jq -r '.[].l1BlockNumber' <<< "$_CORRELATIONS")
    _CORR_BLOCK=$(printf '%s\n' "${numbers[@]}" | sort -n | head -1)
    _CORR_LAST=$(printf '%s\n' "${numbers[@]}" | sort -n | tail -1)
}
network_correlated_l2_blocks() {
    local tx item number hash selected='[]' blocks candidates=''
    for tx in "${L1_BATCH_TXS[@]}"; do
        item=$(jq -c --arg tx "$tx" '[.[]|select(.l1TransactionHash==$tx)]' <<< "$_CORRELATIONS")
        [[ "$item" != '[]' ]] || return 2
        selected=$(jq -cn --argjson old "$selected" --argjson new "$item" '$old+$new|unique_by(.l1TransactionHash)')
    done
    blocks=$(jq -c '[.[].l2Blocks[]]|unique_by(.number,.hash)' <<< "$selected") || return 1
    [[ "$blocks" != '[]' ]] || return 2
    while read -r number hash; do
        network_track_block L2 "$number" "$hash" || return 2
        candidates+="$((number))"$'\n'
    done < <(jq -r '.[]|[.number,.hash]|join(" ")' <<< "$blocks")
    L2_BLOCKS=$(printf '%s' "$candidates" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)|unique')
}
network_pin_l2_blocks() {
    local params headers number hash
    [[ "$L2_BLOCKS" != '[]' ]] || return 0
    params=$(
        while read -r number; do printf '0x%x\n' "$number"; done < <(jq -r '.[]' <<< "$L2_BLOCKS") |
            jq -Rsc 'split("\n")|map(select(length>0)|[.,false])'
    ) || return 2
    headers=$(network_headers L2 "$params") || return 2
    while read -r number hash; do
        network_track_block L2 "$number" "$hash" || return 2
    done < <(jq -r '.[]|[.number,.hash]|join(" ")' <<< "$headers")
}
