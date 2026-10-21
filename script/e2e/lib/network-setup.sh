#!/usr/bin/env bash

network_deploy_setup() {
    local directory
    directory=$(mktemp -d "${TMPDIR:-/tmp}/eez-setup.XXXXXXXX") || return 1
    _E2E_TEMP_DIRS+=("$directory")
    local FOUNDRY_BROADCAST="$directory/broadcast"
    export FOUNDRY_BROADCAST
    local transactions="$directory/l2-transactions.txt"
    : > "$transactions" || return 1
    deploy_contracts "$@" "$transactions" || return 1
    network_wait_setup "$3" "$transactions"
}

# A successful unsafe receipt can disappear during settlement reconciliation.
# Refresh exact setup hashes and require canonical inclusion at or below safe.
network_wait_setup() {
    local rpc="$1" transactions="$2" timeout="${E2E_SETUP_TIMEOUT:-180}" hashes status
    [[ -s "$transactions" ]] || return 0
    if [[ "${E2E_NO_WAIT_FOR_CONFIRMATION:-false}" == true ]]; then
        echo 'Skipping L2 setup confirmation wait (--no-wait-for-confirmation)' >&2
        return 0
    fi
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid E2E_SETUP_TIMEOUT' >&2; return 1; }
    local NETWORK_VERIFY_DEADLINE=$(( $(date +%s) + timeout ))
    hashes=$(jq -Rsc 'split("\n") | map(select(length>0)) | unique' "$transactions") || return 1
    while network_time_left >/dev/null; do
        if network_setup_settled "$rpc" "$hashes"; then return 0; else status=$?; fi
        [[ "$status" != 1 ]] || return 1
        network_retry 'L2 setup transactions are not canonically settled' || return 1
    done
    echo 'L2 setup settlement deadline expired' >&2
    return 1
}

network_setup_settled() {
    local rpc="$1" hashes="$2" safe receipts headers params status number safe_number
    if safe=$(network_rpc "$rpc" eth_getBlockByNumber '["safe",false]'); then :
    else
        status=$?
        [[ "$status" != 3 ]] || { echo 'L2 setup requires the safe block tag' >&2; return 1; }
        return "$status"
    fi
    [[ "$safe" != null ]] || return 2
    jq -e 'type=="object" and (.number|test("^0x[0-9a-fA-F]+$")) and
        (.hash|test("^0x[0-9a-fA-F]{64}$"))' <<< "$safe" >/dev/null || return 1
    safe_number=$(jq -r .number <<< "$safe")
    params=$(jq -c 'map([.])' <<< "$hashes") || return 1
    receipts=$(network_batch_rpc "$rpc" eth_getTransactionReceipt "$params") || return $?
    jq -e 'all(.[]; .!=null)' <<< "$receipts" >/dev/null || return 2
    jq -e --argjson hashes "$hashes" 'length==($hashes|length) and all(to_entries[];
        .key as $i | .value | type=="object" and .transactionHash==$hashes[$i] and
        (.blockHash|test("^0x[0-9a-fA-F]{64}$")) and
        (.blockNumber|test("^0x[0-9a-fA-F]+$")) and (.status=="0x0" or .status=="0x1"))' \
        <<< "$receipts" >/dev/null || return 1
    while read -r number; do
        (( number <= safe_number )) || return 2
    done < <(jq -r '.[].blockNumber' <<< "$receipts")
    params=$(jq -c --arg safe "$safe_number" 'map([.blockNumber,false])+[[$safe,false]]' \
        <<< "$receipts") || return 1
    headers=$(network_batch_rpc "$rpc" eth_getBlockByNumber "$params") || return $?
    jq -e --argjson receipts "$receipts" --argjson safe "$safe" '
        length==($receipts|length)+1 and .[-1].hash==$safe.hash and .[-1].number==$safe.number and
        all(to_entries[] | select(.key<($receipts|length));
            .key as $i | .value | .hash==$receipts[$i].blockHash and .number==$receipts[$i].blockNumber)' \
        <<< "$headers" >/dev/null || return 2
    jq -e 'all(.[]; .status=="0x1")' <<< "$receipts" >/dev/null || {
        echo 'L2 setup transaction reverted in settled canonical history' >&2
        return 1
    }
}
