#!/usr/bin/env bash
# Accept direct EEZ settlement or a batcher bound to that EEZ at settlement time.
# EEZ_POST_BATCHER optionally pins the intermediary; it never bypasses eez().
verify_settlement_target() {
    local rpc="$1" block="$2" target="${3,,}" registry="${4,,}"
    local pinned="${EEZ_POST_BATCHER:-}" bound
    pinned="${pinned,,}"
    if [[ ! "$target" =~ ^0x[0-9a-f]{40}$ ]]; then
        echo "invalid settlement destination: $target"; return 1
    fi
    if [[ -n "$pinned" && ! "$pinned" =~ ^0x[0-9a-f]{40}$ ]]; then
        echo "invalid EEZ_POST_BATCHER address: $pinned"; return 1
    fi
    [[ "$target" != "$registry" ]] || return 0
    if [[ -n "$pinned" && "$target" != "$pinned" ]]; then
        echo "destination $target is neither ROLLUPS nor EEZ_POST_BATCHER"; return 1
    fi
    if ! bound=$(cast call "$target" 'eez()(address)' --rpc-url "$rpc" --block "$block" 2>/dev/null); then
        echo "destination $target: eez() lookup failed at block $block"; return 1
    fi
    if [[ "${bound,,}" != "$registry" ]]; then
        echo "destination $target: eez() returned $bound, expected $registry"; return 1
    fi
    echo "accepted EEZ batcher $target (eez() = $registry at block $block)"
}
