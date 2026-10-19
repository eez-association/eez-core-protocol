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
        if [[ -n "${TARIFF_CODE:-}" ]]; then
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

    def test_tariff_refusals_requote_and_log_every_occurrence(self):
        for code in ("l1_tip_underfunded", "l2_tip_underfunded"):
            for cast_format in ("0", "1"):
                with self.subTest(code=code, cast=cast_format):
                    for name in ("send-refused", "sends", "intents", "evidence.rejections.jsonl"):
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
