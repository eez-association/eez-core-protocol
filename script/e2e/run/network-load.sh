#!/usr/bin/env bash
# Worker and progress helpers. Sourcing this file only defines functions.
load_worker() (
    set -euo pipefail
    local worker="$1" count="$2" address="$3" key="$4"
    local file="$RUN_DIR/worker-$worker.csv" nonce front_nonce i j raw hash receipt status
    local failed=0 start now deadline sent=0
    local hashes=() starts=() nonces=() indexes=()
    : >"$file"
    nonce=$(timeout "$SEND_TIMEOUT" cast nonce "$address" --block pending --rpc-url "$READ_RPC")
    front_nonce=$(timeout "$SEND_TIMEOUT" cast nonce "$address" --block pending --rpc-url "$SEND_RPC")
    (( front_nonce <= nonce )) || nonce=$front_nonce
    for ((i=0; i<count; )); do
        hashes=(); starts=(); nonces=(); indexes=()
        for ((j=0; j<WINDOW && i<count; j++, i++)); do
            start=$(_now_ms)
            # Explicit fees/chain ID make signing offline. Legacy transactions match
            # the devnet's gas-price model and avoid fee-estimation RPCs per trigger.
            if ! raw=$(timeout "$SEND_TIMEOUT" cast mktx "$TARGET" "$CALLDATA" --legacy \
                --value "${VALUE}wei" --gas-limit "$GAS" --gas-price "$GAS_PRICE" \
                --chain-id "$CHAIN_ID" --nonce "$nonce" --private-key "$key"); then
                echo "$worker,$i,$nonce,,sign_error,0" >>"$file"
                failed=1; break
            fi
            # Never advance past an uncertain send: doing so could leave a nonce gap.
            if ! hash=$(timeout "$SEND_TIMEOUT" cast publish "$raw" --async --rpc-url "$SEND_RPC") ||
                [[ ! "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
                echo "$worker,$i,$nonce,,send_error,0" >>"$file"
                failed=1; break
            fi
            echo "$hash" >>"$RUN_DIR/worker-$worker.txs"
            hashes+=("$hash"); starts+=("$start"); nonces+=("$nonce"); indexes+=("$i")
            nonce=$((nonce+1)); sent=$((sent+1))
        done
        # Bound a whole window's wait. Every accepted hash gets a result even on failure.
        deadline=$((SECONDS + RECEIPT_TIMEOUT))
        for ((j=0; j<${#hashes[@]}; j++)); do
            status=timeout
            while (( SECONDS < deadline )); do
                if receipt=$(timeout "$SEND_TIMEOUT" cast receipt "${hashes[$j]}" --async --json --rpc-url "$READ_RPC" 2>/dev/null); then
                    case "$(jq -r '.status' <<<"$receipt" 2>/dev/null)" in
                        0x1|1) status=success; break ;;
                        0x0|0) status=reverted; break ;;
                    esac
                fi
                sleep 1
            done
            now=$(_now_ms)
            echo "$worker,${indexes[$j]},${nonces[$j]},${hashes[$j]},$status,$((now - starts[j]))" >>"$file"
            [[ "$status" == success ]] || failed=1
        done
        echo "worker $worker: sent $sent/$count"
        (( failed == 0 )) || break
    done
    return "$failed"
)

# Run setup in this shell: funding/deployment must retain their exported outputs.
# Do not call this function in an if/|| condition, which disables bash errexit
# inside the command being run.
load_phase() {
    local label="$1" logfile="$2" heartbeat slot started=$SECONDS
    shift 2
    LOAD_PHASE="$label"
    LOAD_PHASE_LOG="$logfile"
    echo "$label... (log: $logfile)"
    (
        while sleep 10; do
            echo "  $label still running ($((SECONDS - started))s); log: $logfile"
        done
    ) &
    heartbeat=$!
    slot=${#_E2E_PIDS[@]}
    _E2E_PIDS+=("$heartbeat")
    "$@" >"$logfile" 2>&1
    kill "$heartbeat" 2>/dev/null || true
    wait "$heartbeat" 2>/dev/null || true
    unset '_E2E_PIDS[slot]'
    echo "$label complete ($((SECONDS - started))s)."
    LOAD_PHASE=""
}

# Read local artifacts only; never poll RPCs or inspect wallet keys.
load_progress() (
    local directory="$1" requested="$2" elapsed="${3:-0}"
    shopt -s nullglob
    awk -F, -v requested="$requested" -v elapsed="$elapsed" '
        FILENAME ~ /[.]txs$/ && /^0x[0-9a-fA-F]+$/ { sent++; next }
        FILENAME ~ /[.]csv$/ && NF == 6 { outcomes[$5]++ }
        END {
            pending = sent - outcomes["success"] - outcomes["reverted"] - outcomes["timeout"]
            if (pending < 0) pending = 0
            printf "[%ds] Submitted %d/%d | success %d | awaiting receipt %d | reverted %d | timed out %d | send/sign errors %d\n", elapsed, sent, requested, outcomes["success"], pending, outcomes["reverted"], outcomes["timeout"], outcomes["send_error"] + outcomes["sign_error"]
        }
    ' /dev/null "$directory"/worker-*.txs "$directory"/worker-*.csv
)

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

# Deploy one scenario once, then reuse its trigger across nonce-isolated wallets.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."

usage() {
    cat <<'EOF'
Usage: bash script/e2e/run/network-load.sh [options] <scenario>
  --txs N           Total trigger transactions (default 1000)
  --txs-per-wallet X Send exactly X transactions from each of N workers
                    (mutually exclusive with --txs)
  --workers N       Concurrent sender wallets (default 20)
  --window N        Pending transactions per wallet (default 10)
  --fund ETH        Worker balance target on each chain (default 0.1)
  --direct          Fund directly from SOURCE_PK
  --fresh           Create new wallets instead of reusing the existing pool
  --gas N           Override trigger gas limit
  --help            Show this help
Env: DEVNET_ENV=chain.env, SOURCE_PK, RECEIPT_TIMEOUT=420, SEND_TIMEOUT=30.
Examples:
  bash script/e2e/run/network-load.sh --workers 20 --txs-per-wallet 500 counter
  bash script/e2e/run/network-load.sh --workers 50 --txs-per-wallet 100 nestedCounter
Deploys once; repeats the scenario's ExecuteNetwork(L2) transaction shape.
Counts transactions, ignoring the scenario's NUM_TXS repetition hint.
Only receipts are checked; this is not full cross-chain settlement verification.
Use repeatable scenarios; one-shot balances/assertions may revert under repetition.
EOF
}
TXS=1000 WORKERS=20 WINDOW=10 DIRECT=false FRESH=false
TXS_PER_WALLET=""
TOTAL_EXPLICIT=false
FUND_ETH="${FUND_ETH:-0.1}"
GAS_OVERRIDE=""
TARGET_SCENARIO=""
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --txs) TXS="${2:?--txs needs a count}"; TOTAL_EXPLICIT=true; shift 2 ;;
        --txs-per-wallet) TXS_PER_WALLET="${2:?--txs-per-wallet needs a count}"; shift 2 ;;
        --fresh) FRESH=true; shift ;;
        --workers) WORKERS="${2:?--workers needs a count}"; shift 2 ;;
        --window) WINDOW="${2:?--window needs a count}"; shift 2 ;;
        --fund) FUND_ETH="${2:?--fund needs an amount}"; shift 2 ;;
        --gas) GAS_OVERRIDE="${2:?--gas needs a limit}"; shift 2 ;;
        --direct) DIRECT=true; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) [[ -z "$TARGET_SCENARIO" ]] || { usage; exit 1; }
           TARGET_SCENARIO="$1"; shift ;;
    esac
done
[[ -n "$TARGET_SCENARIO" ]] || { usage; exit 1; }
RECEIPT_TIMEOUT="${RECEIPT_TIMEOUT:-420}"
SEND_TIMEOUT="${SEND_TIMEOUT:-30}"
for name in TXS WORKERS WINDOW RECEIPT_TIMEOUT SEND_TIMEOUT; do
    [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { echo "$name must be a positive integer"; exit 1; }
done
if [[ -n "$TXS_PER_WALLET" ]]; then
    $TOTAL_EXPLICIT && { echo "Choose --txs or --txs-per-wallet, not both"; exit 1; }
    [[ "$TXS_PER_WALLET" =~ ^[1-9][0-9]*$ ]] || { echo "--txs-per-wallet must be a positive integer"; exit 1; }
    # Bound counts before shell arithmetic to avoid overflow/wraparound.
    (( ${#TXS_PER_WALLET} <= 9 && ${#WORKERS} <= 9 )) || { echo "Count too large"; exit 1; }
    TXS=$((WORKERS * TXS_PER_WALLET))
fi
[[ -z "$GAS_OVERRIDE" || "$GAS_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --gas"; exit 1; }
[[ "$TARGET_SCENARIO" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Expected one scenario name"; exit 1; }
mapfile -t MATCHES < <(find script/e2e -path "*/$TARGET_SCENARIO/E2E*.s.sol" -not -path '*/shared/*' | sort)
(( ${#MATCHES[@]} == 1 )) || { echo "Expected exactly one scenario matching $TARGET_SCENARIO"; exit 1; }
SOL="${MATCHES[0]}"
for tool in forge cast jq bc flock timeout; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool"; exit 1; }
done
source "${DEVNET_ENV:-chain.env}"
source "$SCRIPT_DIR/../shared/E2EBase.sh"
source "$SCRIPT_DIR/orchestrator-lib.sh"
for name in L1_RPC L2_RPC ROLLUPS MANAGER_L2; do
    [[ -n "${!name:-}" ]] || { echo "Missing $name"; exit 1; }
done
export L1_RPC L2_RPC ROLLUPS MANAGER_L2
export L2_ROLLUP_ID="${L2_ROLLUP_ID:-1}"
SOURCE_PK="${SOURCE_PK:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
(( WORKERS <= TXS )) || WORKERS=$TXS
# Reuse the same sender pool and funding helper as the existing orchestrators.
NJOBS=$WORKERS
JOB_NAMES=()
for ((i=0; i<WORKERS; i++)); do JOB_NAMES+=("sender-$i"); done
FLOOR_ETH="$FUND_ETH"
umask 077
mkdir -p tmp/e2e-load
RUN_DIR=$(mktemp -d "tmp/e2e-load/$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Artifacts: $RUN_DIR"
load_exit() {
    local rc=$?
    if (( rc != 0 )); then
        echo "Load run failed (exit $rc): ${LOAD_PHASE:-sending/checking transactions}. See ${LOAD_PHASE_LOG:-$RUN_DIR}." >&2
    fi
    cleanup
}
trap load_exit EXIT
load_phase "Building contracts" "$RUN_DIR/build.log" forge build
load_phase "Funding $WORKERS wallets" "$RUN_DIR/funding.log" fund_workers
export PK="${WALLET_PKS[0]}"
export E2E_JOB_DIR="$RUN_DIR"
load_phase "Deploying $TARGET_SCENARIO once" "$RUN_DIR/deploy.log" deploy_contracts "$SOL" "$L1_RPC" "$L2_RPC" "$PK"
TRIGGER_CONTRACT=ExecuteNetwork
READ_RPC="$L1_RPC"; SEND_RPC="${L1_FRONT:-$L1_RPC}"
if grep -qE '^contract ExecuteNetworkL2\b' "$SOL"; then
    TRIGGER_CONTRACT=ExecuteNetworkL2
    READ_RPC="$L2_RPC"; SEND_RPC="${L2_FRONT:-$L2_RPC}"
fi
load_phase "Reading trigger template" "$RUN_DIR/trigger.log" forge script "$SOL:$TRIGGER_CONTRACT" --rpc-url "$READ_RPC" --sender "${WALLET_ADDRS[0]}"
OUT=$(cat "$RUN_DIR/trigger.log")
TARGET=$(extract "$OUT" TARGET)
VALUE=$(extract "$OUT" VALUE)
CALLDATA=$(extract "$OUT" CALLDATA)
GAS=$(extract "$OUT" GAS)
GAS="${GAS_OVERRIDE:-${GAS:-${E2E_TRIGGER_GAS:-1000000}}}"
[[ "$TARGET" =~ ^0x[0-9a-fA-F]{40}$ && "$VALUE" =~ ^[0-9]+$ &&
   "$CALLDATA" =~ ^0x([0-9a-fA-F]{2})*$ && "$GAS" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid trigger template; see $RUN_DIR/trigger.log"; exit 1;
}
# Resolve fees once on the ordinary RPC; front endpoints only receive signed triggers.
CHAIN_ID=$(cast chain-id --rpc-url "$READ_RPC")
GAS_PRICE=$(cast gas-price --rpc-url "$READ_RPC")
declare -p TARGET_SCENARIO TXS TXS_PER_WALLET WORKERS WINDOW TARGET VALUE CALLDATA GAS CHAIN_ID GAS_PRICE >"$RUN_DIR/config.env"
echo "Sending $TXS transactions to $TARGET ($TRIGGER_CONTRACT), $WORKERS wallets, window $WINDOW"
LOAD_PHASE_LOG="$RUN_DIR"
START=$SECONDS
PIDS=()
for ((i=0; i<WORKERS; i++)); do
    count=$(( TXS / WORKERS + (i < TXS % WORKERS) ))
    load_worker "$i" "$count" "${WALLET_ADDRS[$i]}" "${WALLET_PKS[$i]}" >"$RUN_DIR/worker-$i.log" 2>&1 &
    PIDS+=("$!"); _E2E_PIDS+=("$!")
done
# Aggregate artifacts instead of adding receipt RPC traffic for progress reporting.
load_progress "$RUN_DIR" "$TXS" "$((SECONDS - START))" | tee -a "$RUN_DIR/progress.log"
(
    while sleep 10; do
        load_progress "$RUN_DIR" "$TXS" "$((SECONDS - START))" | tee -a "$RUN_DIR/progress.log"
    done
) &
PROGRESS_PID=$!
_E2E_PIDS+=("$PROGRESS_PID")
RC=0
for pid in "${PIDS[@]}"; do wait "$pid" || RC=1; done
kill "$PROGRESS_PID" 2>/dev/null || true
wait "$PROGRESS_PID" 2>/dev/null || true
_E2E_PIDS=()
load_progress "$RUN_DIR" "$TXS" "$((SECONDS - START))" | tee -a "$RUN_DIR/progress.log"
{
    echo "worker,index,nonce,hash,status,elapsed_ms"
    cat "$RUN_DIR"/worker-*.csv
} >"$RUN_DIR/results.csv"
ELAPSED=$((SECONDS - START))
awk -F, -v requested="$TXS" -v elapsed="$ELAPSED" '
    NR > 1 { counts[$5]++; total++ }
    END {
        printf "Requested: %d; recorded: %d; elapsed: %ds\n", requested, total, elapsed
        for (s in counts) printf "  %s: %d\n", s, counts[s]
        if (elapsed > 0) printf "Successful receipt throughput: %.2f tx/s\n", counts["success"]/elapsed
    }' "$RUN_DIR/results.csv" | tee "$RUN_DIR/summary.txt"
echo "Receipts only; cross-chain settlement not verified. Results: $RUN_DIR/results.csv"
exit "$RC"
