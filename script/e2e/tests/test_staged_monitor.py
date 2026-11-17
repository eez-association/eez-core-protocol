"""Run the real Bash monitor against deterministic receipt endpoints and a fake clock."""
import json
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
        self.assertIn("[trigger] L1: 1/1 resolved (0 pending) | L2: 1/1 resolved (0 pending)", result.stdout)

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


class StagedStaticFailureVerificationTests(unittest.TestCase):
    def test_recovery_uses_normal_verifier_and_propagates_failure(self):
        for name in ("topLevelStaticReentrantMissingProxy", "topLevelStaticReentrantMissingProxyL2"):
            direction = "L2_to_L1" if name.endswith("L2") else "L1_to_L2"
            sol = f"script/e2e/scenarios/static/{direction}/{name}/E2E{name[0].upper() + name[1:]}.s.sol"
            self.assertTrue((E2E.parents[1] / sol).is_file())
            for code in (0, 7):
                with self.subTest(name=name, verifier_exit=code), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "jobs" / name).mkdir(parents=True)
                    # A recorded receipt must reach full verification, not a rejection shortcut.
                    (root / "mined.csv").write_text(f"{name},L1,0xaaa,16,0x1\n")
                    script = r"""
set -euo pipefail
L1_RPC=direct1 L2_RPC=direct2 L1_FRONT=front1 L2_FRONT=front2
ROLLUPS=registry MANAGER_L2=manager
bash() {
    [[ "$1" == script/e2e/lib/network-scenario.sh && "$2" == "$SOL" ]] || return 91
    [[ "$E2E_STAGE" == verify && "$E2E_JOB_DIR" == "$RUN_DIR/jobs/$JOB" ]] || return 92
    echo normal-verifier
    return "$VERIFY_EXIT"
}
""" + function("_expects_static_quote_rejection") + "\n" + function("_verify_launch") + '\n_verify_launch "$JOB" "$SOL" unused-test-key\n'
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                        env={"PATH": os.environ["PATH"], "RUN_DIR": directory, "JOB": name,
                             "SOL": sol, "VERIFY_EXIT": str(code)}, timeout=5)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    self.assertEqual((root / "jobs" / name / "verify.log").read_text(), "normal-verifier\n")


class StagedHashValidationTests(unittest.TestCase):
    HASH = "0x" + "ab" * 32

    def test_rpc_helper_rejects_malformed_success_results(self):
        values = [self.HASH, "0x" + "AB" * 32, "warning", "", None, 42,
                  {"hash": self.HASH}, self.HASH[:-1], self.HASH + "0",
                  "warning\n" + self.HASH, self.HASH + "\nwarning", " " + self.HASH]
        for value in values:
            valid = value in (self.HASH, "0x" + "AB" * 32)
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                script = r'''set -euo pipefail
RUN_DIR="$TEST_ROOT"
curl() { printf '%s\n' "$RESPONSE"; }
''' + function("_rpc_send_raw") + '\n_rpc_send_raw mock-rpc mock-raw\n'
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                    timeout=5, env={"PATH": os.environ["PATH"], "TEST_ROOT": directory,
                                    "RESPONSE": json.dumps({"jsonrpc": "2.0", "id": 1, "result": value})})
                self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
                self.assertEqual(result.stdout, value + "\n" if valid else "")

    def test_send_worker_preserves_resume_journals_on_bad_output(self):
        for chain in ("L1", "L2"):
            for value in (self.HASH, "warning\n" + self.HASH, self.HASH + "\nwarning", "", self.HASH[:-1]):
                valid = value == self.HASH
                with self.subTest(chain=chain, value=value), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    job = root / "jobs/job"
                    job.mkdir(parents=True)
                    (job / "manifest.env").write_text(f'declare -- _TRIGGER_CHAIN="{chain}"\n')
                    (job / "rawtxs.txt").write_text("saved\nnext\nlater\n")
                    (job / "txs.txt").write_text(self.HASH + "\n")
                    original = f"job,{chain},{self.HASH}\n"
                    (root / "sent.csv").write_text(original)
                    (root / "wallets.csv").write_text("job,address,private_key\njob,unused,test-only-key\n")
                    script = r'''set -euo pipefail
source "$ORCHESTRATOR"
ATTEMPT=1
RUN_DIR="$TEST_ROOT"; JOB_NAMES=(job); NJOBS=1
SEND_PAUSE=0 RESUME=saved-run L1_RPC=mock-read L2_RPC=mock-read
_job_prepared() { return 0; }
_front_rpc() { echo mock-front; }
_reply() { echo "$1" >> "$RUN_DIR/submissions"; printf '%s\n' "$RETURNED_HASH"; }
_rpc_send_raw() { _reply "$2"; }
network_send_quoted_trigger() { _reply "$1"; }
''' + function("_expects_static_quote_rejection") + "\n" + function("send_worker") + '\nsend_worker 0 "$CHAIN" 1\n'
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                        timeout=5, env={"PATH": os.environ["PATH"], "TEST_ROOT": directory,
                                       "CHAIN": chain, "RETURNED_HASH": value,
                                       "ORCHESTRATOR": str(E2E / "lib/orchestrator.sh")})
                    self.assertEqual(result.returncode, 0 if valid else 1, result.stdout + result.stderr)
                    self.assertEqual((root / "submissions").read_text().splitlines(),
                                     ["next", "later"] if valid else ["next"])
                    self.assertEqual((job / "txs.txt").read_text(), (self.HASH + "\n") * (3 if valid else 1))
                    self.assertEqual((root / "sent.csv").read_text(), original * (3 if valid else 1))
                    if not valid:
                        self.assertIn(f"SEND FAILED: job ({chain})", (root / "send-failed.log").read_text())


if __name__ == "__main__":
    unittest.main()
