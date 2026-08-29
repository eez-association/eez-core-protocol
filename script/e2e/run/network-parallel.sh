#!/usr/bin/env bash
# Parallel network e2e orchestrator — per-worker wallets remove the shared-nonce
# constraint that forces network-sequential.sh to be sequential.
#
# Wallet hierarchy:
#   source key (anvil #2 or SOURCE_PK)       — funds the run faucet ↓ (or workers directly with --direct)
#   run faucet (fresh wallet, in the run dir)  — funds ↓ via MultiSend (one batched tx per chain)
#   one ephemeral wallet per job             — runs the scenario, nonce-isolated
#
# Worker funding goes through a MultiSend contract (script/e2e/shared/MultiSend.sol,
# address cached per chain-id in multisend.txt): one `fund(address[],uint256)` tx per
# chain funds every worker, instead of one tx per worker — devnet txpools cap pending
# txs per account (~20), which capped the old per-worker funding at ~20 jobs.
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
#   MULTISEND_BATCH  workers funded per MultiSend tx (default 100 — block-gas headroom)
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

# ── Step 0: build once — MultiSend deployment below and the parallel forge
# invocations later both need warm artifacts (parallel builds race the cache).
forge build > /dev/null 2>&1 || { echo "forge build failed"; exit 1; }

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

# ── Step 3: one ephemeral wallet per job, funded via MultiSend ──
# One `fund(address[],uint256)` tx per chain (chunked by MULTISEND_BATCH) funds
# every worker — a single-sender tx count that devnet txpool per-account limits
# never touch.
MULTISEND_BATCH="${MULTISEND_BATCH:-100}"
MULTISEND_FILE="$SCRIPT_DIR/multisend.txt"

# Returns (stdout) the MultiSend address for the chain at $1, deploying it from
# the faucet key and caching it in multisend.txt (keyed by chain id) if needed.
ensure_multisend() {
    local rpc=$1 chain_id addr
    chain_id=$(cast chain-id --rpc-url "$rpc") || return 1
    addr=$(sed -n "s/^$chain_id: *//p" "$MULTISEND_FILE" 2>/dev/null)
    if [[ -n "$addr" && $(cast code "$addr" --rpc-url "$rpc") != "0x" ]]; then
        echo "$addr"; return 0
    fi
    addr=$(forge create script/e2e/shared/MultiSend.sol:MultiSend --broadcast \
        --private-key "$FAUCET_PK" --rpc-url "$rpc" 2>/dev/null \
        | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
    [[ -n "$addr" ]] || { echo "MultiSend deploy FAILED (chain $chain_id)" >&2; return 1; }
    { [[ -f "$MULTISEND_FILE" ]] && grep -v "^$chain_id: " "$MULTISEND_FILE"; \
      echo "$chain_id: $addr"; } > "$MULTISEND_FILE.tmp" && mv "$MULTISEND_FILE.tmp" "$MULTISEND_FILE"
    echo "MultiSend deployed on chain $chain_id → $addr" >&2
    echo "$addr"
}

WALLET_PKS=(); WALLET_ADDRS=()
echo "job,address,private_key" > "$RUN_DIR/wallets.csv"
chmod 600 "$RUN_DIR/wallets.csv"
for ((i = 0; i < NJOBS; i++)); do
    new=$(cast wallet new)
    waddr=$(echo "$new" | grep -oE 'Address: +0x[0-9a-fA-F]{40}' | grep -oE '0x.*')
    wpk=$(echo "$new"  | grep -oE 'Private key: +0x[0-9a-fA-F]{64}' | grep -oE '0x.*')
    WALLET_PKS+=("$wpk"); WALLET_ADDRS+=("$waddr")
    echo "${JOB_NAMES[$i]},$waddr,$wpk" >> "$RUN_DIR/wallets.csv"
done

FUND_WEI=$(cast to-wei "$FUND_ETH")
for chain in L1 L2; do
    rpc_var="${chain}_RPC"; rpc="${!rpc_var}"
    ms=$(ensure_multisend "$rpc") || exit 1
    for ((off = 0; off < NJOBS; off += MULTISEND_BATCH)); do
        slice=("${WALLET_ADDRS[@]:off:MULTISEND_BATCH}")
        total=$(echo "$FUND_WEI * ${#slice[@]}" | bc)
        cast send "$ms" "fund(address[],uint256)" \
            "[$(IFS=,; echo "${slice[*]}")]" "$FUND_WEI" --value "$total" \
            --private-key "$FAUCET_PK" --rpc-url "$rpc" > /dev/null || {
            echo "Worker funding FAILED on $chain (workers $off..$((off + ${#slice[@]} - 1)))"; exit 1; }
        echo "  funded ${#slice[@]} worker(s) on $chain via MultiSend $ms"
    done
done
echo "All workers funded."
flock -u 9   # faucet no longer touched — let concurrent runs proceed

# ── Step 4: launch with a concurrency cap ──
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

# ── Step 5: collect results ──
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
