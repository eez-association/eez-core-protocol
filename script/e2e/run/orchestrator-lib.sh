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

        # ── Fund the run faucet from the source key ──
        # bc, not $(( )) — FUND_ETH may be fractional (e.g. 0.2). Send the amount in
        # wei: bc prints 0.6 as ".6", which cast's <eth>ether parser rejects.
        # 0.05/chunk covers each MultiSend tx's own gas (observed ~0.035 at 100
        # workers/chunk); fundUpTo refunds the value reused wallets don't need.
        local NEED_WEI HAVE_WEI TOPUP_WEI chain rpc_var rpc
        NEED_WEI=$(cast to-wei "$(echo "$NJOBS * $FUND_ETH + $nchunks * 0.05 + 0.1" | bc)")
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

    local FUND_WEI FLOOR_WEI chain rpc_var rpc ms off total
    FUND_WEI=$(cast to-wei "$FUND_ETH")
    FLOOR_WEI=$(cast to-wei "$FLOOR_ETH")
    for chain in L1 L2; do
        rpc_var="${chain}_RPC"; rpc="${!rpc_var}"
        ms=$(_ensure_multisend "$rpc") || exit 1
        for ((off = 0; off < NJOBS; off += MULTISEND_BATCH)); do
            local slice=("${WALLET_ADDRS[@]:off:MULTISEND_BATCH}")
            total=$(echo "$FUND_WEI * ${#slice[@]}" | bc)
            cast send "$ms" "fundUpTo(address[],uint256,uint256)" \
                "[$(IFS=,; echo "${slice[*]}")]" "$FUND_WEI" "$FLOOR_WEI" --value "$total" \
                --private-key "$FAUCET_PK" --rpc-url "$rpc" > /dev/null || {
                echo "Worker funding FAILED on $chain (workers $off..$((off + ${#slice[@]} - 1)))"; exit 1; }
            echo "  topped up ${#slice[@]} worker(s) on $chain via MultiSend $ms"
        done
    done
    echo "All workers funded."
    flock -u 9   # faucet no longer touched — let concurrent runs proceed
}
