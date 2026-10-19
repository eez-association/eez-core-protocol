#!/usr/bin/env bash
# Composer fee quotes bind cross-chain triggers to their exact intent.
# Both origins require a quote; transient RPC failures retry within the deadline.
# Deployments and funding transfers do not enter this trigger-only path.

# Endpoint pair -> checked chain ID. In memory only; workers inherit it, each run rechecks.
declare -gA _NETWORK_FEE_IDENTITIES=()

network_fee_cache_pair() { # front, read RPC, optional expected ID and output variable; call in parent
    local front="$1" read_rpc="$2" expected="${3:-}" chain read_chain pair
    [[ -n "$front" && -n "$read_rpc" ]] || return 1
    pair="${#front}:$front$read_rpc"
    unset '_NETWORK_FEE_IDENTITIES[$pair]'
    chain=$(cast chain-id --rpc-url "$front") || return 1
    read_chain=$(cast chain-id --rpc-url "$read_rpc") || return 1
    [[ "$chain" =~ ^[1-9][0-9]*$ && "$chain" == "$read_chain" &&
       ( -z "$expected" || "$chain" == "$expected" ) ]] || {
        echo 'Quote front/read chain ID mismatch' >&2; return 1;
    }
    _NETWORK_FEE_IDENTITIES[$pair]="$chain"
    [[ -z "${4:-}" ]] || printf -v "$4" '%s' "$chain"
}

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
    local chain read_chain pair
    [[ -n "$front" && -n "$read_rpc" ]] || { echo 'Fee quoting requires a source front and read RPC' >&2; return 1; }
    jq -e '.type=="0x0" or .type=="0x2"' <<< "$tx" >/dev/null || { echo 'Unsupported trigger transaction type for fee quote' >&2; return 1; }
    jq -e '(.to|type)=="string" and ((.accessList // [])|length)==0' <<< "$tx" >/dev/null || {
        echo 'Trigger quotes require a target and an empty access list' >&2; return 1; }
    pair="${#front}:$front$read_rpc"
    chain="${_NETWORK_FEE_IDENTITIES[$pair]:-}"
    if [[ -n "$chain" ]]; then
        read_chain="$chain"
    else
        chain=$(cast chain-id --rpc-url "$front") || return 1
        read_chain=$(cast chain-id --rpc-url "$read_rpc") || return 1
    fi
    [[ "$chain" == "$read_chain" && "$chain" == "$(cast to-dec "$(jq -r .chainId <<< "$tx")")" ]] || {
        echo 'Quote front, read RPC and signed candidate disagree on chain ID' >&2; return 1; }
    echo "$chain"
}

# Normalize complete JSON-RPC errors and Cast's server-error data without
# treating words in an unrelated error message as a typed composer rejection.
_network_rpc_error() {
    local response="$1"
    local cast_error='^Error: server returned an error response: error code (-?[0-9]+):.*, data: (.*)$'
    if [[ "$response" =~ $cast_error ]]; then
        response="{\"code\":${BASH_REMATCH[1]},\"data\":${BASH_REMATCH[2]}}"
    fi
    jq -ce '(.error // .) | select(type=="object" and (.code|type)=="number")' \
        <<< "$response" 2>/dev/null
}

_network_temporary_quote_error() { # normalized error -> retry reason, or failure
    jq -er '.data | select(type=="object") |
        if .code == "quote_busy" or .code == "stale_context" then .code
        elif .code == "quote_unavailable" and
            (.message == "quote unavailable: unsettled native history requires reconciliation" or
             .message == "quote unavailable: settlement reconciliation pending" or
             .message == "quote unavailable: queued predecessor is entering composition") then "reconciliation"
        else empty end' <<< "$1" 2>/dev/null
}

_network_quote_failure_kind() { # Cast/raw JSON error, exit status -> retry|terminal
    local response="$1" status="$2" error code lower="${1,,}"
    local plain_error='^(error: )?(quote_busy|stale_context|quote_unavailable)(: (.*))?$'
    if error=$(_network_rpc_error "$response"); then
        code=$(jq -r .code <<< "$error")
        case "$code" in
            -32700|-32600|-32601|-32602) echo terminal; return ;;
        esac
        # -32004 covers temporary composer errors as well as disabled quotes.
        # Only recognized data.code/details may override a generic RPC refusal.
        if _network_temporary_quote_error "$error" >/dev/null; then
            echo retry
        else
            echo terminal
        fi
        return
    fi
    # Missing/malformed typed data and unrecognized RPC errors are terminal,
    # even when the message happens to contain transport or retry keywords.
    if [[ "$response" =~ ^[[:space:]]*\{ ||
          "$response" =~ error[[:space:]]code[[:space:]](-?[0-9]+) ||
          "$lower" == *'server returned an error response'* ]]; then
        echo terminal; return
    fi
    # Retain support for the older plain composer error format.
    if [[ "$response" =~ $plain_error ]]; then
        code="${BASH_REMATCH[2]}"
        error=$(jq -nc --arg code "$code" --arg message "${BASH_REMATCH[4]:-}" \
            '{data:{code:$code,message:(($code|gsub("_";" "))+": "+$message)}}')
        if _network_temporary_quote_error "$error" >/dev/null; then
            echo retry
        else
            echo terminal
        fi
        return
    fi
    case "$lower" in
        *'execution reverted'*|*'simulation revert'*|*'invalid params'*)
            echo terminal; return ;;
        *'http error 429'*) echo retry; return ;;
        *unsupported_direction*) echo terminal; return ;;
        *'error sending request'*|*'connection refused'*|*'connection reset'*|*'connection closed'*|*'connection error'*|*'tcp connect error'*|*'dns error'*|*'dns resolution'*|*'failed to lookup address'*|*'timed out'*|*timeout*|*'http status server error'*|*'http error 5'*)
            echo retry; return ;;
    esac
    case "$status" in 28|124) echo retry ;; *) echo terminal ;; esac
}

network_fee_quote() { # transaction, front, read RPC, optional checked chain, shared deadline, evidence
    local tx="$1" front="$2" read_rpc="$3" chain="${4:-}" evidence="${6:-}"
    local intent quote option nonce kind gas cap tip value expires attempt deadline left rpc_timeout rc failure
    local retry_reason=reconciliation last_retry_reason='' retry_detail
    [[ -n "$chain" ]] || chain=$(network_fee_chain "$tx" "$front" "$read_rpc") || return 1
    intent=$(jq -c '{from:.signer,to:.to,data:.input,value:.value,nonce:.nonce}' <<< "$tx") || return 1
    # Quotes can be unavailable while earlier native/cross-chain activity is
    # settling, or the RPC may fail to respond. Retry transient failures under one deadline.
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
            retry_reason=transport
            case "$quote" in
                *quote_busy*|*stale_context*|*quote_unavailable*) retry_reason=reconciliation ;;
            esac
            [[ "${quote,,}" != *'http error 429'* ]] || retry_reason=rate-limit
            left=$((deadline - SECONDS))
            if (( attempt < 60 && left > 0 )); then
                if [[ "$retry_reason" != "$last_retry_reason" ]]; then
                    retry_detail="${quote:0:200}"
                    retry_detail="${retry_detail//$'\n'/ }"
                    retry_detail="${retry_detail//$'\r'/ }"
                    (( ${#quote} <= 200 )) || retry_detail+='...'
                    printf 'eez_quoteFee retry (%s, attempt %s): %s\n' "$retry_reason" "$attempt" "$retry_detail" >&2
                    last_retry_reason="$retry_reason"
                fi
                sleep "$((left < 2 ? left : 2))"; continue
            fi
            echo "eez_quoteFee $retry_reason timeout" >&2; return 1
        fi
        printf 'eez_quoteFee failed: %s\n' "$quote" >&2
        return 1
    done
    # Save the RPC response before parsing: malformed quotes never reach signed
    # evidence. Append so retries/resumes retain earlier responses, even non-JSON.
    if [[ -n "$evidence" ]]; then
        mkdir -p "$(dirname "$evidence")" || return 70
        jq -nc --arg receivedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson intent "$intent" --arg nonce "$(jq -r .nonce <<< "$tx")" \
            --arg kind "$(jq -r .type <<< "$tx")" --arg response "$quote" \
            '{receivedAt:$receivedAt,intent:$intent,preparedNonce:$nonce,transactionType:$kind,rawResponse:$response}' \
            >> "${evidence%.json}.responses.jsonl" || {
                echo 'Could not save fee quote response; stopping before signing' >&2; return 70;
            }
    fi
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
    if jq -e 'has("error")' <<< "$option" >/dev/null; then
        jq -e '.error | type=="object" and (.code|type)=="string" and (.message|type)=="string"' \
            <<< "$option" >/dev/null || { echo 'Malformed fee quote option error' >&2; return 1; }
        jq -r '"Fee quote option rejected: \(.error.code): \(.error.message)"' <<< "$option" >&2
        return 1
    fi
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
    [[ $(jq -r .expires <<< "$plan") -gt $(date +%s) ]] || {
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

# Retry only definite admission refusals, never uncertain sends or transport errors.
_network_submission_rejection_kind() {
    local error kind
    error=$(_network_rpc_error "$1") || return 1
    [[ "$(jq -r .code <<< "$error")" == -32003 ]] || return 1
    kind=$(jq -er '.data.code | select(.=="l1_tip_underfunded" or .=="l2_tip_underfunded")' \
        <<< "$error" 2>/dev/null) || kind=''
    if [[ -n "$kind" ]]; then
        echo "$kind"
    else
        _network_temporary_quote_error "$error"
    fi
}

_network_quote_and_send() {
    local tx="$1" chain="$2" key="$3" front="$4" read_rpc="$5" evidence="$6" submit="$7" persist="$8"
    shift 8
    local plan='' balance result rc deadline left rejection_kind retry_reason=reconciliation
    [[ "${EEZ_QUOTE_TIMEOUT:-120}" =~ ^[1-9][0-9]*$ ]] || { echo 'EEZ_QUOTE_TIMEOUT must be positive seconds' >&2; return 1; }
    deadline=$((SECONDS + ${EEZ_QUOTE_TIMEOUT:-120}))
    while (( SECONDS < deadline )); do
        if [[ -z "$plan" ]]; then
            rc=0
            plan=$(network_fee_quote "$tx" "$front" "$read_rpc" "$chain" "$deadline" "$evidence") || rc=$?
            (( rc == 0 )) || return "$rc"
            # Queue time is unbounded. Read funds after each new quote.
            balance=$(cast balance --rpc-url "$read_rpc" "$(jq -r .signer <<< "$tx")") || return 1
            plan=$(network_sign_quote "$plan" "$key" "$balance") || return 1
        fi
        (( SECONDS < deadline )) || break
        rc=0
        result=$(network_submit_quote "$plan" "$front" "$evidence" "$submit" "$persist" "$@" 2>&1) || rc=$?
        if (( rc == 0 )); then printf '%s\n' "$result"; return 0; fi
        rejection_kind=''
        if (( rc == 1 || rc == 2 )); then
            rejection_kind=$(_network_submission_rejection_kind "$result") || rejection_kind=''
        fi
        if [[ -z "$rejection_kind" ]]; then
            printf '%s\n' "$result" >&2; return "$rc"
        fi
        printf 'ERROR: submission refused (%s) chain=%s nonce=%s hash=%s: %s\n' \
            "$rejection_kind" "$chain" "$(jq -r .nonce <<< "$plan")" "$(jq -r .signedHash <<< "$plan")" "$result" >&2
        # Retain every refusal, including retries of the same signed candidate.
        if [[ -n "$evidence" ]]; then
            jq -c --arg error "$result" --arg kind "$rejection_kind" \
                '{intent,quote,selectedOption,signedHash,rejectionKind:$kind,submissionError:$error}' \
                <<< "$plan" >> "${evidence%.json}.rejections.jsonl" || return 70
        fi
        retry_reason="$rejection_kind"
        case "$rejection_kind" in
            l1_tip_underfunded|l2_tip_underfunded)
                plan=''
                echo 'Retrying with a fresh composer quote in 2s (same intent and nonce; original deadline)' >&2 ;;
            *)
                echo 'Retrying identical signed transaction in 2s (original deadline)' >&2 ;;
        esac
        left=$((deadline - SECONDS)); (( left > 0 )) || break
        sleep "$((left < 2 ? left : 2))"
    done
    echo "Quote/sign/send $retry_reason timeout" >&2
    return 1
}

network_fee_rejection_report() ( # staged run directory, including earlier resume attempts
    shopt -s nullglob
    local root="$1" count=0 l1=0 l2=0 totals
    local files=("$root"/jobs/*/fee-quote-*.rejections.jsonl)
    if (( ${#files[@]} )); then
        totals=$(jq -sr '
            [.[] | select(.rejectionKind=="l1_tip_underfunded" or .rejectionKind=="l2_tip_underfunded")] |
            [length, (map(select(.rejectionKind=="l1_tip_underfunded"))|length),
             (map(select(.rejectionKind=="l2_tip_underfunded"))|length)] | @tsv' "${files[@]}") || {
            echo 'Tariff rejection count unavailable: could not read saved evidence'; return 1;
        }
        read -r count l1 l2 <<< "$totals"
    fi
    printf '\nTARIFF REJECTIONS: %s (L1: %s, L2: %s; includes successful retries and prior attempts in this run)\n' "$count" "$l1" "$l2"
)
