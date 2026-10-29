"""Nonce failures never authorize signing; retries and bursts preserve real nonces."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'lib'
MOCK = r'''
RPC=l1 L1_RPC=l1 L2_RPC=l2
L1_FRONT="${FRONT_URL-front}" L2_FRONT="${FRONT_URL-front}"
echo 1000 > clock
date() { cat clock; }
sleep() { echo "$(( $(cat clock) + $1 ))" > clock; }
forge() { printf 'TARGET=0x1111111111111111111111111111111111111111\nVALUE=0\nCALLDATA=0x1234\nNUM_TXS=%s\n' "$COUNT"; }
cast() {
    case "$1" in
      wallet) echo 0x1111111111111111111111111111111111111111 ;;
      nonce)
        printf '%s\n' "$*" >> reads
        rpc="${!#}"
        if [[ "${FAIL_ONCE:-}" == "$rpc" && ! -f "$rpc-read" ]]; then
            touch "$rpc-read"; echo 'connection dropped' >&2; return 1
        fi
        value="$NONCE"; [[ "$rpc" != front ]] || value="$FRONT"
        [[ "$value" != fail ]] || { echo 'connection dropped' >&2; return 1; }
        echo "$value" ;;
      mktx)
        printf '%s\n' "$*" >> signs
        [[ "${SIGN_FAIL:-0}" != 1 ]] || return 1
        echo 0x1234 ;;
      *) command cast "$@" ;;
    esac
}
'''


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_shell(self, body, **env):
        return subprocess.run(['bash', '-c', 'source "$LIB/E2EBase.sh"\n' + MOCK + body],
            cwd=self.root, env={**os.environ, 'LIB': str(LIB), 'NONCE': '2',
                'FRONT': '3', 'COUNT': '1', 'E2E_NONCE_TIMEOUT': '3', **env},
            text=True, capture_output=True, timeout=10)

    def trigger(self, chain='L2', **env):
        name = 'ExecuteNetworkL2' if chain == 'L2' else 'ExecuteNetwork'
        (self.root / 'scenario.sol').write_text(f'contract {name} {{}}\n')
        return self.run_shell('build_trigger_txs scenario.sol network', **env)

    def test_nonce_rpc_failure_never_signs_nonce_zero(self):
        for chain in ('L1', 'L2'):
            for nonce, front in [('fail', '0'), ('0', 'fail'), ('nonsense', '0')]:
                with self.subTest(chain=chain, nonce=nonce, front=front):
                    result = self.trigger(chain, NONCE=nonce, FRONT=front)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((self.root / 'signs').exists())
                    self.assertIn('nonce', result.stderr.lower())
                    self.assertLessEqual(int((self.root / 'clock').read_text()), 1003)

    def test_transient_node_and_front_failures_recover(self):
        for endpoint in ('l1', 'l2', 'front'):
            with self.subTest(endpoint=endpoint):
                result = self.trigger('L1' if endpoint == 'l1' else 'L2', FAIL_ONCE=endpoint)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('source nonce read failed', result.stderr)
                self.assertIn('--nonce 3 ', (self.root / 'signs').read_text().splitlines()[-1])

    def test_burst_keeps_consecutive_prepared_nonces(self):
        result = self.trigger(COUNT='3')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        signs = (self.root / 'signs').read_text().splitlines()
        self.assertEqual(len(signs), 3)
        for nonce, line in zip((3, 4, 5), signs):
            self.assertIn(f'--nonce {nonce} ', line)

    def test_missing_source_front_never_signs(self):
        for chain in ('L1', 'L2'):
            with self.subTest(chain=chain):
                result = self.trigger(chain, FRONT_URL='')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'requires {chain}_FRONT', result.stderr)
                self.assertFalse((self.root / 'signs').exists())
                self.assertFalse((self.root / 'reads').exists())

    def test_signing_failure_stops_burst(self):
        result = self.trigger(COUNT='3', SIGN_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / 'signs').read_text().splitlines()), 1)

    def test_nonce_retries_share_deadline_and_limit_each_rpc(self):
        result = self.trigger(NONCE='fail')
        self.assertNotEqual(result.returncode, 0)
        reads = (self.root / 'reads').read_text().splitlines()
        self.assertEqual(len(reads), 2)
        self.assertIn('--rpc-timeout 3 ', reads[0])
        self.assertIn('--rpc-timeout 1 ', reads[1])
        self.assertEqual(int((self.root / 'clock').read_text()), 1003)
        self.assertIn('deadline expired', result.stderr)

    def test_l1_catchup_retries_read_failures_and_rejects_permanent_lag(self):
        source = (LIB / 'network-scenario.sh').read_text()
        start = source.index('if [[ -n "${L1_FRONT:-}" && "${E2E_PREPARE_STEP:-}" != "plan" ]]')
        loop = source[start:source.index('\n# Staged prepare steps', start)]
        result = self.run_shell(loop, FAIL_ONCE='l1', FRONT='2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('source nonce read failed', result.stderr)
        result = self.run_shell(loop)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('L1 nonce consistency timeout', result.stderr)
        self.assertEqual(int((self.root / 'clock').read_text()), 1120)


if __name__ == '__main__':
    unittest.main()
