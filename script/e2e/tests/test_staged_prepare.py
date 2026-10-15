"""Preparation and resume gates exercised without network access or signing."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_staged_monitor import function

REPO = Path(__file__).resolve().parents[3]
LIB = REPO / 'script/e2e/lib'
STAGED = REPO / 'script/e2e/run/network/staged.sh'


class StagedPrepareTests(unittest.TestCase):
    def run_shell(self, script, root):
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + script],
                              cwd=root, env={**os.environ, 'LIB': str(LIB)},
                              text=True, capture_output=True, timeout=15)

    def test_only_completed_v2_jobs_can_send(self):
        with tempfile.TemporaryDirectory() as root:
            result = self.run_shell('''
source "$LIB/orchestrator.sh"
mkdir job
! _job_prepared job
printf 'declare -- E2E_MANIFEST_VERSION="2"\n' > job/manifest.env
! _job_prepared job
touch job/.deploys-done
_job_prepared job
touch job/.prepare-failed
! _job_prepared job
rm job/.prepare-failed
printf 'declare -- E2E_MANIFEST_VERSION="1"\n' > job/manifest.env
! _job_prepared job
''', root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_removed_modes_fail_before_network_configuration(self):
        for mode in ('waves', 'unknown'):
            with self.subTest(mode=mode):
                result = subprocess.run(['bash', str(STAGED), 'counter:1'], cwd=REPO,
                    env={**os.environ, 'PREPARE_MODE': mode, 'DEVNET_ENV': '/missing/env'},
                    capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unsupported PREPARE_MODE', result.stderr)
                self.assertNotIn('Missing', result.stdout + result.stderr)

    def test_legacy_resume_rejected_before_network_or_run_mutation(self):
        for flag in ('--resume', '--resend'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as root:
                job = Path(root) / 'jobs/job'
                job.mkdir(parents=True)
                (job / 'manifest.env').write_text('_TX_COUNT=1\n')
                result = subprocess.run(['bash', str(STAGED), flag, root], cwd=REPO,
                    env={**os.environ, 'DEVNET_ENV': '/missing/env', 'PREPARE_MODE': 'plan'},
                    capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('only v2 manifests are supported', result.stderr)
                self.assertIn('--verify-only', result.stderr)
                self.assertEqual(list(Path(root).glob('*.csv')), [])

    def test_removed_worker_steps_fail_before_deployment(self):
        for step in ('deploy:1', 'finish'):
            result = subprocess.run(['bash', str(LIB / 'network-scenario.sh')], cwd=REPO,
                env={**os.environ, 'E2E_PREPARE_STEP': step}, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported E2E_PREPARE_STEP', result.stderr)

    def test_interrupted_plan_sends_remaining_deploys_once_then_opens_gate(self):
        functions = '\n'.join(function(name) for name in ('_fire_deploy_txs', '_mark_deploys_done'))
        with tempfile.TemporaryDirectory() as root:
            result = self.run_shell('''
source "$LIB/orchestrator.sh"
RUN_DIR=. NJOBS=1 SEND_WORKERS=1 DEAD=, L1_RPC=direct1 L2_RPC=direct2
JOB_NAMES=(job)
mkdir -p jobs/job
printf 'declare -- E2E_MANIFEST_VERSION="2"\n' > jobs/job/manifest.env
printf 'L1 raw1\nL2 raw2\nL1 raw3\n' > jobs/job/deploytxs.txt
printf 'hash1\n' > jobs/job/deploy-hashes.txt
printf 'job,L1,hash1\n' > deploy-sent.csv
_rpc_send_raw() { echo "$1 $2" >> sends; echo "hash${2#raw}"; }
_chain_counts() { :; }
_prep_failed() { exit 97; }
''' + functions + '''
! _job_prepared jobs/job
_fire_deploy_txs
_fire_deploy_txs
! _job_prepared jobs/job
# This marker is published only after mining and the per-chain code checks.
_mark_deploys_done
_job_prepared jobs/job
_fire_deploy_txs
''', root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((Path(root) / 'sends').read_text().splitlines(), ['direct2 raw2', 'direct1 raw3'])
            self.assertEqual((Path(root) / 'jobs/job/deploy-hashes.txt').read_text().splitlines(), ['hash1', 'hash2', 'hash3'])

    def test_classic_publishes_v2_only_after_successful_preparation(self):
        source = (LIB / 'network-scenario.sh').read_text()
        start = source.index('if [[ "$E2E_STAGE" == "prepare" ]]; then')
        end = source.index('\nfi', start) + len('\nfi')
        with tempfile.TemporaryDirectory() as root:
            result = self.run_shell('''
E2E_STAGE=prepare E2E_JOB_DIR=job
RLP_ENCODED_TXS=(raw) COMPUTE_OUT=expected
_TRIGGER_CHAIN=L1 _TX_COUNT=1 _HAS_COMPUTE=true _SENDER=sender
EXPECTED_L1_CALL_HASHES=[] EXPECTED_L1_HASHES=[] EXPECTED_L2_CALL_HASHES=[] EXPECTED_L2_HASHES=[]
EXPECTED_L1_TABLE=0x EXPECTED_L1_STEPS=0x EXPECTED_L1_STATIC_TABLE=0x EXPECTED_L2_TABLE=0x EXPECTED_L2_STATIC_TABLE=0x EVENTLESS_L2_HASHES=[] ABSENT_L2_HASHES=[]
''' + source[start:end], root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('E2E_MANIFEST_VERSION="2"', (Path(root) / 'job/manifest.env').read_text())
            self.assertTrue((Path(root) / 'job/.deploys-done').exists())
