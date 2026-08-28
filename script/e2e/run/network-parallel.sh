#!/usr/bin/env bash
# Parallel network e2e orchestrator — per-worker wallets remove the shared-nonce
# constraint that forces network-sequential.sh to be sequential.
#
# Wallet hierarchy:
#   source key (anvil #2 or SOURCE_PK)       — funds the run faucet ↓ (or workers directly with --direct)
#   run faucet (fresh wallet, in the run dir)  — funds ↓
#   one ephemeral wallet per job             — runs the scenario, nonce-isolated
#
# Usage:
#   bash script/e2e/run/network-parallel.sh [flags] <target>[:count] ...
#
#   network-parallel.sh counter:10                  # counter 10x in parallel
#   network-parallel.sh counter:5 bridge:3          # mix scenarios and counts
#   network-parallel.sh all                         # every scenario once
#   network-parallel.sh all:3                       # every scenario 3x
#   network-parallel.sh one_way:2 nested            # categories/dirs work too
#   network-parallel.sh --direct counter:10         # fund workers straight from anvil #2
#   network-parallel.sh --fund 0.05 counter:10      # 0.05 ETH per worker per chain
#
# Flags:
#   --direct         skip the run faucet: fund workers directly from the
#                    source key (anvil #2, or SOURCE_PK if set).
#   --fund <eth>     ETH given to each worker per chain (same as FUND_ETH env)
#
# Env knobs:
#   MAX_PARALLEL     max concurrent jobs (default 100 — effectively unthrottled)
#   FUND_ETH         ETH given to each worker per chain (default 0.1)
#   SOURCE_PK        key used for top-ups / --direct funding (default anvil #2)
#   RECEIPT_TIMEOUT  passed through to network.sh (default 420)
#   DEVNET_ENV       env file with endpoints/addresses (default chain.env)
#
# Worker wallets are throwaway and recorded in the run dir. The run faucet is
# persistent (`script/e2e/run/faucet.txt`) so unused top-ups are reused instead
# of being stranded in a fresh account on every invocation.
# Logs: tmp/e2e-parallel-net/<ts>/<job>.log
#
# Known benign race: N parallel runs of the SAME scenario share
# broadcast/<Sol>/<chainId>/run-latest.json. Nothing reads it (no --resume;
# the runner parses forge stdout), so a clobbered file is harmless.

set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

DEVNET_ENV="${DEVNET_ENV:-chain.env}"
[[ -f "$DEVNET_ENV" ]] || { echo "Missing $DEVNET_ENV"; exit 1; }
# shellcheck disable=SC1090
source "$DEVNET_ENV"
for var in L1_RPC L1_FRONT L2_RPC L2_FRONT ROLLUPS MANAGER_L2; do
    [[ -n "${!var:-}" ]] || { echo "Missing $var (check $DEVNET_ENV)"; exit 1; }
done

# ══ DEFAULTS — edit here ══════════════════════════════════════════════════════
DEFAULT_FUND_ETH=0.1        # ETH per worker per chain (override: --fund / FUND_ETH)
DEFAULT_MAX_PARALLEL=100    # concurrent jobs cap (override: MAX_PARALLEL)
DEFAULT_SOURCE_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # anvil #2 (override: SOURCE_PK)
# ══════════════════════════════════════════════════════════════════════════════

MAX_PARALLEL="${MAX_PARALLEL:-$DEFAULT_MAX_PARALLEL}"
FUND_ETH="${FUND_ETH:-$DEFAULT_FUND_ETH}"
SOURCE_PK="${SOURCE_PK:-$DEFAULT_SOURCE_PK}"
DIRECT=false

while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --direct) DIRECT=true; shift ;;
        --fund)   FUND_ETH="${2:?--fund needs an amount}"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

[[ $# -gt 0 ]] || { echo "Usage: network-parallel.sh [--direct] [--fund <eth>] <scenario>[:count] ..."; exit 1; }

# ── Expand args into a flat job list ──
# Each arg is <target>[:count]; target = scenario name, category/direction dir
# (e.g. one_way, multi_call/L2_to_L1), or "all".
JOB_NAMES=(); JOB_SOLS=()
add_jobs() {  # $1=sol $2=count
    local name; name=$(basename "$(dirname "$1")")
    for ((i = 1; i <= $2; i++)); do
        JOB_NAMES+=("$name-$i"); JOB_SOLS+=("$1")
    done
}
for arg in "$@"; do
    scen="${arg%%:*}"
    count=1; [[ "$arg" == *:* ]] && count="${arg##*:}"
    [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || { echo "Bad count in '$arg'"; exit 1; }
    if [[ "$scen" == "all" ]]; then
        while IFS= read -r sol; do add_jobs "$sol" "$count"; done \
            < <(find script/e2e -mindepth 3 -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    elif [[ -d "script/e2e/$scen" ]]; then
        while IFS= read -r sol; do add_jobs "$sol" "$count"; done \
            < <(find "script/e2e/$scen" -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
    else
        sol=$(find script/e2e -mindepth 3 -path "*/$scen/E2E*.s.sol" -not -path '*/shared/*' | head -1)
        [[ -n "$sol" ]] || { echo "No scenario matches '$scen'"; exit 1; }
        add_jobs "$sol" "$count"
    fi
done
NJOBS=${#JOB_NAMES[@]}

RUN_DIR="tmp/e2e-parallel-net/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
echo "== $NJOBS job(s), max $MAX_PARALLEL parallel, ${FUND_ETH} ETH/worker/chain — logs in $RUN_DIR"

# Steps 1–3 hold an exclusive lock: concurrent orchestrator instances share the
# source funding key, and racing its nonce yields "replacement transaction
# underpriced".
exec 9>"$SCRIPT_DIR/.faucet.lock"
flock 9

if $DIRECT; then
    # ── Direct mode: fund workers straight from the source key ──
    FAUCET_PK="$SOURCE_PK"
    FAUCET_ADDR=$(cast wallet address --private-key "$FAUCET_PK")
    echo "Direct mode: funding workers from $FAUCET_ADDR (no faucet account)"
else
    # ── Step 1: persistent faucet account ──
    FAUCET_FILE="$SCRIPT_DIR/faucet.txt"
    if [[ -f "$FAUCET_FILE" ]]; then
        FAUCET_ADDR=$(sed -n 's/^address: *//p' "$FAUCET_FILE")
        FAUCET_PK=$(sed -n 's/^pvtKey: *//p' "$FAUCET_FILE")
        [[ -n "$FAUCET_ADDR" && -n "$FAUCET_PK" ]] || { echo "Malformed $FAUCET_FILE"; exit 1; }
        echo "Reusing faucet $FAUCET_ADDR"
    else
        new=$(cast wallet new)
        FAUCET_ADDR=$(echo "$new" | grep -oE 'Address: +0x[0-9a-fA-F]{40}' | grep -oE '0x.*')
        FAUCET_PK=$(echo "$new"  | grep -oE 'Private key: +0x[0-9a-fA-F]{64}' | grep -oE '0x.*')
        printf 'address: %s\npvtKey:  %s\n' "$FAUCET_ADDR" "$FAUCET_PK" > "$FAUCET_FILE"
        chmod 600 "$FAUCET_FILE"
        echo "Created faucet $FAUCET_ADDR → $FAUCET_FILE"
    fi

    # ── Step 2: fund the run faucet from the source key ──
    # bc, not $(( )) — FUND_ETH may be fractional (e.g. 0.2). Send the amount in
    # wei: bc prints 0.6 as ".6", which cast's <eth>ether parser rejects.
    NEED_WEI=$(cast to-wei "$(echo "$NJOBS * $FUND_ETH + 0.1" | bc)")
    for chain in L1 L2; do
        rpc_var="${chain}_RPC"; rpc="${!rpc_var}"
        HAVE_WEI=$(cast balance "$FAUCET_ADDR" --rpc-url "$rpc")
        if [[ $(echo "$HAVE_WEI < $NEED_WEI" | bc) -eq 1 ]]; then
            TOPUP_WEI=$(echo "$NEED_WEI - $HAVE_WEI" | bc)
            echo "Faucet top-up on $chain: $(cast from-wei "$TOPUP_WEI") ETH from source key"
            cast send "$FAUCET_ADDR" --value "$TOPUP_WEI" \
                --private-key "$SOURCE_PK" --rpc-url "$rpc" > /dev/null || {
                echo "Faucet funding FAILED on $chain"; exit 1; }
        else
            echo "Faucet on $chain already has sufficient balance"
        fi
    done
fi

# ── Step 3: one ephemeral wallet per job, funded in PARALLEL from our faucet ──
# One faucet key + many txs in flight → assign nonces explicitly and submit
# --async (no receipt wait), then wait once for the faucet nonce to advance.
WALLET_PKS=()
echo "job,address,private_key" > "$RUN_DIR/wallets.csv"
chmod 600 "$RUN_DIR/wallets.csv"
# pending, not latest — an in-flight faucet tx would make us reuse its nonce
L1_BASE_NONCE=$(cast nonce "$FAUCET_ADDR" --block pending --rpc-url "$L1_RPC")
L2_BASE_NONCE=$(cast nonce "$FAUCET_ADDR" --block pending --rpc-url "$L2_RPC")
for ((i = 0; i < NJOBS; i++)); do
    new=$(cast wallet new)
    waddr=$(echo "$new" | grep -oE 'Address: +0x[0-9a-fA-F]{40}' | grep -oE '0x.*')
    wpk=$(echo "$new"  | grep -oE 'Private key: +0x[0-9a-fA-F]{64}' | grep -oE '0x.*')
    WALLET_PKS+=("$wpk")
    echo "${JOB_NAMES[$i]},$waddr,$wpk" >> "$RUN_DIR/wallets.csv"
    cast send "$waddr" --value "${FUND_ETH}ether" --async --nonce $((L1_BASE_NONCE + i)) \
        --private-key "$FAUCET_PK" --rpc-url "$L1_RPC" > /dev/null || {
        echo "Worker funding submit FAILED on L1 (${JOB_NAMES[$i]})"; exit 1; }
    cast send "$waddr" --value "${FUND_ETH}ether" --async --nonce $((L2_BASE_NONCE + i)) \
        --private-key "$FAUCET_PK" --rpc-url "$L2_RPC" > /dev/null || {
        echo "Worker funding submit FAILED on L2 (${JOB_NAMES[$i]})"; exit 1; }
    echo "  funding submitted ${JOB_NAMES[$i]} → $waddr"
done
echo "Waiting for $((NJOBS * 2)) funding txs to mine..."
FUND_DEADLINE=$((SECONDS + 120))
until (( $(cast nonce "$FAUCET_ADDR" --rpc-url "$L1_RPC") >= L1_BASE_NONCE + NJOBS )) \
   && (( $(cast nonce "$FAUCET_ADDR" --rpc-url "$L2_RPC") >= L2_BASE_NONCE + NJOBS )); do
    (( SECONDS < FUND_DEADLINE )) || { echo "Funding txs not mined after 120s"; exit 1; }
    sleep 2
done
echo "All workers funded."
flock -u 9   # faucet no longer touched — let concurrent runs proceed

# ── Step 4: build once so parallel forge invocations don't race the cache ──
forge build > /dev/null 2>&1 || { echo "forge build failed"; exit 1; }

# ── Step 5: launch with a concurrency cap ──
run_job() {  # $1=sol $2=worker_pk $3=logfile
    RECEIPT_TIMEOUT="${RECEIPT_TIMEOUT:-420}" bash script/e2e/run/network.sh "$1" \
        --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
        --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
        --pk "$2" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        > "$3" 2>&1
}

PIDS=()
for ((i = 0; i < NJOBS; i++)); do
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do sleep 2; done
    echo "LAUNCH ${JOB_NAMES[$i]}"
    run_job "${JOB_SOLS[$i]}" "${WALLET_PKS[$i]}" "$RUN_DIR/${JOB_NAMES[$i]}.log" &
    PIDS+=($!)
done

# ── Step 6: collect results ──
PASS=0; FAIL=0; FAILED_LIST=()
for ((i = 0; i < NJOBS; i++)); do
    if wait "${PIDS[$i]}"; then
        PASS=$((PASS+1)); echo "RESULT ${JOB_NAMES[$i]}: PASS"
    else
        FAIL=$((FAIL+1)); FAILED_LIST+=("${JOB_NAMES[$i]}")
        echo "RESULT ${JOB_NAMES[$i]}: FAIL  (log: $RUN_DIR/${JOB_NAMES[$i]}.log)"
    fi
done

echo ""
echo "===== PARALLEL RESULT: $PASS passed, $FAIL failed ====="
for t in "${FAILED_LIST[@]:-}"; do [[ -n "$t" ]] && echo "  FAILED: $t"; done
[[ $FAIL -eq 0 ]]
