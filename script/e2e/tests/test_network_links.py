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
