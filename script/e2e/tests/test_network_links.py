"""Link quantity parsing and artifact/verifier compatibility checks."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
LIB = REPO / 'script/e2e/lib'


class NetworkLinksTests(unittest.TestCase):
    def quantity(self, value):
        return subprocess.run(['jq', '-ce', '-L', str(LIB), 'include "network-links"; quantity'],
                              input=json.dumps(value), capture_output=True, text=True, timeout=5)

    def test_equivalent_quantities(self):
        for value in (208, '0xd0', '0x00d0', '0xD0', '0X00D0'):
            with self.subTest(value=value):
                result = self.quantity(value)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), 208)
        self.assertEqual(json.loads(self.quantity('0x1fffffffffffff').stdout), 2**53 - 1)

    def test_invalid_or_inexact_quantities_fail_closed(self):
        for value in (None, True, -1, 1.5, 2**53, '0x20000000000001', '0x', '0xgg', '208'):
            with self.subTest(value=value):
                result = self.quantity(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('quantity', result.stderr)

    def test_recheck_ignores_diagnostics_but_preserves_execution_identity(self):
        base = {'sourceHash': 'source', 'direction': 'inbound', 'basis': 'attempt',
                'attemptGeneration': '0xa', 'references': [{'chain': 'L1', 'hash': 'posting'}],
                'ownership': {'state': 'terminal', 'reason': 'Committed',
                              'canonical': {'hash': 'block', 'number': 3}}}
        def identity(record):
            result = subprocess.run(['jq', '-c', '-L', str(LIB),
                'include "network-links"; execution_identity'], input=json.dumps(record),
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        expected = identity(base)
        diagnostic = json.loads(json.dumps(base))
        diagnostic['ownership'].update(observedAtMs=1234, replacementHash=None)
        diagnostic['ownership']['canonical']['number'] = '0X03'
        diagnostic['attemptGeneration'] = 10
        self.assertEqual(identity(diagnostic), expected)
        for field, value in (('reason', 'Replaced'), ('state', 'held'),
                             ('replacementHash', 'replacement'),
                             ('canonical', {'hash': 'other-block', 'number': 3})):
            changed = json.loads(json.dumps(base))
            changed['ownership'][field] = value
            self.assertNotEqual(identity(changed), expected)
        changed = dict(base, attemptGeneration='0xb')
        self.assertNotEqual(identity(changed), expected)
        changed = dict(base, references=[{'chain': 'L1', 'hash': 'other-posting'}])
        self.assertNotEqual(identity(changed), expected)

    def test_chain_identity_failure_retries_both_chains_before_using_links(self):
        shell = r'''
set -euo pipefail
source "$1/network-links.sh"
E2E_JOB_DIR="$2"
TX_HASHES=(source)
EXPECTED_L1_CHAIN_ID=1 EXPECTED_L2_CHAIN_ID=2
case "$3" in
    L1) NETWORK_LINK_L1_ID=1 ;;
    L2) NETWORK_LINK_L2_ID=2 ;;
esac
failure="$4"
network_urls() { printf '%s-front\n%s-read\n' "$1" "$1"; }
network_rpc() {
    [[ "$2" == eth_chainId && "$3" == '[]' ]] || return 99
    echo "$1" >> "$E2E_JOB_DIR/chain-reads"
    case "$1" in
        L1-*) echo '"0x1"' ;;
        L2-front) echo '"0x2"' ;;
        L2-read)
            case "$failure" in
                transport) return 2 ;;
                mismatch) echo '"0x3"' ;;
                none) echo '"0x2"' ;;
            esac ;;
    esac
}
network_links_status() {
    [[ "$NETWORK_LINK_L1_ID" == 1 && "$NETWORK_LINK_L2_ID" == 2 ]] || return 98
    echo status >> "$E2E_JOB_DIR/status-reads"
    echo '{}'
}
rc=0
network_links_capture || rc=$?
if [[ "$failure" == transport ]]; then [[ "$rc" == 2 ]]; else [[ "$rc" == 1 ]]; fi
[[ "$NETWORK_LINKS_ACTIVE" == false ]]
[[ -z "${NETWORK_LINK_L1_ID:-}" && -z "${NETWORK_LINK_L2_ID:-}" ]]
[[ ! -f "$E2E_JOB_DIR/status-reads" ]]
failure=none
network_links_capture
[[ "$NETWORK_LINKS_ACTIVE" == true ]]
network_links_capture
[[ "$NETWORK_LINKS_ACTIVE" == true ]]
'''
        for initial in ('neither', 'L1', 'L2'):
            for failure in ('transport', 'mismatch'):
                with self.subTest(initial=initial, failure=failure), tempfile.TemporaryDirectory() as root:
                    result = subprocess.run(['bash', '-c', shell, 'test', str(LIB), root,
                                             initial, failure], cwd=REPO, capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('unbound variable', result.stderr)
                    self.assertEqual((Path(root) / 'chain-reads').read_text().splitlines(),
                                     ['L1-front', 'L1-read', 'L2-front', 'L2-read'] * 2)
                    self.assertEqual((Path(root) / 'status-reads').read_text().splitlines(),
                                     ['status', 'status'])

    def test_stale_artifact_names_both_topics_and_rebuild_action(self):
        with tempfile.TemporaryDirectory() as root:
            artifact = Path(root) / 'EEZ.json'
            abi = {'abi': [{'type': 'event', 'name': 'ExecutionConsumed',
                            'inputs': [{'type': 'bytes32'}, {'type': 'uint256'}]}]}
            artifact.write_text(json.dumps(abi))
            result = subprocess.run(['bash', '-c', 'source "$1/network-links.sh"; '
                '_network_event_topic "$2" ExecutionConsumed SIG_EXECUTION_CONSUMED_L1',
                'test', str(LIB), str(artifact)], cwd=REPO, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('artifact=0x', result.stderr)
            self.assertIn('verifier=0x', result.stderr)
            self.assertIn('forge build', result.stderr)
            self.assertEqual(result.stdout, '')
