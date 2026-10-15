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

MOCK = r'''
cast() {
    echo "$1" >> "$TEST_ROOT/cast-calls"
    case "$1" in
        chain-id)
            if [[ "${!#}" == front ]]; then echo "${FRONT_CHAIN:-906969}"; else echo "${READ_CHAIN:-906969}"; fi ;;
        balance) echo "${BALANCE:-1000000000000000000}" ;;
        gas-price) [[ "${NODE_ERROR:-0}" != 1 ]] || return 1; echo 300 ;;
        rpc)
            if [[ "$*" == *eth_getTransactionByHash* ]]; then
                if [[ "${KNOWN:-0}" == 1 ]]; then jq -nc --arg hash "${!#}" '{hash:$hash}'; else echo null; fi
                return
            fi
            if [[ "$*" == *eth_getBlockByNumber* ]]; then echo '{"baseFeePerGas":"0x64"}'; return; fi
            if [[ "$*" == *eth_maxPriorityFeePerGas* ]]; then
                if [[ "${TIP_UNSUPPORTED:-0}" == 1 ]]; then echo 'error code -32601' >&2; return 1; fi
                echo '"0x14"'; return
            fi
            [[ "$*" == *eez_quoteFee* ]] || return 90
            printf '%s\n' "${!#}" >> "$TEST_ROOT/intents"
            if [[ "${BUSY:-0}" == 1 && ! -f "$TEST_ROOT/busy" ]]; then
                touch "$TEST_ROOT/busy"; echo "${TRANSIENT_ERROR:-error: quote_busy}" >&2; return 1
            fi
            if [[ "${PERSISTENT_TRANSIENT:-0}" == 1 ]]; then echo "${TRANSIENT_ERROR:-quote_unavailable: settlement reconciliation pending}" >&2; return 1; fi
            if [[ "${RPC_ERROR:-0}" == 1 ]]; then echo "${RPC_ERROR_TEXT:-error sending request: connection refused}" >&2; return 1; fi
            cat "$TEST_ROOT/quote.json" ;;
        mktx) echo sign >> "$TEST_ROOT/signs"; command cast "$@" ;;
        *) command cast "$@" ;;
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
    if [[ -n "${SUBMIT_ERROR_TEXT:-}" ]]; then printf '%s\n' "$SUBMIT_ERROR_TEXT" >&2; return "${SUBMIT_ERROR_RC:-1}"; fi
    if [[ "${SEND_RECONCILE:-0}" == always || ( "${SEND_RECONCILE:-0}" == once && ! -f "$TEST_ROOT/send-refused" ) ]]; then
        touch "$TEST_ROOT/send-refused"
        if [[ "${SEND_RECONCILE_CAST:-0}" == 1 ]]; then
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

    def run_quote(self, kind='0x2', send=False, start=False, **env):
        (self.root / 'quote.json').write_text(json.dumps(self.quote))
        (self.root / 'rawtxs.txt').write_text(self.candidates[kind] + '\n')
        action = 'network_send_quoted_trigger "$RAW" "$KEY" front direct "$TEST_ROOT/evidence.json" submit persist "$TEST_ROOT/rawtxs.txt" 1'
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
                self.assertEqual(intent, {'from': original['signer'], 'to': TARGET,
                                          'data': '0x12345678', 'value': '0x11'})
                evidence = json.loads((self.root / 'evidence.json').read_text())
                self.assertEqual(evidence['selectedOption']['type'], kind)
                self.assertEqual(evidence['signedHash'], tx['hash'])

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
        for mutation in mutations:
            self.quote = copy.deepcopy(baseline)
            mutation(self.quote)
            result = self.run_quote(send=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / 'signs').exists())
            self.assertFalse((self.root / 'sends').exists())

    def test_front_chain_mismatch_stops_before_quote(self):
        result = self.run_quote(FRONT_CHAIN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'intents').exists())

    def test_insufficient_balance_and_failed_node_oracle_never_send(self):
        for env in ({'BALANCE': '1'}, {'RPC_ERROR': '1', 'BALANCE': '1'},
                    {'RPC_ERROR': '1', 'NODE_ERROR': '1'}):
            result = self.run_quote(send=True, **env)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / 'signs').exists())
            self.assertFalse((self.root / 'sends').exists())
            self.assertNotIn(KEY, result.stderr)

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

    def test_cast_http_5xx_uses_node_fees(self):
        for status in (500, 502, 503, 504):
            with self.subTest(status=status):
                result = self.run_quote(RPC_ERROR='1',
                    RPC_ERROR_TEXT=f'Error: HTTP error {status} with body: <html>Unavailable</html>')
                self.assertEqual(result.returncode, 0, result.stderr)
                evidence = json.loads((self.root / 'evidence.json').read_text())
                self.assertEqual(evidence['feeSource'], 'node')
                self.assertEqual(int(self.decode(result.stdout.strip())['maxFeePerGas'], 16), 300)

    def test_other_chain_lock_does_not_block_quote_or_send(self):
        with (self.root / 'eez-e2e-fee-quote-10200.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_quote(send=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((self.root / 'sends').exists())
            self.assertNotEqual(subprocess.run(
                ['flock', '-n', str(self.root / 'eez-e2e-fee-quote-10200.lock'), 'true']
            ).returncode, 0)

    def test_rpc_unavailability_uses_node_fees_on_both_chains_and_formats(self):
        self.candidates = dict(self.candidates)
        for chain in (10200, 906969):
            for kind in ('0x0', '0x2'):
                args = ['cast', 'mktx', TARGET, '0x12345678', '--private-key', KEY,
                        '--chain', str(chain), '--nonce', '7', '--gas-limit', '1000000',
                        '--gas-price', '100', '--value', '17']
                args += ['--legacy'] if kind == '0x0' else ['--priority-gas-price', '1']
                self.candidates[kind] = subprocess.check_output(args, text=True).strip()
                for error in ('error code -32601: method not found', 'unsupported_direction',
                              'error sending request: connection refused',
                              '{"error":{"code":-32601,"message":"method not found"}}',
                              'Error: server returned an error response: error code -32004: unsupported_direction'):
                    with self.subTest(chain=chain, kind=kind, error=error):
                        result = self.run_quote(kind, RPC_ERROR='1', RPC_ERROR_TEXT=error,
                                                FRONT_CHAIN=str(chain), READ_CHAIN=str(chain))
                        self.assertEqual(result.returncode, 0, result.stderr)
                        tx = self.decode(result.stdout.strip())
                        original = self.decode(self.candidates[kind])
                        for key in ('signer', 'type', 'chainId', 'nonce', 'to', 'value', 'input', 'gas'):
                            self.assertEqual(tx[key], original[key], key)
                        self.assertEqual(int(tx.get('maxFeePerGas', tx.get('gasPrice')), 16), 300)
                        if kind == '0x2':
                            self.assertEqual(int(tx['maxPriorityFeePerGas'], 16), 20)
                        evidence = json.loads((self.root / 'evidence.json').read_text())
                        self.assertEqual(evidence['feeSource'], 'node')
                        self.assertIsNone(evidence['quote'])
                        self.assertEqual(evidence['signedHash'], tx['hash'])

    def test_node_fallback_supports_missing_priority_oracle(self):
        result = self.run_quote(RPC_ERROR='1', TIP_UNSUPPORTED='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        tx = self.decode(result.stdout.strip())
        self.assertEqual(int(tx['maxPriorityFeePerGas'], 16), 200)
        self.assertEqual(int(tx['maxFeePerGas'], 16), 400)

    def test_fallback_uncertain_send_is_persisted_and_not_retried(self):
        result = self.run_quote(send=True, RPC_ERROR='1', SEND_ERROR='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        evidence = json.loads((self.root / 'evidence.json').read_text())
        tx = self.decode((self.root / 'rawtxs.txt').read_text().strip())
        self.assertEqual(tx['hash'], evidence['signedHash'])
        self.assertEqual(evidence['feeSource'], 'node')

    def test_fallback_persistence_failure_prevents_send(self):
        result = self.run_quote(send=True, RPC_ERROR='1', PERSIST_ERROR='1')
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

    def test_send_reconciliation_refusal_requotes_same_nonce_under_lock(self):
        result = self.run_quote(send=True, SEND_RECONCILE='once')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)
        intents = (self.root / 'intents').read_text().splitlines()
        self.assertEqual(len(intents), 2)
        self.assertEqual(intents[0], intents[1])
        rejected = json.loads((self.root / 'evidence.rejections.jsonl').read_text())
        current = json.loads((self.root / 'evidence.json').read_text())
        self.assertNotEqual(rejected['signedHash'], current['signedHash'])
        final = self.decode((self.root / 'rawtxs.txt').read_text().strip())
        self.assertEqual(final['nonce'], '0x7')
        self.assertEqual(int(final['maxFeePerGas'], 16), 8192)
        self.assertEqual(final['hash'], result.stdout.strip())

    def test_cast_formatted_send_rejection_also_requotes(self):
        result = self.run_quote(send=True, SEND_RECONCILE='once', SEND_RECONCILE_CAST='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 2)

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

    def test_other_send_errors_and_uncertainty_are_not_requoted(self):
        errors = [
            'timeout: no response',
            '{"error":{"code":-32603,"data":{"code":"quote_unavailable","message":"quote unavailable: unsettled native history requires reconciliation"}}}',
            '{"error":{"code":-32003,"data":{"code":"quote_unavailable","message":"another failure"}}}',
            'quote_unavailable: unsettled native history requires reconciliation',
            'Error: server returned an error response: error code -32003: bad tx, data: {"code":"quote_busy"}',
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
    def test_l1_burst_finishes_before_quoted_l2_jobs_without_losing_resume_mode(self):
        dispatch = "S_PIDS=()" + RUNNER.split("\nS_PIDS=()", 1)[1].split("\nN_SENT=", 1)[0]
        for resume in ("", "saved-run"):
            with self.subTest(resume=resume), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name, chain in (("first", "L2"), ("second", "L1"), ("third", "L1"), ("last", "L2")):
                    job = root / "jobs" / name
                    job.mkdir(parents=True)
                    (job / "manifest.env").write_text(f'declare -- _TRIGGER_CHAIN="{chain}"\n')
                    (job / "rawtxs.txt").write_text(name + "\n")
                (root / "wallets.csv").write_text("job,address,key\nfirst,unused,test-key\nsecond,unused,test-key\nthird,unused,test-key\nlast,unused,test-key\n")
                script = r'''set -euo pipefail
RUN_DIR="$TEST_ROOT"; JOB_NAMES=(first second third last); NJOBS=4
SEND_WORKERS=1 SEND_PAUSE=0 L1_RPC=read-L1 L2_RPC=read-L2
_job_prepared() { return 0; }
_front_rpc() { echo "$1"; }
_rpc_send_raw() { echo "$2" >> "$RUN_DIR/order"; printf '0x%064x\n' 1; }
network_send_quoted_trigger() {
    [[ "$4" == "read-$3" && "$2" == test-key ]] || return 97
    if [[ "$3" == L2 ]]; then
    [[ $(head -2 "$RUN_DIR/order" | paste -sd,) == second,third ]] || return 99
    fi
    [[ "$EEZ_FRESH_SEND" == "$EXPECTED_FRESH" ]] || return 98
    echo "$1" >> "$RUN_DIR/order"
    printf '0x%064x\n' 2
}
''' + function("send_worker") + "\n" + dispatch
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10,
                    env={"PATH": os.environ["PATH"], "TEST_ROOT": directory, "RESUME": resume,
                         "EXPECTED_FRESH": "0" if resume else "1"})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((root / "order").read_text().splitlines(), ["second", "third", "first", "last"])
                self.assertEqual(len((root / "sent.csv").read_text().splitlines()), 4)


if __name__ == '__main__':
    unittest.main()
