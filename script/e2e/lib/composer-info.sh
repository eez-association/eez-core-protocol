#!/usr/bin/env bash
# Read-only composer discovery. No credentials or env-file parsing.

_composer_rpc() {  # URL, method -> JSON result
    local response
    response=$(curl -fsS --max-time 20 -H 'Content-Type: application/json' "$1" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}") || return 1
    if ! jq -e 'type=="object" and has("result") and (has("error")|not)' <<< "$response" >/dev/null; then
        jq -r '.error.message // "Invalid RPC response"' <<< "$response" >&2
        return 1
    fi
    jq '.result' <<< "$response"
}
_composer_config() {  # JSON on stdin -> validated KEY=value assignments
    jq -er '
        def address($field):
            .eezContracts[$field] |
            if type=="string" and length==42 and test("^0x[0-9a-fA-F]{40}$") and .!="0x0000000000000000000000000000000000000000"
            then . else error("Invalid or missing eezContracts."+$field) end;
        def chain($field):
            .supportedNetworks[$field] |
            if type=="number" and .>0 and .==floor and .<=9007199254740991
            then tostring else error("Invalid or inexact supportedNetworks."+$field) end;
        def version:
            .version | if type=="string" and test("\\A[a-zA-Z0-9.+_-]+\\z")
            then . else error("Invalid or missing composer version") end;
        {
            ROLLUPS: address("eezRegistryAddress"),
            EEZ_ROLLUP_MANAGER: address("eezRollupManagerAddress"),
            MANAGER_L2: address("eezL2Address"),
            EXPECTED_L1_CHAIN_ID: chain("eezL1"),
            EXPECTED_L2_CHAIN_ID: chain("eezL2"),
            COMPOSER_VERSION: version
        } | to_entries[] | "\(.key)=\(.value)"
    '
}
composer_info() {
    local l2_rpc="${L2_RPC:-}" l1_rpc="${L1_RPC:-}" l1_front="${L1_FRONT:-}"
    local env_output=false info assignments url actual expected field i
    while (( $# )); do
        case "$1" in
            --env) env_output=true; shift ;;
            -h|--help)
                echo 'Usage: composer-info.sh --l1-front URL [--l1-rpc URL] [--l2-rpc URL] [--env]'
                return 0 ;;
            --rpc|--l2-rpc|--l1-rpc|--l1-front)
                [[ $# -ge 2 && -n "$2" ]] || { echo "$1 needs a URL" >&2; return 1; }
                case "$1" in
                    --rpc|--l2-rpc) l2_rpc="$2";; --l1-rpc) l1_rpc="$2";;
                    --l1-front) l1_front="$2";;
                esac
                shift 2 ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done
    [[ -n "$l1_front" ]] || { echo 'Provide --l1-front or L1_FRONT' >&2; return 1; }
    info=$(_composer_rpc "$l1_front" eez_composerInfo) || {
        echo 'eez_composerInfo failed on L1_FRONT' >&2; return 1;
    }
    assignments=$(_composer_config <<< "$info") || return 1

    # Metadata comes only from L1_FRONT. Chain RPCs are used only for identity checks.
    local urls labels
    urls=("$l1_rpc" "$l2_rpc"); labels=(EXPECTED_L1_CHAIN_ID EXPECTED_L2_CHAIN_ID)
    for i in "${!urls[@]}"; do
        url="${urls[i]}"; field="${labels[i]}"
        [[ -n "$url" ]] || continue
        actual=$(_composer_rpc "$url" eth_chainId | jq -er 'strings | select(test("^0x[0-9a-fA-F]+$"))') || return 1
        actual=${actual#0x}
        actual=$(printf 'ibase=16;%s\n' "${actual^^}" | BC_LINE_LENGTH=0 bc) || return 1
        expected=$(awk -F= -v key="$field" '$1==key {print $2}' <<< "$assignments")
        [[ "$actual" == "$expected" ]] || { echo "RPC chain ID disagrees with composer $field" >&2; return 1; }
    done
    if $env_output; then printf '%s\n' "$assignments"
    else jq . <<< "$info"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    composer_info "$@"
fi
