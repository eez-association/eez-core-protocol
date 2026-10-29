"""Real offline signing checks composer quote binding and fail-closed submission."""
import copy
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from test_staged_monitor import function, RUNNER

E2E = Path(__file__).resolve().parents[1]
KEY = '0x' + '01'.zfill(64)  # Public test-only key.
TARGET = '0x' + '11' * 20

TEMPORARY_ERRORS = (
    ("quote_busy", "another quote is running"),
    ("stale_context", "quote context expired or changed"),
    ("quote_unavailable", "quote unavailable: settlement reconciliation pending"),
    ("quote_unavailable", "quote unavailable: unsettled native history requires reconciliation"),
    ("quote_unavailable", "quote unavailable: queued predecessor is entering composition"),
)


def rpc_error(rpc_code, code, message, cast_format=False):
    data = {"code": code, "message": message}
    if cast_format:
        return (f"Error: server returned an error response: error code {rpc_code}: "
                f"composer request failed, data: {json.dumps(data)}")
    return json.dumps({"jsonrpc": "2.0", "id": 1, "error": {
        "code": rpc_code, "message": "composer request failed", "data": data}})


class NetworkFeeClassifierTests(unittest.TestCase):
    def classify(self, response, submission=False):
        classifier = '_network_submission_rejection_kind' if submission else '_network_quote_failure_kind'
        return subprocess.run(
            ['bash', '-c', 'source "$1"; ' + classifier + ' "$2" 1',
             'test', str(E2E / 'lib/network-fees.sh'), response],
            capture_output=True, text=True, timeout=5)

    def test_typed_temporary_errors_override_generic_rpc_code(self):
        for cast_format in (False, True):
            for code, message in TEMPORARY_ERRORS:
                for submission in (False, True):
                    with self.subTest(cast=cast_format, code=code, message=message, submission=submission):
                        response = rpc_error(-32003 if submission else -32004, code, message, cast_format)
                        result = self.classify(response, submission)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        expected = ('reconciliation' if code == 'quote_unavailable' else code) if submission else 'retry'
                        self.assertEqual(result.stdout.strip(), expected)

    def test_disabled_unsupported_unknown_and_malformed_errors_stay_terminal(self):
        terminal_details = (
            ('quote_disabled', 'fee quotes are disabled'),
            ('unsupported_direction', 'unsupported request'),
            ('unknown', 'quote_busy: timeout'),
            ('quote_unavailable', 'quote unavailable: unknown condition'),
            ('quote_unavailable', 'quote unavailable: queued predecessor is entering composition; unknown condition'),
        )
        for cast_format in (False, True):
            for submission in (False, True):
                rpc_code = -32003 if submission else -32004
                responses = [rpc_error(rpc_code, code, message, cast_format)
                             for code, message in terminal_details]
                responses += [rpc_error(-32601, *TEMPORARY_ERRORS[0], cast_format),
                              rpc_error(-32602, *TEMPORARY_ERRORS[0], cast_format),
                              rpc_error(rpc_code, *TEMPORARY_ERRORS[0], cast_format)[:-2],
                              rpc_error(rpc_code, 'quote_unavailable', None, cast_format)]
                for response in responses:
                    with self.subTest(response=response, submission=submission):
                        result = self.classify(response, submission)
                        if submission:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertEqual(result.stdout, '')
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertEqual(result.stdout.strip(), 'terminal')


MOCK = r'''
# Keep simulated deadlines independent of host load. Real-sleep tests retain
# Bash's wall clock to verify the deadline across quote/sign/send subshells.
if [[ "${REAL_SLEEP:-0}" != 1 ]]; then
    unset SECONDS
    SECONDS=0
fi
cast() {
    echo "$1" >> "$TEST_ROOT/cast-calls"
    case "$1" in
        chain-id)
            if [[ "${!#}" == front ]]; then echo "${FRONT_CHAIN:-906969}"; else echo "${READ_CHAIN:-906969}"; fi ;;
        balance) echo "${BALANCE:-1000000000000000000}" ;;
        gas-price) return 90 ;;  # Never contact a real fee oracle in these tests.
        rpc)
            if [[ "$*" == *eth_getTransactionByHash* ]]; then
                if [[ "${KNOWN:-0}" == 1 ]]; then jq -nc --arg hash "${!#}" '{hash:$hash}'; else echo null; fi
                return
            fi
            [[ "$*" == *eez_quoteFee* ]] || return 90
            printf '%s\n' "${!#}" >> "$TEST_ROOT/intents"
            if [[ "${BUSY:-0}" == 1 && ! -f "$TEST_ROOT/busy" ]]; then
                touch "$TEST_ROOT/busy"; echo "${TRANSIENT_ERROR:-error: quote_busy}" >&2; return 1
            fi
            if [[ "${PERSISTENT_TRANSIENT:-0}" == 1 ]]; then echo "${TRANSIENT_ERROR:-quote_unavailable: settlement reconciliation pending}" >&2; return 1; fi
            if [[ "${RPC_ERROR:-0}" == 1 ]]; then echo "${RPC_ERROR_TEXT:-error sending request: connection refused}" >&2; return "${RPC_ERROR_STATUS:-1}"; fi
            if [[ "${QUOTE_FAIL_AFTER_REFUSAL:-0}" == 1 && -f "$TEST_ROOT/send-refused" ]]; then
                echo 'error sending request: connection refused' >&2; return 1
            fi
            cat "$TEST_ROOT/quote.json" ;;
        mktx) echo sign >> "$TEST_ROOT/signs"; command cast "$@" ;;
        decode-transaction|keccak|to-dec) command cast "$@" ;;
        *) echo "Unexpected cast subcommand: $1" >&2; return 90 ;;
    esac
}
sleep() { if [[ "${REAL_SLEEP:-0}" == 1 ]]; then command sleep "$1"; else SECONDS=$((SECONDS + $1)); fi; }
flock() {
    [[ "$*" != *-w* ]] || return 94
    # Model a long queue without delaying the test; the quote deadline starts later.
    SECONDS=$((SECONDS + ${QUEUE_WAIT:-0}))
    touch "$TEST_ROOT/lock-wait"
    command flock "$@"
}
date() {
    if [[ -f "$TEST_ROOT/expired" ]]; then echo 9999999999; else command date "$@"; fi
}
persist() {
    [[ "${PERSIST_ERROR:-0}" != 1 ]] || return 1
    _staged_save_quoted_trigger "$@" || return 1
    if [[ "${EXPIRE_ON_SAVE:-0}" == 1 ]]; then touch "$TEST_ROOT/expired"; fi
}

submit() {
    # A second worker must not acquire a new quote turn while this send is running.
    if command flock -n "$TMPDIR/eez-e2e-fee-quote-${READ_CHAIN:-906969}.lock" true; then return 92; fi
    [[ "$(cat "$TEST_ROOT/rawtxs.txt")" == "$2" ]] || return 91
    echo sent >> "$TEST_ROOT/sends"
    printf '%s\n' "$2" >> "$TEST_ROOT/submitted-raws"
    if [[ -n "${SUBMIT_ERROR_TEXT:-}" ]]; then printf '%s\n' "$SUBMIT_ERROR_TEXT" >&2; return "${SUBMIT_ERROR_RC:-1}"; fi
    if [[ "${SEND_RECONCILE:-0}" == always || ( "${SEND_RECONCILE:-0}" == once && ! -f "$TEST_ROOT/send-refused" ) ]]; then
        touch "$TEST_ROOT/send-refused"
        if [[ "${EXPIRE_AFTER_REFUSAL:-0}" == 1 ]]; then touch "$TEST_ROOT/expired"; fi
        if [[ -n "${ADMISSION_ERROR:-}" ]]; then
            printf '%s\n' "$ADMISSION_ERROR" >&2
        elif [[ -n "${TARIFF_CODE:-}" ]]; then
            if [[ "${SEND_RECONCILE_CAST:-0}" == 1 ]]; then
                printf 'Error: server returned an error response: error code -32003: settlement tariff admission failed, data: {"code":"%s","message":"underfunded"}\n' "$TARIFF_CODE" >&2
            else
                jq -nc --arg code "$TARIFF_CODE" '{error:{code:-32003,data:{code:$code,message:"underfunded"}}}' >&2
            fi
        elif [[ "${SEND_RECONCILE_CAST:-0}" == 1 ]]; then
            echo 'Error: server returned an error response: error code -32003: L2 settlement tariff admission failed, data: {"code": "quote_unavailable", "message": "quote unavailable: unsettled native history requires reconciliation"}' >&2
        else
            echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32003,"message":"L2 settlement tariff admission failed","data":{"code":"quote_unavailable","message":"quote unavailable: unsettled native history requires reconciliation"}}}' >&2
        fi
        jq '.options[1].maxFeePerGas="0x2000"' "$TEST_ROOT/quote.json" > "$TEST_ROOT/quote.next"
        mv "$TEST_ROOT/quote.next" "$TEST_ROOT/quote.json"
        return 1
    fi
    [[ "${SEND_ERROR:-0}" != 1 ]] || return 1
    command cast keccak "$2"
}
'''


class NetworkFeeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.candidates = {}
        for kind in ('0x0', '0x2'):
            args = ['cast', 'mktx', TARGET, '0x12345678', '--private-key', KEY,
                    '--chain', '906969', '--nonce', '7', '--gas-limit', '1000000',
                    '--gas-price', '100', '--value', '17']
            args += ['--legacy'] if kind == '0x0' else ['--priority-gas-price', '1']
            cls.candidates[kind] = subprocess.check_output(args, text=True).strip()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.quote = {'version': 1, 'chainId': '0xdd6d9', 'nonce': '0x7',
                      'expiresAt': hex(int(time.time()) + 3600), 'recoveryMode': 'enforced_tariff',
                      'options': [
                          {'type': '0x0', 'gas': '0x3d090', 'gasPrice': '0x1388',
                           'estimatedFee': '0x4a817c80', 'intentHash': '0x' + 'ab' * 32},
                          {'type': '0x2', 'gas': '0x3d090', 'maxFeePerGas': '0x1388',
                           'maxPriorityFeePerGas': '0xfa0', 'estimatedFee': '0x4a817c80',
                           'intentHash': '0x' + 'cd' * 32}]}

    def run_quote(self, kind='0x2', send=False, start=False, quote_text=None, **env):
        (self.root / 'quote.json').write_text(json.dumps(self.quote) if quote_text is None else quote_text)
        (self.root / 'rawtxs.txt').write_text(self.candidates[kind] + '\n')
        action = 'network_send_quoted_trigger "$RAW" "$KEY" front direct "$TEST_ROOT/evidence.json" submit persist "$TEST_ROOT/rawtxs.txt" 1'
        if env.get('REPEAT_SENDS'):
            action = 'for ((i=0; i<REPEAT_SENDS; i++)); do\n' + action + '\ndone'
        if env.get('PRECHECK'):
            action = 'network_fee_cache_pair "${PRECHECK_FRONT:-front}" direct "${EXPECTED_CHAIN:-}" CHECKED_CHAIN\n[[ "$CHECKED_CHAIN" == "${READ_CHAIN:-906969}" ]]\n' + action
        if env.get('RESET_CONTEXT'):
            action = 'network_fee_cache_pair front direct\nsource "$HELPER"\n' + action
        if not send:
            action += ' >/dev/null\ncat "$TEST_ROOT/rawtxs.txt"'
        args = ['bash', '-c', 'set -euo pipefail\nsource "$HELPER"\n' + function("_staged_save_quoted_trigger") + "\n" + MOCK + action]
        settings = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                        env={'PATH': os.environ['PATH'], 'TEST_ROOT': str(self.root),
                             'TMPDIR': str(self.root), 'HELPER': str(E2E / 'lib/network-fees.sh'),
                             'KEY': KEY, 'RAW': self.candidates[kind], **env})
        if start:
            return subprocess.Popen(args, **settings)
        return subprocess.run(args, timeout=15, **settings)

    def decode(self, raw):
        value = json.loads(subprocess.check_output(['cast', 'decode-transaction', raw], text=True))
        return json.loads(value) if isinstance(value, str) else value

    def test_burst_first_send_failure_does_not_wait_for_nonexistent_receipts(self):
        script = r'''set -euo pipefail
source "$LOADER"
_now_ms() { echo 1; }
cast() { if [[ "$1" == nonce ]]; then echo 7; else echo raw; fi; }
timeout() { shift; "$@"; }
load_burst_send() { return 1; }
RECEIPT_POLLER_PID=$$
load_worker 0 2 address key
'''
        env = {'PATH': os.environ['PATH'], 'TMPDIR': str(self.root), 'LOADER': str(E2E / 'run/network/load-testing.sh'),
               'RUN_DIR': str(self.root), 'BURST': 'true', 'WINDOW': '2',
               'READ_RPC': 'direct', 'SEND_RPC': 'front', 'SEND_TIMEOUT': '1',
               'RECEIPT_TIMEOUT': '2', 'TARGET': TARGET, 'CALLDATA': '0x',
               'VALUE': '0', 'GAS': '100000', 'GAS_PRICE': '100', 'CHAIN_ID': '1'}
        result = subprocess.run(['bash', '-c', script], env=env,
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(',send_error,', (self.root / 'worker-0.csv').read_text())

    def test_burst_polls_receipts_before_window_finishes_sending(self):
        script = r'''set -euo pipefail
source "$LOADER"
_now_ms() { date +%s%3N; }
cast() {
    case "$1" in
        nonce) echo 7 ;;
        mktx) echo raw ;;
        receipt) echo '{"status":"0x1"}' ;;
    esac
}
timeout() { shift; "$@"; }
load_burst_send() {
    if [[ -f "$RUN_DIR/first-send" ]]; then
        # The second send cannot complete unless the first receipt is polled.
        for ((n=0; n<100; n++)); do
            [[ -s "$RUN_DIR/worker-0.receipts.csv" ]] && break
            sleep 0.02
        done
        [[ -s "$RUN_DIR/worker-0.receipts.csv" ]] || return 1
    fi
    touch "$RUN_DIR/first-send"
    printf '0x%064d\n' 1
}
# Model the shared poller's queue/results protocol independently of sending.
(
    for ((n=0; n<200; n++)); do
        if [[ -f "$RUN_DIR/worker-0.pending" ]]; then
            awk -F, '{print $1","$2","$3","$4",success,1"}' "$RUN_DIR/worker-0.pending" >"$RUN_DIR/receipts.next"
            mv "$RUN_DIR/receipts.next" "$RUN_DIR/worker-0.receipts.csv"
            (( $(wc -l <"$RUN_DIR/worker-0.receipts.csv") < 2 )) || exit 0
        fi
        sleep 0.02
    done
    exit 1
) &
RECEIPT_POLLER_PID=$!
load_worker 0 2 address key
wait "$RECEIPT_POLLER_PID"
'''
        env = {'PATH': os.environ['PATH'], 'TMPDIR': str(self.root), 'LOADER': str(E2E / 'run/network/load-testing.sh'),
               'RUN_DIR': str(self.root), 'BURST': 'true', 'WINDOW': '2',
               'READ_RPC': 'direct', 'SEND_RPC': 'front', 'SEND_TIMEOUT': '1',
               'RECEIPT_TIMEOUT': '2', 'TARGET': TARGET, 'CALLDATA': '0x',
               'VALUE': '0', 'GAS': '100000', 'GAS_PRICE': '100', 'CHAIN_ID': '1'}
        result = subprocess.run(['bash', '-c', script], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = (self.root / 'worker-0.receipts.csv').read_text().splitlines()
        self.assertEqual(len(rows), 2)
        self.assertEqual({row.split(',')[2] for row in rows}, {'7', '8'})
        self.assertTrue(all(',success,' in row for row in rows))

    def test_burst_shares_fees_across_wallets_without_lock_or_quote(self):
        cache = str(self.root / 'burst-plan.json')
        result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache)
        self.assertEqual(result.returncode, 0, result.stderr)
        key = '0x' + '02'.zfill(64)
        raw = subprocess.check_output([
            'cast', 'mktx', TARGET, '0x12345678', '--private-key', key,
            '--chain', '906969', '--nonce', '12', '--gas-limit', '1000000',
            '--gas-price', '100', '--priority-gas-price', '1', '--value', '17'], text=True).strip()
        script = r'''set -euo pipefail
source "$HELPER"
source "$LOADER"
cast() {
    case "$1" in
        balance) echo 999999999999999999 ;;
        mktx|decode-transaction|keccak|to-dec) command cast "$@" ;;
        *) echo "Unexpected cast subcommand: $1" >&2; return 90 ;;
    esac
}
network_with_fee_lock() { echo 'unexpected lock' >&2; return 99; }
network_send_quoted_trigger() {
    echo retry >>"$RUN_DIR/retries"
    [[ "$FAIL" == refreshed ]] || return 98
    jq '.gas="300000" | .cap="10000" | .tip="8000"' "$RUN_DIR/burst-evidence.json" >"$5"
    printf '0x%064d\n' 2
}
_load_publish_raw() {
    echo attempt >>"$RUN_DIR/burst-attempts"
    case "$FAIL" in
        transport) echo 'connection timeout' >&2; return 124 ;;
        underfunded|refreshed|once)
            if [[ "$FAIL" == underfunded || "$FAIL" == refreshed || ! -f "$RUN_DIR/bump-refused" ]]; then
                touch "$RUN_DIR/bump-refused"
                echo '{"error":{"code":-32003,"data":{"code":"l1_tip_underfunded","message":"underfunded"}}}' >&2
                return 1
            fi ;;
    esac
    printf '%s\n' "$2" >"$RUN_DIR/burst-signed"
    command cast keccak "$2"
}
load_burst_send "$RAW" "$KEY" "$RUN_DIR/burst-evidence.json"
'''
        env = {'PATH': os.environ['PATH'], 'TMPDIR': str(self.root), 'HELPER': str(E2E / 'lib/network-fees.sh'),
               'LOADER': str(E2E / 'run/network/load-testing.sh'),
               'RUN_DIR': str(self.root), 'READ_RPC': 'direct', 'SEND_RPC': 'front',
               'RAW': raw, 'KEY': key, 'FAIL': ''}
        result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = self.decode((self.root / 'burst-signed').read_text().strip())
        self.assertEqual(signed['signer'], self.decode(raw)['signer'])
        self.assertEqual(int(signed['nonce'], 16), 12)
        self.assertEqual(int(signed['gas'], 16), 250000)
        self.assertEqual(int(signed['maxFeePerGas'], 16), 5000)
        evidence = json.loads((self.root / 'burst-evidence.json').read_text())
        self.assertEqual(evidence['feeSource'], 'cached-load-test')
        result = subprocess.run(['bash', '-c', script], env={**env, 'FAIL': 'once'},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        bumped = self.decode((self.root / 'burst-signed').read_text().strip())
        self.assertEqual(int(bumped['maxFeePerGas'], 16), 5900)
        self.assertEqual(int(bumped['maxPriorityFeePerGas'], 16), 4720)
        self.assertEqual(int(bumped['nonce'], 16), 12)
        self.assertFalse((self.root / 'retries').exists())
        # The next send reuses the accepted bump without another refusal.
        result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        retained = self.decode((self.root / 'burst-signed').read_text().strip())
        self.assertEqual(int(retained['maxFeePerGas'], 16), 5900)
        for failure, expected in [('transport', 124), ('underfunded', 98)]:
            (self.root / 'burst-attempts').write_text('')
            result = subprocess.run(['bash', '-c', script], env={**env, 'FAIL': failure},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual((self.root / 'retries').exists(), failure == 'underfunded')
            self.assertEqual(len((self.root / 'burst-attempts').read_text().splitlines()),
                             4 if failure == 'underfunded' else 1)
        result = subprocess.run(['bash', '-c', script], env={**env, 'FAIL': 'refreshed'},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        refreshed = self.decode((self.root / 'burst-signed').read_text().strip())
        self.assertEqual(int(refreshed['gas'], 16), 300000)
        self.assertEqual(int(refreshed['maxFeePerGas'], 16), 10000)
        self.assertEqual(int(refreshed['maxPriorityFeePerGas'], 16), 8000)

    def test_load_cache_reuses_fees_with_new_nonce_and_expired_quote(self):
        cache = str(self.root / 'worker-cache.json')
        result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache)
        self.assertEqual(result.returncode, 0, result.stderr)
        cached = json.loads(Path(cache).read_text())
        cached['expires'] = '1'
        Path(cache).write_text(json.dumps(cached))
        self.candidates = dict(self.candidates)
        self.candidates['0x2'] = subprocess.check_output([
            'cast', 'mktx', TARGET, '0x12345678', '--private-key', KEY,
            '--chain', '906969', '--nonce', '8', '--gas-limit', '1000000',
            '--gas-price', '100', '--priority-gas-price', '1', '--value', '17'], text=True).strip()
        result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache,
                                RPC_ERROR='1', RPC_ERROR_TEXT='connection reset')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('LOAD FEE FALLBACK', result.stderr)
        tx = self.decode((self.root / 'submitted-raws').read_text().splitlines()[-1])
        self.assertEqual(int(tx['nonce'], 16), 8)
        self.assertEqual(int(tx['gas'], 16), 250000)
        self.assertEqual(int(tx['maxFeePerGas'], 16), 5000)
        evidence = json.loads((self.root / 'evidence.json').read_text())
        self.assertEqual(evidence['feeSource'], 'cached-load-test')
        self.assertEqual(evidence['quote']['nonce'], '0x7')
        self.assertEqual(evidence['intent']['nonce'], '0x8')

    def test_load_cache_never_overrides_terminal_quote_failures(self):
        cache = str(self.root / 'worker-cache.json')
        result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache)
        self.assertEqual(result.returncode, 0, result.stderr)
        cached = Path(cache).read_text()
        failures = [
            dict(RPC_ERROR='1', RPC_ERROR_TEXT=rpc_error(-32004, 'quote_disabled', 'disabled')),
            dict(RPC_ERROR='1', RPC_ERROR_TEXT='execution reverted'),
            dict(quote_text='not json'),
        ]
        rejected = copy.deepcopy(self.quote)
        rejected['options'][1] = {'type': '0x2', 'error': {'code': 'simulation_reverted', 'message': 'reverted'}}
        failures.append(dict(quote_text=json.dumps(rejected)))
        wrong_chain = copy.deepcopy(self.quote)
        wrong_chain['chainId'] = '0x1'
        failures.append(dict(quote_text=json.dumps(wrong_chain)))
        for failure in failures:
            with self.subTest(failure=failure):
                result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache, **failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('LOAD FEE FALLBACK', result.stderr)
                self.assertEqual(Path(cache).read_text(), cached)
                self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
                self.assertEqual(len((self.root / 'signs').read_text().splitlines()), 1)

    def test_wallet_offsets_reject_octal_and_overflow_before_setup(self):
        # Validation must fail without touching real tools or loading local credentials,
        # even if the guard being tested regresses.
        binaries = self.root / 'bin'
        binaries.mkdir()
        for tool in ('cast', 'forge', 'curl', 'wget', 'anvil'):
            stub = binaries / tool
            stub.write_text('#!/bin/sh\nprintf blocked >> "$BLOCKED_CALLS"\nexit 97\n')
            stub.chmod(0o755)
        blocked = self.root / 'blocked-calls'
        env = {'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
               'HOME': str(self.root), 'TMPDIR': str(self.root),
               'DEVNET_ENV': str(self.root / 'missing.env'), 'BLOCKED_CALLS': str(blocked)}
        for offset in ('010', '08', '00', '-1', '1000000000'):
            for use_env in (False, True):
                with self.subTest(offset=offset, env=use_env):
                    args = ['bash', str(E2E / 'run/network/load-testing.sh')]
                    settings = {**env, 'WALLET_OFFSET': offset if use_env else '0'}
                    if not use_env:
                        args += ['--wallet-offset', offset]
                    result = subprocess.run(args + ['counter'], env=settings,
                                            capture_output=True, text=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('no leading zeros', result.stdout)
                    self.assertFalse(blocked.exists())
        # Bypass validation with a valid offset: the isolation guard still stops setup.
        result = subprocess.run(['bash', str(E2E / 'run/network/load-testing.sh'),
                                 '--wallet-offset', '0', 'counter'], env=env,
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing environment file:', result.stdout + result.stderr)
        self.assertFalse(blocked.exists())

    def test_fee_mock_rejects_unexpected_cast_subcommands(self):
        for subcommand in ('publish', 'send', 'call', 'nonce'):
            with self.subTest(subcommand=subcommand):
                result = subprocess.run(['bash', '-c', MOCK + '\ncast "$1"', 'test', subcommand],
                                        env={'PATH': os.environ['PATH'], 'TEST_ROOT': str(self.root)},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 90)
                self.assertIn('Unexpected cast subcommand:', result.stderr)

    def test_load_cache_requires_first_quote_and_checks_balance_and_send(self):
        cache = str(self.root / 'worker-cache.json')
        errors = dict(RPC_ERROR='1', RPC_ERROR_TEXT='connection reset', EEZ_LOAD_FEE_CACHE=cache)
        result = self.run_quote(send=True, **errors)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'sends').exists())
        result = self.run_quote(send=True, EEZ_LOAD_FEE_CACHE=cache)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_quote(send=True, BALANCE='1', **errors)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        result = self.run_quote(send=True, SEND_ERROR='1', **errors)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)
        cached = json.loads(Path(cache).read_text())
        cached['transaction']['to'] = '0x' + '22' * 20
        Path(cache).write_text(json.dumps(cached))
        result = self.run_quote(send=True, **errors)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)

    def test_prechecked_endpoints_are_read_once_for_multiple_triggers(self):
        result = self.run_quote(send=True, PRECHECK="1", REPEAT_SENDS="3", EEZ_FRESH_SEND="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "cast-calls").read_text().splitlines()
        self.assertEqual(calls.count("chain-id"), 2)
        self.assertEqual(calls.count("balance"), 3)
        self.assertEqual(len((self.root / "intents").read_text().splitlines()), 3)

    def test_changed_endpoint_pair_cannot_use_cached_identity(self):
        result = self.run_quote(send=True, PRECHECK="1", PRECHECK_FRONT="different-front")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "cast-calls").read_text().splitlines().count("chain-id"), 4)

    def test_new_run_context_rechecks_endpoints(self):
        result = self.run_quote(send=True, RESET_CONTEXT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "cast-calls").read_text().splitlines().count("chain-id"), 4)

    def test_cached_identity_still_checks_candidate_and_quote(self):
        self.quote["chainId"] = "0x1"
        result = self.run_quote(send=True, PRECHECK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fee quote chain ID mismatch", result.stderr)
        self.assertFalse((self.root / "sends").exists())
        result = self.run_quote(send=True, PRECHECK="1", FRONT_CHAIN="1", READ_CHAIN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed candidate disagree", result.stderr)
        self.assertFalse((self.root / "sends").exists())

    def test_preflight_checks_expected_chain_before_send(self):
        result = self.run_quote(send=True, PRECHECK="1", EXPECTED_CHAIN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "intents").exists())
        self.assertFalse((self.root / "sends").exists())

    def test_l1_quote_preserves_intent_and_uses_quoted_fees(self):
        self.candidates = dict(self.candidates)
        self.quote['chainId'] = hex(10200)
        for kind in ('0x0', '0x2'):
            with self.subTest(kind=kind):
                args = ['cast', 'mktx', TARGET, '0x12345678', '--private-key', KEY,
                        '--chain', '10200', '--nonce', '7', '--gas-limit', '1000000',
                        '--gas-price', '100', '--value', '17']
                args += ['--legacy'] if kind == '0x0' else ['--priority-gas-price', '1']
                self.candidates[kind] = subprocess.check_output(args, text=True).strip()
                result = self.run_quote(kind, FRONT_CHAIN='10200', READ_CHAIN='10200')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                tx = self.decode(result.stdout.strip())
                original = self.decode(self.candidates[kind])
                for field in ('signer', 'type', 'chainId', 'nonce', 'to', 'value', 'input'):
                    self.assertEqual(tx[field], original[field], field)
                self.assertEqual(int(tx['gas'], 16), 250000)
                self.assertEqual(int(tx.get('maxFeePerGas', tx.get('gasPrice')), 16), 5000)
                if kind == '0x2':
                    self.assertEqual(int(tx['maxPriorityFeePerGas'], 16), 4000)

    def test_both_formats_sign_the_quoted_gas_and_fees_for_exact_intent(self):
        for kind in ('0x0', '0x2'):
            with self.subTest(kind=kind):
                result = self.run_quote(kind)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                tx = self.decode(result.stdout.strip())
                original = self.decode(self.candidates[kind])
                for key in ('signer', 'type', 'chainId', 'nonce', 'to', 'value', 'input'):
                    self.assertEqual(tx[key], original[key], key)
                self.assertEqual(int(tx['gas'], 16), 250000)
                self.assertEqual(int(tx.get('maxFeePerGas', tx.get('gasPrice')), 16), 5000)
                if kind == '0x2':
                    self.assertEqual(int(tx['maxPriorityFeePerGas'], 16), 4000)
                intent = json.loads((self.root / 'intents').read_text().splitlines()[-1])
                self.assertEqual(intent, {'from': original['signer'], 'nonce': original['nonce'], 'to': TARGET,
                                          'data': '0x12345678', 'value': '0x11'})
                evidence = json.loads((self.root / 'evidence.json').read_text())
                self.assertEqual(evidence['selectedOption']['type'], kind)
                self.assertEqual(evidence['signedHash'], tx['hash'])

    def test_typed_option_error_preserves_diagnostic_without_signing_or_fallback(self):
        for kind in ('0x0', '0x2'):
            with self.subTest(kind=kind):
                index = 0 if kind == '0x0' else 1
                self.quote['options'][index] = {
                    'type': kind, 'error': {
                        'code': 'insufficient_funds', 'message': 'source balance is too small'}}
                result = self.run_quote(kind, send=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('insufficient_funds: source balance is too small', result.stderr)
                self.assertFalse((self.root / 'signs').exists())
                self.assertFalse((self.root / 'sends').exists())
                self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())

    def test_malformed_option_error_cannot_authorize_signing(self):
        self.quote['options'][1]['error'] = {'code': 123, 'message': 'bad response'}
        result = self.run_quote(send=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Malformed fee quote option error', result.stderr)
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_current_request_hash_quote_schema_signs_without_legacy_metadata(self):
        self.quote.pop('recoveryMode')
        for option in self.quote['options']:
            option['requestHash'] = option.pop('intentHash')
        result = self.run_quote(send=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads((self.root / 'evidence.json').read_text())
        self.assertIn('requestHash', evidence['selectedOption'])
        self.assertNotIn('intentHash', evidence['selectedOption'])

    def test_legacy_option_uses_legacy_price_even_with_an_extra_dynamic_fee_field(self):
        self.quote['options'][0]['maxFeePerGas'] = '0x1'
        result = self.run_quote('0x0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(int(self.decode(result.stdout.strip())['gasPrice'], 16), 5000)

    def test_invalid_quote_never_signs_or_sends(self):
        mutations = [lambda q: q.update(chainId='0x1'), lambda q: q.update(nonce='0x8'),
                     lambda q: q.update(expiresAt='0x1'), lambda q: q.update(version=2),
                     lambda q: q.update(options=[]),
                     lambda q: q['options'][1].update(maxFeePerGas='0x1'),
                     lambda q: q['options'][1].update(gas='0x0'),
                     lambda q: q['options'][1].update(maxPriorityFeePerGas='bad'),
                     lambda q: q['options'][1].update(intentHash=None),
                     lambda q: q['options'][1].update(requestHash='bad')]
        baseline = copy.deepcopy(self.quote)
        for index, mutation in enumerate(mutations, 1):
            self.quote = copy.deepcopy(baseline)
            mutation(self.quote)
            result = self.run_quote(send=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / 'signs').exists())
            self.assertFalse((self.root / 'sends').exists())
            records = [json.loads(line) for line in
                       (self.root / 'evidence.responses.jsonl').read_text().splitlines()]
            self.assertEqual(len(records), index)
            self.assertEqual(json.loads(records[-1]['rawResponse']), self.quote)
            self.assertEqual(records[-1]['intent']['to'], TARGET)
            self.assertEqual(records[-1]['preparedNonce'], '0x7')
            self.assertEqual(records[-1]['transactionType'], '0x2')
            self.assertFalse((self.root / 'evidence.json').exists())
            self.assertNotIn(KEY, json.dumps(records))

    def test_non_json_quote_response_is_saved_before_validation(self):
        response = 'broken response\n"quoted" text'
        result = self.run_quote(send=True, quote_text=response)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Malformed eez_quoteFee response', result.stderr)
        records = (self.root / 'evidence.responses.jsonl').read_text().splitlines()
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(records[0])['rawResponse'], response)
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_response_persistence_failure_stops_before_signing(self):
        (self.root / 'evidence.responses.jsonl').mkdir()
        result = self.run_quote(send=True)
        self.assertEqual(result.returncode, 70)
        self.assertIn('Could not save fee quote response', result.stderr)
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_front_chain_mismatch_stops_before_quote(self):
        result = self.run_quote(FRONT_CHAIN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'intents').exists())

    def test_valid_quote_with_insufficient_balance_never_signs_or_sends(self):
        result = self.run_quote(send=True, BALANCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Insufficient quote funding', result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)
        self.assertIn('balance', (self.root / 'cast-calls').read_text().splitlines())
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())
        self.assertNotIn(KEY, result.stderr)

    def test_failed_quote_stops_before_balance_check_or_signing(self):
        result = self.run_quote(send=True, RPC_ERROR='1', EEZ_QUOTE_TIMEOUT='3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('transport timeout', result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)
        self.assertNotIn('balance', (self.root / 'cast-calls').read_text().splitlines())
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())
        self.assertNotIn(KEY, result.stderr)

    def test_repeated_transport_errors_log_one_bounded_single_line(self):
        error = 'Error: HTTP error 503\r\n<html>\n' + 'x' * 1000 + '</html>'
        result = self.run_quote(send=True, PERSISTENT_TRANSIENT='1',
                                TRANSIENT_ERROR=error, EEZ_QUOTE_TIMEOUT='7')
        self.assertNotEqual(result.returncode, 0)
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 2)
        prefix = 'eez_quoteFee retry (transport, attempt 1): '
        self.assertTrue(lines[0].startswith(prefix), result.stderr)
        self.assertLessEqual(len(lines[0]), len(prefix) + 203)
        self.assertTrue(lines[0].endswith('...'), result.stderr)
        self.assertEqual(lines[1], 'eez_quoteFee transport timeout')
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 4)
        self.assertFalse((self.root / 'sends').exists())

    def test_retry_log_reports_reason_changes(self):
        result = self.run_quote(send=True, BUSY='1', RPC_ERROR='1', EEZ_QUOTE_TIMEOUT='7')
        self.assertNotEqual(result.returncode, 0)
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn('retry (reconciliation, attempt 1)', lines[0])
        self.assertIn('retry (transport, attempt 2)', lines[1])
        self.assertEqual(lines[2], 'eez_quoteFee transport timeout')
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 4)
        self.assertFalse((self.root / 'sends').exists())

    def test_explicit_busy_retries_quote_then_signs(self):
        result = self.run_quote(BUSY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)

    def test_explicit_reconciliation_and_stale_context_errors_retry(self):
        for error in ('quote_unavailable: settlement reconciliation pending',
                      'quote_unavailable: unsettled native history requires reconciliation',
                      'stale_context: quote context expired or changed'):
            (self.root / 'busy').unlink(missing_ok=True)
            result = self.run_quote(BUSY='1', TRANSIENT_ERROR=error)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_temporary_quote_errors_retry_exact_prepared_intent(self):
        for cast_format in (False, True):
            for code, message in TEMPORARY_ERRORS:
                with self.subTest(cast=cast_format, code=code, message=message):
                    for name in ('busy', 'intents', 'sends', 'signs'):
                        (self.root / name).unlink(missing_ok=True)
                    result = self.run_quote(send=True, BUSY='1',
                                            TRANSIENT_ERROR=rpc_error(-32004, code, message, cast_format))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    intents = (self.root / 'intents').read_text().splitlines()
                    self.assertEqual(len(intents), 2)
                    self.assertEqual(intents[0], intents[1])
                    original = self.decode(self.candidates['0x2'])
                    self.assertEqual(json.loads(intents[0]), {
                        'from': original['signer'], 'nonce': original['nonce'], 'to': TARGET,
                        'data': original['input'], 'value': original['value']})
                    self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
                    self.assertEqual((self.root / 'sends').read_text().splitlines(), ['sent'])

    def test_complete_queued_predecessor_quote_errors_stop_at_deadline(self):
        for cast_format in (False, True):
            with self.subTest(cast=cast_format):
                (self.root / 'intents').unlink(missing_ok=True)
                result = self.run_quote(send=True, PERSISTENT_TRANSIENT='1', EEZ_QUOTE_TIMEOUT='3',
                                        TRANSIENT_ERROR=rpc_error(-32004, *TEMPORARY_ERRORS[-1], cast_format))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('reconciliation timeout', result.stderr)
                intents = (self.root / 'intents').read_text().splitlines()
                self.assertEqual(len(intents), 2)
                self.assertEqual(intents[0], intents[1])
                self.assertFalse((self.root / 'signs').exists())
                self.assertFalse((self.root / 'sends').exists())

    def test_rate_limit_retries_then_uses_composer_quote(self):
        result = self.run_quote(BUSY='1',
            TRANSIENT_ERROR='Max retries exceeded HTTP error 429')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)
        self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
        evidence = json.loads((self.root / 'evidence.json').read_text())
        self.assertEqual(evidence['feeSource'], 'composer')

    def test_persistent_rate_limit_stops_at_deadline_without_node_fallback(self):
        result = self.run_quote(send=True, EEZ_QUOTE_TIMEOUT='3', PERSISTENT_TRANSIENT='1',
            TRANSIENT_ERROR='Max retries exceeded HTTP error 429')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rate-limit timeout', result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)
        self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_quote_reconciliation_timeout_never_falls_back_or_sends(self):
        result = self.run_quote(EEZ_QUOTE_TIMEOUT='3', PERSISTENT_TRANSIENT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reconciliation timeout', result.stderr)
        self.assertNotIn('falling back', result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)
        self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
        self.assertFalse((self.root / 'signs').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_composer_rejections_never_fall_back_or_sign(self):
        errors = [
            '{"error":{"code":-32602,"message":"invalid params"}}',
            '{"error":{"code":-32000,"message":"simulation reverted: timeout"}}',
            'Error: server returned an error response: error code -32602: invalid params',
            'Error: server returned an error response: error code -32000: execution reverted',
            'Error: server returned an error response: error code -32003: quote_unavailable',
            'Error: server returned an error response: error code 3: execution reverted: timeout',
            'execution reverted: timeout',
            'Error: server returned an error response: error code -32000: HTTP error 429',
            'quote_unavailable',
            'unrecognized quote failure',
            'Error: HTTP error 400 with body: Bad Request',
            'Error: deserialization error: <html>Bad Gateway</html>',
            'Error: deserialization error: garbage',
        ]
        for error in errors:
            with self.subTest(error=error):
                result = self.run_quote(send=True, RPC_ERROR='1', RPC_ERROR_TEXT=error)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('falling back', result.stderr)
                self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
                self.assertFalse((self.root / 'signs').exists())
                self.assertFalse((self.root / 'sends').exists())

    def test_transport_failure_retries_then_uses_composer_quote(self):
        errors = [
            'Error: MPP HTTP request failed: error sending request: operation timed out',
            'error sending request: connection refused',
            'connection reset', 'connection closed', 'tcp connect error',
            'dns resolution failed',
            *[f'Error: HTTP error {status} with body: <html>Unavailable</html>'
              for status in (500, 502, 503, 504)],
        ]
        for error in errors:
            with self.subTest(error=error):
                for name in ('busy', 'intents', 'sends', 'signs'):
                    (self.root / name).unlink(missing_ok=True)
                result = self.run_quote(send=True, BUSY='1', TRANSIENT_ERROR=error)
                self.assertEqual(result.returncode, 0, result.stderr)
                intents = (self.root / 'intents').read_text().splitlines()
                self.assertEqual(len(intents), 2)
                self.assertEqual(intents[0], intents[1])
                self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
                self.assertEqual((self.root / 'sends').read_text().splitlines(), ['sent'])
                self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
                evidence = json.loads((self.root / 'evidence.json').read_text())
                self.assertEqual(evidence['feeSource'], 'composer')

    def test_other_chain_lock_does_not_block_quote_or_send(self):
        with (self.root / 'eez-e2e-fee-quote-10200.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_quote(send=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((self.root / 'sends').exists())
            self.assertNotEqual(subprocess.run(
                ['flock', '-n', str(self.root / 'eez-e2e-fee-quote-10200.lock'), 'true']
            ).returncode, 0)

    def test_quote_unavailability_never_sends_on_either_chain_or_format(self):
        self.candidates = dict(self.candidates)
        for chain in (10200, 906969):
            for kind in ('0x0', '0x2'):
                args = ['cast', 'mktx', TARGET, '0x12345678', '--private-key', KEY,
                        '--chain', str(chain), '--nonce', '7', '--gas-limit', '1000000',
                        '--gas-price', '100', '--value', '17']
                args += ['--legacy'] if kind == '0x0' else ['--priority-gas-price', '1']
                self.candidates[kind] = subprocess.check_output(args, text=True).strip()
                for error, attempts in (
                        ('error code -32601: method not found', 1),
                        ('unsupported_direction', 1),
                        ('error sending request: connection refused', 2),
                        ('operation timed out', 2),
                        ('Error: HTTP error 503', 2),
                        ('{"error":{"code":-32601,"message":"method not found"}}', 1),
                        ('Error: server returned an error response: error code -32004: unsupported_direction', 1)):
                    with self.subTest(chain=chain, kind=kind, error=error):
                        (self.root / 'intents').unlink(missing_ok=True)
                        result = self.run_quote(kind, send=True, RPC_ERROR='1', RPC_ERROR_TEXT=error,
                                                FRONT_CHAIN=str(chain), READ_CHAIN=str(chain),
                                                EEZ_QUOTE_TIMEOUT='3')
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), attempts)
                        self.assertFalse((self.root / 'signs').exists())
                        self.assertFalse((self.root / 'sends').exists())
                        self.assertNotIn('gas-price', (self.root / 'cast-calls').read_text().splitlines())
                        self.assertEqual((self.root / 'rawtxs.txt').read_text().strip(), self.candidates[kind])

    def test_timeout_exit_status_retries_without_signing(self):
        for status in ('28', '124'):
            with self.subTest(status=status):
                (self.root / 'intents').unlink(missing_ok=True)
                result = self.run_quote(send=True, RPC_ERROR='1', RPC_ERROR_TEXT='request failed',
                                        RPC_ERROR_STATUS=status, EEZ_QUOTE_TIMEOUT='3')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('transport timeout', result.stderr)
                self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)
                self.assertFalse((self.root / 'signs').exists())
                self.assertFalse((self.root / 'sends').exists())

    def test_quoted_uncertain_send_is_persisted_and_not_retried(self):
        result = self.run_quote(send=True, SEND_ERROR='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        evidence = json.loads((self.root / 'evidence.json').read_text())
        tx = self.decode((self.root / 'rawtxs.txt').read_text().strip())
        self.assertEqual(tx['hash'], evidence['signedHash'])
        self.assertEqual(evidence['feeSource'], 'composer')

    def test_quoted_persistence_failure_prevents_send(self):
        result = self.run_quote(send=True, PERSIST_ERROR='1')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertFalse((self.root / 'sends').exists())

    def test_queue_wait_does_not_consume_quote_deadline_or_add_rpc_calls(self):
        result = self.run_quote(send=True, QUEUE_WAIT='121', EEZ_QUOTE_TIMEOUT='3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)
        calls = (self.root / 'cast-calls').read_text().splitlines()
        self.assertEqual(calls.count('rpc'), 3)  # Two known-hash checks, one quote.
        self.assertEqual(calls.count('chain-id'), 2)
        self.assertEqual(calls.count('balance'), 1)
        self.assertEqual(calls.count('decode-transaction'), 2)  # Candidate and signed intent check.

    def test_fresh_send_skips_resume_lookups(self):
        result = self.run_quote(send=True, EEZ_FRESH_SEND='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / 'cast-calls').read_text().splitlines()
        self.assertEqual(calls.count('rpc'), 1)  # Only the fresh composer quote.
        self.assertEqual(calls.count('chain-id'), 2)
        self.assertEqual(calls.count('balance'), 1)

    def test_worker_waits_for_existing_turn_then_quotes_and_sends(self):
        with (self.root / 'eez-e2e-fee-quote-906969.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            worker = self.run_quote(send=True, start=True)
            try:
                deadline = time.monotonic() + 5
                while not (self.root / 'lock-wait').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((self.root / 'lock-wait').exists())
                self.assertIsNone(worker.poll())
                self.assertFalse((self.root / 'intents').exists())
                self.assertFalse((self.root / 'sends').exists())
                calls = (self.root / 'cast-calls').read_text().splitlines()
                self.assertEqual(calls.count('chain-id'), 2)
                self.assertEqual(calls.count('decode-transaction'), 1)
                self.assertNotIn('balance', calls)  # Funds must be read after queueing.
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                try:
                    stdout, stderr = worker.communicate(timeout=15)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.communicate()
                    raise
            self.assertEqual(worker.returncode, 0, stdout + stderr)
            self.assertTrue((self.root / 'sends').exists())

    def test_persistence_failure_or_expiry_prevents_submission(self):
        for env in ({'PERSIST_ERROR': '1'}, {'EXPIRE_ON_SAVE': '1'}):
            result = self.run_quote(send=True, **env)
            self.assertEqual(result.returncode, 70, result.stderr)
            self.assertFalse((self.root / 'sends').exists())
            subprocess.run(['flock', '-n', str(self.root / 'eez-e2e-fee-quote-906969.lock'), 'true'], check=True)

    def test_send_reconciliation_refusal_reuses_signed_bytes_under_lock(self):
        result = self.run_quote(send=True, SEND_RECONCILE='once')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)
        intents = (self.root / 'intents').read_text().splitlines()
        self.assertEqual(len(intents), 1)
        raws = (self.root / 'submitted-raws').read_text().splitlines()
        self.assertEqual(raws[0], raws[1])
        self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
        rejected = json.loads((self.root / 'evidence.rejections.jsonl').read_text())
        current = json.loads((self.root / 'evidence.json').read_text())
        self.assertEqual(rejected['signedHash'], current['signedHash'])
        final = self.decode((self.root / 'rawtxs.txt').read_text().strip())
        self.assertEqual(final['nonce'], '0x7')
        self.assertEqual(int(final['maxFeePerGas'], 16), 5000)
        self.assertEqual(final['hash'], result.stdout.strip())

    def test_cast_formatted_send_rejection_also_retries(self):
        result = self.run_quote(send=True, SEND_RECONCILE='once', SEND_RECONCILE_CAST='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)

    def test_complete_temporary_admission_errors_retry_identical_signed_bytes(self):
        for cast_format in (False, True):
            for code, message in TEMPORARY_ERRORS:
                with self.subTest(cast=cast_format, code=code, message=message):
                    for name in ('send-refused', 'sends', 'submitted-raws', 'intents', 'signs', 'evidence.rejections.jsonl'):
                        (self.root / name).unlink(missing_ok=True)
                    result = self.run_quote(send=True, SEND_RECONCILE='once',
                                            ADMISSION_ERROR=rpc_error(-32003, code, message, cast_format))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    raws = (self.root / 'submitted-raws').read_text().splitlines()
                    self.assertEqual(len(raws), 2)
                    self.assertEqual(raws[0], raws[1])
                    self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
                    self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)
                    final = self.decode(raws[-1])
                    original = self.decode(self.candidates['0x2'])
                    for field in ('signer', 'type', 'chainId', 'nonce', 'to', 'value', 'input'):
                        self.assertEqual(final[field], original[field], field)
                    rejected = json.loads((self.root / 'evidence.rejections.jsonl').read_text())
                    self.assertEqual(rejected['signedHash'], result.stdout.strip())

    def test_complete_queued_predecessor_admission_errors_share_quote_deadline(self):
        for cast_format in (False, True):
            with self.subTest(cast=cast_format):
                for name in ('busy', 'sends', 'submitted-raws', 'intents', 'signs'):
                    (self.root / name).unlink(missing_ok=True)
                result = self.run_quote(send=True, BUSY='1', SEND_RECONCILE='always', EEZ_QUOTE_TIMEOUT='5', REAL_SLEEP='1',
                                        ADMISSION_ERROR=rpc_error(-32003, *TEMPORARY_ERRORS[-1], cast_format))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('reconciliation timeout', result.stderr)
                raws = (self.root / 'submitted-raws').read_text().splitlines()
                self.assertGreaterEqual(len(raws), 1)
                self.assertLessEqual(len(raws), 2)
                self.assertEqual(len(set(raws)), 1)
                self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
                self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)

    def test_temporary_admission_retry_stops_if_original_quote_expires(self):
        result = self.run_quote(send=True, SEND_RECONCILE='once', EXPIRE_AFTER_REFUSAL='1',
                                ADMISSION_ERROR=rpc_error(-32003, *TEMPORARY_ERRORS[-1]))
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn('Fee quote expired before submission', result.stderr)
        self.assertEqual((self.root / 'sends').read_text().splitlines(), ['sent'])
        self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign'])
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)

    def test_send_reconciliation_retries_share_original_deadline(self):
        result = self.run_quote(send=True, SEND_RECONCILE='always', EEZ_QUOTE_TIMEOUT='3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reconciliation timeout', result.stderr)
        self.assertLessEqual(len((self.root / 'sends').read_text().splitlines()), 2)

    def test_quote_wait_and_send_retry_share_one_wall_clock_budget(self):
        result = self.run_quote(send=True, SEND_RECONCILE='always', BUSY='1',
                                EEZ_QUOTE_TIMEOUT='4', REAL_SLEEP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reconciliation timeout', result.stderr)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 2)

    def test_tariff_refusals_requote_and_log_every_occurrence(self):
        for code in ("l1_tip_underfunded", "l2_tip_underfunded"):
            for cast_format in ("0", "1"):
                with self.subTest(code=code, cast=cast_format):
                    for name in ("send-refused", "sends", "submitted-raws", "intents", "signs", "evidence.rejections.jsonl"):
                        (self.root / name).unlink(missing_ok=True)
                    result = self.run_quote(send=True, SEND_RECONCILE="once", TARIFF_CODE=code,
                                            SEND_RECONCILE_CAST=cast_format)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr.count("ERROR: submission refused (" + code + ")"), 1)
                    self.assertEqual(len((self.root / "sends").read_text().splitlines()), 2)
                    intents = (self.root / "intents").read_text().splitlines()
                    self.assertEqual(intents[0], intents[1])
                    self.assertEqual(self.decode((self.root / "rawtxs.txt").read_text().strip())["nonce"], "0x7")
                    evidence = json.loads((self.root / "evidence.rejections.jsonl").read_text())
                    self.assertEqual(evidence["rejectionKind"], code)
                    raws = (self.root / 'submitted-raws').read_text().splitlines()
                    self.assertNotEqual(raws[0], raws[1])
                    self.assertEqual((self.root / 'signs').read_text().splitlines(), ['sign', 'sign'])

    def test_persistent_tariff_refusals_stop_and_log_each_attempt(self):
        result = self.run_quote(send=True, SEND_RECONCILE="always", TARIFF_CODE="l2_tip_underfunded",
                                EEZ_QUOTE_TIMEOUT="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("l2_tip_underfunded timeout", result.stderr)
        count = len((self.root / "sends").read_text().splitlines())
        self.assertLessEqual(count, 2)
        self.assertEqual(result.stderr.count("ERROR: submission refused (l2_tip_underfunded)"), count)
        self.assertEqual(len((self.root / "evidence.rejections.jsonl").read_text().splitlines()), count)

    def test_tariff_retry_does_not_fall_back_to_node_fees_when_quote_fails(self):
        result = self.run_quote(send=True, SEND_RECONCILE="once", TARIFF_CODE="l2_tip_underfunded",
                                QUOTE_FAIL_AFTER_REFUSAL="1", EEZ_QUOTE_TIMEOUT="5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("transport timeout", result.stderr)
        self.assertEqual(len((self.root / "sends").read_text().splitlines()), 1)
        self.assertNotIn("gas-price", (self.root / "cast-calls").read_text().splitlines())

    def test_pending_nonce_quote_failure_does_not_wait_for_mining_or_send(self):
        error = 'Error: server returned an error response: error code -32602: invalid transaction: source nonce is already pending; queued predecessors are not simulated'
        result = self.run_quote(send=True, RPC_ERROR="1", RPC_ERROR_TEXT=error)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source nonce is already pending", result.stderr)
        self.assertEqual(len((self.root / "intents").read_text().splitlines()), 1)
        self.assertFalse((self.root / "sends").exists())

    def test_tariff_count_includes_recovered_and_prior_attempts_but_not_other_rejections(self):
        for job in ("a", "b"):
            directory = self.root / "jobs" / job
            directory.mkdir(parents=True)
            rows = [{"rejectionKind": "l1_tip_underfunded"}, {"rejectionKind": "l2_tip_underfunded"},
                    {"rejectionKind": "reconciliation"}]
            (directory / "fee-quote-1.rejections.jsonl").write_text("\n".join(map(json.dumps, rows)) + "\n")
        result = subprocess.run(["bash", "-c", 'source "$1"; network_fee_rejection_report "$2"', "test",
                                 str(E2E / "lib/network-fees.sh"), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TARIFF REJECTIONS: 4 (L1: 2, L2: 2", result.stdout)

    def test_other_send_errors_and_uncertainty_are_not_requoted(self):
        errors = [
            'timeout: no response',
            '{"error":{"code":-32603,"data":{"code":"l2_tip_underfunded"}}}',
            'l2_tip_underfunded',
            '{"error":{"code":-32603,"data":{"code":"quote_unavailable","message":"quote unavailable: unsettled native history requires reconciliation"}}}',
            '{"error":{"code":-32003,"data":{"code":"quote_unavailable","message":"another failure"}}}',
            'quote_unavailable: unsettled native history requires reconciliation',
            'Error: server returned an error response: error code -32003: bad tx, data: {"code":"unknown"}',
        ]
        for error in errors:
            with self.subTest(error=error):
                for name in ('sends', 'intents'):
                    (self.root / name).unlink(missing_ok=True)
                result = self.run_quote(send=True, SUBMIT_ERROR_TEXT=error)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
                self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)

    def test_transport_timeout_is_not_retried_even_with_rejection_text(self):
        result = self.run_quote(send=True, SUBMIT_ERROR_RC='124', SUBMIT_ERROR_TEXT=
            '{"error":{"code":-32003,"data":{"code":"quote_unavailable","message":"quote unavailable: unsettled native history requires reconciliation"}}}')
        self.assertEqual(result.returncode, 124)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        self.assertEqual(len((self.root / 'intents').read_text().splitlines()), 1)

    def test_resume_adopts_known_candidate_without_requoting_or_resending(self):
        result = self.run_quote(send=True, KNOWN='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.decode(self.candidates['0x2'])['hash'])
        self.assertFalse((self.root / 'intents').exists())
        self.assertFalse((self.root / 'sends').exists())

    def test_persists_signed_candidate_before_successful_or_uncertain_send(self):
        for fail in ('0', '1'):
            result = self.run_quote(send=True, SEND_ERROR=fail)
            self.assertEqual(result.returncode, int(fail), result.stderr)
            raw = (self.root / 'rawtxs.txt').read_text().strip()
            self.assertNotEqual(raw, self.candidates['0x2'])
            evidence = json.loads((self.root / 'evidence.json').read_text())
            self.assertEqual(self.decode(raw)['hash'], evidence['signedHash'])


class StandaloneTriggerTests(unittest.TestCase):
    def test_both_origins_and_l1_multitx_use_source_endpoints(self):
        script = r"""
set -euo pipefail
source "$BASE"
PK=test-key RPC=read-L1 L2_RPC=read-L2 L2_FRONT=front-L2
network_send_quoted_trigger() {
    [[ "$EEZ_FRESH_SEND" == 1 && "$2" == test-key ]] || return 91
    printf '%s %s %s\n' "$1" "$3" "$4" >> "$TEST_ROOT/quotes"
    echo hash
}
cast() { echo digest; }
_wait_user_tx() { :; }
RLP_ENCODED_TX=first
publish_user_tx front-L1
RLP_ENCODED_TX=second
publish_l2_user_tx
RLP_ENCODED_TXS=(third fourth)
publish_user_txs_nowait front-L1
"""
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                env={'PATH': os.environ['PATH'], 'TEST_ROOT': directory,
                     'BASE': str(E2E / 'lib/E2EBase.sh')}, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(directory) / 'quotes').read_text().splitlines(), [
                'first front-L1 read-L1', 'second front-L2 read-L2',
                'third front-L1 read-L1', 'fourth front-L1 read-L1'])


class StagedSendOrderTests(unittest.TestCase):
    def test_both_chains_progress_without_a_barrier_and_keep_job_nonce_order(self):
        dispatch = "S_PIDS=()" + RUNNER.split("\nS_PIDS=()", 1)[1].split("\nN_SENT=", 1)[0]
        for resume in ("", "saved-run"):
            for workers in (1, 2):
                with self.subTest(resume=resume, workers=workers), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    names = (("first", "L2"), ("second", "L1"), ("third", "L1"), ("last", "L2"))
                    for name, chain in names:
                        job = root / "jobs" / name
                        job.mkdir(parents=True)
                        (job / "manifest.env").write_text(f'declare -- _TRIGGER_CHAIN="{chain}"\n')
                        (job / "rawtxs.txt").write_text(name + "_1\n" + name + "_2\n")
                        if resume:
                            (job / "txs.txt").write_text("0x" + "a" * 64 + "\n")
                    (root / "wallets.csv").write_text("job,address,key\n" + "".join(f"{n},unused,test-key\n" for n, _ in names))
                    script = r'''set -euo pipefail
source "$ORCHESTRATOR"
ATTEMPT=1
RUN_DIR="$TEST_ROOT"; JOB_NAMES=(first second third last); NJOBS=4
SEND_PAUSE=0 L1_RPC=read-L1 L2_RPC=read-L2
_job_prepared() { return 0; }
_front_rpc() { echo "$1"; }
network_send_quoted_trigger() {
    [[ "$4" == "read-$3" && "$2" == test-key ]] || return 97
    [[ "$EEZ_FRESH_SEND" == "$EXPECTED_FRESH" ]] || return 98
    touch "$RUN_DIR/entered-$3"
    local other=L1 tries=0
    [[ "$3" != L1 ]] || other=L2
    while [[ ! -f "$RUN_DIR/entered-$other" ]]; do
        (( tries++ < 200 )) || return 99
        sleep 0.01
    done
    echo "ERROR: example retry for $1" >&2
    echo "$1" >> "$RUN_DIR/order"
    printf '0x%064x\n' 2
}
''' + function("send_worker") + "\n" + dispatch
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10,
                        env={"PATH": os.environ["PATH"], "TEST_ROOT": directory, "RESUME": resume,
                             "SEND_WORKERS": str(workers), "EXPECTED_FRESH": "0" if resume else "1",
                             "ORCHESTRATOR": str(E2E / "lib/orchestrator.sh")})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    order = (root / "order").read_text().splitlines()
                    for name, _ in names:
                        expected = [name + "_2"] if resume else [name + "_1", name + "_2"]
                        self.assertEqual([x for x in order if x.startswith(name + "_")], expected)
                        timings = (root / "jobs" / name / "timings.csv").read_text().splitlines()
                        self.assertEqual(len(timings), len(expected))
                        self.assertTrue(all(row.endswith(",pass") for row in timings))
                        for value in expected:
                            self.assertIn("ERROR: example retry for " + value, result.stderr)
                            self.assertIn("ERROR: example retry for " + value, (root / "send-failed.log").read_text())
                    self.assertEqual(len((root / "sent.csv").read_text().splitlines()), 4 if resume else 8)


if __name__ == '__main__':
    unittest.main()
