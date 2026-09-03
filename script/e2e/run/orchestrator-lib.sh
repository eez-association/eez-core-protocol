#!/usr/bin/env bash
# Shared machinery for the network e2e orchestrators (network-parallel.sh,
# network-staged.sh): job-list expansion and worker-wallet funding.
#
# Callers source this file and must set beforehand:
#   SCRIPT_DIR RUN_DIR FUND_ETH FLOOR_ETH SOURCE_PK DIRECT FRESH L1_RPC L2_RPC
# Optional: MULTISEND_BATCH (default 100).
#
# expand_jobs "<target>[:count]" ...   → JOB_NAMES[] JOB_SOLS[] NJOBS
# fund_workers                         → WALLET_ADDRS[] WALLET_PKS[] (one per job),
#                                        wallets.csv in RUN_DIR, pool + faucet updated
# Also pure helpers used by network-staged.sh: phase timing, the adaptive poll
# delay, manifest version detection and the prepared-job gate.

# ══ Phase timing ══
# Run-scope rows go to $RUN_DIR/timings.csv; job-scope rows to
# $RUN_DIR/jobs/<job>/timings.csv (one writer per file — parallel jobs never
# append to a shared file) and are consolidated into $RUN_DIR/job-timings.csv
# by the parent at the end. Schema (both files):
#   attempt,scope,name,start_ms,end_ms,duration_ms,status
# ATTEMPT is 1 for a fresh run and +1 for every --resume / --verify-only on the
# same run dir (rows are appended, never overwritten). status: pass | fail |
# timeout | skipped. Timestamps come from bash's EPOCHREALTIME (no subprocess).
_TIMING_HEADER="attempt,scope,name,start_ms,end_ms,duration_ms,status"
declare -A _PHASE_T0=() _PHASE_DONE=()
# EPOCHREALTIME prints the fraction with the locale's decimal separator ("." or ",").
_now_ms() { local t="${EPOCHREALTIME//[.,]/}"; echo "${t:0:${#t}-3}"; }
_timing_init() {  # $1=run dir → ATTEMPT; creates timings.csv on a fresh run
    local f="$1/timings.csv"
    if [[ -s "$f" ]]; then
        ATTEMPT=$(( $(awk -F, 'NR > 1 && $1 + 0 > m {m = $1 + 0} END {print m + 0}' "$f") + 1 ))
    else
        echo "$_TIMING_HEADER" > "$f"; ATTEMPT=1
    fi
}
_phase_begin() { _PHASE_T0[$1]=$(_now_ms); unset '_PHASE_DONE[$1]'; }
_phase_end() {  # $1=phase name $2=status (default pass)
    local t0="${_PHASE_T0[$1]:-}" t1
    t1=$(_now_ms); [[ -n "$t0" ]] || t0="$t1"
    echo "$ATTEMPT,run,$1,$t0,$t1,$((t1 - t0)),${2:-pass}" >> "$RUN_DIR/timings.csv"
    _PHASE_DONE[$1]=1
}
_phases_close_open() {  # $1=status — end every phase still open (exit paths, aborts)
    local p
    for p in "${!_PHASE_T0[@]}"; do [[ -n "${_PHASE_DONE[$p]:-}" ]] || _phase_end "$p" "$1"; done
}
_timed_job() {  # $1=job name $2=phase, rest = command: runs it, appends the job row, returns its rc
    local name="$1" phase="$2" t0 t1 rc=0 st
    shift 2
    t0=$(_now_ms); "$@" || rc=$?; t1=$(_now_ms)
    case $rc in 0) st=pass ;; 124) st=timeout ;; *) st=fail ;; esac
    echo "$ATTEMPT,job,$name:$phase,$t0,$t1,$((t1 - t0)),$st" >> "$RUN_DIR/jobs/$name/timings.csv"
    return $rc
}
_timing_summary() {  # consolidate job rows; print this attempt's phases (slowest first) + 5 slowest jobs
    local jf="$RUN_DIR/job-timings.csv"
    { echo "$_TIMING_HEADER"; cat "$RUN_DIR"/jobs/*/timings.csv 2>/dev/null; } > "$jf"
    echo ""
    echo "  Timings (attempt $ATTEMPT, $RUN_DIR/timings.csv):"
    awk -F, -v a="$ATTEMPT" '$1 == a && $2 == "run"' "$RUN_DIR/timings.csv" | sort -t, -k6,6nr \
        | LC_NUMERIC=C awk -F, '{printf "    %-24s %7.1f s  %s\n", $3, $6 / 1000, $7}'
    echo "  Slowest jobs (attempt $ATTEMPT, $jf):"
    awk -F, -v a="$ATTEMPT" 'NR > 1 && $1 == a' "$jf" | sort -t, -k6,6nr | head -5 \
        | LC_NUMERIC=C awk -F, '{printf "    %-40s %7.1f s  %s\n", $3, $6 / 1000, $7}'
    _timing_baseline_check
}
# E2E_TIMING_BASELINE=<timings.csv of a reference run>: every passed run-scope
# phase of this attempt is compared with the same phase of the baseline's last
# attempt; more than TIMING_REGRESSION_PCT (default 20) % slower is reported.
_timing_baseline_check() {
    local b="${E2E_TIMING_BASELINE:-}" pct="${TIMING_REGRESSION_PCT:-20}" ba name cur ref n=0
    [[ -n "$b" && -s "$b" ]] || return 0
    ba=$(awk -F, 'NR > 1 && $1 + 0 > m {m = $1 + 0} END {print m + 0}' "$b")
    while IFS=, read -r name cur; do
        ref=$(awk -F, -v a="$ba" -v n="$name" '$1 == a && $2 == "run" && $3 == n && $7 == "pass" {print $6}' "$b" | tail -1)
        [[ -n "$ref" && "$ref" -gt 0 ]] || continue
        if (( cur * 100 > ref * (100 + pct) )); then
            echo "  REGRESSION: $name $(( cur / 1000 )) s vs baseline $(( ref / 1000 )) s (more than ${pct}% slower)"
            n=$((n + 1))
        fi
    done < <(awk -F, -v a="$ATTEMPT" '$1 == a && $2 == "run" && $7 == "pass" {print $3 "," $6}' "$RUN_DIR/timings.csv")
    (( n == 0 )) && echo "  baseline $b: no phase more than ${pct}% slower"
    return 0
}

# ══ Adaptive receipt-poll delay ══
# Short intervals right after a send (most txs mine within a block or two),
# backing off so a long wait stays cheap. $1 = seconds elapsed since the send.
_poll_delay() {
    if (( $1 < POLL_FAST_WINDOW )); then echo "$POLL_FAST_INTERVAL"
    elif (( $1 < POLL_MEDIUM_WINDOW )); then echo "$POLL_MEDIUM_INTERVAL"
    else echo "$POLL_SLOW_INTERVAL"; fi
}

# ══ Manifest version ══
# v1: written by the finish step after the deploys mined (waves / classic /
# older runs). v2: written by the plan step BEFORE the deploys are fired, so
# "manifest present" alone no longer means "prepared" — the job must also hold
# .deploys-done and no .prepare-failed marker.
_manifest_version() {  # $1=manifest.env → 1 | 2
    local v
    v=$(sed -n 's/^declare -- E2E_MANIFEST_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null)
    echo "${v:-1}"
}
_job_prepared() {  # $1=job dir → 0 when the job may be sent / verified
    [[ -f "$1/manifest.env" && ! -f "$1/.prepare-failed" ]] || return 1
    [[ "$(_manifest_version "$1/manifest.env")" == 1 || -f "$1/.deploys-done" ]]
}

# ── Expand args into a flat job list ──
# Each arg is <target>[:count]; target = scenario name, category/direction dir
# (e.g. one_way, multi_call/L2_to_L1), or "all".
expand_jobs() {
    JOB_NAMES=(); JOB_SOLS=()
    _add_jobs() {  # $1=sol $2=count
        local name i; name=$(basename "$(dirname "$1")")
        for ((i = 1; i <= $2; i++)); do
            JOB_NAMES+=("$name-$i"); JOB_SOLS+=("$1")
        done
    }
    local arg scen count sol
    for arg in "$@"; do
        scen="${arg%%:*}"
        count=1; [[ "$arg" == *:* ]] && count="${arg##*:}"
        [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || { echo "Bad count in '$arg'"; exit 1; }
        if [[ "$scen" == "all" ]]; then
            while IFS= read -r sol; do _add_jobs "$sol" "$count"; done \
                < <(find script/e2e -mindepth 3 -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
        elif [[ -d "script/e2e/$scen" ]]; then
            while IFS= read -r sol; do _add_jobs "$sol" "$count"; done \
                < <(find "script/e2e/$scen" -name 'E2E*.s.sol' -not -path '*/shared/*' | sort)
        else
            sol=$(find script/e2e -mindepth 3 -path "*/$scen/E2E*.s.sol" -not -path '*/shared/*' | head -1)
            [[ -n "$sol" ]] || { echo "No scenario matches '$scen'"; exit 1; }
            _add_jobs "$sol" "$count"
        fi
    done
    NJOBS=${#JOB_NAMES[@]}
}

# ── Fund one pooled wallet per job (faucet + MultiSend, exclusive lock) ──
# Holds an exclusive lock for the whole funding sequence: concurrent
# orchestrator instances share the source funding key, and racing its nonce
# yields "replacement transaction underpriced".
fund_workers() {
    exec 9>"$SCRIPT_DIR/.faucet.lock"
    flock 9

    MULTISEND_BATCH="${MULTISEND_BATCH:-100}"
    local nchunks=$(( (NJOBS + MULTISEND_BATCH - 1) / MULTISEND_BATCH ))
    local NEED_WEI=""   # faucet balance the run needs (faucet mode only)

    if $DIRECT; then
        # ── Direct mode: fund workers straight from the source key ──
        FAUCET_PK="$SOURCE_PK"
        FAUCET_ADDR=$(cast wallet address --private-key "$FAUCET_PK")
        echo "Direct mode: funding workers from $FAUCET_ADDR (no faucet account)"
    else
        # ── Persistent faucet account ──
        local FAUCET_FILE="$SCRIPT_DIR/faucet.txt" new
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

        # The faucet itself is topped up from the source key inside _fund_chain
        # (per chain, in parallel). bc, not $(( )) — FUND_ETH may be fractional
        # (e.g. 0.2). 0.05/chunk covers each MultiSend tx's own gas (observed
        # ~0.035 at 100 workers/chunk); fundUpTo refunds the value reused
        # wallets don't need.
        NEED_WEI=$(cast to-wei "$(echo "$NJOBS * $FUND_ETH + $nchunks * 0.05 + 0.1" | bc)")
    fi

    # ── One pooled wallet per job, topped up via MultiSend ──
    # One `fundUpTo(address[],uint256,uint256)` tx per chain (chunked by
    # MULTISEND_BATCH) tops every worker up to FUND_ETH — a single-sender tx count
    # that devnet txpool per-account limits never touch. Reused wallets keep their
    # leftover balance; the unspent value refunds to the faucet in the same tx.
    local MULTISEND_FILE="$SCRIPT_DIR/multisend.txt"
    local POOL_FILE="$SCRIPT_DIR/wallet-pool.csv"

    # Returns (stdout) the MultiSend address for the chain at $1, deploying it from
    # the faucet key and caching it in multisend.txt (keyed by chain id). The cached
    # address is reused only when its on-chain code matches the local artifact, so a
    # contract edit (or a devnet reset) triggers a redeploy.
    local MULTISEND_CODE
    MULTISEND_CODE=$(forge inspect MultiSend deployedBytecode)
    _ensure_multisend() {
        local rpc=$1 chain_id addr
        chain_id=$(cast chain-id --rpc-url "$rpc") || return 1
        addr=$(sed -n "s/^$chain_id: *//p" "$MULTISEND_FILE" 2>/dev/null)
        if [[ -n "$addr" && $(cast code "$addr" --rpc-url "$rpc") == "$MULTISEND_CODE" ]]; then
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

    # Take the first NJOBS wallets from the persistent pool, minting (and
    # appending) new ones only when the pool runs short.
    touch "$POOL_FILE"; chmod 600 "$POOL_FILE"
    local POOL_LINES=() new waddr wpk i
    $FRESH || mapfile -t POOL_LINES < "$POOL_FILE"
    echo "Wallet pool: ${#POOL_LINES[@]} available, $NJOBS needed$($FRESH && echo ' (--fresh: minting new)')"
    WALLET_PKS=(); WALLET_ADDRS=()
    echo "job,address,private_key" > "$RUN_DIR/wallets.csv"
    chmod 600 "$RUN_DIR/wallets.csv"
    for ((i = 0; i < NJOBS; i++)); do
        if (( i < ${#POOL_LINES[@]} )); then
            waddr="${POOL_LINES[$i]%%,*}"; wpk="${POOL_LINES[$i]##*,}"
        else
            new=$(cast wallet new)
            waddr=$(echo "$new" | grep -oE 'Address: +0x[0-9a-fA-F]{40}' | grep -oE '0x.*')
            wpk=$(echo "$new"  | grep -oE 'Private key: +0x[0-9a-fA-F]{64}' | grep -oE '0x.*')
            echo "$waddr,$wpk" >> "$POOL_FILE"
        fi
        WALLET_PKS+=("$wpk"); WALLET_ADDRS+=("$waddr")
        echo "${JOB_NAMES[$i]},$waddr,$wpk" >> "$RUN_DIR/wallets.csv"
    done

    local FUND_WEI FLOOR_WEI MS_L1 MS_L2 pid_l1 pid_l2 rc=0
    FUND_WEI=$(cast to-wei "$FUND_ETH")
    FLOOR_WEI=$(cast to-wei "$FLOOR_ETH")

    # ── Faucet top-up from the source key, both chains at once ──
    # Must precede the MultiSend resolution: a (re)deploy is paid by the faucet.
    _topup_faucet() {  # $1=chain label $2=rpc
        local chain="$1" rpc="$2" have topup
        have=$(cast balance "$FAUCET_ADDR" --rpc-url "$rpc") || { echo "balance lookup FAILED on $chain"; return 1; }
        if [[ $(echo "$have < $NEED_WEI" | bc) -eq 1 ]]; then
            topup=$(echo "$NEED_WEI - $have" | bc)
            echo "Faucet top-up on $chain: $(cast from-wei "$topup") ETH from source key"
            cast send "$FAUCET_ADDR" --value "$topup" \
                --private-key "$SOURCE_PK" --rpc-url "$rpc" > /dev/null || {
                echo "Faucet funding FAILED on $chain"; return 1; }
        else
            echo "Faucet on $chain already has sufficient balance"
        fi
    }
    if ! $DIRECT; then
        _topup_faucet L1 "$L1_RPC" & pid_l1=$!
        _topup_faucet L2 "$L2_RPC" & pid_l2=$!
        wait "$pid_l1" || rc=1
        wait "$pid_l2" || rc=1
        (( rc == 0 )) || exit 1
    fi

    # Resolved before the parallel worker funding: a redeploy rewrites
    # multisend.txt, and two chains doing that at once would drop each other's line.
    MS_L1=$(_ensure_multisend "$L1_RPC") || exit 1
    MS_L2=$(_ensure_multisend "$L2_RPC") || exit 1

    # ── Worker top-ups, both chains at once ──
    # Per chain (their nonces are independent): fire every fundUpTo chunk at
    # once with consecutive nonces and wait for all receipts in one pass. A
    # blocking `cast send` per chunk cost one block time each (~12 s on L1);
    # now the whole sequence costs about one block per chain.
    _fund_chain() {  # $1=chain label $2=rpc $3=MultiSend address
        local chain="$1" rpc="$2" ms="$3"
        local nonce off total h hashes=() deadline status
        nonce=$(cast nonce "$FAUCET_ADDR" --rpc-url "$rpc") || { echo "nonce lookup FAILED on $chain"; return 1; }
        for ((off = 0; off < NJOBS; off += MULTISEND_BATCH)); do
            local slice=("${WALLET_ADDRS[@]:off:MULTISEND_BATCH}")
            total=$(echo "$FUND_WEI * ${#slice[@]}" | bc)
            h=$(cast send "$ms" "fundUpTo(address[],uint256,uint256)" \
                "[$(IFS=,; echo "${slice[*]}")]" "$FUND_WEI" "$FLOOR_WEI" --value "$total" \
                --nonce "$nonce" --async --private-key "$FAUCET_PK" --rpc-url "$rpc") || {
                echo "Worker funding SEND FAILED on $chain (workers $off..$((off + ${#slice[@]} - 1)))"; return 1; }
            hashes+=("$h"); nonce=$((nonce + 1))
        done
        deadline=$(( $(date +%s) + ${FUND_MINE_TIMEOUT:-300} ))
        for h in "${hashes[@]}"; do
            while true; do
                status=$(cast receipt "$h" status --rpc-url "$rpc" 2>/dev/null) && [[ -n "$status" ]] && break
                (( $(date +%s) < deadline )) || { echo "Worker funding tx $h never mined on $chain"; return 1; }
                sleep 2
            done
            status="${status%% *}"   # cast versions print "true", "1 (success)" or "0x1"
            [[ "$status" == "true" || "$status" == "1" || "$status" == "0x1" ]] || { echo "Worker funding tx $h REVERTED on $chain"; return 1; }
        done
        echo "  topped up $NJOBS worker(s) on $chain via MultiSend $ms (${#hashes[@]} tx)"
    }
    rc=0
    _fund_chain L1 "$L1_RPC" "$MS_L1" & pid_l1=$!
    _fund_chain L2 "$L2_RPC" "$MS_L2" & pid_l2=$!
    wait "$pid_l1" || rc=1
    wait "$pid_l2" || rc=1
    (( rc == 0 )) || { echo "Worker funding FAILED"; exit 1; }
    echo "All workers funded."
    flock -u 9   # faucet no longer touched — let concurrent runs proceed
}
