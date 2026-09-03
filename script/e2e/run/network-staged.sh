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
#   2. prepare  — default "plan" mode: one batched nonce barrier, then ONE forge
#                 run per job (capped at PREPARE_PARALLEL) that drives all of the
#                 scenario's Deploy* contracts against in-process forks of both
#                 chains with the wallet nonces injected and pre-signs the planned
#                 deploy txs, trigger txs, and expected verification data
#                 (network.sh E2E_STAGE=prepare, E2E_PREPARE_STEP=plan) — nothing waits
#                 for a block. ALL deploy txs are then fired at
#                 once by the curl workers, mined with ONE wait, a batched
#                 eth_getCode pass asserts every predicted address holds code, and
#                 version-2 manifests are already complete. The finish step is
#                 retained only for waves mode and version-1/incomplete resumes.
#                 PREPARE_MODE=waves = per Deploy-contract dry-run waves against the
#                 real RPCs, mined one wave at a time (E2E_PREPARE_STEP=deploy:<k>,
#                 then finish); PREPARE_MODE=classic = per-job forge deploys.
#                 Every prepare launch is bounded by PREPARE_JOB_TIMEOUT (a hung
#                 forge run drops its job; the run goes on).
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
#   --resend <run-dir>       like --resume, but ALSO re-fires the jobs whose
#                    triggers were sent and never mined (a front accepted and
#                    then dropped them; their nonces are still free): the old
#                    hashes are archived (txs.txt.attempt<N>, sent.csv.attempt<N>)
#                    and the same pre-signed raw txs go out again — usually with
#                    SEND_PAUSE / --workers to avoid the burst that lost them
#
# Env knobs:
#   PREPARE_MODE      plan (default) | waves | classic — see phase 2 above
#   DEPLOY_MINE_TIMEOUT  seconds to wait for the deploy txs to mine (default 300)
#   DEPLOY_POLL_INTERVAL fixed deploy receipt polling override
#   PREPARE_PARALLEL  concurrent prepare jobs (default 40)
#   PREPARE_JOB_TIMEOUT  seconds one prepare launch (plan / wave / finish /
#                     classic) may run before its job is dropped (default 300)
#   SEND_WORKERS      send workers (default 80; --workers overrides)
#   SEND_RETRIES      attempts per raw-tx send when the RPC gives no answer at
#                     all (default 3; JSON-RPC errors are never retried)
#   SEND_PAUSE        seconds each send worker sleeps after every trigger it
#                     fires (default 0 = burst); the effective rate is
#                     SEND_WORKERS / SEND_PAUSE tx/s, e.g. --workers 5 with
#                     SEND_PAUSE=0.5 → 10 tx/s
#   VERIFY_PARALLEL   concurrent verify jobs (default 8)
#   POLL_INTERVAL     fixed trigger receipt polling compatibility override
#   POLL_FAST_INTERVAL / POLL_FAST_WINDOW / POLL_MEDIUM_INTERVAL /
#                     POLL_MEDIUM_WINDOW / POLL_SLOW_INTERVAL configure the
#                     adaptive default (1s through 15s, 3s through 45s, then 10s)
#   MINE_TIMEOUT      seconds to wait for all trigger receipts (default 600)
#   E2E_TRIGGER_GAS   trigger gas limit, passed through to network.sh (default
#                     1000000; a scenario's GAS output takes precedence)
#   E2E_TIMING_BASELINE  timings.csv of a reference run: run phases more than
#                     TIMING_REGRESSION_PCT (default 20) % slower are reported
#   FUND_ETH / FLOOR_ETH / SOURCE_PK / MULTISEND_BATCH / DEVNET_ENV  as in
#   network-parallel.sh.
#
# Run dir: tmp/e2e-staged-net/<ts>/ — jobs.csv, wallets.csv, snapshot.env,
# timings.csv (run phases per attempt) / job-timings.csv (per-job plan / finish
# / verify durations; schema in orchestrator-lib.sh),
# deploy-sent.csv / deploy-mined.csv, sent.csv, mined.csv, pending.csv (what
# never mined), send-notes.log (duplicate sends recovered on resume),
# jobs/<job>/{prepare.log, deploy-env.env, deploy-addrs.txt, deploytxs.txt,
# deploy-hashes.txt, .deploys-done, manifest.env, rawtxs.txt, compute.out,
# txs.txt, verify.log}.
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
PREPARE_JOB_TIMEOUT="${PREPARE_JOB_TIMEOUT:-300}"
SEND_WORKERS="${SEND_WORKERS:-80}"
VERIFY_PARALLEL="${VERIFY_PARALLEL:-8}"

POLL_INTERVAL_SET=${POLL_INTERVAL+x}
DEPLOY_POLL_INTERVAL_SET=${DEPLOY_POLL_INTERVAL+x}
POLL_INTERVAL="${POLL_INTERVAL:-10}"
MINE_TIMEOUT="${MINE_TIMEOUT:-600}"
DEPLOY_MINE_TIMEOUT="${DEPLOY_MINE_TIMEOUT:-300}"
DEPLOY_POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-3}"
POLL_FAST_INTERVAL="${POLL_FAST_INTERVAL:-1}"
POLL_FAST_WINDOW="${POLL_FAST_WINDOW:-15}"
POLL_MEDIUM_INTERVAL="${POLL_MEDIUM_INTERVAL:-3}"
POLL_MEDIUM_WINDOW="${POLL_MEDIUM_WINDOW:-45}"
POLL_SLOW_INTERVAL="${POLL_SLOW_INTERVAL:-10}"
DIRECT=false
FRESH=false
NO_VERIFY=false
VERIFY_ONLY=""
RESUME=""
RESEND=false
SEND_PAUSE="${SEND_PAUSE:-0}"
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
        --resend)      RESUME="${2:?--resend needs a run dir}"; RESEND=true; shift 2 ;;
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
    _phase_begin build
    forge build > /dev/null 2>&1 || { echo "forge build failed"; exit 1; }
    cp "$_FORGE_CACHE_JSON" "$RUN_DIR/.forge-cache.json"
    _phase_end build
}
_restore_forge_cache() {
    [[ -n "${RUN_DIR:-}" && -f "$RUN_DIR/.forge-cache.json" ]] && cp "$RUN_DIR/.forge-cache.json" "$_FORGE_CACHE_JSON"
    return 0
}
# Exit: put the forge cache back, close every phase still open (an abort mid-phase
# still leaves a row), record the total and print the timing summary.
_on_exit() {
    local rc=$?
    _restore_forge_cache
    if [[ -n "${ATTEMPT:-}" ]]; then
        _phases_close_open "$([[ $rc -eq 0 ]] && echo pass || echo fail)"
        _timing_summary
    fi
}
trap _on_exit EXIT

# ── Lightweight JSON-RPC helpers (the whole send/monitor path uses only these) ──
_rpc_send_raw() {  # $1=rpc $2=raw signed tx → accepted hash on stdout
    local out="" hash err attempt
    # Transport failures (no HTTP answer at all: timeout, reset, empty body) are
    # retried SEND_RETRIES times: a resend is idempotent — a node that did take
    # the tx answers "already known" (or a nonce-taken error, resolved below by
    # hash lookup). JSON-RPC errors are never retried.
    for ((attempt = 1; attempt <= ${SEND_RETRIES:-3}; attempt++)); do
        out=$(curl -s --max-time 15 -X POST "$1" -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"$2\"]}") \
            && [[ -n "$out" ]] && break
        out=""
        echo "NOTE: no answer from $1 on send attempt $attempt/${SEND_RETRIES:-3}" >> "$RUN_DIR/send-notes.log"
        sleep 1
    done
    [[ -n "$out" ]] || { echo "send: no answer from $1 after ${SEND_RETRIES:-3} attempts" >&2; return 1; }
    hash=$(jq -r '.result // empty' <<< "$out" 2>/dev/null)
    if [[ -z "$hash" ]]; then
        # A tx the node already holds (a resume re-sending what a crash between
        # send and hash-record left unrecorded, or a duplicate worker) is not a
        # failure: its hash is keccak of the raw bytes, so record that and let
        # the receipt poll decide. "already known" and its variants name THIS
        # tx. "nonce too low" / "replacement transaction underpriced" (nodes) and
        # "invalid nonce ... expected next unreserved nonce" (the fronts) only
        # say the nonce is taken — by our earlier send, or by a foreign tx — so
        # the endpoint is asked whether it holds our hash before it is trusted
        # (fronts answer eth_getTransactionByHash for held and mined txs); if it
        # does not, this is a nonce collision and the job fails now instead of
        # after a receipt poll that could never succeed.
        err=$(jq -r '.error.message // empty' <<< "$out" 2>/dev/null)
        if [[ "$err" =~ (already\ known|already\ imported|known\ transaction) ]]; then
            hash=$(cast keccak "$2") || { echo "$out" >&2; return 1; }
            echo "NOTE: node answered '$err' - treating as already sent ($hash)" >> "$RUN_DIR/send-notes.log"
        elif [[ "$err" =~ (nonce\ too\ low|replacement\ transaction\ underpriced|invalid\ nonce) ]]; then
            hash=$(cast keccak "$2") || { echo "$out" >&2; return 1; }
            if _rpc_has_tx "$1" "$hash"; then
                echo "NOTE: node answered '$err' and holds $hash - treating as already sent" >> "$RUN_DIR/send-notes.log"
            else
                echo "NONCE COLLISION: node answered '$err' and does not hold $hash - a different tx took this nonce" >&2
                return 1
            fi
        else
            echo "$out" >&2; return 1
        fi
    fi
    echo "$hash"
}
_rpc_has_tx() {  # $1=rpc $2=tx hash → 0 when the node knows the tx (pending or mined)
    local out
    out=$(curl -s --max-time 15 -X POST "$1" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionByHash\",\"params\":[\"$2\"]}") || return 1
    jq -e '.result != null' <<< "$out" >/dev/null 2>&1
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
# $1=sent.csv $2=mined.csv $3=pending.csv $4=timeout $5=rpc mode
# $6=fixed poll interval (empty = adaptive, see _poll_delay in orchestrator-lib.sh).
# Returns 1 on timeout, leaving the unmined rows in $3.
_monitor_files() {
    cp "$1" "$3"; : > "$2"
    local start deadline total left interval="${6:-}" now elapsed delay remaining
    start=$(date +%s); deadline=$(( start + $4 )); total=$(wc -l < "$1")
    while true; do
        _poll_pending_once "$3" "$2" "$5"
        left=$(wc -l < "$3")
        now=$(date +%s); elapsed=$((now - start))
        echo "  mined $(( total - left ))/$total (${elapsed}s elapsed)"
        (( left == 0 )) && return 0
        (( now >= deadline )) && { echo "MONITOR TIMEOUT: $left tx(s) never mined (see $3)"; return 1; }
        if [[ -n "$interval" ]]; then delay="$interval"; else delay=$(_poll_delay "$elapsed"); fi
        remaining=$((deadline - now)); (( delay > remaining )) && delay=$remaining
        (( delay > 0 )) && sleep "$delay"
    done
}

# ══════════════════════════════════════════════
#  Deploy-tx helpers shared by the plan and wave prepare modes
# ══════════════════════════════════════════════
# Per-job files: deploytxs<sfx>.txt ("<L1|L2> <rawtx>" lines, nonce order) and
# deploy-hashes<sfx>.txt (one accepted hash per sent line — a resumed fire
# continues after them, so nothing is ever sent twice). Run files:
# deploy-sent<sfx>.csv / deploy-mined<sfx>.csv / deploy-pending<sfx>.csv.
# sfx is "" (plan mode: one batch) or "-wave<k>". A job holding .deploys-done
# has nothing left to fire.

# ── Fire every live job's pending deploy txs with the curl workers ──
# Deploys go to the normal RPCs, never the fronts (fronts swallow ordinary txs).
# A job whose send fails is dropped: its remaining txs would collide.
_fire_deploy_txs() {  # $1=sfx
    local sfx="$1" w pids=()
    touch "$RUN_DIR/deploy-sent$sfx.csv"
    : > "$RUN_DIR/deploy-send-failed$sfx.txt"
    for ((w = 0; w < SEND_WORKERS; w++)); do
        (
            local j name dir f chain raw rpc hash done_n
            for ((j = w; j < NJOBS; j += SEND_WORKERS)); do
                name="${JOB_NAMES[$j]}"; dir="$RUN_DIR/jobs/$name"; f="$dir/deploytxs$sfx.txt"
                [[ "$DEAD" == *",$name,"* ]] && continue
                [[ -s "$f" && ! -f "$dir/.deploys-done" ]] || continue
                done_n=0
                [[ -f "$dir/deploy-hashes$sfx.txt" ]] && done_n=$(wc -l < "$dir/deploy-hashes$sfx.txt")
                touch "$dir/deploy-hashes$sfx.txt"
                while IFS=' ' read -r chain raw; do
                    [[ -n "$raw" ]] || continue
                    [[ "$chain" == "L2" ]] && rpc="$L2_RPC" || rpc="$L1_RPC"
                    if ! hash=$(_rpc_send_raw "$rpc" "$raw" 2>>"$RUN_DIR/send-failed.log"); then
                        echo "DEPLOY SEND FAILED: $name ($chain)" >> "$RUN_DIR/send-failed.log"
                        echo "$name" >> "$RUN_DIR/deploy-send-failed$sfx.txt"   # parent marks it dead
                        break
                    fi
                    echo "$hash" >> "$dir/deploy-hashes$sfx.txt"
                    echo "$name,$chain,$hash" >> "$RUN_DIR/deploy-sent$sfx.csv"
                done < <(tail -n +$((done_n + 1)) "$f")
            done
        ) &
        pids+=($!)
    done
    wait "${pids[@]}"   # the senders only
    echo "  fired $(wc -l < "$RUN_DIR/deploy-sent$sfx.csv") deploy tx(s)"
    local name
    while read -r name; do
        [[ -n "$name" ]] && _prep_failed "$name" "deploy tx not sent - see send-failed.log"
    done < "$RUN_DIR/deploy-send-failed$sfx.txt"
}

# ── Wait for the fired deploy txs; drop jobs whose txs never mined or reverted ──
_mine_deploy_txs() {  # $1=sfx
    local sfx="$1" name chain hash blk status
    [[ -s "$RUN_DIR/deploy-sent$sfx.csv" ]] || return 0
    local deploy_interval=""
    [[ -n "$DEPLOY_POLL_INTERVAL_SET" ]] && deploy_interval="$DEPLOY_POLL_INTERVAL"
    _monitor_files "$RUN_DIR/deploy-sent$sfx.csv" "$RUN_DIR/deploy-mined$sfx.csv" \
        "$RUN_DIR/deploy-pending$sfx.csv" "$DEPLOY_MINE_TIMEOUT" direct "$deploy_interval" || true
    while IFS=, read -r name chain hash; do
        _prep_failed "$name" "deploy tx $hash never mined"
    done < "$RUN_DIR/deploy-pending$sfx.csv"
    while IFS=, read -r name chain hash blk status; do
        [[ "$status" == "0x1" ]] && continue
        _prep_failed "$name" "deploy tx $hash reverted"
    done < "$RUN_DIR/deploy-mined$sfx.csv"
}

# ── Assert every predicted address really holds code before trusting it ──
# Both prepare modes rest on forge's dry-run address prediction; this is the
# cheap cross-check (one batched eth_getCode per chain). Each address the
# planned txs create (jobs/<job>/deploy-addrs.txt, "<L1|L2> <address>" lines
# recorded at re-sign) is checked on the chain its tx targets: the same
# deployer+nonce yields the same CREATE address on both chains, so code on the
# wrong chain must not pass.
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
_check_deploy_liveness() {
    local chain rpc i name f a n=0
    local -A CODED=()
    for chain in L1 L2; do
        [[ "$chain" == "L1" ]] && rpc="$L1_RPC" || rpc="$L2_RPC"
        local addrs=()
        mapfile -t addrs < <(awk -v c="$chain" '$1 == c {print tolower($2)}' "$RUN_DIR"/jobs/*/deploy-addrs.txt 2>/dev/null | sort -u)
        (( ${#addrs[@]} > 0 )) || continue
        n=$(( n + ${#addrs[@]} ))
        while read -r a; do CODED["$chain ${a,,}"]=1; done < <(printf '%s\n' "${addrs[@]}" | _addrs_with_code "$rpc")
    done
    (( n > 0 )) || return 0
    for ((i = 0; i < NJOBS; i++)); do
        name="${JOB_NAMES[$i]}"
        [[ "$DEAD" == *",$name,"* ]] && continue
        f="$RUN_DIR/jobs/$name/deploy-addrs.txt"
        [[ -f "$f" ]] || continue
        while read -r chain a; do
            [[ -n "${CODED["$chain ${a,,}"]:-}" ]] && continue
            _prep_failed "$name" "predicted address $a has no code on $chain"
            break
        done < <(sort -u "$f")
    done
    echo "deploy-liveness: $n predicted address(es) checked on their own chain"
}

# ══════════════════════════════════════════════
#  Plan-mode prepare helpers
# ══════════════════════════════════════════════
# ── Batched nonces: stdin one address per line → "address nonce" (decimal) ──
_batch_nonces() {  # $1=rpc
    local addrs=() o
    mapfile -t addrs
    (( ${#addrs[@]} > 0 )) || return 0
    for ((o = 0; o < ${#addrs[@]}; o += 200)); do
        local chunk=("${addrs[@]:o:200}")
        printf '%s\n' "${chunk[@]}" | jq -R -s 'split("\n")|map(select(length>0))|to_entries
            |map({jsonrpc:"2.0",id:.key,method:"eth_getTransactionCount",params:[.value,"latest"]})' \
            | curl -s --max-time 30 -X POST "$1" -H 'Content-Type: application/json' -d @- \
            | jq -r '.[]? | select(.result != null) | "\(.id) \(.result)"' \
            | while read -r id hex; do echo "${chunk[$id]} $(printf '%d' "$hex")"; done
    done
}

# ── One read-consistency barrier for every wallet (replaces the per-job one) ──
# A load-balanced public RPC can lag behind txs the fronts already saw (earlier
# runs' triggers); planning from a lagging RPC would reuse a spent nonce and
# every predicted CREATE address would be wrong. Wait until, on each chain whose
# front differs from its RPC, the RPC's nonce is at least the front's for every
# wallet.
_nonce_barrier() {
    local chain rpc front behind i addr n got ok
    for chain in L1 L2; do
        if [[ "$chain" == "L1" ]]; then rpc="$L1_RPC"; front="$L1_FRONT"; else rpc="$L2_RPC"; front="$L2_FRONT"; fi
        [[ -n "$front" && "$front" != "$rpc" ]] || continue
        # Every wallet must answer on both endpoints: a missing batch item (a
        # dropped request, an error entry) would read as "nonce 0 = caught up".
        local -A FRONT_N=()
        for i in $(seq 1 10); do
            FRONT_N=()
            while read -r addr n; do FRONT_N[$addr]="$n"; done < <(printf '%s\n' "${WALLET_ADDRS[@]}" | _batch_nonces "$front")
            (( ${#FRONT_N[@]} == ${#WALLET_ADDRS[@]} )) && break
            echo "nonce barrier: $chain front answered ${#FRONT_N[@]}/${#WALLET_ADDRS[@]} wallets - retrying"
            sleep 2
        done
        (( ${#FRONT_N[@]} == ${#WALLET_ADDRS[@]} )) || { echo "nonce barrier: $chain front unreachable or incomplete - aborting"; exit 1; }
        ok=false
        for i in $(seq 1 60); do
            behind=0; got=0
            while read -r addr n; do
                got=$((got+1))
                (( n < FRONT_N[$addr] )) && behind=$((behind+1))
            done < <(printf '%s\n' "${WALLET_ADDRS[@]}" | _batch_nonces "$rpc")
            if (( got == ${#WALLET_ADDRS[@]} && behind == 0 )); then ok=true; break; fi
            echo "waiting for $chain RPC to catch up ($behind wallet nonce(s) behind the front, $got/${#WALLET_ADDRS[@]} answered)..."
            sleep 2
        done
        $ok || { echo "nonce barrier: $chain RPC still behind the front after 120s - aborting (planning from a lagging RPC would reuse spent nonces)"; exit 1; }
    done
}

# ── Plan inputs: the fork block and every wallet's nonce, per chain ──
# Read once after the barrier and handed to each job's PrepareJob run: the
# block pins the in-process forks (and lets forge cache what it fetches on
# disk, shared by every job), the nonce seeds the planned txs.
declare -A NONCE_L1=() NONCE_L2=()
BLOCK_L1=""; BLOCK_L2=""
_read_plan_inputs() {
    local addr n
    BLOCK_L1=$(cast block-number --rpc-url "$L1_RPC") && BLOCK_L2=$(cast block-number --rpc-url "$L2_RPC") \
        && [[ "$BLOCK_L1" =~ ^[0-9]+$ && "$BLOCK_L2" =~ ^[0-9]+$ ]] || { echo "plan: block number lookup failed - RPCs unreachable?"; exit 1; }
    while read -r addr n; do NONCE_L1[$addr]="$n"; done < <(printf '%s\n' "${WALLET_ADDRS[@]}" | _batch_nonces "$L1_RPC")
    while read -r addr n; do NONCE_L2[$addr]="$n"; done < <(printf '%s\n' "${WALLET_ADDRS[@]}" | _batch_nonces "$L2_RPC")
    (( ${#NONCE_L1[@]} == ${#WALLET_ADDRS[@]} && ${#NONCE_L2[@]} == ${#WALLET_ADDRS[@]} )) \
        || { echo "plan: nonce lookup incomplete (L1 ${#NONCE_L1[@]}, L2 ${#NONCE_L2[@]} of ${#WALLET_ADDRS[@]} wallets)"; exit 1; }
    echo "== plan inputs: L1 @$BLOCK_L1, L2 @$BLOCK_L2, nonces for ${#WALLET_ADDRS[@]} wallet(s)"
}

# ══════════════════════════════════════════════
#  Verify phase (also the whole of --verify-only)
# ══════════════════════════════════════════════
_verify_launch() {  # $1=job name $2=sol $3=pk — one job's network.sh verify stage, log in its dir
    E2E_STAGE=verify E2E_JOB_DIR="$RUN_DIR/jobs/$1" E2E_SNAPSHOT="$RUN_DIR/snapshot.env" \
        E2E_L1TX_CACHE="$RUN_DIR/l1tx-cache" \
        bash script/e2e/run/network.sh "$2" \
        --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
        --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
        --pk "$3" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        > "$RUN_DIR/jobs/$1/verify.log" 2>&1 < /dev/null
}
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
        elif ! _job_prepared "$dir"; then
            # v2 manifest (written at plan time) whose deploys never mined / held no code
            PRE_FAILED+=("$name (planned but deploys not confirmed - $dir/prepare.log)"); continue
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
        echo "VERIFY $name (manifest v$(_manifest_version "$dir/manifest.env"))"
        ( _timed_job "$name" verify _verify_launch "$name" "$sol" "${JOB_PK[$name]}" ) &
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
    _timing_init "$RUN_DIR"; _phase_begin total
    _warm_forge_cache
    _phase_begin verify
    verify_phase; _RC=$?
    _phase_end verify "$([[ $_RC -eq 0 ]] && echo pass || echo fail)"
    exit $_RC
fi

PREP_FAIL=0
DEAD=","   # ",name," membership list of jobs that can no longer continue
_prep_failed() {  # $1=job name $2=reason — drop the job and leave a marker the verify summary reads
    [[ "$DEAD" == *",$1,"* ]] && return 0
    DEAD="$DEAD$1,"; PREP_FAIL=$((PREP_FAIL+1))
    touch "$RUN_DIR/jobs/$1/.prepare-failed"
    echo "PREPARE FAILED: $1 ($2)"
}
# Bounded by PREPARE_JOB_TIMEOUT: a forge run stuck on a dead RPC would
# otherwise hold the whole run (every job's deploys are fired together). GNU
# timeout signals its own process group, so the forge child dies with the
# runner; rc 124 = timed out.
_job_launch_prepare() {  # $1=job index $2=E2E_PREPARE_STEP value ("" = classic one-pass)
    local addr="${WALLET_ADDRS[$1]:-}" nonce_l1="" nonce_l2=""
    [[ "$2" == "plan" ]] && { nonce_l1="${NONCE_L1[$addr]}"; nonce_l2="${NONCE_L2[$addr]}"; }
    E2E_STAGE=prepare E2E_PREPARE_STEP="$2" E2E_JOB_DIR="$RUN_DIR/jobs/${JOB_NAMES[$1]}" \
        E2E_L1_NONCE="$nonce_l1" E2E_L2_NONCE="$nonce_l2" E2E_L1_BLOCK="$BLOCK_L1" E2E_L2_BLOCK="$BLOCK_L2" \
        timeout "$PREPARE_JOB_TIMEOUT" bash script/e2e/run/network.sh "${JOB_SOLS[$1]}" \
        --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" \
        --l2-rpc "$L2_RPC" --l2-front "$L2_FRONT" \
        --pk "${WALLET_PKS[$1]}" --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        >> "$RUN_DIR/jobs/${JOB_NAMES[$1]}/prepare.log" 2>&1
}
_prep_launch_failed() {  # $1=job name $2=step label $3=rc of the prepare launch
    if [[ "$3" -eq 124 ]]; then
        echo "PREPARE TIMEOUT: killed after ${PREPARE_JOB_TIMEOUT}s (PREPARE_JOB_TIMEOUT)" >> "$RUN_DIR/jobs/$1/prepare.log"
        _prep_failed "$1" "$2 - timed out after ${PREPARE_JOB_TIMEOUT}s"
    else
        _prep_failed "$1" "$2 - log: $RUN_DIR/jobs/$1/prepare.log"
    fi
}
_mark_deploys_done() {  # every live job's deploys are mined and hold code
    local i d
    for ((i = 0; i < NJOBS; i++)); do
        [[ "$DEAD" == *",${JOB_NAMES[$i]},"* ]] && continue
        d="$RUN_DIR/jobs/${JOB_NAMES[$i]}"
        touch "$d/.deploys-done"
        # A v2 manifest is complete once its deploys hold code: a marker left by an
        # earlier attempt whose deploys had not mined yet is stale now.
        [[ -f "$d/manifest.env" && "$(_manifest_version "$d/manifest.env")" == 2 ]] && rm -f "$d/.prepare-failed"
    done
}
# ── Finish step: trigger presign + ComputeExpected (read-only, fast) for every
# live job whose deploys all mined and that has no manifest yet. Success clears
# a .prepare-failed marker left by an earlier, interrupted attempt. ──
_finish_prepare() {
    local i k name todo=() pids=() idx=()
    for ((i = 0; i < NJOBS; i++)); do
        name="${JOB_NAMES[$i]}"
        [[ "$DEAD" == *",$name,"* ]] && continue
        [[ -f "$RUN_DIR/jobs/$name/.deploys-done" && ! -f "$RUN_DIR/jobs/$name/manifest.env" ]] && todo+=("$i")
    done
    (( ${#todo[@]} > 0 )) || return 0
    echo ""
    echo "== Prepare finish: ${#todo[@]} job(s) ($PREPARE_PARALLEL parallel)"
    _restore_forge_cache
    for i in "${todo[@]}"; do
        while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 1; done
        echo "PREPARE ${JOB_NAMES[$i]}"
        ( _timed_job "${JOB_NAMES[$i]}" finish _job_launch_prepare "$i" finish ) &
        pids+=($!); idx+=("$i")
    done
    local rc
    for k in "${!pids[@]}"; do
        name="${JOB_NAMES[${idx[$k]}]}"
        rc=0; wait "${pids[$k]}" || rc=$?
        if (( rc == 0 )); then rm -f "$RUN_DIR/jobs/$name/.prepare-failed"
        else _prep_launch_failed "$name" finish "$rc"; fi
    done
}

if [[ -n "$RESUME" ]]; then
# ── Resume a stopped run: mine what was fired, finish what is deploy-complete, fire what is prepared ──
# A job is fireable once it has a complete manifest (written last by the prepare
# stage) and has sent nothing yet (double-fire guard). A job whose pre-signed
# deploys (deploytxs.txt) have not all mined (no .deploys-done) gets the rest
# fired first (continuing after any hash already in deploy-hashes.txt) and
# mined. A job whose deploys all mined but that never reached the finish step
# only lacks the read-only part (trigger presign + ComputeExpected), so that
# step is re-run — no deploy is repeated, and a job killed mid-finish just
# rewrites its manifest. Everything else in jobs.csv is left for the verify
# summary to report as "never prepared".
RUN_DIR="${RESUME%/}"
[[ -f "$RUN_DIR/jobs.csv" && -f "$RUN_DIR/wallets.csv" ]] || {
    echo "Not a staged run dir: $RUN_DIR (missing jobs.csv/wallets.csv)"; exit 1; }
_bind_run_network "$RUN_DIR"
_timing_init "$RUN_DIR"; _phase_begin total
declare -A _PK_OF
while IFS=, read -r _j _a _k; do [[ "$_j" == "job" ]] || _PK_OF[$_j]="$_k"; done < "$RUN_DIR/wallets.csv"
JOB_NAMES=(); JOB_SOLS=(); WALLET_PKS=()
_SKIPPED_SENT=0; _RESENT=0
while IFS=, read -r _name _sol; do
    [[ "$_name" == "job" ]] && continue
    _jd="$RUN_DIR/jobs/$_name"
    # --resend: a job whose sent triggers NEVER mined (every hash still pending, none
    # in mined.csv) is put back on the send list — its raw txs are unchanged and their
    # nonces unused. The old hashes are archived per attempt; their rows leave
    # sent.csv so the monitor does not wait on them again.
    if $RESEND && [[ -s "$_jd/txs.txt" ]] && ! grep -qFf "$_jd/txs.txt" "$RUN_DIR/mined.csv" 2>/dev/null; then
        mv "$_jd/txs.txt" "$_jd/txs.txt.attempt$ATTEMPT"
        [[ -f "$RUN_DIR/sent.csv.attempt$ATTEMPT" ]] || cp "$RUN_DIR/sent.csv" "$RUN_DIR/sent.csv.attempt$ATTEMPT"
        grep -v "^$_name," "$RUN_DIR/sent.csv" > "$RUN_DIR/sent.csv.tmp" || true
        mv "$RUN_DIR/sent.csv.tmp" "$RUN_DIR/sent.csv"
        _RESENT=$((_RESENT+1))
    fi
    # fully sent = one hash per pre-signed tx; a partial multi-tx send is resumed from where it stopped
    if [[ -s "$_jd/txs.txt" ]] && (( $(wc -l < "$_jd/txs.txt") >= $(wc -l < "$_jd/rawtxs.txt" 2>/dev/null || echo 0) )); then
        _SKIPPED_SENT=$((_SKIPPED_SENT+1)); continue
    fi
    if [[ ! -f "$_jd/manifest.env" ]]; then
        [[ -n "${_PK_OF[$_name]:-}" && -s "$_jd/deploy-env.env" ]] || continue
        [[ -f "$_jd/.deploys-done" || -s "$_jd/deploytxs.txt" ]] || continue
    fi
    JOB_NAMES+=("$_name"); JOB_SOLS+=("$_sol"); WALLET_PKS+=("${_PK_OF[$_name]}")
done < "$RUN_DIR/jobs.csv"
NJOBS=${#JOB_NAMES[@]}
RESUME_TRUNCATED=true
touch "$RUN_DIR/.truncated"   # later --verify-only passes report unprepared jobs as truncated, not failed

_warm_forge_cache
_DEPLOYS_PENDING=0
for ((i = 0; i < NJOBS; i++)); do
    _jd="$RUN_DIR/jobs/${JOB_NAMES[$i]}"
    [[ -s "$_jd/deploytxs.txt" && ! -f "$_jd/.deploys-done" ]] && _DEPLOYS_PENDING=$((_DEPLOYS_PENDING+1))
done
if (( _DEPLOYS_PENDING > 0 )); then
    echo "== RESUME $RUN_DIR: firing + mining the deploys of $_DEPLOYS_PENDING job(s)"
    _phase_begin deploy-send; _fire_deploy_txs ""; _phase_end deploy-send
    _phase_begin deploy-mine; _mine_deploy_txs ""
    _phase_end deploy-mine "$([[ -s "$RUN_DIR/deploy-pending.csv" ]] && echo timeout || echo pass)"
    _phase_begin deploy-liveness; _check_deploy_liveness; _phase_end deploy-liveness
    _mark_deploys_done
fi
_phase_begin finish; _finish_prepare; _phase_end finish
# keep only jobs that are prepared (deploy and finish failures drop out here)
_N=(); _S=(); _P=()
for ((i = 0; i < NJOBS; i++)); do
    _job_prepared "$RUN_DIR/jobs/${JOB_NAMES[$i]}" || continue
    _N+=("${JOB_NAMES[$i]}"); _S+=("${JOB_SOLS[$i]}"); _P+=("${WALLET_PKS[$i]}")
done
JOB_NAMES=("${_N[@]}"); JOB_SOLS=("${_S[@]}"); WALLET_PKS=("${_P[@]}")
NJOBS=${#JOB_NAMES[@]}
(( NJOBS > 0 )) || { echo "Nothing prepared-but-unsent in $RUN_DIR"; exit 1; }
echo "== RESUME $RUN_DIR: firing $NJOBS prepared job(s) ($_SKIPPED_SENT already sent, skipped; $_RESENT re-fired after never mining)$([[ "$SEND_PAUSE" != 0 ]] && echo " - paced: $SEND_WORKERS worker(s), ${SEND_PAUSE}s between sends")"

else
# ── Fresh run: expand, fund, prepare ──

[[ $# -gt 0 ]] || { echo "Usage: network-staged.sh [flags] <scenario>[:count] ...  |  --verify-only <run-dir>  |  --resume <run-dir>"; exit 1; }

expand_jobs "$@"
RUN_DIR="tmp/e2e-staged-net/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
_save_run_network "$RUN_DIR"
_timing_init "$RUN_DIR"; _phase_begin total
echo "== $NJOBS job(s) — prepare x$PREPARE_PARALLEL, send x$SEND_WORKERS, verify x$VERIFY_PARALLEL — run dir $RUN_DIR"

echo "job,sol" > "$RUN_DIR/jobs.csv"
for ((i = 0; i < NJOBS; i++)); do
    echo "${JOB_NAMES[$i]},${JOB_SOLS[$i]}" >> "$RUN_DIR/jobs.csv"
done

# Warm artifacts once; every forge-heavy phase restores this cache (see guard above).
_warm_forge_cache

# ══ Phase 1: fund ══
_phase_begin fund
fund_workers
_phase_end fund

# ══ Phase 2: prepare ══
# plan (default): one batched nonce barrier, then ONE forge run per job
#   (PrepareJob.s.sol) that drives all of its Deploy* contracts against
#   in-process forks of both chains with the wallet nonces injected, then — in
#   the same process, on the simulated post-deploy state — the trigger oracle
#   and ComputeExpected; the plan step pre-signs the deploy AND trigger txs and
#   writes a v2 manifest, so nothing waits for a block and no finish step is
#   needed. ALL deploy txs are then fired at once, mined with ONE wait and
#   checked for code; a job whose deploys fail keeps its manifest but is dropped
#   (_job_prepared). Triggers are fired only after the deploys mined (phase 4):
#   a front's acceptance of a trigger whose nonce is ahead of chain state is
#   unverified.
# waves: dry-run + pre-sign each job's k-th Deploy contract against the real
#   RPCs, fire the whole wave, mine ONCE, then wave k+1 — the run blocks on
#   deploy mining once per Deploy contract. Wave ordering keeps the dry-run
#   nonce truthful.
# classic: each job's forge deploys and waits for its own receipts.
PREPARE_MODE="${PREPARE_MODE:-plan}"

if [[ "$PREPARE_MODE" == "classic" ]]; then
    # ── classic single-pass prepare ──
    echo ""
    echo "== Prepare phase ($PREPARE_PARALLEL parallel, classic)"
    _phase_begin prepare-classic
    _restore_forge_cache
    P_PIDS=()
    for ((i = 0; i < NJOBS; i++)); do
        while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 2; done
        mkdir -p "$RUN_DIR/jobs/${JOB_NAMES[$i]}"
        echo "PREPARE ${JOB_NAMES[$i]}"
        ( _timed_job "${JOB_NAMES[$i]}" prepare _job_launch_prepare "$i" "" ) &
        P_PIDS+=($!)
    done
    for ((i = 0; i < ${#P_PIDS[@]}; i++)); do
        rc=0; wait "${P_PIDS[$i]}" || rc=$?
        (( rc == 0 )) || _prep_launch_failed "${JOB_NAMES[$i]}" classic "$rc"
    done
    _phase_end prepare-classic
else
    if [[ "$PREPARE_MODE" == "plan" ]]; then
        _phase_begin nonce-barrier; _nonce_barrier; _phase_end nonce-barrier
        _phase_begin plan-inputs; _read_plan_inputs; _phase_end plan-inputs
        echo ""
        echo "== Prepare (plan mode): one forge run per job, $NJOBS job(s) ($PREPARE_PARALLEL parallel)"
        _phase_begin plan
        _restore_forge_cache
        P_PIDS=(); P_IDX=()
        for ((i = 0; i < NJOBS; i++)); do
            while (( $(jobs -rp | wc -l) >= PREPARE_PARALLEL )); do sleep 1; done
            mkdir -p "$RUN_DIR/jobs/${JOB_NAMES[$i]}"
            echo "PREPARE ${JOB_NAMES[$i]}"
            ( _timed_job "${JOB_NAMES[$i]}" plan _job_launch_prepare "$i" plan ) &
            P_PIDS+=($!); P_IDX+=($i)
        done
        for k in "${!P_PIDS[@]}"; do
            rc=0; wait "${P_PIDS[$k]}" || rc=$?
            (( rc == 0 )) || _prep_launch_failed "${JOB_NAMES[${P_IDX[$k]}]}" plan "$rc"
        done
        _phase_end plan

        # ── fire every job's deploys at once, mine with one wait ──
        echo ""
        echo "== Deploy: firing all pre-signed deploy txs"
        _phase_begin deploy-send; _fire_deploy_txs ""; _phase_end deploy-send
        _phase_begin deploy-mine; _mine_deploy_txs ""
        _phase_end deploy-mine "$([[ -s "$RUN_DIR/deploy-pending.csv" ]] && echo timeout || echo pass)"
        _phase_begin deploy-liveness; _check_deploy_liveness; _phase_end deploy-liveness
        _mark_deploys_done
    elif [[ "$PREPARE_MODE" == "waves" ]]; then
        _phase_begin prepare-waves
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
                ( _timed_job "$name" "wave$wave" _job_launch_prepare "$i" "deploy:$wave" ) &
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
                    *) _prep_launch_failed "$name" "wave $wave dry-run" "$rc" ;;
                esac
            done
            $WAVE_TXS || continue

            # ── fire the wave, then mine it (one shared wait). A job whose deploy
            # never left the machine would dry-run the next wave from a stale nonce
            # and presign a colliding trigger — _fire_deploy_txs drops it. ──
            _fire_deploy_txs "-wave$wave"
            _mine_deploy_txs "-wave$wave"
        done
        _check_deploy_liveness
        _phase_end prepare-waves
    else
        echo "Unknown PREPARE_MODE: $PREPARE_MODE (plan | waves | classic)"; exit 1
    fi
    # v2 manifests (plan mode) already exist — _finish_prepare only picks up jobs without one
    _phase_begin finish; _finish_prepare; _phase_end finish
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
_phase_begin send
# touch, not truncate — a resumed run appends to the earlier records
touch "$RUN_DIR/sent.csv" "$RUN_DIR/send-failed.log"
send_worker() {  # $1=worker index — handles jobs $1, $1+W, $1+2W, ... (round-robin shard)
    local j name dir chain rpc raw hash done_n
    for ((j = $1; j < NJOBS; j += SEND_WORKERS)); do
        name="${JOB_NAMES[$j]}"; dir="$RUN_DIR/jobs/$name"
        _job_prepared "$dir" || continue   # prepare failed, or a v2 manifest whose deploys never mined
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
            [[ "$SEND_PAUSE" == 0 ]] || sleep "$SEND_PAUSE"   # pace the burst (per worker)
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
_phase_end send "$([[ -s "$RUN_DIR/send-failed.log" ]] && echo fail || echo pass)"
(( N_SENT > 0 )) || { echo "Nothing sent - aborting"; exit 1; }

# ══ Phase 5: monitor ══
# One batched eth_getTransactionReceipt request per chain per tick — the local
# footprint stays two curl calls every POLL_INTERVAL s no matter how many txs
# are in flight. Fronts HOLD trigger txs until the composer bundles them, so
# "sent but not mined" is a real (and eventually failing) state: MINE_TIMEOUT
# bounds the wait and leftovers stay in pending.csv.
echo ""
_phase_begin monitor
if [[ -n "$POLL_INTERVAL_SET" ]]; then
    echo "== Monitor phase (fixed ${POLL_INTERVAL}s, timeout ${MINE_TIMEOUT}s)"
    _monitor_files "$RUN_DIR/sent.csv" "$RUN_DIR/mined.csv" "$RUN_DIR/pending.csv" "$MINE_TIMEOUT" front "$POLL_INTERVAL" || true
else
    echo "== Monitor phase (adaptive ${POLL_FAST_INTERVAL}/${POLL_MEDIUM_INTERVAL}/${POLL_SLOW_INTERVAL}s, timeout ${MINE_TIMEOUT}s)"
    _monitor_files "$RUN_DIR/sent.csv" "$RUN_DIR/mined.csv" "$RUN_DIR/pending.csv" "$MINE_TIMEOUT" front "" || true
fi
_phase_end monitor "$([[ -s "$RUN_DIR/pending.csv" ]] && echo timeout || echo pass)"
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
_phase_begin verify
verify_phase; _RC=$?
_phase_end verify "$([[ $_RC -eq 0 ]] && echo pass || echo fail)"
exit $_RC
