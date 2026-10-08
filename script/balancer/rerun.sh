#!/usr/bin/env bash
# A fresh loan attempt against an existing deployment; never deploys contracts.
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run.sh"

latest_attempt() {
    local deployment=$1 name
    if [[ -f "$deployment/reruns/latest" ]]; then
        name=$(cat "$deployment/reruns/latest")
        [[ "$name" =~ ^attempt\.[a-zA-Z0-9]+$ && -d "$deployment/reruns/$name" ]] || fail 'Invalid latest attempt journal'
        printf '%s\n' "$deployment/reruns/$name"
    else
        printf '%s\n' "$deployment"
    fi
}

rerun_loan() {
    local deployment=$1 previous mode raw decoded latest prior_nonce price_floor=0 attempt
    previous=$(latest_attempt "$deployment")
    # Failed checks can leave a journal without a signed transaction. Find the
    # preceding signed attempt so its nonce/fee remains accounted for.
    while [[ "$previous" != "$deployment" && ! -f "$previous/trigger.raw" ]]; do
        local earlier
        earlier=$(jq -er '.previous_attempt' "$previous/state.json")
        [[ "$earlier" == "$deployment" || ( "$earlier" == "$deployment/reruns/attempt."* && "$earlier" != "$previous" && -f "$earlier/state.json" ) ]] || fail 'Invalid previous attempt journal'
        previous=$earlier
    done
    mode=$(jq -r '.loan_mode // (if .requested_amount then "fixed" else "legacy" end)' "$deployment/state.json")
    [[ "$mode" == fixed || "$mode" == legacy ]] || fail 'Unknown deployment loan mode'
    # A lost/dropped attempt may still have the current nonce. If so, a fresh
    # signature uses a higher fee, still subject to the existing gas-cost cap.
    # trigger() checks reported pending nonces and claim eligibility before signing.
    if [[ -f "$previous/trigger.raw" ]]; then
        raw=$(cat "$previous/trigger.raw")
        [[ -f "$previous/trigger.hash" && $(cast keccak "$raw") == "$(cat "$previous/trigger.hash")" ]] || fail 'Previous signed transaction/hash mismatch'
        decoded=$(cast decode-transaction "$raw" | jq 'if type=="string" then fromjson else . end')
        [[ $(jq -r '.signer | ascii_downcase' <<< "$decoded") == "${WALLET,,}" ]] || fail 'Previous transaction belongs to another signer'
        [[ $(jq -r '.to | ascii_downcase' <<< "$decoded") == "$(jq -r '.executor | ascii_downcase' "$deployment/state.json")" ]] || fail 'Previous transaction targets another deployment'
        [[ $(cast to-dec "$(jq -r .chainId <<< "$decoded")") == "$L2_CHAIN_ID" ]] || fail 'Previous transaction has wrong chain'
        prior_nonce=$(cast to-dec "$(jq -r .nonce <<< "$decoded")")
        latest=$(cast nonce "$WALLET" --block latest --rpc-url "$L2_RPC" 2>/dev/null)
        [[ "$latest" =~ ^[0-9]+$ ]] || fail 'Invalid latest nonce'
        if [[ "$prior_nonce" == "$latest" ]]; then
            price_floor=$(cast to-dec "$(jq -r .gasPrice <<< "$decoded")")
            price_floor=$(BC_LINE_LENGTH=0 bc <<< "$price_floor * 9 / 8 + 1")
        fi
    fi
    mkdir -p "$deployment/reruns"
    attempt=$(mktemp -d "$deployment/reruns/attempt.XXXXXX")
    jq --arg parent "$deployment" --arg previous "$previous" --arg mode "$mode" \
        '{wallet,executor,borrower,l1_deployment_mode,loan_mode:$mode,source_deployment:$parent,previous_attempt:$previous}' \
        "$deployment/state.json" > "$attempt/state.json"
    RUN_DIR=$attempt
    export FOUNDRY_BROADCAST="$RUN_DIR/broadcast"
    # Persist before signing/sending; a timeout remains inspectable through status.
    basename "$attempt" > "$deployment/reruns/latest.next"
    mv "$deployment/reruns/latest.next" "$deployment/reruns/latest"
    echo "Attempt journal: $RUN_DIR"
    echo "Deployment amount behavior: $mode"
    trigger "$mode" "$price_floor" true
    echo "Check progress: bash script/balancer/rerun.sh '$deployment' status"
}

rerun_main() {
    local deployment=${1:-} action=${2:-trigger}
    [[ -n "$deployment" && "$deployment" != --help ]] || {
        echo 'Usage: bash script/balancer/rerun.sh DEPLOYMENT_DIR [trigger|status]'
        return
    }
    [[ "$action" == trigger || "$action" == status ]] || fail 'Expected trigger or status'
    deployment=$(cd "$deployment" && pwd)
    [[ -f "$deployment/state.json" ]] || fail 'Deployment state.json missing'
    jq -e 'all(.wallet,.executor,.borrower; type=="string" and test("^0x[0-9a-fA-F]{40}$"))' "$deployment/state.json" >/dev/null || fail 'Deployment is incomplete'
    umask 077
    exec 9>"$deployment/run.lock"
    flock -n 9 || fail 'Another runner holds this deployment journal lock'
    cd "$BALANCER_ROOT"
    source script/e2e/lib/network-config.sh
    load_network_config
    load_balancer_addresses
    set +x
    : "${PK:?Set PK or SOURCE_PK in chain.env}" "${L2_FRONT:?Set L2_FRONT}"
    WALLET=$(cast wallet address --private-key "$PK" 2>/dev/null)
    [[ "${WALLET,,}" == "$(jq -r '.wallet | ascii_downcase' "$deployment/state.json")" ]] || fail 'Journal belongs to another wallet'
    MAX_FEE_WEI=${BALANCER_MAX_FEE_WEI:-2000000000000000}
    RUN_DIR=$deployment
    if [[ "$action" == status ]]; then RUN_DIR=$(latest_attempt "$deployment"); fi
    export FOUNDRY_BROADCAST="$RUN_DIR/broadcast"
    preflight
    if [[ "$action" == status ]]; then status; else rerun_loan "$deployment"; fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then rerun_main "$@"; fi
