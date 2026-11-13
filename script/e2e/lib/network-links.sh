#!/usr/bin/env bash
# Exact composer links. RPCs, receipts and canonical checks remain in network-evidence.sh.
_NETWORK_LINKS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

network_links_status() { # source hash -> validated references; keep every raw observation
    local source="$1" front result file rc=0 direction
    front="${L1_FRONT:-}"; direction=inbound
    if [[ "$_TRIGGER_CHAIN" == L2 ]]; then front="${L2_FRONT:-}"; direction=outbound; fi
    [[ -n "$front" ]] || return 3
    mkdir -p "$NETWORK_LINK_DIR/$source" || return 1
    file=$(mktemp "$NETWORK_LINK_DIR/$source/status-XXXXXXXX.json") || return 1
    result=$(NETWORK_RPC_CAPTURE="$file" network_rpc "$front" eez_getCrossChainTransaction "[\"$source\"]") || rc=$?
    (( rc == 0 )) || return "$rc"
    [[ "$result" != null ]] || return 2
    jq -e --arg source "$source" --arg direction "$direction" 'type=="object" and
        .hash==$source and .direction==$direction and (.ownership.rejection // null)==null' \
        <<< "$result" >/dev/null || { echo 'Invalid source identity/direction or terminal rejection' >&2; return 1; }
    jq -e 'has("transactions")' <<< "$result" >/dev/null || return 3
    jq -e '(.transactions|type)=="object" and (.transactions.complete|type)=="boolean"' \
        <<< "$result" >/dev/null || return 1
    [[ $(jq -r .transactions.complete <<< "$result") == true ]] || return 2
    jq -ce --arg source "$source" --arg chain "$_TRIGGER_CHAIN" \
        --arg l1 "$(printf '0x%x' "$NETWORK_LINK_L1_ID")" --arg l2 "$(printf '0x%x' "$NETWORK_LINK_L2_ID")" \
        --arg observation "$file" --arg time "$(date -u +%FT%TZ)" \
        -L "$_NETWORK_LINKS_LIB" 'include "network-links"; status($source; $chain; $l1; $l2; $observation; $time)' <<< "$result" || {
            echo 'Invalid transaction links: wrong chain, missing/duplicate reference, or unsupported L1 execution layout' >&2; return 1; }
}

network_links_chain_ids() {
    local chain rpc value expected id
    local -A ids=()
    unset NETWORK_LINK_L1_ID NETWORK_LINK_L2_ID
    for chain in L1 L2; do
        id=''
        while read -r rpc; do
            value=$(network_rpc "$rpc" eth_chainId '[]') || return $?
            value=$(jq -er 'strings|select(test("^0x[0-9a-fA-F]+$"))' <<< "$value") || return 1
            value=$(cast to-dec "$value") || return 1
            [[ -z "$id" || "$id" == "$value" ]] || { echo 'Front/read chain ID mismatch' >&2; return 1; }
            id="$value"
        done < <(network_urls "$chain")
        expected="EXPECTED_${chain}_CHAIN_ID"
        [[ -z "${!expected:-}" || "${!expected}" == "$id" ]] || { echo 'Saved/current chain ID mismatch' >&2; return 1; }
        ids[$chain]="$id"
    done
    # Publish the pair only after both chains and their endpoints validate.
    NETWORK_LINK_L1_ID="${ids[L1]}"
    NETWORK_LINK_L2_ID="${ids[L2]}"
}

network_links_capture() {
    local source record rc artifact archive
    NETWORK_LINKS='[]'; NETWORK_LINKS_ACTIVE=false; NETWORK_LINK_HAS_L2_TABLES=false
    unset E2E_LINK_EVIDENCE
    case "${E2E_TX_LINKS:-required}" in
        off) return 0 ;;
        auto|required) ;;
        *) echo 'E2E_TX_LINKS must be required, auto, or off' >&2; return 1 ;;
    esac
    if [[ "${_HAS_COMPUTE:-true}" != true ]]; then
        [[ "${E2E_TX_LINKS:-required}" != required ]] || { echo 'Required links need ComputeExpected tables' >&2; return 1; }
        echo 'Transaction links: scenario has no table expectations; retaining state-only verification'
        return 0
    fi
    NETWORK_LINK_DIR="${E2E_JOB_DIR:-tmp/e2e-network/${TX_HASHES[0]}}/cross-chain"
    if [[ "${NETWORK_LINK_STARTED:-false}" != true ]]; then
        NETWORK_LINK_STARTED=true
        for source in "${TX_HASHES[@]}"; do
            artifact="$NETWORK_LINK_DIR/$source/verified-links.json"
            if [[ -f "$artifact" ]]; then
                archive=$(mktemp "$NETWORK_LINK_DIR/$source/previous-verified-XXXXXXXX.json") || return 1
                mv "$artifact" "$archive" || return 1
            fi
        done
        if [[ -f "$NETWORK_LINK_DIR/transactions.csv" ]]; then
            archive=$(mktemp "$NETWORK_LINK_DIR/previous-transactions-XXXXXXXX.csv") || return 1
            mv "$NETWORK_LINK_DIR/transactions.csv" "$archive" || return 1
        fi
    fi
    # Cache identities within this process only. Resume always reads them again.
    if [[ -z "${NETWORK_LINK_L1_ID:-}" || -z "${NETWORK_LINK_L2_ID:-}" ]]; then
        network_links_chain_ids || return $?
    fi
    for source in "${TX_HASHES[@]}"; do
        rc=0; record=$(network_links_status "$source") || rc=$?
        if (( rc == 3 )) && [[ "${E2E_TX_LINKS:-required}" == auto ]]; then
            echo 'Transaction links unavailable (unsupported/legacy); compatibility verification uses settlement/content scans'
            NETWORK_LINKS='[]'; return 0
        fi
        (( rc != 3 )) || { echo 'Required transaction links unsupported' >&2; return 1; }
        (( rc == 0 )) || return "$rc"
        NETWORK_LINKS=$(printf '%s\n%s\n' "$NETWORK_LINKS" "$record" | jq -cs '.[0]+[.[1]]') || return 1
    done
    NETWORK_LINKS_ACTIVE=true
}

# Resolve event topics from the compiled contracts; do not duplicate selector/hash constants.
_network_event_topic() { # artifact, event name, verifier constant
    local signature topic verifier_signature verifier_topic
    signature=$(jq -er --arg name "$2" '.abi[]|select(.type=="event" and .name==$name)|
        .name+"("+([.inputs[].type]|join(","))+")"' "$1") || return 1
    topic=$(cast keccak "$signature") || return 1
    # These two verifier constants use literal event signatures. Check the source
    # before associating receipts, so stale artifacts produce an actionable error.
    verifier_signature=$(awk -v name="$3" '
        $0 ~ "bytes32 constant " name "[ =]" {found=1}
        found {print; if ($0 ~ /;/) exit}' "$_NETWORK_LINKS_LIB/../scenarios/shared/Verify.s.sol" |
        sed -n "s/.*keccak256(\"\($2([^\"]*)\)\").*/\1/p")
    [[ -n "$verifier_signature" ]] || { echo "Cannot find verifier topic for $2" >&2; return 1; }
    if [[ "$signature" != "$verifier_signature" ]]; then
        verifier_topic=$(cast keccak "$verifier_signature") || return 1
        echo "Event topic mismatch for $2: artifact=$topic verifier=$verifier_topic; rebuild artifacts (forge build) and check event definitions" >&2
        return 1
    fi
    printf '%s\n' "$topic"
}

network_links_resolve() {
    local chain hash receipt tx evidence='{}' references wanted hints receipts='[]'
    $NETWORK_LINKS_ACTIVE || return 0
    references=$(jq -c '[.[].references[]]|unique_by(.chain,.hash)' <<< "$NETWORK_LINKS") || return 1
    wanted=$(jq -c '[.[]|select(.chain=="L2")|.hash]' <<< "$references")
    hints=$(jq -r '[.[].l2Blocks[].hash]|unique[]' <<< "${_CORRELATIONS:-[]}")
    if [[ "$wanted" != '[]' && -n "$hints" ]]; then
        receipts=$(network_receipts_from_blocks L2 "$wanted" "$hints" true) || receipts='[]'
    fi
    while read -r chain hash; do
        receipt="${NETWORK_RECEIPTS[$chain:$hash]:-}"
        if [[ -z "$receipt" && "$chain" == L2 ]]; then
            receipt=$(jq -c --arg hash "$hash" '.[]|select(.transactionHash==$hash)' <<< "$receipts")
        fi
        [[ -n "$receipt" ]] || receipt=$(network_receipt "$chain" "$hash") || return 2
        network_track_receipt "$chain" "$hash" "$receipt" || return 2
        tx=$(network_transaction "$chain" "$hash" "$receipt") || return 2
        evidence=$(printf '%s\n%s\n%s\n' "$evidence" "$receipt" "$tx" | jq -cs --arg key "$chain:$hash" \
            '.[0]+{($key):{receipt:.[1],transaction:.[2]}}') || return 1
    done < <(jq -r '.[]|[.chain,.hash]|join(" ")' <<< "$references")
    NETWORK_LINK_EVIDENCE="$evidence"
    if [[ -z "${NETWORK_LINK_CONSUMED_TOPIC:-}" ]]; then
        NETWORK_LINK_CONSUMED_TOPIC=$(_network_event_topic out/EEZ.sol/EEZ.json ExecutionConsumed SIG_EXECUTION_CONSUMED_L1) || return 1
        NETWORK_LINK_INCOMING_TOPIC=$(_network_event_topic out/EEZL2.sol/EEZL2.json IncomingCrossChainCallExecuted SIG_INCOMING_CROSSCHAIN_CALL) || return 1
    fi
    # Validate each reference against canonical evidence, retaining every source and role.
    NETWORK_LINKS=$(printf '%s\n%s\n' "$NETWORK_LINKS" "$evidence" | jq -ces \
        --arg manager "${MANAGER_L2,,}" --arg registry "${ROLLUPS,,}" \
        --arg consumed "$NETWORK_LINK_CONSUMED_TOPIC" --arg incoming "$NETWORK_LINK_INCOMING_TOPIC" \
        --arg rollup "$(printf '0x%064x' "$L2_ROLLUP_ID")" \
        -L "$_NETWORK_LINKS_LIB" 'include "network-links"; evidence($manager; $registry; $consumed; $incoming; $rollup)') || return 1
    local table_hashes source_positions blocks
    table_hashes=$(jq -r -L "$_NETWORK_LINKS_LIB" 'include "network-links"; [.[]|.references|map(select(.role=="l2-table-load" or .role=="l2-delivery"))|
        sort_by(position)|.[].hash]|join(",")' <<< "$NETWORK_LINKS")
    source_positions=$(jq -r '.[]|select(.sourceChain=="L2")|.references[]|select(.role=="source")|.blockNumber,.transactionIndex' <<< "$NETWORK_LINKS" |
        while read -r value; do echo "$((value))"; done | paste -sd,)
    [[ -z "$table_hashes" ]] || NETWORK_LINK_HAS_L2_TABLES=true
    blocks=$(jq -r '[.[].references[]|select(.chain=="L2")|.blockNumber]|unique[]' <<< "$NETWORK_LINKS" |
        while read -r number; do echo "$((number))"; done | jq -sc 'unique')
    NETWORK_LINK_POSTS=$(jq -r '[.[].references[]|select(.role=="l1-post-batch")|.hash]|unique[]' <<< "$NETWORK_LINKS")
    # Public verification inputs belong in a file, not an environment string or
    # command argument (Linux limits each of those to 128 KiB).
    local expected
    expected=$(printf '%s\n' "$EXPECTED_L1_TABLE" "$EXPECTED_L1_STEPS" "$EXPECTED_L1_STATIC_TABLE" \
        "$EXPECTED_L2_TABLE" "${EXPECTED_L2_STATIC_TABLE:-0x}" "${EXPECTED_L2_HASHES:-[]}" \
        "${EXPECTED_L2_CALL_HASHES:-[]}" "${EVENTLESS_L2_HASHES:-[]}" | jq -Rsc '
        def hashes: gsub("(?<hash>0x[0-9a-fA-F]+)"; "\"\(.hash)\"")|fromjson;
        split("\n") | {l1Table:.[0],l1Steps:.[1],l1StaticTable:.[2],l2Table:.[3],l2StaticTable:.[4],
            l2EntryHashes:(.[5]|hashes),l2CallHashes:(.[6]|hashes),eventlessHashes:(.[7]|hashes)}') || return 1
    E2E_LINK_EVIDENCE="$(cd "$NETWORK_LINK_DIR" && pwd)/evidence.json"
    export E2E_LINK_EVIDENCE
    printf '%s\n%s\n%s\n' "$NETWORK_LINKS" "$evidence" "$expected" | jq -s \
        --arg hashes "$table_hashes" --argjson positions "[$source_positions]" --argjson blocks "$blocks" '
        .[0] as $records | .[1] as $e | .[2] as $expected |
        ($hashes|split(",")|map(select(length>0))) as $tables |
        ([$records[].references[]|select(.role=="l1-post-batch")|.hash]|unique) as $posts |
        {records:$records,evidence:$e,expected:$expected,
         l1:{hashes:$posts,inputs:[$posts[]|$e["L1:"+.].transaction.input]},l2:{blocks:$blocks,
            allowedTransactions:([$records[].references[]|select(.chain=="L2")|.hash]|unique),
            tableTransactions:$tables,tableInputs:[$tables[]|$e["L2:"+.].transaction.input],
            loaders:[$records[].references[]|select(.role=="l2-table-load")|.hash],sourcePositions:$positions}}' \
        > "$E2E_LINK_EVIDENCE" || return 1
    if [[ "${_CORRELATIONS:-[]}" != '[]' ]]; then
        jq -e --argjson records "$NETWORK_LINKS" 'map(.l1TransactionHash) as $posts |
            all($records[].references[]|select(.role=="l1-post-batch"); .hash as $h|$posts|index($h)!=null)' \
            <<< "$_CORRELATIONS" >/dev/null || { echo 'Posting links contradict settlement correlation' >&2; return 1; }
    fi
}

network_links_recheck() {
    local source fresh old
    $NETWORK_LINKS_ACTIVE || return 0
    while read -r source; do
        fresh=$(network_links_status "$source") || return 2
        old=$(jq -c --arg source "$source" '.[]|select(.sourceHash==$source)' <<< "$NETWORK_LINKS")
        printf '%s\n%s\n' "$old" "$fresh" | jq -se -L "$_NETWORK_LINKS_LIB" \
            'include "network-links"; map(execution_identity)|.[0]==.[1]' >/dev/null || return 2
    done < <(jq -r '.[].sourceHash' <<< "$NETWORK_LINKS")
}

network_links_finish() {
    local record source temp role hash block
    $NETWORK_LINKS_ACTIVE || return 0
    while read -r record; do
        source=$(jq -r .sourceHash <<< "$record")
        temp="$NETWORK_LINK_DIR/$source/verified-links.json.tmp"
        jq '.checks += ["posted-L1-content", "L2-tables-and-events", "canonical-recheck"]' \
            <<< "$record" > "$temp" && mv "$temp" "${temp%.tmp}" || return 1
        echo "Source $(jq -r .sourceChain <<< "$record") transaction: $source"
        while read -r role hash block; do
            case "$role" in
                l2-table-load) echo "L2 system table load: $hash  (block $((block)))" ;;
                l2-delivery) echo "L2 delivery (load+execute): $hash  (block $((block)))" ;;
                l1-execution) echo "L1 execution: $hash  (block $((block)))" ;;
            esac
        done < <(jq -r '.references[]|[.role,.hash,.blockNumber]|join(" ")' <<< "$record")
        if jq -e '.sourceChain=="L1" and ([.references[]|select(.chain=="L2")]|length)==0' <<< "$record" >/dev/null; then
            echo 'No L2 delivery: expected and verified'
        fi
    done < <(jq -c '.[]' <<< "$NETWORK_LINKS")
    { echo 'source_chain,source_hash,chain,transaction_hash,role,block_hash,block_number,transaction_index'
      jq -r '.[]|. as $s|.references[]|[$s.sourceChain,$s.sourceHash,.chain,.hash,.role,.blockHash,.blockNumber,.transactionIndex]|@csv' <<< "$NETWORK_LINKS"
    } > "$NETWORK_LINK_DIR/transactions.csv"
}
