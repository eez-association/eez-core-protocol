"""Fresh-attempt journaling and offline signatures. No chain.env or live RPC."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_run import HARNESS, KEY, ROOT, RUNNER

HELPER = ROOT / "script/balancer/rerun.sh"


class RerunTests(unittest.TestCase):
    def run_shell(self, directory, action, scenario="legacy_ready"):
        return subprocess.run(["bash", "-c", HARNESS + '\nsource "$HELPER"\n' + action],
            text=True, capture_output=True, timeout=25,
            env={"PATH": os.environ["PATH"], "RUNNER": str(RUNNER), "HELPER": str(HELPER),
                 "TEST_DIR": str(directory), "TEST_KEY": KEY, "REAL_CAST": shutil.which("cast"),
                 "SCENARIO": scenario})

    def decode(self, path):
        tx = json.loads(subprocess.check_output(["cast", "decode-transaction", path.read_text().strip()], text=True))
        return json.loads(tx) if isinstance(tx, str) else tx

    def test_fresh_attempts_preserve_parent_and_raise_fee_for_same_nonce(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, '''
parent=$RUN_DIR
cp "$parent/state.json" "$parent/original-state.json"
trigger legacy
cp "$parent/trigger.raw" "$parent/original.raw"
cp "$parent/trigger.hash" "$parent/original.hash"
cp "$parent/state.json" "$parent/signed-state.json"
rerun_loan "$parent"
cp "$parent/reruns/latest" "$parent/first-attempt"
rerun_loan "$parent"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            p = Path(d)
            self.assertEqual((p / "state.json").read_bytes(), (p / "signed-state.json").read_bytes())
            self.assertEqual((p / "trigger.raw").read_bytes(), (p / "original.raw").read_bytes())
            self.assertEqual((p / "trigger.hash").read_bytes(), (p / "original.hash").read_bytes())
            first = p / "reruns" / (p / "first-attempt").read_text().strip()
            last = p / "reruns" / (p / "reruns/latest").read_text().strip()
            tx1, tx2 = self.decode(first / "trigger.raw"), self.decode(last / "trigger.raw")
            self.assertEqual(tx1["input"], self.decode(p / "trigger.raw")["input"])
            self.assertEqual(int(tx1["nonce"], 16), 5)
            self.assertEqual(int(tx1["gasPrice"], 16), 226)
            self.assertEqual(int(tx2["gasPrice"], 16), 255)
            self.assertNotEqual((first / "trigger.hash").read_text(), (last / "trigger.hash").read_text())
            self.assertEqual(json.loads((last / "state.json").read_text())["loan_mode"], "legacy")
            self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_updated_deployment_uses_fixed_amount(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, 'set_field loan_mode fixed\nrerun_loan "$RUN_DIR"')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            p = Path(d)
            attempt = p / "reruns" / (p / "reruns/latest").read_text().strip()
            state = json.loads((attempt / "state.json").read_text())
            self.assertEqual(state["loan_mode"], "fixed")
            self.assertEqual(state["requested_amount"], "32000000000")
            self.assertFalse((p / "trigger.hash").exists())

    def test_pending_or_claimed_never_signs(self):
        for scenario in ("success", "already_claimed"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as d:
                result = self.run_shell(d, 'rerun_loan "$RUN_DIR"', scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(Path(d).glob("reruns/*/trigger.raw")))
                self.assertIn("Pending wallet transaction" if scenario == "success" else "Wallet already claimed", result.stderr)
                for calls in Path(d).glob("reruns/*/calls"):
                    self.assertNotIn("SEND", calls.read_text())

    def test_unsigned_failed_attempt_keeps_previous_fee_history(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, '''
parent=$RUN_DIR
trigger legacy
mkdir -p "$parent/reruns/attempt.failed"
jq -n --arg parent "$parent" '{previous_attempt:$parent}' > "$parent/reruns/attempt.failed/state.json"
echo attempt.failed > "$parent/reruns/latest"
rerun_loan "$parent"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            p = Path(d)
            last = p / "reruns" / (p / "reruns/latest").read_text().strip()
            self.assertEqual(int(self.decode(last / "trigger.raw")["gasPrice"], 16), 226)

    def test_hash_mismatch_stops_before_new_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, '''
trigger legacy
echo wrong > "$RUN_DIR/trigger.hash"
rerun_loan "$RUN_DIR"
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("transaction/hash mismatch", result.stderr)
            self.assertFalse((Path(d) / "reruns").exists())

    def test_failed_submission_keeps_signed_attempt_for_status(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, '_send_raw_tx() { return 43; }\nrerun_loan "$RUN_DIR"')
            self.assertNotEqual(result.returncode, 0)
            p = Path(d)
            last = p / "reruns" / (p / "reruns/latest").read_text().strip()
            self.assertTrue((last / "trigger.raw").exists())
            self.assertTrue((last / "trigger.hash").exists())
            self.assertFalse((p / "trigger.hash").exists())

    def test_help_does_not_load_environment(self):
        result = subprocess.run(["bash", str(HELPER), "--help"], text=True, capture_output=True,
                                env={"PATH": os.environ["PATH"]}, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("DEPLOYMENT_DIR", result.stdout)


if __name__ == "__main__":
    unittest.main()
