#!/usr/bin/env bash
# Parallel network e2e orchestrator — per-worker wallets remove the shared-nonce
# constraint that forces network-sequential.sh to be sequential.
#
# Wallet hierarchy:
#   source key (anvil #2 or SOURCE_PK)       — funds the run faucet ↓ (or workers directly with --direct)
#   run faucet (fresh wallet, in the run dir)  — funds ↓ via MultiSend (one batched tx per chain)
#   one pooled wallet per job                — runs the scenario, nonce-isolated
#
# Worker funding goes through a MultiSend contract (script/e2e/shared/MultiSend.sol,
# address cached per chain-id in multisend.txt): one `fundUpTo(address[],uint256,uint256)`
# tx per chain tops every worker below FLOOR_ETH up to FUND_ETH (workers at or above
# the floor keep their balance — no dust transfers) and refunds the remainder, instead
# of one tx per worker — devnet txpools cap pending txs per account (~20), which capped the
# old per-worker funding at ~20 jobs.
#
# Worker wallets persist in wallet-pool.csv (address,private_key — gitignored) and are
# reused across runs: leftover balances count toward the next run's top-up, so nothing
# is stranded. The pool grows on demand when a run needs more wallets than it holds.
# Because runs share the pool from index 0, do NOT run two orchestrator instances
# concurrently — they would hand the same wallets to different jobs and race nonces.
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
#   --floor <eth>    skip topping up workers already holding this much (same as
#                    FLOOR_ETH env; default FUND_ETH / 2). Must cover the most
#                    expensive scenario's per-chain spend, or floor-admitted
#                    workers can run dry mid-scenario.
#   --fresh          mint brand-new worker wallets instead of reusing the pool
#                    (still appended to the pool, so their leftovers are reused later)
#
# Env knobs:
#   MAX_PARALLEL     max concurrent jobs (default 100 — effectively unthrottled)
#   FUND_ETH         ETH given to each worker per chain (default 0.1)
#   FLOOR_ETH        top-up trigger threshold (default FUND_ETH / 2)
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
FRESH=false

while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --direct) DIRECT=true; shift ;;
        --fresh)  FRESH=true; shift ;;
        --fund)   FUND_ETH="${2:?--fund needs an amount}"; shift 2 ;;
        --floor)  FLOOR_ETH="${2:?--floor needs an amount}"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# Default floor = half the target; resolved after flag parsing so --fund moves it.
FLOOR_ETH="${FLOOR_ETH:-$(echo "scale=18; $FUND_ETH / 2" | bc)}"

[[ $# -gt 0 ]] || { echo "Usage: network-parallel.sh [--direct] [--fresh] [--fund <eth>] [--floor <eth>] <scenario>[:count] ..."; exit 1; }

# Job expansion + wallet funding are shared with network-staged.sh.
source "$SCRIPT_DIR/orchestrator-lib.sh"
expand_jobs "$@"

RUN_DIR="tmp/e2e-parallel-net/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
echo "== $NJOBS job(s), max $MAX_PARALLEL parallel, ${FUND_ETH} ETH/worker/chain — logs in $RUN_DIR"

# ── Step 0: build once — MultiSend deployment below and the parallel forge
# invocations later both need warm artifacts (parallel builds race the cache).
forge build > /dev/null 2>&1 || { echo "forge build failed"; exit 1; }

# ── Steps 1–3: faucet + wallet pool + MultiSend top-up (orchestrator-lib.sh) ──
fund_workers

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
