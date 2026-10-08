"""Offline checks for the devnet address adapter and shared runner."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_run import HARNESS, KEY, RUNNER


class DevnetTests(unittest.TestCase):
    def run_shell(self, directory, action):
        return subprocess.run(["bash", "-c", HARNESS + "\n" + action], text=True,
            capture_output=True, timeout=25, env={"PATH": os.environ["PATH"],
            "RUNNER": str(RUNNER), "TEST_DIR": str(directory), "TEST_KEY": KEY,
            "REAL_CAST": shutil.which("cast"), "SCENARIO": "success"})

    def test_trigger_signs_devnet_chain_and_uses_devnet_script(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_shell(directory, 'source "$(dirname "$RUNNER")/devnet.sh"\ntrigger')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            raw = (Path(directory) / "trigger.raw").read_text().strip()
            tx = json.loads(subprocess.check_output(["cast", "decode-transaction", raw], text=True))
            if isinstance(tx, str):
                tx = json.loads(tx)
            self.assertEqual(int(tx["chainId"], 16), 906969)
            calls = (Path(directory) / "calls").read_text()
            self.assertIn("Devnet.s.sol:Devnet", calls)
            self.assertNotIn("Mainnet.s.sol:Mainnet", calls)
            self.assertEqual(calls.count("SEND front2"), 1)

    def test_wrong_chain_stops_before_deployment(self):
        with tempfile.TemporaryDirectory() as directory:
            action = """
source "$(dirname "$RUNNER")/devnet.sh"
cast() { echo 1; }
preflight
"""
            result = self.run_shell(directory, action)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("L1_RPC has unexpected chain ID", result.stderr)
            self.assertFalse((Path(directory) / "deploy-l1.started").exists())

    def test_missing_deployment_address_stops_before_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_shell(directory, "unset BALANCER_TOKEN\nload_balancer_addresses\ntrigger")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Set BALANCER_TOKEN", result.stderr)
            self.assertFalse((Path(directory) / "trigger.raw").exists())
