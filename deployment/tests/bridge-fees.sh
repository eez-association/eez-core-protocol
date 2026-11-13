#!/usr/bin/env bash
# Offline signing test: synthetic public test key, stubbed RPC, no publishing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CAST_BIN=$(command -v cast)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
RUN_DIR=$TEST_DIR
KEY=$($CAST_BIN keccak 'public unfunded bridge fee regression test')
DEPLOYER=$($CAST_BIN wallet address --private-key "$KEY")
MAX_FEE_WEI=200000000000
declare -A RPC=([test]=http://127.0.0.1:1) CHAIN=([test]=31337)
TARGET=0x0000000000000000000000000000000000000011
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
source <(sed -n '/^json() {/p; /^redact() {/p; /^send() {/,/^}/p' deployment/deploy-bridge.sh)
declare -F send >/dev/null
rpc() { [[ $2 == eth_maxPriorityFeePerGas ]]; printf '"0xb"\n'; }
cast() {
    case "$1" in
        estimate) printf '21000\n';;
        base-fee) printf '100\n';;
        nonce) printf '7\n';;
        *) "$CAST_BIN" "$@";;
    esac
}
publish_saved() {
    local decoded
    decoded=$($CAST_BIN decode-transaction --json "$3" | json)
    jq -e '.type=="0x2" and .gas=="0x5208" and .maxFeePerGas=="0x7b" and .maxPriorityFeePerGas=="0xb"' <<<"$decoded" >/dev/null
}
send test normal "$TARGET" 0x
printf 'PASS: type 2, exact gas estimate, unchanged tip, 10%% max-fee headroom\n'
MAX_FEE_WEI=122
if (send test capped "$TARGET" 0x) >"$TEST_DIR/cap.log" 2>&1; then fail 'Over-cap signing was accepted'; fi
grep -q 'exceeds cap' "$TEST_DIR/cap.log"
[[ ! -f $RUN_DIR/capped.raw ]]
printf 'PASS: over-cap transaction rejected before signing\n'
if (send test normal "$TARGET" 0x) >"$TEST_DIR/resume.log" 2>&1; then fail 'Over-cap saved transaction was accepted'; fi
grep -q 'saved max fee exceeds' "$TEST_DIR/resume.log"
printf 'PASS: saved transactions respect the current cap\n'
MAX_FEE_WEI=200000000000
legacy=$($CAST_BIN mktx "$TARGET" 0x --legacy --chain 31337 --nonce 7 --gas-limit 21000 --gas-price 111 --private-key "$KEY")
printf '%s\n' "$legacy" >"$RUN_DIR/legacy.raw"
if (send test legacy "$TARGET" 0x) >"$TEST_DIR/legacy.log" 2>&1; then fail 'Saved legacy transaction was accepted'; fi
grep -q 'expected EIP-1559' "$TEST_DIR/legacy.log"
[[ $(cat "$RUN_DIR/legacy.raw") == "$legacy" ]]
printf 'PASS: saved legacy transaction rejected without replacement\n'
