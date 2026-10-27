#!/usr/bin/env bash
# Shared live-network configuration. Local Anvil runners do not use discovery.
_COMPOSER_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_COMPOSER_CONFIG_DIR/rollup-id.sh"

load_composer_info() {
    local assignments name value
    [[ -n "${L1_FRONT:-}" ]] || { echo "Set L1_FRONT for eez_composerInfo discovery" >&2; return 1; }
    [[ -n "${L1_RPC:-}" && -n "${L2_RPC:-}" ]] || {
        echo 'load_composer_info requires L1_RPC and L2_RPC for rollup identity validation' >&2; return 1;
    }
    local args=(--l1-front "$L1_FRONT" --l1-rpc "$L1_RPC" --l2-rpc "$L2_RPC" --env)
    assignments=$(bash "$_COMPOSER_CONFIG_DIR/composer-info.sh" "${args[@]}") || return 1
    while IFS='=' read -r name value; do
        case "$name" in
            ROLLUPS|MANAGER_L2|EEZ_ROLLUP_MANAGER|EXPECTED_L1_CHAIN_ID|EXPECTED_L2_CHAIN_ID|COMPOSER_VERSION)
                export "$name=$value" ;;
            *) echo "Unexpected composer configuration field: $name" >&2; return 1 ;;
        esac
    done <<< "$assignments"
    resolve_network_rollup_id "$EEZ_ROLLUP_MANAGER"
}

# Read URLs and credentials separately so direct runners can apply CLI overrides
# before discovery. SOURCE_PK also supports the sequential/single-run drivers.
load_network_env() {
    local env_file="${1:-${DEVNET_ENV:-chain.env}}"
    # A prior discovery is not an assertion for a newly loaded configuration.
    if [[ -n "${EEZ_DISCOVERED_ROLLUP_ID:-}" && "${L2_ROLLUP_ID:-}" == "$EEZ_DISCOVERED_ROLLUP_ID" ]]; then
        unset L2_ROLLUP_ID
    fi
    unset EEZ_DISCOVERED_ROLLUP_ID
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
        # Older snapshots may omit this field; do not inherit another deployment's assertion.
        EEZ_ROLLUP_MANAGER=""
        source "$snapshot/devnet.env" || return 1
        export ROLLUPS MANAGER_L2 EEZ_POST_BATCHER
        resolve_network_rollup_id "${EEZ_ROLLUP_MANAGER:-}" || return 1
    else
        load_composer_info || return 1
    fi
}

# Read-only calls: at most three 20-second attempts, retrying only transport failures.
# Contract reverts, malformed results and identity mismatches remain terminal.
_rollup_rpc_call() {
    local output attempt lower
    for attempt in 1 2 3; do
        if output=$(cast call "$@" --rpc-timeout 20 2>&1); then
            printf '%s\n' "$output"
            return 0
        fi
        lower="${output,,}"
        case "$lower" in
            *'execution reverted'*|*'error code'*|*'server returned an error response'*|*'invalid params'*|\{*)
                printf '%s\n' "$output" >&2; return 1 ;;
            *'error sending request'*|*'connection refused'*|*'connection reset'*|\
                *'connection closed'*|*'connection error'*|*'tcp connect error'*|\
                *'dns error'*|*'dns resolution'*|*'failed to lookup address'*|\
                *'timed out'*|*timeout*|*'http status server error'*|\
                *'http error 5'*|*'http error 429'*)
                if (( attempt < 3 )); then
                    echo "Rollup identity read: transient transport failure; retrying ($attempt/3)" >&2
                    sleep 1
                    continue
                fi ;;
        esac
        printf '%s\n' "$output" >&2
        return 1
    done
}

# Exported to workers only after validation. A CLI override of either endpoint or
# manager address invalidates an inherited composer/snapshot manager assertion.
_rollup_identity_context() {
    printf '%s\n' "$L1_RPC" "$L2_RPC" "${ROLLUPS,,}" "${MANAGER_L2,,}" "${EEZ_ROLLUP_MANAGER:-}"
}

# Bind the L2 immutable identity to the L1 registry and composer deployment.
# An explicit/snapshotted ID is an assertion, never a replacement for discovery.
resolve_network_rollup_id() {
    local discovered registered configured expected_manager="${1:-}"
    local requested_id="${L2_ROLLUP_ID:-}" inferred=false current_context
    [[ -n "${L2_RPC:-}" && -n "${L1_RPC:-}" && -n "${MANAGER_L2:-}" && -n "${ROLLUPS:-}" ]] || {
        echo 'Rollup discovery requires L1/L2 RPCs and manager addresses' >&2; return 1;
    }
    current_context=$(_rollup_identity_context)
    if [[ $# == 0 && -n "${EEZ_ROLLUP_IDENTITY_CONTEXT:-}" &&
          "$EEZ_ROLLUP_IDENTITY_CONTEXT" == "$current_context" ]]; then
        expected_manager="${EEZ_ROLLUP_MANAGER:-}"
    fi
    if [[ -n "${EEZ_DISCOVERED_ROLLUP_ID:-}" && "$requested_id" == "$EEZ_DISCOVERED_ROLLUP_ID" ]]; then
        inferred=true
        # Workers retain the discovered assertion only for the same deployment.
        if [[ "${EEZ_ROLLUP_IDENTITY_CONTEXT:-}" != "$current_context" ]]; then
            requested_id=""
        fi
    fi
    discovered=$(_rollup_rpc_call "$MANAGER_L2" 'ROLLUP_ID()(uint64)' --rpc-url "$L2_RPC") || return 1
    discovered=${discovered%% *}
    discovered=$(_canonical_rollup_id "$discovered") || {
        echo 'Invalid discovered L2 rollup ID' >&2; return 1;
    }
    if [[ -n "$requested_id" ]]; then
        configured=$(_canonical_rollup_id "$requested_id") || {
            echo 'Invalid configured L2_ROLLUP_ID' >&2; return 1;
        }
        [[ "$configured" == "$discovered" ]] || {
            echo "Configured L2_ROLLUP_ID=$L2_ROLLUP_ID disagrees with L2 manager ROLLUP_ID=$discovered" >&2; return 1;
        }
    fi
    registered=$(_rollup_rpc_call "$ROLLUPS" 'rollups(uint64)(address,bytes32,uint256)' "$discovered" --rpc-url "$L1_RPC") || return 1
    registered=${registered%%$'\n'*}
    [[ "$registered" =~ ^0x[[:xdigit:]]{40}$ && "${registered,,}" != 0x0000000000000000000000000000000000000000 ]] || {
        echo "L2 rollup $discovered is not registered on L1" >&2; return 1;
    }
    [[ -z "$expected_manager" || "${registered,,}" == "${expected_manager,,}" ]] || {
        echo "L1 rollup $discovered manager disagrees with composer/snapshot identity" >&2; return 1;
    }
    if [[ "$inferred" == true || -z "$requested_id" ]]; then
        export EEZ_DISCOVERED_ROLLUP_ID="$discovered"
    else
        unset EEZ_DISCOVERED_ROLLUP_ID
    fi
    export L2_ROLLUP_ID="$discovered"
    export EEZ_ROLLUP_MANAGER="$registered"
    EEZ_ROLLUP_IDENTITY_CONTEXT=$(_rollup_identity_context)
    export EEZ_ROLLUP_IDENTITY_CONTEXT
}
