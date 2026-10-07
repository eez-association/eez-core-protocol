#!/usr/bin/env bash
# Shared live-network configuration. Local Anvil runners do not use discovery.
_COMPOSER_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_composer_info() {
    local assignments name value
    [[ -n "${L1_FRONT:-}" ]] || { echo "Set L1_FRONT for eez_composerInfo discovery" >&2; return 1; }
    local args=(--l1-front "$L1_FRONT" --env)
    [[ -z "${L1_RPC:-}" ]] || args+=(--l1-rpc "$L1_RPC")
    [[ -z "${L2_RPC:-}" ]] || args+=(--l2-rpc "$L2_RPC")
    assignments=$(bash "$_COMPOSER_CONFIG_DIR/composer-info.sh" "${args[@]}") || return 1
    while IFS='=' read -r name value; do
        case "$name" in
            ROLLUPS|MANAGER_L2|EEZ_ROLLUP_MANAGER|EXPECTED_L1_CHAIN_ID|EXPECTED_L2_CHAIN_ID|COMPOSER_VERSION)
                export "$name=$value" ;;
            *) echo "Unexpected composer configuration field: $name" >&2; return 1 ;;
        esac
    done <<< "$assignments"
}

# Read URLs and credentials separately so direct runners can apply CLI overrides
# before discovery. SOURCE_PK also supports the sequential/single-run drivers.
load_network_env() {
    local env_file="${1:-${DEVNET_ENV:-chain.env}}"
    if [[ -f "$env_file" ]]; then
        source "$env_file" || return 1
    elif [[ -n "${1:-}${DEVNET_ENV:-}" ]]; then
        echo "Missing environment file: $env_file" >&2; return 1
    fi
    export L1_RPC L2_RPC L1_FRONT L2_FRONT
    export EEZ_POST_BATCHER="${EEZ_POST_BATCHER:-}"
    if [[ -z "${PK:-}" && -n "${SOURCE_PK:-}" ]]; then
        export PK="$SOURCE_PK"
    fi
}

# Composer owns deployment addresses and chain IDs. A saved run snapshot is
# authoritative for resuming its already-signed transactions.
load_network_config() {
    local snapshot="${2:-}"
    load_network_env "${1:-}" || return 1
    if [[ -n "$snapshot" && -f "$snapshot/devnet.env" ]]; then
        source "$snapshot/devnet.env" || return 1
        export ROLLUPS MANAGER_L2 EEZ_POST_BATCHER
    else
        load_composer_info || return 1
    fi
}
