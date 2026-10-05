#!/usr/bin/env bash
# Sourced by staged.sh. Normal receipt polling stays in the runner.
# Recovery uses the runner's existing curl/jq/cast/bc dependencies.

_recovery_log() {
    printf '[%s][%s] %s\n' "$_rec_phase" "$_rec_chain" "$*" | tee -a "$_rec_root/recovery.log"
}
_recovery_rpc() {  # rpc, method, params; rc 1 = uncertain, rc 2 = explicit RPC error
    local response
    response=$(printf '%s' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" \
        | curl -s --max-time 15 -H 'Content-Type: application/json' "$1" -d @-) || return 1
    if jq -e '.error | type=="object" and has("message")' <<< "$response" >/dev/null 2>&1; then
        jq -c '.error' <<< "$response"
        return 2
    fi
    jq -e 'has("result") and (.error == null)' <<< "$response" >/dev/null 2>&1 || return 1
    jq -c '.result' <<< "$response"
}
_recovery_lookup_once() {  # rpc, method, hashes file -> JSON objects, one per batch
    local hashes=() offset response count
    mapfile -t hashes < "$3"
    for ((offset=0; offset<${#hashes[@]}; offset+=200)); do
        count=$((${#hashes[@]} - offset)); (( count > 200 )) && count=200
        response=$(printf '%s\n' "${hashes[@]:offset:count}" | jq -Rsc --arg method "$2" \
            'split("\n") | map(select(length>0) | {jsonrpc:"2.0",id:.,method:$method,params:[.]})' \
            | curl -s --max-time 30 -H 'Content-Type: application/json' "$1" -d @-) || return 1
        jq -e --argjson n "$count" 'type=="array" and length==$n and
            (map(.id)|unique|length)==$n and all(.[]; has("result") and .error==null)' \
            <<< "$response" >/dev/null || return 1
        jq -c 'map(select(.result!=null) | {key:.id,value:.result}) | from_entries' <<< "$response"
    done
}
# Read failures get exactly one status recheck. Never use this for submission.
_recovery_read() {
    local result
    result=$(_recovery_rpc "$@") || result=$(_recovery_rpc "$@") || return 1
    printf '%s\n' "$result"
}
_recovery_lookup() {
    local result
    result=$(_recovery_lookup_once "$@") || result=$(_recovery_lookup_once "$@") || return 1
    printf '%s\n' "$result"
}
_recovery_collect() {  # Preserve successful receipts even if another endpoint fails.
    local url result rc=0
    : > "$2"
    for url in "${_rec_urls[@]}"; do
        if result=$(_recovery_lookup "$url" "$1" "$_rec_work/hashes"); then
            printf '%s\n' "$result" >> "$2"
        else rc=1; fi
    done
    jq -s 'add // {}' "$2" > "$2.tmp" && mv "$2.tmp" "$2" || return 1
    return "$rc"
}
_recovery_decode() {
    cast decode-transaction "$1" 2>/dev/null | jq 'if type=="string" then fromjson else . end'
}
_recovery_fees() {  # type, old cap, old tip, base, suggested price, suggested tip (wei)
    # bc avoids Bash's signed-64-bit overflow; round both replacement fees up by 10%.
    BC_LINE_LENGTH=0 bc <<EOF
        define max(a,b) { if (a>b) return(a); return(b); }
        c=$2; t=$3; b=$4; p=$5; s=$6;
        n=max(t+1,(t*110+99)/100); n=max(n,s);
        m=max(c+1,(c*110+99)/100);
        if ($1 == 0) { print (c<max(b,p)), " ", max(m,max(2*b,p)), " 0\n"; }
        if ($1 == 2) { print (c<b+s || t<s), " ", max(m,max(2*b+n,p)), " ", n, "\n"; }
EOF
}
_recovery_save() {  # Persist _rec_entry before broadcast / multi-file updates.
    { cat "$_rec_journal"; printf '%s\n' "$_rec_entry"; } | jq -s \
        '.[1] as $e | .[0] | map(select(.hash_file!=$e.hash_file or .index!=$e.index)) + [$e]' \
        > "$_rec_journal.tmp" && mv "$_rec_journal.tmp" "$_rec_journal"
}
_recovery_apply() {  # Repair accepted/winning hash and raw bytes; never writes mined.csv.
    local current aliases file index value field
    current=$(jq -r '.current' <<< "$_rec_entry")
    aliases=$(jq -r '.variants|keys|join(",")' <<< "$_rec_entry")
    for file in "$_rec_sent" "$_rec_pending"; do
        awk -F, -v OFS=, -v j="$_rec_job" -v c="$_rec_chain" -v h="$current" -v aliases="$aliases" \
            'BEGIN {n=split(aliases,a,","); for(i=1;i<=n;i++) known[a[i]]=1}
             $1==j && $2==c && ($3 in known) {$3=h} {print}' "$file" > "$file.tmp" \
            && mv "$file.tmp" "$file" || return 1
    done
    index=$(jq -r '.index+1' <<< "$_rec_entry")
    for field in hash_file raw_file; do
        file="$_rec_root/$(jq -r --arg f "$field" '.[$f]' <<< "$_rec_entry")"
        [[ -f "$file" && $(wc -l < "$file") -ge $index ]] || return 1
        value="$current"
        if [[ "$field" == raw_file ]]; then
            value=$(jq -r '.variants[.current]' <<< "$_rec_entry")
            [[ "$_rec_mode" != direct ]] || value="$_rec_chain $value"
        fi
        # Read the replacement via stdin: large deployment bytecode can exceed ARG_MAX.
        { printf '%s\n' "$value"; cat "$file"; } | awk -v n="$index" \
            'NR==1 {replacement=$0; next} NR==n+1 {$0=replacement} {print}' > "$file.tmp" \
            && mv "$file.tmp" "$file" || return 1
    done
}
_recovery_adopt() {
    _rec_entry=$(jq --arg h "$1" '.current=$h' <<< "$_rec_entry") || return 1
    _recovery_save && _recovery_apply
}
_recovery_locate() {  # Original hash -> _rec_entry (same journal format as earlier runs)
    local suffix hashes raws index raw
    suffix=$(basename "$_rec_pending" .csv); suffix=${suffix#deploy-pending}
    hashes="jobs/$_rec_job/txs.txt"; raws="jobs/$_rec_job/rawtxs.txt"
    if [[ "$_rec_mode" == direct ]]; then
        hashes="jobs/$_rec_job/deploy-hashes$suffix.txt"; raws="jobs/$_rec_job/deploytxs$suffix.txt"
    fi
    index=$(awk -v h="$1" '$0==h {print NR-1; exit}' "$_rec_root/$hashes")
    [[ -n "$index" ]] || return 1
    raw=$(sed -n "$((index+1))p" "$_rec_root/$raws")
    if [[ "$_rec_mode" == direct ]]; then
        [[ "$raw" == "$_rec_chain "* ]] || return 1
        raw=${raw#* }
    fi
    [[ $(cast keccak "$raw") == "$1" ]] || return 1
    _rec_entry=$(printf '%s' "$raw" | jq -Rs --arg j "$_rec_job" --arg c "$_rec_chain" --arg h "$1" \
        --arg hf "$hashes" --arg rf "$raws" --argjson i "$index" \
        '{job:$j,chain:$c,current:$h,variants:{($h):.},index:$i,hash_file:$hf,raw_file:$rf}')
}
_recovery_sign() {  # tx JSON, private key, fee cap, tip -> signed replacement
    local tx="$1" raw decoded field
    local args=(mktx --private-key "$2" --gas-price "$3")
    for field in chainId nonce gas value; do
        case "$field" in chainId) args+=(--chain);; nonce) args+=(--nonce);; gas) args+=(--gas-limit);; value) args+=(--value);; esac
        args+=("$(cast to-dec "$(jq -r --arg f "$field" '.[$f]' <<< "$tx")")")
    done
    if [[ $(jq -r '.type' <<< "$tx") == 0x0 ]]; then args+=(--legacy)
    else args+=(--priority-gas-price "$4" --access-list "$(jq -c '.accessList // []' <<< "$tx")"); fi
    if [[ $(jq -r '.to' <<< "$tx") == null ]]; then args+=(--create "$(jq -r '.input' <<< "$tx")")
    else args+=("$(jq -r '.to' <<< "$tx")" "$(jq -r '.input' <<< "$tx")"); fi
    raw=$(cast "${args[@]}" 2>/dev/null) || return 1  # Never print argv/signing keys on failure.
    decoded=$(_recovery_decode "$raw") || return 1
    printf '%s\n%s\n' "$tx" "$decoded" | jq -se \
        'map({signer,type,chainId,nonce,gas,to,value,input,accessList}) | .[0]==.[1]' >/dev/null || return 1
    printf '%s\n' "$raw"
}
_recovery_stop() {
    _rec_entry=$(jq --arg reason "$*" '.stop_retry=$reason' <<< "$_rec_entry") || return 1
    _recovery_save || return 1
    _recovery_log "job=$_rec_job hash=$(jq -r .current <<< "$_rec_entry") FAILED: $*"
}
_recovery_record_receipt() {  # Record immediately, before optional pool/fee work.
    local hash="$1" receipt="$2" block status
    [[ -n "$_rec_entry" ]] || _recovery_locate "$hash" || return 1
    _rec_entry=$(jq 'del(.stop_retry,.fee_retry) | .last_state="mined"' <<< "$_rec_entry")
    _recovery_adopt "$hash" || return 1
    block=$(cast to-dec "$(jq -r .blockNumber <<< "$receipt")") || return 1
    status=$(jq -r .status <<< "$receipt")
    [[ "$status" == 0x0 || "$status" == 0x1 ]] || return 1
    touch "$_rec_mined"
    if ! awk -F, -v c="$_rec_chain" -v h="$hash" '$2==c && $3==h {found=1} END {exit !found}' "$_rec_mined"; then
        printf '%s,%s,%s,%s,%s\n' "$_rec_job" "$_rec_chain" "$hash" "$block" "$status" >> "$_rec_mined"
    fi
    _remove_mined "$_rec_pending" "$_rec_mined" || return 1
    _recovery_log "job=$_rec_job attempt=$hash mined status=$status"
}
_recovery_fee_snapshot() {
    local value
    value=$(_recovery_read "$_rec_rpc" eth_getBlockByNumber '["latest",false]') || return 1
    _rec_base=$(cast to-dec "$(jq -r '.baseFeePerGas // "0x0"' <<< "$value")") || return 1
    value=$(_recovery_read "$_rec_rpc" eth_gasPrice '[]') || return 1
    _rec_price=$(cast to-dec "$(jq -r . <<< "$value")") || return 1
    # Some chains do not implement this optional oracle. Fall back only for that
    # explicit error; a transport failure still gets one status recheck.
    local rc=0
    value=$(_recovery_rpc "$_rec_rpc" eth_maxPriorityFeePerGas '[]') || rc=$?
    if (( rc == 2 )) && [[ $(jq -r .code <<< "$value") == -32601 ]]; then
        _rec_tip=$(bc <<< "if ($_rec_price > $_rec_base) $_rec_price-$_rec_base else 0")
    else
        (( rc == 0 )) || value=$(_recovery_rpc "$_rec_rpc" eth_maxPriorityFeePerGas '[]') || return 1
        _rec_tip=$(cast to-dec "$(jq -r . <<< "$value")") || return 1
    fi
}
_recovery_nonce_owner() {  # Find the mined transaction consuming sender+nonce.
    local sender="$1" nonce="$2" lo=0 hi mid count block
    hi=$(_recovery_read "$_rec_rpc" eth_blockNumber '[]') || return 1
    hi=$(cast to-dec "$(jq -r . <<< "$hi")") || return 1
    while (( lo < hi )); do
        mid=$(((lo + hi) / 2))
        count=$(_recovery_read "$_rec_rpc" eth_getTransactionCount "[\"$sender\",\"$(printf '0x%x' "$mid")\"]") || return 1
        count=$(cast to-dec "$(jq -r . <<< "$count")") || return 1
        if (( count > nonce )); then hi=$mid; else lo=$((mid+1)); fi
    done
    block=$(_recovery_read "$_rec_rpc" eth_getBlockByNumber "[\"$(printf '0x%x' "$lo")\",true]") || return 1
    jq -er --arg s "${sender,,}" --arg n "$(printf '0x%x' "$nonce")" \
        '.transactions[] | select((.from|ascii_downcase)==$s and .nonce==$n) | .hash' <<< "$block"
}
_recovery_one() {
    local hash="$1" _rec_entry h raw tx sender kind nonce gas value cap tip low newcap newtip
    local balance needed confirmed pk newhash rc=0 error reason held=false receipt owner
    _rec_entry=$(jq -c --arg j "$_rec_job" --arg c "$_rec_chain" --arg h "$hash" \
        '.[] | select(.job==$j and .chain==$c and (.variants|has($h)))' "$_rec_journal") || return 1
    local aliases=("$hash")
    [[ -z "$_rec_entry" ]] || mapfile -t aliases < <(jq -r '.variants|keys[]' <<< "$_rec_entry")
    for h in "${aliases[@]}"; do
        receipt=$(jq -c --arg h "$h" '.[$h] // null' "$_rec_work/receipts")
        if [[ $(jq -r '.blockNumber // empty' <<< "$receipt") != "" ]]; then
            _recovery_record_receipt "$h" "$receipt"; return $?
        fi
    done
    [[ -z "$_rec_entry" ]] || _recovery_apply || return 1
    [[ "$_rec_reconcile" != true ]] || return 0
    [[ -n "$_rec_entry" ]] || _recovery_locate "$hash" || return 1
    if jq -e '.stop_retry!=null' <<< "$_rec_entry" >/dev/null; then return 0; fi
    if [[ -n "${_rec_error:-}" ]]; then _recovery_stop "$_rec_error"; return $?; fi
    # A failed lower nonce blocks the rest of that wallet's job on this chain.
    reason=$(jq -r --arg j "$_rec_job" --arg c "$_rec_chain" \
        '[.[] | select(.job==$j and .chain==$c and .stop_retry!=null)][0].stop_retry // empty' "$_rec_journal")
    if [[ -n "$reason" ]]; then _recovery_stop "job blocked: $reason"; return $?; fi
    hash=$(jq -r .current <<< "$_rec_entry")
    # Honor rebroadcasts made by the old runner when migrating an existing run.
    if jq -e '.missing_resends==null' <<< "$_rec_entry" >/dev/null; then
        local previous=0
        if grep -Fq "job=$_rec_job hash=$hash not visible in pool/front; rebroadcasting" "$_rec_root/recovery.log" 2>/dev/null ||
           grep -Fq "job=$_rec_job hash=$hash not visible in transaction lookup; rebroadcasting" "$_rec_root/recovery.log" 2>/dev/null; then previous=1; fi
        _rec_entry=$(jq --argjson n "$previous" '.missing_resends=$n' <<< "$_rec_entry")
        _recovery_save || return 1
    fi
    for h in "$hash" "${aliases[@]}"; do
        if jq -e --arg h "$h" 'has($h)' "$_rec_work/pool" >/dev/null; then
            [[ "$hash" == "$h" ]] || _recovery_adopt "$h" || return 1
            hash="$h"; held=true
            if jq -e --arg h "$h" '.[$h].blockNumber!=null' "$_rec_work/pool" >/dev/null; then
                if $_rec_expired; then _recovery_stop 'RPC status error: mined transaction has no receipt'
                else _recovery_log "job=$_rec_job hash=$h mined; waiting for receipt"; fi
                return $?
            fi
            break
        fi
    done
    raw=$(jq -r '.variants[.current]' <<< "$_rec_entry")
    tx=$(_recovery_decode "$raw") || return 1
    sender=$(jq -r .signer <<< "$tx"); kind=$(cast to-dec "$(jq -r .type <<< "$tx")") || return 1
    [[ "$kind" == 0 || "$kind" == 2 ]] || { _recovery_stop "unsupported transaction type=$kind"; return $?; }
    nonce=$(cast to-dec "$(jq -r .nonce <<< "$tx")"); gas=$(cast to-dec "$(jq -r .gas <<< "$tx")")
    value=$(cast to-dec "$(jq -r .value <<< "$tx")")
    cap=$(cast to-dec "$(jq -r '.maxFeePerGas // .gasPrice' <<< "$tx")")
    tip=$(cast to-dec "$(jq -r '.maxPriorityFeePerGas // .gasPrice' <<< "$tx")")
    local fee_cap="$cap" fee_tip="$tip"
    if jq -e '.fee_retry!=null' <<< "$_rec_entry" >/dev/null; then
        fee_cap=$(jq -r .fee_retry.cap <<< "$_rec_entry"); fee_tip=$(jq -r .fee_retry.tip <<< "$_rec_entry")
        fee_cap=$(bc <<< "if ($cap > $fee_cap) $cap else $fee_cap")
        fee_tip=$(bc <<< "if ($tip > $fee_tip) $tip else $fee_tip")
    fi
    read -r low newcap newtip < <(_recovery_fees "$kind" "$fee_cap" "$fee_tip" "$_rec_base" "$_rec_price" "$_rec_tip") || return 1
    if jq -e '.fee_retry!=null' <<< "$_rec_entry" >/dev/null; then low=1; fi
    confirmed=$(_recovery_read "$_rec_rpc" eth_getTransactionCount "[\"$sender\",\"latest\"]") || {
        _recovery_stop 'RPC status error: nonce lookup failed after one status recheck'; return $?; }
    confirmed=$(cast to-dec "$(jq -r . <<< "$confirmed")") || return 1
    if (( confirmed > nonce )); then
        if ! owner=$(_recovery_nonce_owner "$sender" "$nonce"); then
            _recovery_stop 'RPC status error: nonce consumed but its transaction could not be identified'; return $?
        fi
        if ! jq -e --arg h "$owner" '.variants|has($h)' <<< "$_rec_entry" >/dev/null; then
            _recovery_stop "nonce used by another transaction: nonce=$nonce hash=$owner"; return $?
        fi
        receipt=$(_recovery_read "$_rec_rpc" eth_getTransactionReceipt "[\"$owner\"]") || {
            _recovery_stop 'RPC status error: receipt lookup failed after one status recheck'; return $?; }
        if [[ "$receipt" != null ]]; then _recovery_record_receipt "$owner" "$receipt"
        elif $_rec_expired; then _recovery_stop 'RPC status error: own nonce mined but receipt unavailable'
        else _recovery_adopt "$owner"; _recovery_log "job=$_rec_job own nonce mined; waiting for receipt"; fi
        return $?
    fi
    balance=$(_recovery_read "$_rec_rpc" eth_getBalance "[\"$sender\",\"latest\"]") || {
        _recovery_stop 'RPC status error: balance lookup failed after one status recheck'; return $?; }
    balance=$(cast to-dec "$(jq -r . <<< "$balance")") || return 1
    needed="$value+$gas*$cap"; [[ "$low" != 1 ]] || needed="$value+$gas*$newcap"
    needed=$(BC_LINE_LENGTH=0 bc <<< "$needed")
    if [[ $(bc <<< "$balance < $needed") == 1 ]]; then
        local shortfall
        shortfall=$(bc <<< "$needed-$balance")
        _recovery_stop "insufficient funds: need=$(cast from-wei "$needed") ETH have=$(cast from-wei "$balance") ETH shortfall=$(cast from-wei "$shortfall") ETH; increase funding floor"
        return $?
    fi
    if $held && [[ "$low" == 0 ]]; then
        if $_rec_expired; then _recovery_stop 'non-mined valid tx: visible with adequate fees at the 5-minute limit'
        else _recovery_log "job=$_rec_job hash=$hash visible; fees adequate; waiting (maximum 5 minutes)"; fi
        return $?
    fi
    if $_rec_expired; then
        if [[ "$low" == 1 ]]; then _recovery_stop 'low fees: monitor deadline reached'
        else _recovery_stop 'disappeared tx: not visible at monitor deadline'; fi
        return $?
    fi
    if [[ "$low" == 1 ]] && (( $(jq -r '.fee_bumps // 0' <<< "$_rec_entry") >= 2 )); then
        _recovery_stop 'low fees: two fee increases exhausted'; return $?
    fi
    if [[ "$low" == 0 ]] && (( $(jq -r '.missing_resends // 0' <<< "$_rec_entry") >= 1 )); then
        _recovery_stop 'disappeared tx: absent again after one resend (front may hide held transactions)'; return $?
    fi
    # Close the receipt race before spending a retry. Each read has one recheck.
    local url
    for url in "${_rec_urls[@]}"; do
        for h in "${aliases[@]}"; do
            receipt=$(_recovery_read "$url" eth_getTransactionReceipt "[\"$h\"]") || {
                _recovery_stop 'RPC status error: pre-send receipt check failed after one recheck'; return $?; }
            if [[ "$receipt" != null ]]; then _recovery_record_receipt "$h" "$receipt"; return $?; fi
        done
    done
    newhash="$hash"
    if [[ "$low" == 1 ]]; then
        pk=$(awk -F, -v j="$_rec_job" 'NR>1 && $1==j {print $3; exit}' "$_rec_root/wallets.csv")
        [[ -n "$pk" ]] || return 1
        raw=$(_recovery_sign "$tx" "$pk" "$newcap" "$newtip") || return 1
        newhash=$(cast keccak "$raw") || return 1
        _rec_entry=$( { printf '%s\n' "$_rec_entry"; printf '%s' "$raw" | jq -Rs .; } | jq -s --arg h "$newhash" \
            '.[0].variants[$h]=.[1] | .[0] | .fee_bumps=((.fee_bumps // 0)+1)') || return 1
        _recovery_log "job=$_rec_job fee increase $(jq -r .fee_bumps <<< "$_rec_entry")/2 nonce=$nonce cap=$cap->$newcap tip=$tip->$newtip hash=$newhash"
    else
        _rec_entry=$(jq '.missing_resends=1' <<< "$_rec_entry")
        _recovery_log "job=$_rec_job disappeared tx hash=$hash; resend 1/1 with same nonce=$nonce (lookup absence does not prove a front dropped it)"
    fi
    _recovery_save || return 1  # Counters and candidates survive a crash/lost response.
    confirmed=$(_recovery_rpc "$_rec_submit" eth_sendRawTransaction "[\"$raw\"]") || rc=$?
    if (( rc == 2 )); then
        error=$(jq -r .message <<< "$confirmed"); reason=${error,,}
        [[ "$reason" != *revert* ]] || reason='execution rejected'
        case "$reason" in
            *already\ known*|*already\ imported*|*known\ transaction*)
                _rec_entry=$(jq 'del(.fee_retry)' <<< "$_rec_entry")
                _recovery_adopt "$newhash"; return $? ;;
            *underpriced*|*fee\ cap*less\ than*|*fee\ cap*below*|*fee\ cap*too\ low*|*max\ fee\ per\ gas*too\ low*|*priority\ fee*too\ low*|*max\ fee\ per\ gas*less\ than*|*max\ fee\ per\ gas*below*|*gas\ price*too\ low*|*gas\ price*below*|*transaction\ fee*too\ low*|*tip*too\ low*)
                [[ "$low" == 1 ]] || { newcap=$cap; newtip=$tip; }
                _rec_entry=$(jq --arg cap "$newcap" --arg tip "$newtip" '.fee_retry={cap:$cap,tip:$tip}' <<< "$_rec_entry")
                _recovery_save || return 1
                if (( $(jq -r '.fee_bumps // 0' <<< "$_rec_entry") >= 2 )); then
                    _recovery_stop "low fees: two fee increases rejected; $error"; return $?
                fi
                _recovery_log "job=$_rec_job fee rejected; refresh fees and retry immediately: $error"
                _recovery_fee_snapshot || { _recovery_stop 'RPC status error: fee refresh failed after one recheck'; return $?; }
                _recovery_one "$hash"; return $? ;;
            *insufficient\ funds*|*insufficient\ balance*)
                _recovery_stop "insufficient funds: need=$(cast from-wei "$needed") ETH last_balance=$(cast from-wei "$balance") ETH; $error"; return $? ;;
            *timeout*|*timed\ out*|*temporarily\ unavailable*|*rate\ limit*|*too\ many\ requests*) rc=1 ;;
            *) _recovery_stop "transaction rejected: $error"; return $? ;;
        esac
    fi
    if (( rc == 1 )) || [[ $(jq -r . <<< "$confirmed") != "$newhash" ]]; then
        # A send may have succeeded despite losing the response. Make ONE status
        # check, with no blind second send, and retain all signed candidates.
        receipt=$(_recovery_rpc "$_rec_submit" eth_getTransactionReceipt "[\"$newhash\"]") || {
            _recovery_stop 'RPC status error: send uncertain and status check failed'; return $?; }
        if [[ "$receipt" != null ]]; then _recovery_record_receipt "$newhash" "$receipt"; return $?; fi
        confirmed=$(_recovery_rpc "$_rec_submit" eth_getTransactionByHash "[\"$newhash\"]") || {
            _recovery_stop 'RPC status error: send uncertain and status check failed'; return $?; }
        if [[ "$confirmed" == null ]]; then
            _recovery_stop 'RPC status error: send uncertain; status check could not confirm transaction'; return $?
        fi
    fi
    _rec_entry=$(jq 'del(.fee_retry,.funds_wait)' <<< "$_rec_entry")
    _recovery_adopt "$newhash" || return 1
    _recovery_log "job=$_rec_job resend accepted hash=$newhash (acknowledgement only; still awaiting receipt)"
}
_recover_pending() {  # pending.csv, direct|front, optional --reconcile-only|--expire|--rpc-error, chain
    local _rec_pending="$1" _rec_mode="$2" _rec_reconcile=false _rec_expired=false
    local _rec_root _rec_sent _rec_mined _rec_journal _rec_phase _rec_work _rec_chain _rec_job
    local _rec_rpc _rec_submit _rec_urls=() _rec_base _rec_price _rec_tip hash c _rec_error receipt_rc=0
    local option="${3:-}" only_chain="${4:-}" result=0
    [[ "$option" != --reconcile-only ]] || _rec_reconcile=true
    [[ "$option" != --expire ]] || _rec_expired=true
    [[ -s "$_rec_pending" ]] || return 0
    _rec_root=$(dirname "$_rec_pending")
    _rec_sent="$_rec_root/$(basename "$_rec_pending" | sed 's/pending/sent/')"
    _rec_mined="$_rec_root/$(basename "$_rec_pending" | sed 's/pending/mined/')"
    _rec_journal="${_rec_sent%.csv}.replacements.json"
    _rec_phase=trigger; [[ "$_rec_mode" != direct ]] || _rec_phase=deploy
    if [[ ! -f "$_rec_journal" ]]; then
        $_rec_reconcile && return 0
        printf '[]\n' > "$_rec_journal"
    fi
    _rec_work=$(mktemp -d "$_rec_root/.recovery.XXXXXX") || return 1
    for _rec_chain in L1 L2; do
        [[ -z "$only_chain" || "$only_chain" == "$_rec_chain" ]] || continue
        awk -F, -v c="$_rec_chain" '$2==c {print $3}' "$_rec_pending" > "$_rec_work/hashes"
        [[ -s "$_rec_work/hashes" ]] || continue
        jq -r --arg c "$_rec_chain" '.[] | select(.chain==$c) | .variants | keys[]' "$_rec_journal" >> "$_rec_work/hashes"
        sort -u -o "$_rec_work/hashes" "$_rec_work/hashes"
        _rec_rpc="$L1_RPC"; [[ "$_rec_chain" != L2 ]] || _rec_rpc="$L2_RPC"
        _rec_submit="$_rec_rpc"; [[ "$_rec_mode" != front ]] || _rec_submit=$(_front_rpc "$_rec_chain")
        _rec_urls=("$_rec_submit"); [[ "$_rec_rpc" == "$_rec_submit" ]] || _rec_urls+=("$_rec_rpc")
        _rec_error=''; receipt_rc=0
        if [[ "$option" == --rpc-error ]]; then
            printf '{}\n' > "$_rec_work/receipts"
            _rec_error='RPC status error: receipt polling failed after one status recheck'
        else
            _recovery_collect eth_getTransactionReceipt "$_rec_work/receipts" || receipt_rc=$?
            # Reconcile first, even if a different endpoint failed. No pool or fee
            # query can block a receipt that was already successfully collected.
            local original_reconcile="$_rec_reconcile"
            _rec_reconcile=true
            while IFS=, read -r _rec_job c hash; do
                [[ "$c" == "$_rec_chain" ]] || continue
                _recovery_one "$hash" || result=1
            done < "$_rec_pending"
            _rec_reconcile="$original_reconcile"
            $_rec_reconcile && continue
            if (( receipt_rc != 0 )); then _rec_error='RPC status error: receipt lookup failed after one status recheck'
            elif ! awk -F, -v c="$_rec_chain" '$2==c {found=1} END {exit !found}' "$_rec_pending"; then continue
            elif ! _recovery_collect eth_getTransactionByHash "$_rec_work/pool"; then _rec_error='RPC status error: pool lookup failed after one status recheck'
            elif ! _recovery_fee_snapshot; then _rec_error='RPC status error: fee lookup failed after one status recheck'; fi
        fi
        while IFS=, read -r _rec_job c hash; do
            [[ "$c" == "$_rec_chain" ]] || continue
            if ! _recovery_one "$hash"; then
                _recovery_log "job=$_rec_job recovery bookkeeping/signing error"
                result=1
            fi
        done < "$_rec_pending"
    done
    rm -f "$_rec_work/hashes" "$_rec_work/receipts" "$_rec_work/pool" "$_rec_work/receipts.tmp" "$_rec_work/pool.tmp"
    rmdir "$_rec_work"
    return "$result"
}
_recovery_all_stopped() {
    local journal="$(dirname "$1")/$(basename "$1" .csv | sed 's/pending/sent/').replacements.json"
    [[ -s "$journal" && -s "$1" ]] || return 1
    jq -Rse --slurpfile entries "$journal" '
        split("\n") | map(select(length>0) | split(",")) |
        length>0 and all(.[]; . as $row | any($entries[0][];
            .job==$row[0] and .chain==$row[1] and .stop_retry!=null))' "$1" >/dev/null
}
_recovery_report() {
    local journal entry job chain hash reason missing fees mined
    for journal in "$1"/sent.replacements.json "$1"/deploy-sent*.replacements.json; do
        [[ -s "$journal" ]] || continue
        mined="${journal%.replacements.json}.csv"; mined="${mined/sent/mined}"
        while IFS= read -r entry; do
            job=$(jq -r .job <<< "$entry"); chain=$(jq -r .chain <<< "$entry"); hash=$(jq -r .current <<< "$entry")
            reason=$(jq -r '.stop_retry // "awaiting receipt"' <<< "$entry")
            missing=$(jq -r '.missing_resends // 0' <<< "$entry"); fees=$(jq -r '.fee_bumps // 0' <<< "$entry")
            if [[ -f "$mined" ]] && awk -F, -v c="$chain" -v h="$hash" '$2==c && $3==h {found=1} END {exit !found}' "$mined"; then
                reason='mined (see verification result)'
            fi
            printf '  RECOVERY %s [%s] hash=%s: %s; disappeared/resends=%s/1 fee-increases=%s/2\n' "$job" "$chain" "$hash" "$reason" "$missing" "$fees"
        done < <(jq -c '.[] | select(.stop_retry!=null or (.missing_resends // 0)>0 or (.fee_bumps // 0)>0)' "$journal")
    done
}
