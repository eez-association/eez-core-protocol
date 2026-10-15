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
    "_expects_missing_proxy_rejection", "_check_missing_proxy_rejection",
    "_poll_expected_rejections", "_remove_mined", "_poll_pending_once", "_chain_counts", "_monitor_files"))
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


class StagedRejectionTests(unittest.TestCase):
    def status(self):
        return {
            "hash": "0xaaa", "lifecycle": "terminal",
            "ownership": {
                "state": "terminal", "reason": "SimulationFailed",
                "rejection": {"error": "executor: static callback source proxy 0x" + "a" * 40
                              + " is not deployed on chain 1; it must exist before the read"},
            },
        }

    def run_check(self, chain, status, **settings):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "status.json").write_text(json.dumps(status))
            script = r"""
set -euo pipefail
cd "$TEST_ROOT"
L1_RPC=direct1 L2_RPC=direct2
_front_rpc() { [[ "$1" == L1 ]] && echo front1 || echo front2; }
cast() {
    [[ "$1 $2 $3 $4" == 'rpc --rpc-timeout 10 --rpc-url' && "$7" == 0xaaa ]] || return 90
    echo "$5 $6 $7" >> calls
    case "$6" in
        eez_getCrossChainTransaction)
            [[ "$5" == "$EXPECTED_FRONT" && "${LOOKUP_FAIL:-0}" != 1 ]] || return 91
            cat status.json ;;
        eth_getTransactionReceipt)
            [[ "$5" == "$EXPECTED_FRONT" || "$5" == "$EXPECTED_DIRECT" ]] || return 92
            if [[ "$5" == "${MINED_ENDPOINT:-none}" ]]; then
                echo '{"status":"0x0"}'
            else
                echo null
            fi ;;
        *) return 93 ;;
    esac
}
""" + function("_check_missing_proxy_rejection") + r"""
_check_missing_proxy_rejection "$CHAIN" 0xaaa evidence.json
"""
            suffix = "1" if chain == "L1" else "2"
            result = subprocess.run(
                ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                env={"PATH": os.environ["PATH"], "TEST_ROOT": directory, "CHAIN": chain,
                     "EXPECTED_FRONT": "front" + suffix, "EXPECTED_DIRECT": "direct" + suffix,
                     **settings})
            files = {p.name: p.read_text() for p in root.iterdir()}
            return result, files

    def test_status_uses_matching_front_and_receipts_check_both_endpoints(self):
        for chain, suffix in (("L1", "1"), ("L2", "2")):
            with self.subTest(chain=chain):
                status = self.status()
                result, files = self.run_check(chain, status)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(files["calls"].splitlines(), [
                    f"front{suffix} eez_getCrossChainTransaction 0xaaa",
                    f"direct{suffix} eth_getTransactionReceipt 0xaaa",
                    f"front{suffix} eth_getTransactionReceipt 0xaaa",
                ])
                self.assertEqual(json.loads(files["evidence.json"]), status)

    def test_null_wrong_hash_nonterminal_and_unrelated_rejections_fail(self):
        statuses = [None]
        for field, value in (("hash", "0xbbb"), ("lifecycle", "pending")):
            status = self.status()
            status[field] = value
            statuses.append(status)
        for field, value in (("reason", "OtherFailure"), ("state", "pending"),
                             ("rejection", {"error": "some other simulation failure"})):
            status = self.status()
            status["ownership"][field] = value
            statuses.append(status)
        for chain in ("L1", "L2"):
            for status in statuses:
                with self.subTest(chain=chain, status=status):
                    result, _ = self.run_check(chain, status)
                    self.assertNotEqual(result.returncode, 0)

    def test_rpc_failure_or_receipt_at_either_endpoint_cannot_pass(self):
        for chain, suffix in (("L1", "1"), ("L2", "2")):
            for settings in ({"LOOKUP_FAIL": "1"}, {"MINED_ENDPOINT": "front" + suffix},
                             {"MINED_ENDPOINT": "direct" + suffix}):
                with self.subTest(chain=chain, settings=settings):
                    result, _ = self.run_check(chain, self.status(), **settings)
                    self.assertNotEqual(result.returncode, 0)


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
RUN_DIR="$TEST_ROOT"; JOB_NAMES=(job); NJOBS=1
SEND_PAUSE=0 RESUME=saved-run L1_RPC=mock-read L2_RPC=mock-read
_job_prepared() { return 0; }
_front_rpc() { echo mock-front; }
_reply() { echo "$1" >> "$RUN_DIR/submissions"; printf '%s\n' "$RETURNED_HASH"; }
_rpc_send_raw() { _reply "$2"; }
network_send_quoted_trigger() { _reply "$1"; }
''' + function("send_worker") + '\nsend_worker 0 "$CHAIN" 1\n'
                    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                        timeout=5, env={"PATH": os.environ["PATH"], "TEST_ROOT": directory,
                                       "CHAIN": chain, "RETURNED_HASH": value})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((root / "submissions").read_text().splitlines(),
                                     ["next", "later"] if valid else ["next"])
                    self.assertEqual((job / "txs.txt").read_text(), (self.HASH + "\n") * (3 if valid else 1))
                    self.assertEqual((root / "sent.csv").read_text(), original * (3 if valid else 1))
                    if not valid:
                        self.assertIn(f"SEND FAILED: job ({chain})", (root / "send-failed.log").read_text())


if __name__ == "__main__":
    unittest.main()
