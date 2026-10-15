#!/usr/bin/env bash
# Composer fee quotes bind cross-chain triggers to their exact intent.
# Both origins try quotes, then node fees if the quote RPC is unavailable.
# Deployments and funding transfers do not enter this trigger-only path.
# Return 75 only for unsupported quote RPCs or transport failures.

network_with_fee_lock() ( # chain ID, command, args...; release on every exit
    local chain="$1" fee_lock
    shift
    [[ "$chain" =~ ^[0-9]+$ ]] || return 1
    exec {fee_lock}>"${TMPDIR:-/tmp}/eez-e2e-fee-quote-$chain.lock" || return 1
    # Queue time is not quote time. A busy worker must not expire another's turn.
    flock "$fee_lock" || return 1
    "$@"
)

network_fee_chain() { # validate the candidate and endpoint identities before queueing
    local tx="$1" front="$2" read_rpc="$3"
    local chain read_chain
    [[ -n "$front" && -n "$read_rpc" ]] || { echo 'Fee quoting requires a source front and read RPC' >&2; return 1; }
    jq -e '.type=="0x0" or .type=="0x2"' <<< "$tx" >/dev/null || { echo 'Unsupported trigger transaction type for fee quote' >&2; return 1; }
    jq -e '(.to|type)=="string" and ((.accessList // [])|length)==0' <<< "$tx" >/dev/null || {
        echo 'Trigger quotes require a target and an empty access list' >&2; return 1; }
    chain=$(cast chain-id --rpc-url "$front") || return 1
    read_chain=$(cast chain-id --rpc-url "$read_rpc") || return 1
    [[ "$chain" == "$read_chain" && "$chain" == "$(cast to-dec "$(jq -r .chainId <<< "$tx")")" ]] || {
        echo 'Quote front, read RPC and signed candidate disagree on chain ID' >&2; return 1; }
    echo "$chain"
}

_network_quote_failure_kind() { # Cast/raw JSON error, exit status -> retry|fallback|terminal
    local response="$1" status="$2" code='' lower="${1,,}"
    if [[ "$response" == \{* ]]; then
        code=$(jq -er '(.error // .).code | numbers' <<< "$response" 2>/dev/null) || {
            echo terminal; return;
        }
    elif [[ "$response" =~ error[[:space:]]code[[:space:]](-?[0-9]+) ]]; then
        code="${BASH_REMATCH[1]}"
    elif [[ "$lower" == *'server returned an error response'* ]]; then
        echo terminal; return
    fi
    case "$code" in
        -32601|-32004) echo fallback; return ;;
        -32700|-32600|-32602) echo terminal; return ;;
    esac
    case "$response" in
        *quote_busy*|*stale_context*|*quote_unavailable*'settlement reconciliation pending'*|*quote_unavailable*'unsettled native history requires reconciliation'*)
            echo retry; return ;;
    esac
    # Composer rejections take precedence over transport words in their messages.
    [[ -z "$code" ]] || { echo terminal; return; }
    case "$lower" in
        *'execution reverted'*|*'simulation revert'*|*'invalid params'*)
            echo terminal; return ;;
        *'http error 429'*) echo retry; return ;;
        *unsupported_direction*|*'error sending request'*|*'connection refused'*|*'connection reset'*|*'connection closed'*|*'connection error'*|*'tcp connect error'*|*'dns error'*|*'dns resolution'*|*'failed to lookup address'*|*'timed out'*|*timeout*|*'http status server error'*|*'http error 5'*)
            echo fallback; return ;;
    esac
    case "$status" in 28|124) echo fallback ;; *) echo terminal ;; esac
}

network_fee_quote() { # transaction, front, read RPC, optional checked chain and shared deadline
    local tx="$1" front="$2" read_rpc="$3" chain="${4:-}"
    local intent quote option nonce kind gas cap tip value expires attempt deadline left rpc_timeout rc failure
    local retry_reason=reconciliation
    [[ -n "$chain" ]] || chain=$(network_fee_chain "$tx" "$front" "$read_rpc") || return 1
    intent=$(jq -c '{from:.signer,to:.to,data:.input,value:.value}' <<< "$tx") || return 1
    # Quotes can be unavailable while earlier native/cross-chain activity is
    # settling. Retry only those explicit transient responses under one deadline.
    [[ "${EEZ_QUOTE_TIMEOUT:-120}" =~ ^[1-9][0-9]*$ ]] || { echo 'EEZ_QUOTE_TIMEOUT must be positive seconds' >&2; return 1; }
    deadline="${5:-$((SECONDS + ${EEZ_QUOTE_TIMEOUT:-120}))}"
    for ((attempt=1; attempt<=60; attempt++)); do
        left=$((deadline - SECONDS))
        (( left > 0 )) || { echo "eez_quoteFee $retry_reason timeout" >&2; return 1; }
        rpc_timeout=$left; (( rpc_timeout <= 30 )) || rpc_timeout=30
        if quote=$(cast rpc --rpc-timeout "$rpc_timeout" --rpc-url "$front" eez_quoteFee "$intent" 2>&1); then
            break
        else
            rc=$?
        fi
        failure=$(_network_quote_failure_kind "$quote" "$rc")
        if [[ "$failure" == retry ]]; then
            retry_reason=reconciliation
            [[ "${quote,,}" != *'http error 429'* ]] || retry_reason=rate-limit
            left=$((deadline - SECONDS))
            if (( attempt < 60 && left > 0 )); then
                (( attempt != 1 )) || echo "Waiting for composer fee-quote $retry_reason" >&2
                sleep "$((left < 2 ? left : 2))"; continue
            fi
            echo "eez_quoteFee $retry_reason timeout" >&2; return 1
        fi
        printf 'eez_quoteFee failed: %s\n' "$quote" >&2
        [[ "$failure" != fallback ]] || return 75
        return 1
    done
    jq -e 'def quantity: type=="string" and test("^0x[0-9a-fA-F]+$");
        .version==1 and (.chainId|quantity) and (.nonce|quantity) and (.expiresAt|quantity)
        and (.options|type)=="array"' <<< "$quote" >/dev/null || { echo 'Malformed eez_quoteFee response' >&2; return 1; }
    [[ "$(cast to-dec "$(jq -r .chainId <<< "$quote")")" == "$chain" ]] || { echo 'Fee quote chain ID mismatch' >&2; return 1; }
    nonce=$(cast to-dec "$(jq -r .nonce <<< "$tx")") || return 1
    [[ "$(cast to-dec "$(jq -r .nonce <<< "$quote")")" == "$nonce" ]] || { echo 'Fee quote nonce differs from prepared trigger; refusing to change its nonce' >&2; return 1; }
    expires=$(cast to-dec "$(jq -r .expiresAt <<< "$quote")") || return 1
    [[ "$expires" -gt $(date +%s) ]] || { echo 'Fee quote already expired' >&2; return 1; }
    kind=$(jq -r .type <<< "$tx")
    option=$(jq -ce --arg kind "$kind" '[.options[] | select(.type==$kind)] | select(length==1) | .[0]' <<< "$quote") || {
        echo 'Fee quote must contain exactly one option matching the transaction type' >&2; return 1; }
    jq -e 'def quantity: type=="string" and test("^0x[0-9a-fA-F]+$");
        (.gas|quantity) and (.estimatedFee|quantity) and
        ((.requestHash // .intentHash)|type=="string" and test("^0x[0-9a-fA-F]{64}$")) and
        (if .type=="0x0" then (.gasPrice|quantity) else (.maxFeePerGas|quantity) and (.maxPriorityFeePerGas|quantity) end)' \
        <<< "$option" >/dev/null || { echo 'Malformed fee quote option' >&2; return 1; }
    gas=$(cast to-dec "$(jq -r .gas <<< "$option")") || return 1
    cap=$(cast to-dec "$(jq -r 'if .type=="0x0" then .gasPrice else .maxFeePerGas end' <<< "$option")") || return 1
    tip=0
    [[ "$kind" != 0x2 ]] || tip=$(cast to-dec "$(jq -r .maxPriorityFeePerGas <<< "$option")") || return 1
    [[ $(bc <<< "$gas > 0 && $cap > 0 && $cap >= $tip") == 1 ]] || { echo 'Invalid quoted gas or fees' >&2; return 1; }
    value=$(cast to-dec "$(jq -r .value <<< "$tx")") || return 1
    jq -nc --argjson tx "$tx" --argjson intent "$intent" --argjson quote "$quote" --argjson option "$option" \
        --arg chain "$chain" --arg nonce "$nonce" --arg gas "$gas" --arg cap "$cap" --arg tip "$tip" \
        --arg value "$value" --arg expires "$expires" \
        '{feeSource:"composer",transaction:$tx,intent:$intent,quote:$quote,selectedOption:$option,
          chain:$chain,nonce:$nonce,gas:$gas,cap:$cap,tip:$tip,value:$value,expires:$expires}'
}

network_node_fee_plan() { # validated trigger, source read RPC, chain -> fresh node fees
    local tx="$1" read_rpc="$2" chain="$3" price base tip=0 cap value nonce gas kind response rc=0
    kind=$(jq -r .type <<< "$tx")
    price=$(cast gas-price --rpc-url "$read_rpc") || return 1
    [[ "$price" =~ ^[0-9]+$ ]] || return 1
    cap="$price"
    if [[ "$kind" == 0x2 ]]; then
        response=$(cast rpc --rpc-timeout 15 --rpc-url "$read_rpc" eth_getBlockByNumber latest false) || return 1
        base=$(cast to-dec "$(jq -er '.baseFeePerGas // "0x0"' <<< "$response")") || return 1
        response=$(cast rpc --rpc-timeout 15 --rpc-url "$read_rpc" eth_maxPriorityFeePerGas 2>&1) || rc=$?
        if (( rc == 0 )); then
            tip=$(cast to-dec "$(jq -er 'strings' <<< "$response")") || return 1
        elif [[ "$response" == *-32601* ]]; then
            tip=$(bc <<< "if ($price > $base) $price-$base else 0")
        else
            echo 'Node priority-fee lookup failed' >&2; return 1
        fi
        cap=$(bc <<< "if (2*$base+$tip > $price) 2*$base+$tip else $price")
    fi
    nonce=$(cast to-dec "$(jq -r .nonce <<< "$tx")") || return 1
    gas=$(cast to-dec "$(jq -r .gas <<< "$tx")") || return 1
    value=$(cast to-dec "$(jq -r .value <<< "$tx")") || return 1
    [[ $(bc <<< "$gas > 0 && $cap > 0 && $tip >= 0 && $cap >= $tip") == 1 ]] || return 1
    jq -nc --argjson tx "$tx" --arg chain "$chain" --arg nonce "$nonce" \
        --arg gas "$gas" --arg cap "$cap" --arg tip "$tip" --arg value "$value" \
        '{feeSource:"node",transaction:$tx,intent:($tx|{from:.signer,to:.to,data:.input,value:.value}),
          quote:null,selectedOption:null,expires:null,
          chain:$chain,nonce:$nonce,gas:$gas,cap:$cap,tip:$tip,value:$value}'
}

network_sign_quote() { # checked quote, key, balance in wei -> quote + signed bytes/hash
    local plan="$1" key="$2" balance="$3" tx kind chain nonce gas cap tip value needed signed decoded
    tx=$(jq -c .transaction <<< "$plan") || return 1
    read -r kind chain nonce gas cap tip value < <(jq -r \
        '[.transaction.type,.chain,.nonce,.gas,.cap,.tip,.value] | @tsv' <<< "$plan") || return 1
    needed=$(BC_LINE_LENGTH=0 bc <<< "$value + $gas * $cap") || return 1
    [[ $(bc <<< "$balance >= $needed") == 1 ]] || {
        printf 'Insufficient quote funding: need %s wei, have %s wei; increase --fund/--floor\n' "$needed" "$balance" >&2; return 1; }
    local args=(mktx "$(jq -r .to <<< "$tx")" "$(jq -r .input <<< "$tx")"
        --value "${value}wei" --gas-limit "$gas" --gas-price "$cap"
        --nonce "$nonce" --chain "$chain" --private-key "$key")
    if [[ "$kind" == 0x0 ]]; then args+=(--legacy); else args+=(--priority-gas-price "$tip"); fi
    signed=$(cast "${args[@]}" 2>/dev/null) || { echo 'Failed to sign quoted trigger' >&2; return 1; }
    decoded=$(cast decode-transaction "$signed" 2>/dev/null | jq 'if type=="string" then fromjson else . end') || return 1
    printf '%s\n%s\n' "$tx" "$decoded" | jq -se \
        'map({signer,type,chainId,nonce,to,value,input,accessList:(.accessList // [])}) | .[0]==.[1]' >/dev/null || {
        echo 'Quoted signing changed the prepared transaction intent' >&2; return 1; }
    jq -c --arg raw "$signed" --arg hash "$(cast keccak "$signed")" \
        '. + {raw:$raw,signedHash:$hash}' <<< "$plan"
}

network_submit_quote() { # signed quote, front, evidence, submit, persist callback, callback args...
    local plan="$1" front="$2" evidence="$3" submit="$4" persist="$5"
    shift 5
    # Return 70 for local failures: callers must not mistake these for uncertain sends.
    if [[ -n "$evidence" ]]; then
        mkdir -p "$(dirname "$evidence")" || return 70
        jq '{feeSource,intent,quote,selectedOption,signedHash,gas,cap,tip}' <<< "$plan" > "$evidence" || return 70
    fi
    # The runner owns its files. Save exact signed bytes before risking an uncertain send.
    "$persist" "$plan" "$@" || return 70
    [[ $(jq -r .feeSource <<< "$plan") == node || $(jq -r .expires <<< "$plan") -gt $(date +%s) ]] || {
        echo 'Fee quote expired before submission' >&2; return 70; }
    "$submit" "$front" "$(jq -r .raw <<< "$plan")"
}

network_send_quoted_trigger() { # raw, key, front, read RPC, evidence, submit, optional persist callback + args
    local raw="$1" key="$2" front="$3" read_rpc="$4" evidence="$5" submit="$6"
    shift 6
    local persist="${1:-:}"; if (( $# )); then shift; fi
    local original_hash known endpoint tx chain
    # An earlier submission may have succeeded without returning a response.
    # Adopt that exact hash before asking for another quote/nonce; do not resend.
    if [[ "${EEZ_FRESH_SEND:-0}" != 1 ]]; then
        original_hash=$(cast keccak "$raw") || return 1
        for endpoint in "$front" "$read_rpc"; do
            known=$(cast rpc --rpc-timeout 15 --rpc-url "$endpoint" eth_getTransactionByHash "$original_hash") || return 1
            if [[ "$known" != null ]]; then
                jq -e --arg hash "$original_hash" '.hash==$hash' <<< "$known" >/dev/null || return 1
                printf '%s\n' "$original_hash"
                return 0
            fi
        done
    fi
    tx=$(cast decode-transaction "$raw" 2>/dev/null | jq 'if type=="string" then fromjson else . end') || return 1
    chain=$(network_fee_chain "$tx" "$front" "$read_rpc") || return 1
    network_with_fee_lock "$chain" _network_quote_and_send "$tx" "$chain" "$key" "$front" "$read_rpc" "$evidence" "$submit" "$persist" "$@"
}

# Recognize only a definite tariff admission refusal, in raw JSON-RPC or Cast's
# server-error format. Timeouts, arbitrary text and other error codes never retry.
_network_reconciliation_rejection() {
    local response="$1"
    if [[ "$response" != \{* ]]; then
        response=$(sed -n 's/^Error: server returned an error response: error code -32003:.*, data: \(.*\)$/\1/p' <<< "$response")
        [[ -n "$response" ]] || return 1
        response="{\"code\":-32003,\"data\":$response}"
    fi
    jq -e '(.error // .) | .code == -32003 and .data.code == "quote_unavailable" and
        (.data.message == "quote unavailable: unsettled native history requires reconciliation" or
         .data.message == "quote unavailable: settlement reconciliation pending")' \
        <<< "$response" >/dev/null 2>&1
}

_network_quote_and_send() {
    local tx="$1" chain="$2" key="$3" front="$4" read_rpc="$5" evidence="$6" submit="$7" persist="$8"
    shift 8
    local plan balance result rc deadline left
    [[ "${EEZ_QUOTE_TIMEOUT:-120}" =~ ^[1-9][0-9]*$ ]] || { echo 'EEZ_QUOTE_TIMEOUT must be positive seconds' >&2; return 1; }
    deadline=$((SECONDS + ${EEZ_QUOTE_TIMEOUT:-120}))
    while (( SECONDS < deadline )); do
        rc=0
        plan=$(network_fee_quote "$tx" "$front" "$read_rpc" "$chain" "$deadline") || rc=$?
        if (( rc == 75 )); then
            echo 'eez_quoteFee unavailable; falling back to node fees' >&2
            plan=$(network_node_fee_plan "$tx" "$read_rpc" "$chain") || return 1
        elif (( rc != 0 )); then
            return "$rc"
        fi
        # Queue time is unbounded. Read funds after each quote, including retries.
        balance=$(cast balance --rpc-url "$read_rpc" "$(jq -r .signer <<< "$tx")") || return 1
        plan=$(network_sign_quote "$plan" "$key" "$balance") || return 1
        [[ $(jq -r .feeSource <<< "$plan") == node ]] || (( SECONDS < deadline )) || break
        rc=0
        result=$(network_submit_quote "$plan" "$front" "$evidence" "$submit" "$persist" "$@" 2>&1) || rc=$?
        if (( rc == 0 )); then printf '%s\n' "$result"; return 0; fi
        if [[ $(jq -r .feeSource <<< "$plan") == node ]] || (( rc != 1 && rc != 2 )) || ! _network_reconciliation_rejection "$result"; then
            printf '%s\n' "$result" >&2; return "$rc"
        fi
        # Retain the rejected quote before the next attempt replaces the current
        # evidence and signed candidate. The refused nonce/intent remain unchanged.
        if [[ -n "$evidence" ]]; then
            jq --arg error "$result" '{intent,quote,selectedOption,signedHash,submissionError:$error}' \
                <<< "$plan" >> "${evidence%.json}.rejections.jsonl" || return 70
        fi
        echo 'Submission refused pending reconciliation; waiting for a fresh quote' >&2
        left=$((deadline - SECONDS)); (( left > 0 )) || break
        sleep "$((left < 2 ? left : 2))"
    done
    echo 'Quote/sign/send reconciliation timeout' >&2
    return 1
}
