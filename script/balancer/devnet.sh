#!/usr/bin/env bash
# Address configuration only; deployment, signing and verification stay in the existing runner.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rerun.sh"

SCRIPT_PATH=script/balancer/Devnet.s.sol:Devnet
SCRIPT_FILE=Devnet.s.sol
L1_CHAIN_ID=10200
L2_CHAIN_ID=906969
TOKEN_SYMBOL=mUSD
export DEVNET_ENV="${DEVNET_ENV:-chain.envdevnet}"
export BALANCER_RUN_DIR="${BALANCER_RUN_DIR:-$BALANCER_ROOT/tmp-balancer-devnet}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == rerun ]]; then
        shift
        rerun_main "$@"
    else
        main "$@"
    fi
fi
