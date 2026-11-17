"""Audit expected quote rejection against real offline signed candidates."""
import contextlib
import copy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from test_staged_monitor import E2E, RUNNER, function

SPEC = importlib.util.spec_from_file_location("quote_rejection", E2E / "lib/verify-quote-rejection.py")
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
KEY = "0x" + "01".zfill(64)  # Public test-only key.
NAMES = ("topLevelStaticReentrantMissingProxyCaught", "topLevelStaticReentrantMissingProxyCaughtL2")
HELPERS = "\n".join(function(name) for name in (
    "_expects_static_quote_rejection", "_verify_static_quote_rejection",
    "_probe_static_quote_rejection", "_verify_launch"))


class QuoteRejectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raws = {}
        cls.txs = {}
        for kind in ("0x0", "0x2"):
            args = ["cast", "mktx", "0x" + "11" * 20, "0x12345678", "--private-key", KEY,
                    "--chain", "906969", "--nonce", "7", "--gas-limit", "1000000",
                    "--gas-price", "100", "--value", "17"]
            args += ["--legacy"] if kind == "0x0" else ["--priority-gas-price", "1"]
            cls.raws[kind] = subprocess.check_output(args, text=True).strip()
            tx = json.loads(subprocess.check_output(["cast", "decode-transaction", cls.raws[kind]], text=True))
            cls.txs[kind] = json.loads(tx) if isinstance(tx, str) else tx

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.quote = {
            "version": 1, "chainId": "0xdd6d9", "nonce": "0x7",
            "expiresAt": hex(int(time.time()) + 3600),
            "options": [{"type": kind, "error": {"code": VERIFY.CODE, "message": VERIFY.MESSAGE}}
                        for kind in ("0x0", "0x2")],
        }

    def record(self, kind="0x2"):
        tx = self.txs[kind]
        return {
            "receivedAt": datetime.now(timezone.utc).isoformat(),
            "intent": {"from": tx["signer"], "to": tx["to"], "data": tx["input"],
                       "value": tx["value"], "nonce": tx["nonce"]},
            "preparedNonce": tx["nonce"], "transactionType": kind,
            "rawResponse": json.dumps(self.quote),
        }

    def job(self, name=NAMES[0], kind="0x2"):
        job = self.root / "jobs" / name
        job.mkdir(parents=True, exist_ok=True)
        (job / "rawtxs.txt").write_text(self.raws[kind] + "\n")
        (job / "fee-quote-1.responses.jsonl").write_text(json.dumps(self.record(kind)) + "\n")
        return job

    def assert_invalid(self, record):
        with self.assertRaises((ValueError, KeyError, TypeError, IndexError)):
            VERIFY.validate_record(record, self.txs["0x2"])

    def test_both_transaction_types_accept_exact_rejection(self):
        for kind in self.raws:
            job = self.job(kind=kind)
            VERIFY.verify_job(self.root, job.name)

    def test_binding_checks_every_intent_field_nonce_chain_and_type(self):
        record = self.record()
        for field in record["intent"]:
            wrong = copy.deepcopy(record)
            wrong["intent"][field] = "wrong"
            with self.subTest(field=field):
                self.assert_invalid(wrong)
        for field in ("preparedNonce", "transactionType"):
            wrong = copy.deepcopy(record)
            wrong[field] = "0x0"
            self.assert_invalid(wrong)
        for field in ("nonce", "chainId"):
            quote = copy.deepcopy(self.quote)
            quote[field] = "0x8"
            wrong = dict(record, rawResponse=json.dumps(quote))
            self.assert_invalid(wrong)

    def test_other_errors_missing_duplicate_or_successful_options_fail(self):
        options = [
            [], [self.quote["options"][0]],
            [self.quote["options"][1]] * 2,
            [{"type": "0x2", "gas": "0x1"}],
            [{"type": "0x2", "error": {"code": "other", "message": VERIFY.MESSAGE}}],
            [{"type": "0x2", "error": {"code": VERIFY.CODE, "message": "other"}}],
            [dict(self.quote["options"][1], gas="0x1")],
            [None], None,
        ]
        for value in options:
            with self.subTest(options=value):
                self.assert_invalid(dict(self.record(), rawResponse=json.dumps(dict(self.quote, options=value))))

    def test_malformed_json_duplicate_fields_and_boolean_version_fail(self):
        for raw in ("null", "[]", "{", json.dumps(dict(self.quote, version=True)),
                    '{"version":0,' + json.dumps(self.quote)[1:]):
            with self.subTest(raw=raw):
                self.assert_invalid(dict(self.record(), rawResponse=raw))

    def test_validity_is_checked_at_capture_not_reverification_time(self):
        self.quote["expiresAt"] = "0x6553f101"  # 2023, valid for one second after capture.
        record = dict(self.record(), receivedAt="2023-11-14T22:13:20Z")
        VERIFY.validate_record(record, self.txs["0x2"])
        self.quote["expiresAt"] = "0x6553f100"
        self.assert_invalid(dict(record, rawResponse=json.dumps(self.quote)))

    def test_timestamps_fail_without_echoing_input_or_traceback(self):
        job = self.job()
        for value in (None, 17, "DO_NOT_ECHO_THIS_INPUT", "2026-11-13T11:00:00"):
            (job / "fee-quote-1.responses.jsonl").write_text(json.dumps(dict(self.record(), receivedAt=value)) + "\n")
            output = io.StringIO()
            with patch.object(sys, "argv", ["verify", str(self.root), job.name]), contextlib.redirect_stdout(output):
                self.assertEqual(VERIFY.main(), 1)
            self.assertNotIn("DO_NOT_ECHO_THIS_INPUT", output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())

    def test_missing_evidence_later_success_and_stale_attempt_cannot_pass(self):
        job = self.job()
        path = job / "fee-quote-1.responses.jsonl"
        record = path.read_text()
        for data in ("", record + "null\n", record + "{\n"):
            path.write_text(data)
            with self.assertRaises((ValueError, TypeError)):
                VERIFY.verify_job(self.root, job.name)
        path.write_text(record)
        for count in ("1", "-1", "invalid"):
            (job / "quote-probe-start.txt").write_text(count)
            with self.assertRaises(ValueError):
                VERIFY.verify_job(self.root, job.name)

    def test_any_recorded_or_archived_submission_prevents_pass(self):
        job = self.job()
        for path, content in [
            (job / "txs.txt", "hash\n"), (job / "txs.txt.attempt1", "hash\n"),
            (self.root / "sent.csv", f"{job.name},L1,hash\n"),
            (self.root / "sent.csv.attempt1", f"{job.name},L1,hash\n"),
            (self.root / "mined.csv", f"{job.name},L1,hash,10,0x1\n"),
            (job / "fee-quote-1.json", "{}"),
        ]:
            path.write_text(content)
            with self.assertRaises(ValueError):
                VERIFY.verify_job(self.root, job.name)
            path.unlink()

    def test_decoder_is_bounded_and_failure_has_fixed_output(self):
        job = self.job()
        with patch.object(VERIFY.subprocess, "run", side_effect=subprocess.TimeoutExpired("cast", 10)) as call:
            output = io.StringIO()
            with patch.object(sys, "argv", ["verify", str(self.root), job.name]), contextlib.redirect_stdout(output):
                self.assertEqual(VERIFY.main(), 1)
            self.assertEqual(call.call_args.kwargs["timeout"], 10)
            self.assertNotIn(self.raws["0x2"], output.getvalue())

    def probe(self, name, mode="reject"):
        (self.root / "quote.json").write_text(json.dumps(self.quote))
        script = r"""
set -euo pipefail
source script/e2e/lib/network-fees.sh
L1_RPC=direct-L1 L2_RPC=direct-L2
_front_rpc() { echo "front-$1"; }
cast() {
    case "$1" in
        chain-id) echo 906969 ;;
        rpc)
            [[ "$*" == *eez_quoteFee* && "$*" == *"front-$CHAIN"* ]] || return 91
            if [[ "$MODE" == transport ]]; then echo 'execution reverted' >&2; return 1; fi
            cat "$RUN_DIR/quote.json" ;;
        decode-transaction|to-dec) command cast "$@" ;;
        *) echo forbidden >> "$RUN_DIR/forbidden"; return 92 ;;
    esac
}
""" + HELPERS + '\n_probe_static_quote_rejection "$JOB" "$CHAIN"\n'
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10,
            env={"PATH": os.environ["PATH"], "RUN_DIR": str(self.root), "JOB": name,
                 "CHAIN": "L2" if name.endswith("L2") else "L1", "MODE": mode, "TMPDIR": str(self.root)})

    def test_live_probe_uses_source_front_and_never_signs_or_submits(self):
        for name in NAMES:
            self.job(name)
            result = self.probe(name)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse((self.root / "forbidden").exists())

    def test_failed_resume_does_not_reuse_preceding_rejection(self):
        job = self.job()
        result = self.probe(job.name, "transport")
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            VERIFY.verify_job(self.root, job.name)
        self.assertFalse((self.root / "forbidden").exists())

    def test_unexpected_valid_quote_never_submits_and_fails_verification(self):
        job = self.job()
        self.quote["options"][1] = {
            "type": "0x2", "gas": "0x100", "maxFeePerGas": "0x100",
            "maxPriorityFeePerGas": "0x1", "estimatedFee": "0x10000",
            "intentHash": "0x" + "ab" * 32,
        }
        result = self.probe(job.name)
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            VERIFY.verify_job(self.root, job.name)
        self.assertFalse((self.root / "forbidden").exists())

    def test_send_phase_propagates_failures_in_mixed_runs_and_ignores_old_logs(self):
        # Execute the actual dispatch, monitor and exit paths with offline jobs.
        # Verification succeeds deliberately: it must not erase a send failure.
        phase = RUNNER[RUNNER.index("# ══ Phase 4: send"):]
        for chain, name in zip(("L1", "L2"), NAMES):
            direction = "L2_to_L1" if chain == "L2" else "L1_to_L2"
            sol = f"script/e2e/scenarios/static/{direction}/{name}/E2E{name[0].upper() + name[1:]}.s.sol"
            for no_verify in ("true", "false"):
                for old_failure in (False, True):
                    for quote_rc, send_rc in ((0, 0), (1, 0), (75, 0), (0, 1)):
                        with self.subTest(chain=chain, no_verify=no_verify, old_failure=old_failure,
                                          quote_rc=quote_rc, send_rc=send_rc), tempfile.TemporaryDirectory() as directory:
                            root = Path(directory)
                            for job_name in (name, "normal"):
                                job = root / "jobs" / job_name
                                job.mkdir(parents=True)
                                (job / "manifest.env").write_text(f'declare -- _TRIGGER_CHAIN="{chain}"\n')
                                (job / "rawtxs.txt").write_text("offline-candidate\n")
                            (root / "wallets.csv").write_text("job,address,key\nnormal,unused,test-only-key\n")
                            if old_failure:
                                (root / "send-failed.log").write_text("QUOTE CHECK FAILED: previous attempt\nSEND FAILED: previous attempt\n")
                            script = r"""
set -uo pipefail
NJOBS=2 SEND_WORKERS=1 SEND_PAUSE=0 RESUME=saved-run
PREP_FAIL=0 MINE_TIMEOUT=1 MAX_MONITOR_WAIT=1 POLL_INTERVAL=0
L1_RPC=offline-L1 L2_RPC=offline-L2
JOB_NAMES=("$JOB" normal)
JOB_SOLS=("$SOL" ordinary-scenario)
_job_prepared() { return 0; }
_front_rpc() { echo offline-front; }
_timed_job() { shift 2; "$@"; }
_phase_begin() { :; }
_phase_end() { echo "phase $1 $2"; }
_chain_counts() { :; }
_probe_static_quote_rejection() { return "$QUOTE_RC"; }
network_send_quoted_trigger() {
    [[ "$SEND_RC_TEST" == 0 ]] || return "$SEND_RC_TEST"
    printf '0x%064x\n' 1
}
_monitor_files() {
    awk -F, '{print $0 ",10,0x1"}' "$1" > "$2"
    : > "$3"
}
verify_phase() { return 0; }
""" + function("_expects_static_quote_rejection") + "\n" + phase
                            result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10,
                                env={"PATH": os.environ["PATH"], "RUN_DIR": directory, "JOB": name, "SOL": sol,
                                     "NO_VERIFY": no_verify, "QUOTE_RC": str(quote_rc), "SEND_RC_TEST": str(send_rc)})
                            failed = quote_rc != 0 or send_rc != 0
                            self.assertEqual(result.returncode, 1 if failed else 0, result.stdout + result.stderr)
                            self.assertIn("phase send " + ("fail" if failed else "pass"), result.stdout)
                            sent = (root / "sent.csv").read_text().splitlines()
                            self.assertEqual(len(sent), 0 if send_rc else 1)
                            self.assertTrue(all(row.startswith("normal,") for row in sent))
                            self.assertFalse((root / "jobs" / name / "txs.txt").exists())

    def test_quote_only_jobs_reach_verification_without_submissions(self):
        jobs = []
        for name in NAMES:
            job = self.job(name)
            (job / "manifest.env").write_text('declare -- _TX_COUNT="1"\n')
            direction = "L2_to_L1" if name.endswith("L2") else "L1_to_L2"
            sol = f"script/e2e/scenarios/static/{direction}/{name}/E2E{name[0].upper() + name[1:]}.s.sol"
            jobs.append(f"{name},{sol}\n")
        (self.root / "jobs.csv").write_text("job,sol\n" + "".join(jobs))
        (self.root / "wallets.csv").write_text("job,address,key\n" + "".join(f"{name},unused,unused\n" for name in NAMES))
        script = r"""
set -uo pipefail
VERIFY_PARALLEL=1 RESUME_TRUNCATED=false
_restore_forge_cache() { :; }
_print_block_summary() { :; }
_manifest_version() { echo 2; }
_job_prepared() { return 0; }
_timed_job() { shift 2; "$@"; }
""" + HELPERS + "\n" + function("verify_phase") + "\nverify_phase\n"
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=15,
            env={"PATH": os.environ["PATH"], "RUN_DIR": str(self.root)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 passed, 0 failed, 0 not verifiable", result.stdout)
        self.assertFalse((self.root / "sent.csv").exists())


if __name__ == "__main__":
    unittest.main()
