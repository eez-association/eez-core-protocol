"""Run the real Bash monitor against deterministic receipt endpoints and a fake clock."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

E2E = Path(__file__).resolve().parents[1]
RUNNER = (E2E / "run/network/staged.sh").read_text()


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", RUNNER, re.M | re.S)
    assert match, name
    return match.group()


FUNCTIONS = "\n".join(function(name) for name in (
    "_remove_mined", "_poll_pending_once", "_chain_counts", "_monitor_files"))
DEFAULT = re.search(r'^MAX_MONITOR_WAIT=.*$', RUNNER, re.M).group()


class StagedMonitorTests(unittest.TestCase):
    def run_monitor(self, mode="front", **settings):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sent.csv").write_text("job1,L1,0xaaa\njob2,L2,0xbbb\n")
            (root / "clock").write_text("0\n")
            script = r"""
set -uo pipefail
cd "$TEST_ROOT"
L1_RPC=direct1 L2_RPC=direct2
_front_rpc() { [[ "$1" == L1 ]] && echo front1 || echo front2; }
date() { cat clock; }
sleep() { echo $(( $(cat clock) + $1 )) > clock; }
_poll_delay() { echo 1; }
_reconcile_replacements() { return "${RECONCILE_RC:-0}"; }
_recovery_all_stopped() { [[ "${REJECTED:-0}" == 1 ]]; }
_recover_pending() { if [[ "${3:-}" == --expire ]]; then echo expired >> expiry; else echo accepted >> recoveries; date +%s >> checkpoints; fi; }
_batch_receipts() {
    local hash
    echo "$1" >> lookups
    while read -r hash; do
        echo "$1 $hash" >> queried
        [[ "$1" == "${HIDE_ENDPOINT:-none}" ]] && continue
        [[ "$1" == front* && "${HIDE_FRONT:-0}" == 1 ]] && continue
        (( $(date +%s) >= ${MINE_AT:-0} )) || continue
        printf '%s 0x10 %s\n' "$hash" "${RECEIPT_STATUS:-0x1}"
    done
}
""" + FUNCTIONS + r"""
if [[ "${ALREADY_MINED:-0}" == 1 ]]; then
    echo 'job1,L1,0xaaa,16,0x1' > mined.csv
fi
_monitor_files sent.csv mined.csv pending.csv "${RECOVERY_INTERVAL:-2}" "$MODE" 1
"""
            env = {"PATH": os.environ["PATH"], "TEST_ROOT": directory,
                   "MODE": mode, "MAX_MONITOR_WAIT": "5", **{k: str(v) for k, v in settings.items()}}
            result = subprocess.run(["bash", "-c", script], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.stderr, "", result.stdout + result.stderr)
            files = {p.name: p.read_text() for p in root.iterdir()}
            return result, files

    def test_default_is_five_minutes(self):
        for value, expected in ((None, "300"), ("60", "60")):
            env = {"PATH": os.environ["PATH"]}
            if value is not None:
                env["MAX_MONITOR_WAIT"] = value
            result = subprocess.run(["bash", "-c", DEFAULT + '; echo "$MAX_MONITOR_WAIT"'],
                                    env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), expected)

    def test_repeated_acceptance_does_not_reset_deadline(self):
        result, files = self.run_monitor(MINE_AT=999)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MONITOR TIMEOUT: 2 tx(s) unmined after 5s", result.stdout)
        self.assertIn("pending job=job1 chain=L1 hash=0xaaa", result.stdout)
        self.assertIn("composer logs", result.stdout)
        self.assertEqual(files["recoveries"].count("accepted"), 2)
        self.assertEqual(files["expiry"].strip(), "expired")
        self.assertEqual(files["pending.csv"], files["sent.csv"])

    def test_first_status_check_is_at_one_minute_even_with_longer_interval(self):
        result, files = self.run_monitor(MINE_AT=999, MAX_MONITOR_WAIT=65, RECOVERY_INTERVAL=120)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(files["checkpoints"].splitlines(), ["60"])

    def test_source_receipts_complete_when_front_hides_them(self):
        result, files = self.run_monitor(HIDE_FRONT=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["pending.csv"], "")
        self.assertEqual(len(files["mined.csv"].splitlines()), 2)
        self.assertEqual(files["lookups"].splitlines(), ["front1", "direct1", "front2", "direct2"])

    def test_front_receipts_do_not_get_queried_or_recorded_twice(self):
        result, files = self.run_monitor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["lookups"].splitlines(), ["front1", "front2"])
        self.assertEqual(len(files["mined.csv"].splitlines()), 2)

    def test_deploys_query_direct_endpoints_only(self):
        result, files = self.run_monitor(mode="direct")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["lookups"].splitlines(), ["direct1", "direct2"])

    def test_resume_preserves_mined_rows_without_repolling_them(self):
        result, files = self.run_monitor(ALREADY_MINED=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(files["mined.csv"].splitlines()), 2)
        self.assertNotIn("0xaaa", files["queried"])

    def test_both_chains_share_one_progress_line(self):
        result, _ = self.run_monitor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[trigger] L1: 1/1 mined (0 pending) | L2: 1/1 mined (0 pending)", result.stdout)

    def test_rejected_transactions_stop_without_rebroadcast(self):
        result, files = self.run_monitor(MINE_AT=999, REJECTED=1)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MONITOR FAILED", result.stdout)
        self.assertNotIn("recoveries", files)

    def test_mined_revert_is_recorded_without_resending(self):
        result, files = self.run_monitor(RECEIPT_STATUS="0x0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["mined.csv"].count(",16,0x0"), 2)
        self.assertNotIn("recoveries", files)

    def test_no_verify_fails_for_mined_reverts(self):
        block = re.search(r"^if \$NO_VERIFY; then.*?^fi", RUNNER, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as directory:
            for reverted, expected in (("0", 0), ("1", 1)):
                result = subprocess.run(["bash", "-c", block], capture_output=True, text=True,
                                        env={"PATH": os.environ["PATH"], "NO_VERIFY": "true",
                                             "RUN_DIR": directory, "MONITOR_RC": "0",
                                             "PREP_FAIL": "0", "N_REVERTED": reverted})
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_reconciliation_failure_propagates(self):
        result, files = self.run_monitor(RECONCILE_RC=1)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("lookups", files)


if __name__ == "__main__":
    unittest.main()
