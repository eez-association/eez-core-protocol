#!/usr/bin/env bash
# verify-from-txs.sh — trace txs, collect every contract they touch, and verify
# those contracts on a Blockscout explorer using this repo's compiled artifacts.
#
# Usage:
#   verify-from-txs.sh -r <rpc-url> -e <explorer-base-url> [-n] <txhash> [<txhash>...]
#   verify-from-txs.sh -r <rpc-url> -e <explorer-base-url> -f <file-with-txhashes>
#
#   -r  RPC endpoint of the chain the txs live on (must support debug_traceTransaction)
#   -e  Blockscout API base URL — the BACKEND, not the frontend (verifier API =
#       <base>/api). On the devnet: L1 http://host:34556, L2 http://host:34560
#       (frontends 34557/34561 serve HTML only and cannot verify).
#   -f  File with one tx hash per line (may be combined with positional hashes)
#   -n  Dry run: trace + identify only, skip the verification submissions
#
# Pipeline per run:
#   1. debug_traceTransaction (callTracer) on every tx; collect each call target.
#   2. Dedupe; drop EOAs/precompiles; group addresses by runtime codehash.
#   3. Match each unique code against out/ artifacts (immutable regions masked;
#      falls back to a match that ignores the trailing solc metadata hash).
#   4. Skip already-verified addresses, then `forge verify-contract` the rest
#      (--guess-constructor-args first, plain retry on failure).
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RPC="" EXPLORER="" TXFILE="" DRY=false
while getopts "r:e:f:n" opt; do
    case $opt in
        r) RPC=$OPTARG ;;
        e) EXPLORER=${OPTARG%/} ;;
        f) TXFILE=$OPTARG ;;
        n) DRY=true ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
TXS=("$@")
[[ -n "$TXFILE" ]] && while read -r t; do [[ -n "$t" ]] && TXS+=("$t"); done < "$TXFILE"
if [[ -z "$RPC" || -z "$EXPLORER" || ${#TXS[@]} -eq 0 ]]; then
    grep '^#' "$0" | head -20; exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/codes"

# ── 1. trace every tx, collect call targets (CALL/STATICCALL/DELEGATECALL/CREATE*) ──
echo "== Tracing ${#TXS[@]} tx =="
for tx in "${TXS[@]}"; do
    trace=$(cast rpc debug_traceTransaction "$tx" '{"tracer":"callTracer"}' --rpc-url "$RPC" 2>/dev/null) || {
        echo "WARN: trace failed for $tx"; continue; }
    echo "$trace" | jq -r '[recurse(.calls[]?) | .to // empty] | .[]'
done | tr 'A-F' 'a-f' | sort -u > "$WORK/addrs.txt"
echo "unique call targets: $(wc -l < "$WORK/addrs.txt")"

# ── 2. keep only addresses with code; group by codehash ──
: > "$WORK/contracts.txt"
while read -r a; do
    # precompiles
    [[ "$a" =~ ^0x0{37} ]] && continue
    code=$(cast code "$a" --rpc-url "$RPC" 2>/dev/null)
    [[ -z "$code" || "$code" == "0x" ]] && continue
    h=$(cast keccak "$code")
    echo "$code" > "$WORK/codes/$h.hex"
    echo "$a $h" >> "$WORK/contracts.txt"
done < "$WORK/addrs.txt"
echo "with code: $(wc -l < "$WORK/contracts.txt") ($(awk '{print $2}' "$WORK/contracts.txt" | sort -u | wc -l) unique codes)"

# ── 3. identify each unique code against the repo's forge artifacts ──
(cd "$REPO_ROOT" && forge build >/dev/null 2>&1)
python3 - "$REPO_ROOT" "$WORK" <<'PYEOF' > "$WORK/matches.txt"
import json, glob, os, sys
root, work = sys.argv[1], sys.argv[2]

def mask(b, refs):
    b = bytearray(b)
    for s, l in refs:
        if s + l <= len(b):
            b[s:s + l] = b'\x00' * l
    return bytes(b)

def strip_meta(b):
    if len(b) < 2:
        return b
    l = int.from_bytes(b[-2:], 'big')
    return b[:-(l + 2)] if l + 2 <= len(b) else b

arts = {}
for p in glob.glob(os.path.join(root, 'out', '**', '*.json'), recursive=True):
    try:
        j = json.load(open(p))
    except Exception:
        continue
    db = j.get('deployedBytecode')
    if not isinstance(db, dict):
        continue
    obj = db.get('object', '')
    if not obj or obj == '0x' or '__$' in obj:
        continue
    tgt = list(j.get('metadata', {}).get('settings', {}).get('compilationTarget', {}).items())
    if not tgt:
        continue
    name = f"{tgt[0][0]}:{tgt[0][1]}"
    refs = [(int(r['start']), int(r['length']))
            for rr in (db.get('immutableReferences') or {}).values() for r in rr]
    arts[name] = (bytes.fromhex(obj[2:]), refs)

seen = {}
for line in open(os.path.join(work, 'contracts.txt')):
    addr, h = line.split()
    if h not in seen:
        code = bytes.fromhex(open(os.path.join(work, 'codes', h + '.hex')).read().strip()[2:])
        exact = partial = None
        for name, (a, refs) in arts.items():
            if len(a) == len(code) and mask(a, refs) == mask(code, refs):
                exact = name
                break
        near = None
        if not exact:
            cs = strip_meta(code)
            for name, (a, refs) in arts.items():
                s = strip_meta(a)
                if len(s) == len(cs) and mask(s, refs) == mask(cs, refs):
                    partial = name
                    break
        if not exact and not partial:
            # near-match: same length, few small differing regions — typically the
            # metadata hash of an EMBEDDED contract's creation code (auxdata inside
            # the code body). The explorer's matcher decides; a wrong guess just
            # fails verification.
            best = None
            for name, (a, refs) in arts.items():
                if len(a) != len(code):
                    continue
                ma, mc = mask(a, refs), mask(code, refs)
                regions = []
                i = 0
                while i < len(ma) and len(regions) <= 4:
                    if ma[i] != mc[i]:
                        st = i
                        while i < len(ma) and ma[i] != mc[i]:
                            i += 1
                        regions.append(i - st)
                    i += 1
                if 0 < len(regions) <= 4 and max(regions) <= 34:
                    if best is None or len(regions) < best[1]:
                        best = (name, len(regions))
            if best:
                near = best[0]
        seen[h] = (exact or partial or near or 'NO_MATCH',
                   'exact' if exact else ('metadata-differs' if partial else ('near-match' if near else '-')))
    name, kind = seen[h]
    print(addr, name, kind)
PYEOF

echo ""
echo "== Identification =="
sort -k2 "$WORK/matches.txt" | awk '{print "  " $1 "  " $2 "  (" $3 ")"}'
$DRY && exit 0

# Constructor args for contracts with no visible creation tx (genesis
# predeploys), where --guess-constructor-args has nothing to work from.
# Reads the values back from the contract's own immutable getters.
known_constructor_args() { # $1=addr $2=path:Name ; echoes ABI-encoded args or nothing
    case "${2##*:}" in
        EEZL2)
            local rid sys ugl
            rid=$(cast call "$1" "ROLLUP_ID()(uint64)" --rpc-url "$RPC" 2>/dev/null) || return 0
            sys=$(cast call "$1" "SYSTEM_ADDRESS()(address)" --rpc-url "$RPC" 2>/dev/null) || return 0
            ugl=$(cast call "$1" "USE_GAS_LEFT()(bool)" --rpc-url "$RPC" 2>/dev/null) || return 0
            cast abi-encode "constructor(uint64,address,bool)" "$rid" "$sys" "$ugl" 2>/dev/null
            ;;
    esac
}

# Direct Blockscout submission for contracts forge refuses locally (e.g. a
# metadata-hash drift INSIDE the code, like an embedded proxy creation code's
# auxdata): Blockscout's own matcher handles nested metadata regions and
# accepts these as partial matches.
verify_via_api() { # $1=addr $2=target ; returns 0 once the explorer confirms
    local art ver sj
    art="$REPO_ROOT/out/$(basename "${2%%:*}")/${2##*:}.json"
    ver=$(jq -r '.metadata.compiler.version // empty' "$art" 2>/dev/null)
    [[ -z "$ver" ]] && return 1
    sj="$WORK/stdjson-$1.json"
    (cd "$REPO_ROOT" && forge verify-contract "$1" "$2" --show-standard-json-input > "$sj" 2>/dev/null) || return 1
    curl -sf --max-time 30 -X POST "$EXPLORER/api/v2/smart-contracts/$1/verification/via/standard-input" \
        -F "compiler_version=v$ver" \
        -F "contract_name=$2" \
        -F "autodetect_constructor_args=true" \
        -F "files[0]=@$sj;type=application/json" >/dev/null || return 1
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 5
        [[ "$(curl -sf --max-time 10 "$EXPLORER/api/v2/smart-contracts/$1" | jq -r '.is_verified // false' 2>/dev/null)" == "true" ]] && return 0
    done
    return 1
}

# ── 4. verify everything identifiable that isn't verified yet ──
echo ""
echo "== Verification =="
PASS=0; SKIP=0; FAIL=0
while read -r addr target kind; do
    if [[ "$target" == "NO_MATCH" ]]; then
        echo "SKIP  $addr  (no artifact match)"; SKIP=$((SKIP+1)); continue
    fi
    already=$(curl -sf --max-time 10 "$EXPLORER/api/v2/smart-contracts/$addr" | jq -r '.is_verified // false' 2>/dev/null)
    if [[ "$already" == "true" ]]; then
        echo "OK    $addr  $target (already verified)"; PASS=$((PASS+1)); continue
    fi
    # --skip-is-verified-check: Blockscout reports bytecode TWINS of a verified
    # contract as "already verified", which makes forge skip the submission and
    # leaves the address itself unverified (is_verified stays false).
    kargs=$(known_constructor_args "$addr" "$target")
    out=$(cd "$REPO_ROOT" && forge verify-contract "$addr" "$target" \
        --verifier blockscout --verifier-url "$EXPLORER/api" \
        --rpc-url "$RPC" --guess-constructor-args --skip-is-verified-check --watch 2>&1) \
    || { [[ -n "$kargs" ]] && out=$(cd "$REPO_ROOT" && forge verify-contract "$addr" "$target" \
        --verifier blockscout --verifier-url "$EXPLORER/api" \
        --rpc-url "$RPC" --constructor-args "$kargs" --skip-is-verified-check --watch 2>&1); } \
    || out=$(cd "$REPO_ROOT" && forge verify-contract "$addr" "$target" \
        --verifier blockscout --verifier-url "$EXPLORER/api" \
        --rpc-url "$RPC" --skip-is-verified-check --watch 2>&1)
    # trust the explorer's state, not forge's output
    confirmed=$(curl -sf --max-time 10 "$EXPLORER/api/v2/smart-contracts/$addr" | jq -r '.is_verified // false' 2>/dev/null)
    via=""
    if [[ "$confirmed" != "true" ]] && verify_via_api "$addr" "$target"; then
        confirmed=true; via=" (direct API, partial match)"
    fi
    if [[ "$confirmed" == "true" ]]; then
        echo "OK    $addr  $target$via"; PASS=$((PASS+1))
    else
        echo "FAIL  $addr  $target"
        echo "$out" | grep -iE "error|fail" | head -2 | sed 's/^/      /'
        FAIL=$((FAIL+1))
    fi
done < "$WORK/matches.txt"
echo ""
echo "verified/already: $PASS   failed: $FAIL   skipped: $SKIP"
