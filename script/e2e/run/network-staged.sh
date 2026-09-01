#!/usr/bin/env bash
# Staged network e2e orchestrator — decouples SENDING triggers from WAITING on
# them, so thousands of transactions can be in flight while the local machine
# only runs a handful of lightweight workers. The heavy lifting (forge scripts)
# is confined to the prepare and verify phases, each with its own concurrency
# cap; the send phase is pure curl.
#
# Phases:
#   1. fund     — one pooled wallet per job via the run faucet + MultiSend
#                 (shared with network-parallel.sh, orchestrator-lib.sh).
#   2. prepare  — default "waves" mode: per Deploy-contract wave, dry-run +
#                 pre-sign every job's deploy txs (capped at PREPARE_PARALLEL),
#                 fire them with the curl workers, mine once, next wave; then a
#                 read-only finish pass pre-signs triggers + runs ComputeExpected
#                 (network.sh E2E_STAGE=prepare, E2E_PREPARE_STEP=deploy:<k>/finish).
#                 PREPARE_MODE=classic = the original per-job forge deploys.
#   3. snapshot — one L1+L2 block snapshot bounds every job's verification scans.
#   4. send     — SEND_WORKERS curl-only workers publish the pre-signed raw txs
#                 fire-and-forget and record job,chain,txhash in sent.csv.
#   5. monitor  — a single loop batch-polls receipts (one JSON-RPC batch per
#                 chain) every POLL_INTERVAL s until everything is mined or
#                 MINE_TIMEOUT passes; progress in place, results in mined.csv.
#   6. verify   — per mined job, capped at VERIFY_PARALLEL (deliberately low —
#                 this is the expensive part and it is in no hurry): the
#                 content-addressed verification steps of network.sh
#                 (E2E_STAGE=verify). Skip with --no-verify and run later:
#                     network-staged.sh --verify-only tmp/e2e-staged-net/<ts>
#
# Usage:
#   bash script/e2e/run/network-staged.sh [flags] <target>[:count] ...
#   bash script/e2e/run/network-staged.sh --verify-only <run-dir>
#
# Flags (funding flags as in network-parallel.sh):
#   --direct / --fresh / --fund <eth> / --floor <eth>
#   --workers <n>    send workers (default 80)
#   --no-verify      stop after the monitor phase (verify later with --verify-only)
#   --verify-only <run-dir>  run/re-run only the verify phase of a previous run
#   --resume <run-dir>       continue a STOPPED run: skip fund+prepare and fire
#                    every job that already has a manifest but no sent txs, then
#                    monitor/verify that subset (unprepared jobs are reported,
#                    not counted as failures)
#
# Env knobs:
#   PREPARE_MODE      waves (default) | classic — see phase 2 above
#   DEPLOY_MINE_TIMEOUT  seconds to wait for a deploy wave to mine (default 300)
#   PREPARE_PARALLEL  concurrent prepare jobs (default 40)
#   SEND_WORKERS      send workers (default 80; --workers overrides)
#   VERIFY_PARALLEL   concurrent verify jobs (default 4 — keep the PC alive)
#   POLL_INTERVAL     seconds between receipt polls (default 10)
#   MINE_TIMEOUT      seconds to wait for all receipts (default 600)
#   FUND_ETH / FLOOR_ETH / SOURCE_PK / MULTISEND_BATCH / DEVNET_ENV  as in
#   network-parallel.sh.
#
# Run dir: tmp/e2e-staged-net/<ts>/ — jobs.csv, wallets.csv, snapshot.env,
# sent.csv, mined.csv, pending.csv (what never mined), jobs/<job>/{prepare.log,
# manifest.env, rawtxs.txt, compute.out, txs.txt, verify.log}.
#
# Do NOT run two orchestrator instances concurrently (shared wallet pool).

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
DEFAULT_FUND_ETH=0.1
DEFAULT_SOURCE_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # anvil #2
# ══════════════════════════════════════════════════════════════════════════════

FUND_ETH="${FUND_ETH:-$DEFAULT_FUND_ETH}"
SOURCE_PK="${SOURCE_PK:-$DEFAULT_SOURCE_PK}"
PREPARE_PARALLEL="${PREPARE_PARALLEL:-40}"
SEND_WORKERS="${SEND_WORKERS:-80}"
VERIFY_PARALLEL="${VERIFY_PARALLEL:-4}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
MINE_TIMEOUT="${MINE_TIMEOUT:-600}"
DIRECT=false
FRESH=false
NO_VERIFY=false
VERIFY_ONLY=""
RESUME=""
RESUME_TRUNCATED=false

while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --direct)      DIRECT=true; shift ;;
        --fresh)       FRESH=true; shift ;;
        --fund)        FUND_ETH="${2:?--fund needs an amount}"; shift 2 ;;
        --floor)       FLOOR_ETH="${2:?--floor needs an amount}"; shift 2 ;;
        --workers)     SEND_WORKERS="${2:?--workers needs a count}"; shift 2 ;;
        --no-verify)   NO_VERIFY=true; shift ;;
        --verify-only) VERIFY_ONLY="${2:?--verify-only needs a run dir}"; shift 2 ;;
        --resume)      RESUME="${2:?--resume needs a run dir}"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done
FLOOR_ETH="${FLOOR_ETH:-$(echo "scale=18; $FUND_ETH / 2" | bc)}"

source "$SCRIPT_DIR/orchestrator-lib.sh"

# A run is bound to the network it was prepared on: its pre-signed txs carry
# that chain's nonces and contract addresses. Fresh runs record the resolved
# endpoints in <run-dir>/devnet.env; --resume / --verify-only reload them, so
# forgetting DEVNET_ENV later cannot point the run at a different devnet.
_NET_VARS=(L1_RPC L1_FRONT L2_RPC L2_FRONT ROLLUPS MANAGER_L2)
_save_run_network() {  # $1=run dir
    local v
    { echo "# resolved from $DEVNET_ENV"; for v in "${_NET_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done; } > "$1/devnet.env"
}
_bind_run_network() {  # $1=run dir
    if [[ -f "$1/devnet.env" ]]; then
        # shellcheck disable=SC1090
        source "$1/devnet.env"
        echo "== network: $1/devnet.env (L1 $L1_RPC, L2 $L2_RPC)"
    else
        echo "WARNING: $1 has no devnet.env (older run) - using $DEVNET_ENV as-is"
    fi
}

# ── forge compile-cache guard ──
# `forge script <file>:<Contract>` rewrites cache/solidity-files-cache.json with
# only that script's dependency subset (~70 of ~157 files here), so after any
# parallel forge phase the next `forge build` recompiles the rest — ~3 min under
# via-IR — and looks like a hang. Keep the warm cache from the one-time build
# and put it back before every forge-heavy phase and on exit (artifacts in out/
# are never deleted, so the restored index is always valid).
_FORGE_CACHE_JSON="cache/solidity-files-cache.json"
_warm_forge_cache() {
    echo "== forge build (warming artifacts; a cold via-IR build takes ~3 min)"
    forge build > /dev/null 2>&1 || { echo "forge build failed"; exit 1; }
    cp "$_FORGE_CACHE_JSON" "$RUN_DIR/.forge-cache.json"
}
_restore_forge_cache() {
    [[ -n "${RUN_DIR:-}" && -f "$RUN_DIR/.forge-cache.json" ]] && cp "$RUN_DIR/.forge-cache.json" "$_FORGE_CACHE_JSON"
    return 0
}
trap _restore_forge_cache EXIT

# ── Lightweight JSON-RPC helpers (the whole send/monitor path uses only these) ──
_rpc_send_raw() {  # $1=rpc $2=raw signed tx → accepted hash on stdout
    local out hash
    out=$(curl -s --max-time 15 -X POST "$1" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"$2\"]}") || return 1
    hash=$(jq -r '.result // empty' <<< "$out" 2>/dev/null)
    [[ -n "$hash" ]] || { echo "$out" >&2; return 1; }
    echo "$hash"
}

_batch_receipts() {  # $1=rpc; stdin: one tx hash per line → "hash hexblock status" for the mined ones
    # Chunked (200/request) and fed to curl via stdin (-d @-): one giant batch
    # passed as an argv value exceeds the exec per-argument limit ("Argument
    # list too long" from ~850 hashes) and can trip node batch caps.
    local rpc="$1" hashes=() o
    mapfile -t hashes
    (( ${#hashes[@]} > 0 )) || return 0
    for ((o = 0; o < ${#hashes[@]}; o += 200)); do
        printf '%s\n' "${hashes[@]:o:200}" \
            | jq -R -s 'split("\n") | map(select(length > 0)) | to_entries
                | map({jsonrpc: "2.0", id: .key, method: "eth_getTransactionReceipt", params: [.value]})' \
            | curl -s --max-time 30 -X POST "$rpc" -H 'Content-Type: application/json' -d @- \
            | jq -r '.[]? | .result | select(. != null) | "\(.transactionHash) \(.blockNumber) \(.status)"' 2>/dev/null
    done
    return 0
}

_front_rpc() { [[ "$1" == "L2" ]] && echo "${L2_FRONT:-$L2_RPC}" || echo "${L1_FRONT:-$L1_RPC}"; }

# ── One receipt sweep: move newly-mined rows from a pending csv to a mined csv ──
# One batched request per chain; used every monitor tick (triggers AND deploy
# waves) and as the one-shot refresh before a deferred verify (a run stopped
# mid-monitor leaves mined txs still listed as pending). Trigger receipts come
# from the fronts (mode "front", the default); deploy receipts from the normal
# RPCs (mode "direct" — deploys never touch a front).
_poll_pending_once() {
    local pend="${1:-$RUN_DIR/pending.csv}" mined="${2:-$RUN_DIR/mined.csv}" mode="${3:-front}"
    local chain name c hash hexblock status rpc
    for chain in L1 L2; do
        if [[ "$mode" == "front" ]]; then
            rpc=$(_front_rpc "$chain")
        else
            [[ "$chain" == "L2" ]] && rpc="$L2_RPC" || rpc="$L1_RPC"
        fi
        local -A _JOB_OF=()
        while IFS=, read -r name c hash; do
            [[ "$c" == "$chain" ]] && _JOB_OF[$hash]="$name"
        done < "$pend"
        (( ${#_JOB_OF[@]} > 0 )) || continue
        while read -r hash hexblock status; do
            [[ -n "${_JOB_OF[$hash]:-}" ]] || continue
            echo "${_JOB_OF[$hash]},$chain,$hash,$(printf "%d" "$hexblock"),$status" >> "$mined"
            grep -vF ",$hash" "$pend" > "$pend.tmp" || true
            mv "$pend.tmp" "$pend"
        done < <(printf '%s\n' "${!_JOB_OF[@]}" | _batch_receipts "$rpc")
    done
}

# ── Monitor a sent-csv until everything is mined or a deadline passes ──
# $1=sent.csv $2=mined.csv $3=pending.csv $4=timeout $5=rpc mode. Returns 1 on
# timeout, leaving the unmined rows in $3.
_monitor_files() {
    cp "$1" "$3"; : > "$2"
    local start deadline total left
    start=$(date +%s); deadline=$(( start + $4 )); total=$(wc -l < "$1")
    while true; do
        _poll_pending_once "$3" "$2" "$5"
        left=$(wc -l < "$3")
        echo "  mined $(( total - left ))/$total ($(( $(date +%s) - start ))s elapsed)"
        (( left == 0 )) && return 0
        (( $(date +%s) >= deadline )) && { echo "MONITOR TIMEOUT: $left tx(s) never mined (see $3)"; return 1; }
        sleep "$POLL_INTERVAL"
    done
}

# ══════════════════════════════════════════════
#  Verify phase (also the whole of --verify-only)
# ══════════════════════════════════════════════
verify_phase() {
    [[ -f "$RUN_DIR/jobs.csv" && -f "$RUN_DIR/wallets.csv" ]] || {
        echo "Not a staged run dir: $RUN_DIR (missing jobs.csv/wallets.csv)"; exit 1; }
    # A truncated run (stopped mid-prepare, resumed) never prepared some listed
    # jobs on purpose — report those as truncated, not as failures.
    [[ -f "$RUN_DIR/.truncated" ]] && RESUME_TRUNCATED=true
    declare -A JOB_PK
    local j a k
    while IFS=, read -r j a k; do
        [[ "$j" == "job" ]] && continue
        JOB_PK[$j]="$k"
    done < "$RUN_DIR/wallets.csv"

    # Refresh receipt bookkeeping before judging anything unmined: a run stopped
    # during (or before) its monitor phase leaves mined txs listed as pending.
    if [[ ! -f "$RUN_DIR/pending.csv" && -s "$RUN_DIR/sent.csv" ]]; then
        cp "$RUN_DIR/sent.csv" "$RUN_DIR/pending.csv"
        touch "$RUN_DIR/mined.csv"
    fi
    if [[ -s "$RUN_DIR/pending.csv" ]]; then
        _poll_pending_once
        echo "receipt re-poll: $(wc -l < "$RUN_DIR/pending.csv") tx(s) still unmined"
    fi

    echo ""
    echo "== Verify phase ($VERIFY_PARALLEL parallel) — logs in $RUN_DIR/jobs/<job>/verify.log"
    # Pre-read the job list: the loop spawns children, which must not inherit
    # (and drain) the csv on stdin.
    local JOBS_ROWS=()
    mapfile -t JOBS_ROWS < <(tail -n +2 "$RUN_DIR/jobs.csv")
    local V_NAMES=() V_PIDS=() PRE_FAILED=() NOT_PREPARED=0 SKIPPED_OK=0 row name sol dir want_n sent_n
    _restore_forge_cache
    for row in "${JOBS_ROWS[@]}"; do
        name="${row%%,*}"; sol="${row#*,}"
        dir="$RUN_DIR/jobs/$name"
        want_n=$(sed -n 's/^declare -- _TX_COUNT="\(.*\)"$/\1/p' "$dir/manifest.env" 2>/dev/null)
        sent_n=$(wc -l 2>/dev/null < "$dir/txs.txt" || echo 0)
        if [[ ! -f "$dir/manifest.env" ]]; then
            # A truncated (resumed) run deliberately stopped before these jobs —
            # report them, but they are not failures. Jobs the prepare phase
            # actually dropped carry a .prepare-failed marker and stay failures.
            if [[ ! -f "$dir/.prepare-failed" ]] && $RESUME_TRUNCATED; then NOT_PREPARED=$((NOT_PREPARED+1)); else
                PRE_FAILED+=("$name (prepare failed - $dir/prepare.log)"); fi
            continue
        elif [[ ! -s "$dir/txs.txt" ]]; then
            PRE_FAILED+=("$name (nothing sent)"); continue
        elif (( sent_n < ${want_n:-1} )); then   # a send failure mid-job is an orchestration failure, not a protocol one
            PRE_FAILED+=("$name (partial send: $sent_n of ${want_n:-1} trigger tx(s) went out - see send-failed.log)"); continue
        elif [[ -f "$RUN_DIR/pending.csv" ]] && grep -q "^$name," "$RUN_DIR/pending.csv"; then
            PRE_FAILED+=("$name (trigger tx never mined - see pending.csv)"); continue
        elif [[ "${SKIP_VERIFIED:-0}" == "1" ]] && grep -q "^====== Done ======" "$dir/verify.log" 2>/dev/null; then
            SKIPPED_OK=$((SKIPPED_OK+1)); continue   # already passed in an earlier verify pass
        fi
        while (( $(jobs -rp | wc -l) >= VERIFY_PARALLEL )); do sleep 2; done
        echo "VERIFY $name"
        E2E_STAGE=verify E2E_JOB_DIR="$dir" E2E_SNAPSHOT="$RUN_DIR/snapshot.env" \
            E2E_L1TX_CACHE="$RUN_DIR/l1tx-cache" \
            bash script/e2e/run/network.sh "$sol" \
            --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
            --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
            --pk "${JOB_PK[$name]}" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
            > "$dir/verify.log" 2>&1 < /dev/null &
        V_NAMES+=("$name"); V_PIDS+=($!)
    done

    local PASS=0 FAIL=0 FAILED_LIST=() i
    for i in "${!V_PIDS[@]}"; do
        if wait "${V_PIDS[$i]}"; then
            PASS=$((PASS+1)); echo "RESULT ${V_NAMES[$i]}: PASS"
        else
            FAIL=$((FAIL+1)); FAILED_LIST+=("${V_NAMES[$i]}")
            echo "RESULT ${V_NAMES[$i]}: FAIL  (log: $RUN_DIR/jobs/${V_NAMES[$i]}/verify.log)"
        fi
    done

    echo ""
    echo "===== STAGED RESULT: $PASS passed$( ((SKIPPED_OK > 0)) && echo " (+$SKIPPED_OK already verified, skipped)"), $FAIL failed, ${#PRE_FAILED[@]} not verifiable ====="
    if (( NOT_PREPARED > 0 )); then
        echo "  ($NOT_PREPARED listed job(s) never prepared - run truncated before them; not counted)"
    fi
    local t
    for t in "${FAILED_LIST[@]:-}";  do [[ -n "$t" ]] && echo "  FAILED: $t"; done
    for t in "${PRE_FAILED[@]:-}";   do [[ -n "$t" ]] && echo "  NOT RUN: $t"; done
    _print_block_summary
    [[ $FAIL -eq 0 && ${#PRE_FAILED[@]} -eq 0 ]]
}

# ── Block summary: where the run's txs landed on each chain ──
# Trigger txs come from mined.csv (name,chain,hash,block,status); settlement txs
# (L1 postBatch / L2 loadTable) from the "(block N)" Summary lines of each
# job's verify.log — no extra RPC calls.
_block_list() {   # stdin: one block number per line → "5062 x7  5063 x3"
    sort -n | uniq -c | awk '{printf "%s%s x%d", (NR>1?"  ":""), $2, $1} END{print ""}'
}
_settle_blocks() {   # $1 = summary label ("L1 postBatch" / "L2 loadTable")
    grep -hE "^$1:.*\(block [0-9]+\)" "$RUN_DIR"/jobs/*/verify.log 2>/dev/null \
        | sed -E 's/.*\(block ([0-9]+)\)/\1/' | _block_list
}
_print_block_summary() {
    local l1t l2t l1b l2b
    l1t=$(awk -F, '$2=="L1"{print $4}' "$RUN_DIR/mined.csv" 2>/dev/null | _block_list)
    l2t=$(awk -F, '$2=="L2"{print $4}' "$RUN_DIR/mined.csv" 2>/dev/null | _block_list)
    l1b=$(_settle_blocks "L1 postBatch")
    l2b=$(_settle_blocks "L2 loadTable")
    echo ""
    echo "  Blocks mined (block xN = N txs / jobs in that block):"
    echo "    trigger txs    L1: ${l1t:-none}"
    echo "                   L2: ${l2t:-none}"
    echo "    L1 postBatch:  ${l1b:-none}"
    echo "    L2 loadTable:  ${l2b:-none}"
}

if [[ -n "$VERIFY_ONLY" ]]; then
    RUN_DIR="${VERIFY_ONLY%/}"
    _bind_run_network "$RUN_DIR"
    _warm_forge_cache
    verify_phase
    exit $?
fi

PREP_FAIL=0
DEAD=","   # ",name," membership list of jobs that can no longer continue
_prep_failed() {  # $1=job name $2=reason — drop the job and leave a marker the verify summary reads
    [[ "$DEAD" == *",$1,"* ]] && return 0
    DEAD="$DEAD$1,"; PREP_FAIL=$((PREP_FAIL+1))
    touch "$RUN_DIR/jobs/$1/.prepare-failed"
    echo "PREPARE FAILED: $1 ($2)"
}
_job_launch_prepare() {  # $1=job index $2=E2E_PREPARE_STEP value ("" = classic one-pass)
    E2E_STAGE=prepare E2E_PREPARE_STEP="$2" E2E_JOB_DIR="$RUN_DIR/jobs/${JOB_NAMES[$1]}" \
        bash script/e2e/run/network.sh "${JOB_SOLS[$1]}" \
        --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
        --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
        --pk "${WALLET_PKS[$1]}" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        >> "$RUN_DIR/jobs/${JOB_NAMES[$1]}/prepare.log" 2>&1
}

if [[ -n "$RESUME" ]]; then
# ── Resume a stopped run: finish what is deploy-complete, fire what is prepared ──
# A job is fireable once it has a complete manifest (written last by the prepare
# stage) and has sent nothing yet (double-fire guard). A wave-mode job whose
# deploys all mined (.deploys-done + deploy-env.env) but that never reached the
# finish step only lacks the read-only part (trigger presign + ComputeExpected),
# so that step is re-run here first — no deploy is repeated, and a job killed
# mid-finish just rewrites its manifest. Everything else in jobs.csv is left for
# the verify summary to report as "never prepared".
RUN_DIR="${RESUME%/}"
[[ -f "$RUN_DIR/jobs.csv" && -f "$RUN_DIR/wallets.csv" ]] || {
    echo "Not a staged run dir: $RUN_DIR (missing jobs.csv/wallets.csv)"; exit 1; }
_bind_run_network "$RUN_DIR"
declare -A _PK_OF
while IFS=, read -r _j _a _k; do [[ "$_j" == "job" ]] || _PK_OF[$_j]="$_k"; done < "$RUN_DIR/wallets.csv"
JOB_NAMES=(); JOB_SOLS=(); WALLET_PKS=()
_SKIPPED_SENT=0; _FINISH_IDX=()
while IFS=, read -r _name _sol; do
    [[ "$_name" == "job" ]] && continue
    _jd="$RUN_DIR/jobs/$_name"
    # fully sent = one hash per pre-signed tx; a partial multi-tx send is resumed from where it stopped
    if [[ -s "$_jd/txs.txt" ]] && (( $(wc -l < "$_jd/txs.txt") >= $(wc -l < "$_jd/rawtxs.txt" 2>/dev/null || echo 0) )); then
        _SKIPPED_SENT=$((_SKIPPED_SENT+1)); continue
    fi
    if [[ ! -f "$_jd/manifest.env" ]]; then
        [[ -f "$_jd/.deploys-done" && -s "$_jd/deploy-env.env" && -n "${_PK_OF[$_name]:-}" ]] || continue
        _FINISH_IDX+=(${#JOB_NAMES[@]})
    fi
    JOB_NAMES+=("$_name"); JOB_SOLS+=("$_sol"); WALLET_PKS+=("${_PK_OF[$_name]}")
done < "$RUN_DIR/jobs.csv"
RESUME_TRUNCATED=true
touch "$RUN_DIR/.truncated"   # later --verify-only passes report unprepared jobs as truncated, not failed

_warm_forge_cache
if (( ${#_FINISH_IDX[@]} > 0 )); then
    echo "== RESUME $RUN_DIR: finishing ${#_FINISH_IDX[@]} deploy-complete job(s) ($PREPARE_PARALLEL parallel)"
    _restore_forge_cache
    F_PIDS=(); F_IDX=()
    for i in "${_FINISH_IDX[@]}"; do
        while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 1; done
        echo "PREPARE ${JOB_NAMES[$i]}"
        _job_launch_prepare "$i" finish &
        F_PIDS+=($!); F_IDX+=($i)
    done
    for k in "${!F_PIDS[@]}"; do
        if wait "${F_PIDS[$k]}"; then rm -f "$RUN_DIR/jobs/${JOB_NAMES[${F_IDX[$k]}]}/.prepare-failed"
        else _prep_failed "${JOB_NAMES[${F_IDX[$k]}]}" "finish - log: $RUN_DIR/jobs/${JOB_NAMES[${F_IDX[$k]}]}/prepare.log"; fi
    done
fi
# keep only jobs that now hold a manifest (finish failures drop out here)
_N=(); _S=(); _P=()
for ((i = 0; i < ${#JOB_NAMES[@]}; i++)); do
    [[ -f "$RUN_DIR/jobs/${JOB_NAMES[$i]}/manifest.env" ]] || continue
    _N+=("${JOB_NAMES[$i]}"); _S+=("${JOB_SOLS[$i]}"); _P+=("${WALLET_PKS[$i]}")
done
JOB_NAMES=("${_N[@]}"); JOB_SOLS=("${_S[@]}"); WALLET_PKS=("${_P[@]}")
NJOBS=${#JOB_NAMES[@]}
(( NJOBS > 0 )) || { echo "Nothing prepared-but-unsent in $RUN_DIR"; exit 1; }
echo "== RESUME $RUN_DIR: firing $NJOBS prepared job(s) ($_SKIPPED_SENT already sent, skipped)"

else
# ── Fresh run: expand, fund, prepare ──

[[ $# -gt 0 ]] || { echo "Usage: network-staged.sh [flags] <scenario>[:count] ...  |  --verify-only <run-dir>  |  --resume <run-dir>"; exit 1; }

expand_jobs "$@"
RUN_DIR="tmp/e2e-staged-net/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
_save_run_network "$RUN_DIR"
echo "== $NJOBS job(s) — prepare x$PREPARE_PARALLEL, send x$SEND_WORKERS, verify x$VERIFY_PARALLEL — run dir $RUN_DIR"

echo "job,sol" > "$RUN_DIR/jobs.csv"
for ((i = 0; i < NJOBS; i++)); do
    echo "${JOB_NAMES[$i]},${JOB_SOLS[$i]}" >> "$RUN_DIR/jobs.csv"
done

# Warm artifacts once; every forge-heavy phase restores this cache (see guard above).
_warm_forge_cache

# ══ Phase 1: fund ══
fund_workers

# ══ Phase 2: prepare ══
# waves (default): dry-run + pre-sign each job's k-th Deploy contract, fire the
#   whole wave with the curl workers, mine ONCE, then wave k+1 — the run blocks
#   on deploy mining a handful of times (max Deploy contracts per scenario)
#   instead of once per script per job. Wave ordering is what keeps the dry-run
#   nonce (and thus every predicted CREATE address) truthful.
# classic (PREPARE_MODE=classic): each job's forge deploys and waits for its own
#   receipts — the original single-pass prepare.
PREPARE_MODE="${PREPARE_MODE:-waves}"

if [[ "$PREPARE_MODE" == "waves" ]]; then
    for ((wave = 1; ; wave++)); do
        # ── dry-run + presign every live job's <wave>-th Deploy contract ──
        W_PIDS=(); W_IDX=()
        _restore_forge_cache
        for ((i = 0; i < NJOBS; i++)); do
            name="${JOB_NAMES[$i]}"
            [[ "$DEAD" == *",$name,"* ]] && continue
            [[ -f "$RUN_DIR/jobs/$name/.deploys-done" ]] && continue
            while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 1; done
            mkdir -p "$RUN_DIR/jobs/$name"
            _job_launch_prepare "$i" "deploy:$wave" &
            W_PIDS+=($!); W_IDX+=($i)
        done
        (( ${#W_PIDS[@]} > 0 )) || break   # every job is done deploying (or dead)
        echo ""
        echo "== Prepare wave $wave: dry-run + presign, ${#W_PIDS[@]} job(s) ($PREPARE_PARALLEL parallel)"
        WAVE_TXS=false
        for k in "${!W_PIDS[@]}"; do
            rc=0; wait "${W_PIDS[$k]}" || rc=$?
            name="${JOB_NAMES[${W_IDX[$k]}]}"
            case $rc in
                0) WAVE_TXS=true ;;
                2) touch "$RUN_DIR/jobs/$name/.deploys-done" ;;   # fewer than <wave> Deploy contracts
                *) _prep_failed "$name" "wave $wave dry-run - log: $RUN_DIR/jobs/$name/prepare.log" ;;
            esac
        done
        $WAVE_TXS || continue

        # ── fire the wave (curl workers; a job's txs stay in nonce order) ──
        : > "$RUN_DIR/deploy-sent-$wave.csv"
        : > "$RUN_DIR/deploy-send-failed-$wave.txt"
        for ((w = 0; w < SEND_WORKERS; w++)); do
            (
                for ((j = w; j < NJOBS; j += SEND_WORKERS)); do
                    name="${JOB_NAMES[$j]}"; f="$RUN_DIR/jobs/$name/deploytxs-wave$wave.txt"
                    [[ "$DEAD" == *",$name,"* ]] && continue
                    [[ -f "$f" ]] || continue
                    while IFS=' ' read -r chain raw; do
                        [[ -n "$raw" ]] || continue
                        [[ "$chain" == "L2" ]] && rpc="$L2_RPC" || rpc="$L1_RPC"  # deploys skip the fronts
                        if ! hash=$(_rpc_send_raw "$rpc" "$raw" 2>>"$RUN_DIR/send-failed.log"); then
                            echo "DEPLOY SEND FAILED: $name (wave $wave)" >> "$RUN_DIR/send-failed.log"
                            echo "$name" >> "$RUN_DIR/deploy-send-failed-$wave.txt"   # parent marks it dead
                            break
                        fi
                        echo "$name,$chain,$hash" >> "$RUN_DIR/deploy-sent-$wave.csv"
                    done < "$f"
                done
            ) &
        done
        wait   # only the senders are in flight here
        echo "  fired $(wc -l < "$RUN_DIR/deploy-sent-$wave.csv") deploy tx(s)"
        # A job whose deploy never left the machine would dry-run the next wave
        # from a stale nonce and presign a colliding trigger — drop it now.
        while read -r name; do
            [[ -n "$name" ]] && _prep_failed "$name" "wave $wave deploy tx not sent - see send-failed.log"
        done < "$RUN_DIR/deploy-send-failed-$wave.txt"

        # ── mine the wave (one shared wait) ──
        if [[ -s "$RUN_DIR/deploy-sent-$wave.csv" ]]; then
            _monitor_files "$RUN_DIR/deploy-sent-$wave.csv" "$RUN_DIR/deploy-mined-$wave.csv" \
                "$RUN_DIR/deploy-pending-$wave.csv" "${DEPLOY_MINE_TIMEOUT:-300}" direct || true
            while IFS=, read -r name chain hash; do
                _prep_failed "$name" "wave $wave deploy tx $hash never mined"
            done < "$RUN_DIR/deploy-pending-$wave.csv"
            while IFS=, read -r name chain hash blk status; do
                [[ "$status" == "0x1" ]] && continue
                _prep_failed "$name" "wave $wave deploy tx $hash reverted"
            done < "$RUN_DIR/deploy-mined-$wave.csv"
        fi
    done

    # ── assert every predicted address really holds code before trusting it ──
    # The whole wave design rests on dry-run address prediction; this is the
    # cheap cross-check (one batched eth_getCode per chain). Only exact-address
    # env values count — 32-byte hashes would false-positive a substring grep.
    # PREDICTED_* outputs are exempt: they name addresses a scenario pre-computes
    # for a contract that is deployed later, during execution (CREATE2 from a
    # bridge, say), so they legitimately hold no code at this point.
    _addrs_with_code() {  # $1=rpc; stdin: one address per line → subset holding code
        # Chunked + stdin-fed for the same ARG_MAX reason as _batch_receipts.
        local addrs=() o
        mapfile -t addrs
        (( ${#addrs[@]} > 0 )) || return 0
        for ((o = 0; o < ${#addrs[@]}; o += 200)); do
            local chunk=("${addrs[@]:o:200}")
            printf '%s\n' "${chunk[@]}" | jq -R -s 'split("\n")|map(select(length>0))|to_entries
                |map({jsonrpc:"2.0",id:.key,method:"eth_getCode",params:[.value,"latest"]})' \
                | curl -s --max-time 30 -X POST "$1" -H 'Content-Type: application/json' -d @- \
                | jq -r '.[]? | select(.result != null and .result != "0x") | .id' \
                | while read -r id; do echo "${chunk[$id]}"; done
        done
    }
    mapfile -t _ALL_ADDRS < <(sed -n '/^PREDICTED_/d; s/^[A-Z0-9_]*=\(0x[0-9a-fA-F]\{40\}\)$/\1/p' \
        "$RUN_DIR"/jobs/*/deploy-env.env 2>/dev/null | sort -u)
    if (( ${#_ALL_ADDRS[@]} > 0 )); then
        _CODED=$( { printf '%s\n' "${_ALL_ADDRS[@]}" | _addrs_with_code "$L1_RPC"; \
                    printf '%s\n' "${_ALL_ADDRS[@]}" | _addrs_with_code "$L2_RPC"; } | sort -u )
        for ((i = 0; i < NJOBS; i++)); do
            name="${JOB_NAMES[$i]}"
            [[ "$DEAD" == *",$name,"* ]] && continue
            envf="$RUN_DIR/jobs/$name/deploy-env.env"
            [[ -f "$envf" ]] || continue
            while read -r a; do
                grep -qiF "$a" <<< "$_CODED" && continue
                _prep_failed "$name" "predicted address $a has no code on either chain"
                break
            done < <(sed -n '/^PREDICTED_/d; s/^[A-Z0-9_]*=\(0x[0-9a-fA-F]\{40\}\)$/\1/p' "$envf" | sort -u)
        done
        echo "deploy-liveness: ${#_ALL_ADDRS[@]} predicted address(es) checked"
    fi

    # ── prepare-finish: trigger presign + ComputeExpected (read-only, fast) ──
    echo ""
    echo "== Prepare finish ($PREPARE_PARALLEL parallel)"
    _restore_forge_cache
    F_PIDS=(); F_IDX=()
    for ((i = 0; i < NJOBS; i++)); do
        [[ "$DEAD" == *",${JOB_NAMES[$i]},"* ]] && continue
        while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 1; done
        echo "PREPARE ${JOB_NAMES[$i]}"
        _job_launch_prepare "$i" finish &
        F_PIDS+=($!); F_IDX+=($i)
    done
    for k in "${!F_PIDS[@]}"; do
        wait "${F_PIDS[$k]}" || _prep_failed "${JOB_NAMES[${F_IDX[$k]}]}" "finish - log: $RUN_DIR/jobs/${JOB_NAMES[${F_IDX[$k]}]}/prepare.log"
    done
else
    # ── classic single-pass prepare ──
    echo ""
    echo "== Prepare phase ($PREPARE_PARALLEL parallel, classic)"
    _restore_forge_cache
    P_PIDS=()
    for ((i = 0; i < NJOBS; i++)); do
        while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 2; done
        mkdir -p "$RUN_DIR/jobs/${JOB_NAMES[$i]}"
        echo "PREPARE ${JOB_NAMES[$i]}"
        _job_launch_prepare "$i" "" &
        P_PIDS+=($!)
    done
    for ((i = 0; i < ${#P_PIDS[@]}; i++)); do
        wait "${P_PIDS[$i]}" || _prep_failed "${JOB_NAMES[$i]}" "log: $RUN_DIR/jobs/${JOB_NAMES[$i]}/prepare.log"
    done
fi
echo "prepared $((NJOBS - PREP_FAIL))/$NJOBS job(s)"
(( NJOBS - PREP_FAIL > 0 )) || { echo "Nothing prepared - aborting"; exit 1; }

fi  # ── end fresh-run block (resume joins here: snapshot → send → monitor → verify) ──

# ══ Phase 3: snapshot ══
# One pre-send snapshot for the whole run: every verification scan starts here,
# so nothing settled before this instant can satisfy a check. On a resume the
# EXISTING snapshot is kept — moving it forward would start already-sent jobs'
# scans after their settlements.
if [[ ! -f "$RUN_DIR/snapshot.env" ]]; then
    # Both RPCs must answer: an empty snapshot would be kept by every later
    # resume and leave the verify scans unbounded.
    _L1B=$(cast block-number --rpc-url "$L1_RPC") && _L2B=$(cast block-number --rpc-url "$L2_RPC") \
        && [[ -n "$_L1B" && -n "$_L2B" ]] || { echo "Snapshot failed: RPCs unreachable - nothing sent"; exit 1; }
    printf 'L1_BLOCK_BEFORE=%s\nL2_BLOCK_BEFORE=%s\n' "$_L1B" "$_L2B" > "$RUN_DIR/snapshot.env"
fi
echo ""
echo "== Snapshot: $(tr '\n' ' ' < "$RUN_DIR/snapshot.env")"

# ══ Phase 4: send (curl only — nothing heavier runs until the monitor is done) ══
echo "== Send phase ($SEND_WORKERS workers)"
# touch, not truncate — a resumed run appends to the earlier records
touch "$RUN_DIR/sent.csv" "$RUN_DIR/send-failed.log"
send_worker() {  # $1=worker index — handles jobs $1, $1+W, $1+2W, ... (round-robin shard)
    local j name dir chain rpc raw hash done_n
    for ((j = $1; j < NJOBS; j += SEND_WORKERS)); do
        name="${JOB_NAMES[$j]}"; dir="$RUN_DIR/jobs/$name"
        [[ -f "$dir/manifest.env" ]] || continue   # prepare failed
        chain=$(sed -n 's/^declare -- _TRIGGER_CHAIN="\(.*\)"$/\1/p' "$dir/manifest.env")
        rpc=$(_front_rpc "$chain")
        # A resumed partial multi-tx send continues after the hashes already recorded.
        done_n=0
        [[ -f "$dir/txs.txt" ]] && done_n=$(wc -l < "$dir/txs.txt")
        touch "$dir/txs.txt"
        # Multi-tx jobs: same worker, in nonce order, back-to-back (fire-and-forget).
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            if ! hash=$(_rpc_send_raw "$rpc" "$raw" 2>>"$RUN_DIR/send-failed.log"); then
                echo "SEND FAILED: $name ($chain)" >> "$RUN_DIR/send-failed.log"
                break
            fi
            echo "$hash" >> "$dir/txs.txt"
            echo "$name,$chain,$hash" >> "$RUN_DIR/sent.csv"   # single-line O_APPEND: atomic
        done < <(tail -n +$((done_n + 1)) "$dir/rawtxs.txt")
    done
}
S_PIDS=()
for ((w = 0; w < SEND_WORKERS; w++)); do
    send_worker "$w" &
    S_PIDS+=($!)
done
for pid in "${S_PIDS[@]}"; do wait "$pid"; done
N_SENT=$(wc -l < "$RUN_DIR/sent.csv")
echo "fired $N_SENT tx(s)$([[ -s "$RUN_DIR/send-failed.log" ]] && echo " — SEND FAILURES in $RUN_DIR/send-failed.log")"
(( N_SENT > 0 )) || { echo "Nothing sent - aborting"; exit 1; }

# ══ Phase 5: monitor ══
# One batched eth_getTransactionReceipt request per chain per tick — the local
# footprint stays two curl calls every POLL_INTERVAL s no matter how many txs
# are in flight. Fronts HOLD trigger txs until the composer bundles them, so
# "sent but not mined" is a real (and eventually failing) state: MINE_TIMEOUT
# bounds the wait and leftovers stay in pending.csv.
echo ""
echo "== Monitor phase (every ${POLL_INTERVAL}s, timeout ${MINE_TIMEOUT}s)"
cp "$RUN_DIR/sent.csv" "$RUN_DIR/pending.csv"
: > "$RUN_DIR/mined.csv"
MON_START=$(date +%s)
MON_DEADLINE=$(( MON_START + MINE_TIMEOUT ))
while true; do
    _poll_pending_once
    N_MINED=$(wc -l < "$RUN_DIR/mined.csv")
    N_LEFT=$(wc -l < "$RUN_DIR/pending.csv")
    echo "  mined $N_MINED/$N_SENT ($(( $(date +%s) - MON_START ))s elapsed)"
    (( N_LEFT == 0 )) && break
    if (( $(date +%s) >= MON_DEADLINE )); then
        echo "MONITOR TIMEOUT: $N_LEFT tx(s) never mined (see $RUN_DIR/pending.csv):"
        sed 's/^/  UNMINED: /' "$RUN_DIR/pending.csv"
        break
    fi
    sleep "$POLL_INTERVAL"
done
N_REVERTED=$(awk -F, '$5 != "0x1"' "$RUN_DIR/mined.csv" | wc -l)
(( N_REVERTED > 0 )) && { echo "WARNING: $N_REVERTED mined tx(s) REVERTED (status != 0x1):"; awk -F, '$5 != "0x1" {print "  " $0}' "$RUN_DIR/mined.csv"; }

if $NO_VERIFY; then
    echo ""
    echo "== --no-verify: stopping after monitor. Verify later with:"
    echo "   bash script/e2e/run/network-staged.sh --verify-only $RUN_DIR"
    [[ ! -s "$RUN_DIR/pending.csv" && $PREP_FAIL -eq 0 ]]
    exit $?
fi

# ══ Phase 6: verify ══
verify_phase
