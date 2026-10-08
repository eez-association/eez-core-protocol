#!/usr/bin/env bash
# Mainnet v0.1.0-rc.1 -> reviewed 9744950. Defaults to unsigned simulation.
set +x
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=plan
TRAFFIC_PAUSED=false
L1_RPC=
L2_RPC=
L1_MANAGER=
L2_MANAGER=
UPGRADE_OWNER=
RUN_DIR="$ROOT/tmp-mainnet-upgrade-9744950"
usage() {
    cat <<'HELP'
Usage: bash deployment/upgrade-mainnet.sh \
  --l1-rpc URL --l2-rpc URL \
  --l1-manager ADDRESS --l2-manager ADDRESS --owner ADDRESS \
  [--broadcast --traffic-paused] [--run-dir DIR]
All five connection/address parameters are required. No env file is sourced.
Default: simulate both chains without using a signing key.
Broadcast: prompts privately for the owner's key, or uses exported UPGRADE_PRIVATE_KEY.
SOURCE_PK is never used. Do not put a private key on the command line.
--traffic-paused acknowledges that new composer submissions are stopped and pending work is drained.
Reuse the SAME run directory after interruption; a started but unfinished stage requires receipt inspection.
HELP
}
fail() { echo "ERROR: $*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --broadcast) MODE=broadcast; shift ;;
        --traffic-paused) TRAFFIC_PAUSED=true; shift ;;
        --l1-rpc|--l2-rpc|--l1-manager|--l2-manager|--owner|--run-dir)
            (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || fail "$1 needs a value"
            case "$1" in
                --l1-rpc) L1_RPC=$2;;
                --l2-rpc) L2_RPC=$2;;
                --l1-manager) L1_MANAGER=$2;;
                --l2-manager) L2_MANAGER=$2;;
                --owner) UPGRADE_OWNER=$2;;
                --run-dir) RUN_DIR=$2;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$L1_RPC" && -n "$L2_RPC" ]] || fail 'Provide --l1-rpc and --l2-rpc (see --help)'
for name in L1_MANAGER L2_MANAGER UPGRADE_OWNER; do
    [[ "${!name}" =~ ^0x[[:xdigit:]]{40}$ && ! "${!name}" =~ ^0x0{40}$ ]] ||
        fail "$name must be a nonzero address (see --help)"
done
for tool in forge cast flock; do command -v "$tool" >/dev/null || fail "Missing $tool"; done
if [[ "$MODE" == broadcast ]]; then
    $TRAFFIC_PAUSED || fail 'Broadcast requires --traffic-paused'
    if [[ -z "${UPGRADE_PRIVATE_KEY:-}" ]]; then
        [[ -t 0 ]] || fail 'Export UPGRADE_PRIVATE_KEY when running without a terminal'
        read -rsp 'Upgrade owner private key (0x-prefixed): ' UPGRADE_PRIVATE_KEY
        echo
    fi
    [[ "$UPGRADE_PRIVATE_KEY" =~ ^0x[[:xdigit:]]{64}$ ]] || fail 'Expected a 0x-prefixed private key'
    export UPGRADE_PRIVATE_KEY
else
    unset UPGRADE_PRIVATE_KEY
fi
mkdir -p "$RUN_DIR"
RUN_DIR=$(cd "$RUN_DIR" && pwd)
exec 9>"$RUN_DIR/lock"
flock -n 9 || fail 'Another upgrade runner holds this run-directory lock'
cd "$ROOT"

# Keep credentials and credential-bearing RPC URLs out of terminal output and logs.
safe_run() {
    local log=$1 output rc=0 secret; shift
    output=$("$@" 2>&1) || rc=$?
    for secret in "${UPGRADE_PRIVATE_KEY:-}" "${SOURCE_PK:-}" "$L1_RPC" "$L2_RPC" "${L1_FRONT:-}" "${L2_FRONT:-}"; do
        [[ -z "$secret" ]] || output=${output//"$secret"/[redacted]}
    done
    printf '%s\n' "$output" > "$log"
    ((rc == 0)) || fail "Command failed. See sanitized log: $log"
}
for side in l1 l2; do
    if [[ "$side" == l1 ]]; then rpc=$L1_RPC; expected=1; else rpc=$L2_RPC; expected=696990; fi
    safe_run "$RUN_DIR/$side-chain.log" cast chain-id --rpc-url "$rpc"
    [[ $(cat "$RUN_DIR/$side-chain.log") == "$expected" ]] || fail "Wrong $side chain"
done
script() {
    local side=$1 phase=$2 signature=$3; shift 3
    local rpc=$L1_RPC manager=$L1_MANAGER
    if [[ "$side" == l2 ]]; then rpc=$L2_RPC; manager=$L2_MANAGER; fi
    safe_run "$RUN_DIR/$side-$phase.log" env \
        FOUNDRY_BROADCAST="$RUN_DIR/foundry-$side" \
        FOUNDRY_CACHE_PATH="$RUN_DIR/cache-$side" \
        forge script deployment/MainnetUpgrade.s.sol:MainnetUpgrade \
        --rpc-url "$rpc" --sig "$signature" "$manager" "$UPGRADE_OWNER" "$@"
}

# Validate BOTH networks and, when requested, BOTH owners before any transaction.
for side in l1 l2; do
    signing=false; [[ "$MODE" != broadcast ]] || signing=true
    script "$side" preflight 'check(address,address,bool)' "$signing"
    # The planned deployment and upgrade never receive a key, even in broadcast mode.
    saved_key=${UPGRADE_PRIVATE_KEY:-}
    unset UPGRADE_PRIVATE_KEY
    script "$side" plan 'run(address,address,bool)' false
    if [[ "$MODE" == broadcast ]]; then export UPGRADE_PRIVATE_KEY=$saved_key; fi
    unset saved_key
    echo "$side preflight and unsigned simulation passed."
done
if [[ "$MODE" == plan ]]; then
    echo "Simulation only. No transactions signed or sent. Logs: $RUN_DIR"
    exit 0
fi
for side in l1 l2; do
    if [[ -f "$RUN_DIR/$side.done" ]]; then
        script "$side" verify 'verify(address,address)'
        echo "$side already complete and verified."
        continue
    fi
    [[ ! -f "$RUN_DIR/$side.started" ]] || fail "$side was previously attempted. Inspect receipts and implementation before recovery; do not delete the journal or use a new run directory to bypass this check."
    # A timeout may mean a transaction WAS accepted: never automatically replay.
    touch "$RUN_DIR/$side.started"
    script "$side" broadcast 'run(address,address,bool)' true --broadcast --slow
    script "$side" verify 'verify(address,address)'
    touch "$RUN_DIR/$side.done"
    echo "$side upgrade confirmed and verified."
done
unset UPGRADE_PRIVATE_KEY
echo "Both mainnet managers upgraded to reviewed 9744950. Rollup was not changed. Logs: $RUN_DIR"
