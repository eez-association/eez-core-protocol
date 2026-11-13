#!/usr/bin/env bash
# Canonical decimal EEZ rollup IDs: nonzero uint64, distinct from chain IDs.
_canonical_rollup_id() {
    local id="$1" max_id=18446744073709551615 LC_ALL=C
    [[ "$id" =~ ^[0-9]+$ ]] || return 1

    # Strip leading zeros without interpreting the ID as a signed Bash integer.
    while [[ "$id" == 0* ]]; do
        id="${id#0}"
    done
    [[ -n "$id" ]] || return 1

    # Decimal strings of equal length sort numerically in the C locale.
    if (( ${#id} > ${#max_id} )); then
        return 1
    fi
    if (( ${#id} == ${#max_id} )) && [[ "$id" > "$max_id" ]]; then
        return 1
    fi
    printf '%s\n' "$id"
}
