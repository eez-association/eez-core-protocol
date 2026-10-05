"""Real offline signing; deterministic RPCs exercise the production recovery code."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_staged_monitor import E2E, function

KEY = "0x" + "01".zfill(64)  # Public test-only key.

RPC = r'''
L1_RPC=direct1 L2_RPC=direct2
_front_rpc() { echo front1; }
_recovery_lookup_once() {
    echo "lookup $1 $2" >> calls
    if [[ "$SCENARIO" == rpc_failure || "$SCENARIO" == partial_receipt_failure && "$1" == front1 ]]; then return 1; fi
    if [[ "$2" == eth_getTransactionReceipt ]]; then
        case "$SCENARIO" in
            original_wins_pool_failure|original_wins_fee_failure|partial_receipt_failure)
                jq -nc --arg h "$ORIGINAL" '{($h):{transactionHash:$h,blockNumber:"0x10",status:"0x1"}}'; return ;;
        esac
        echo '{}'
    else
        [[ "$SCENARIO" != original_wins_pool_failure ]] || return 1
        if [[ "$SCENARIO" != missing && "$SCENARIO" != missing_low ]]; then
            jq -nc --arg h "$ORIGINAL" '{($h):{hash:$h,blockNumber:null}}'
        else echo '{}'; fi
    fi
}
_recovery_rpc() {
    echo "rpc $1 $2" >> calls
    case "$2" in
        eth_getBlockByNumber)
            [[ "$SCENARIO" != original_wins_fee_failure ]] || return 1
            if [[ "$3" == *true* ]]; then
                jq -nc --arg h "${NONCE_OWNER:-0xffff}" --arg s "$SENDER" '{transactions:[{hash:$h,from:$s,nonce:"0x0"}]}'
            elif [[ "$SCENARIO" == fee_reject || "$SCENARIO" == lost_response || "$SCENARIO" == funds_reject || "$SCENARIO" == send_unknown || "$SCENARIO" == missing_low ]]; then
                echo '{"baseFeePerGas":"0xc8","number":"0x10"}'
            else echo '{"baseFeePerGas":"0x32","number":"0x10"}'; fi ;;
        eth_gasPrice) echo '"0x64"' ;;
        eth_maxPriorityFeePerGas) echo '"0x1"' ;;
        eth_getBalance)
            if [[ "$SCENARIO" == funds ]]; then echo '"0x1"'
            else echo '"0xde0b6b3a7640000"'; fi ;;
        eth_getTransactionCount)
            if [[ "$SCENARIO" == nonce_* ]]; then echo '"0x1"'; else echo '"0x0"'; fi ;;
        eth_blockNumber) echo '"0x10"' ;;
        eth_getTransactionReceipt)
            if [[ "$SCENARIO" == nonce_own ]]; then
                jq -nc --arg h "$ORIGINAL" '{transactionHash:$h,blockNumber:"0x10",status:"0x1"}'
            else echo null; fi ;;
        eth_getTransactionByHash)
            if [[ "$SCENARIO" == lost_response ]]; then
                jq -nc --arg h "$(jq -r '.[0]' <<< "$3")" '{hash:$h,blockNumber:null}'
            else return 1; fi ;;
        eth_sendRawTransaction)
            echo send >> sends
            if [[ "$SCENARIO" == fee_reject ]]; then
                echo '{"code":-32000,"message":"replacement transaction underpriced"}'; return 2
            elif [[ "$SCENARIO" == lost_response || "$SCENARIO" == send_unknown ]]; then return 1
            elif [[ "$SCENARIO" == funds_reject ]]; then
                echo '{"code":-32000,"message":"insufficient funds"}'; return 2
            else cast keccak "$(jq -r '.[0]' <<< "$3")" | jq -R .; fi ;;
        *) echo "unexpected method $2" >&2; return 99 ;;
    esac
}
SENDER=$(_recovery_decode "$(cat jobs/job/rawtxs.txt)" | jq -r .signer)
'''


class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = subprocess.check_output([
            "cast", "mktx", "--private-key", KEY, "--chain", "1", "--nonce", "0",
            "--gas-limit", "21000", "--gas-price", "100", "--priority-gas-price", "1",
            "0x1111111111111111111111111111111111111111", "0x"], text=True).strip()
        cls.hash = subprocess.check_output(["cast", "keccak", cls.raw], text=True).strip()

    def run_recovery(self, scenario="missing", actions="_recover_pending pending.csv front\n"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            job = root / "jobs/job"
            job.mkdir(parents=True)
            (job / "rawtxs.txt").write_text(self.raw + "\n")
            (job / "txs.txt").write_text(self.hash + "\n")
            for name in ("sent", "pending"):
                (root / f"{name}.csv").write_text(f"job,L1,{self.hash}\n")
            (root / "wallets.csv").write_text(f"job,address,key\njob,unused,{KEY}\n")
            shell = 'set -euo pipefail\ncd "$TEST_ROOT"\nsource "$RECOVERY"\n' + function("_remove_mined") + RPC + actions + '\n_recovery_report .\n'
            result = subprocess.run(["bash", "-c", shell], capture_output=True, text=True, timeout=30,
                                    env={"PATH": os.environ["PATH"], "TEST_ROOT": directory,
                                         "RECOVERY": str(E2E / "lib/staged-recovery.sh"),
                                         "SCENARIO": scenario, "ORIGINAL": self.hash})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "", result.stdout + result.stderr)
            files = {str(p.relative_to(root)): p.read_text() for p in root.rglob("*") if p.is_file()}
            return result, files, json.loads(files.get("sent.replacements.json", "[]"))

    def test_missing_is_marked_without_resending_including_resume(self):
        result, files, entries = self.run_recovery(actions='''
_recover_pending pending.csv front
_recover_pending pending.csv front --reconcile-only
_recover_pending pending.csv front
_recovery_all_stopped pending.csv || exit 9
''')
        self.assertNotIn("sends", files)
        self.assertTrue(entries[0]["disappeared"])
        self.assertIn("disappeared tx", entries[0]["stop_retry"])
        self.assertIn("DISAPPEARED TESTS (1 transaction(s))", result.stdout)
        self.assertIn("DISAPPEARED", result.stdout)
        self.assertIn("Tx: " + self.hash, result.stdout)

    def test_missing_does_not_require_previous_resend_history(self):
        _, files, entries = self.run_recovery(actions='''
echo "[trigger][L1] job=job hash=$ORIGINAL not visible in pool/front; rebroadcasting same nonce=0" > recovery.log
_recover_pending pending.csv front
''')
        self.assertNotIn("sends", files)
        self.assertIn("disappeared tx", entries[0]["stop_retry"])

    def test_two_immediate_fee_increases_then_fail(self):
        _, files, entries = self.run_recovery("fee_reject")
        self.assertEqual(files["sends"].count("send"), 2)
        self.assertEqual(entries[0]["fee_bumps"], 2)
        self.assertIn("two fee increases rejected", entries[0]["stop_retry"])
        self.assertFalse(entries[0].get("disappeared", False))
        self.assertEqual(len(entries[0]["variants"]), 3)

    def test_visible_low_fees_and_lost_response_are_reconciled(self):
        _, files, entries = self.run_recovery("lost_response")
        self.assertEqual(entries[0]["fee_bumps"], 1)
        self.assertFalse(entries[0].get("disappeared", False))
        self.assertNotIn("stop_retry", entries[0])
        self.assertNotEqual(entries[0]["current"], self.hash)
        self.assertEqual(files["jobs/job/txs.txt"].strip(), entries[0]["current"])
        decoded = []
        for raw in (self.raw, files["jobs/job/rawtxs.txt"].strip()):
            value = json.loads(subprocess.check_output(["cast", "decode-transaction", raw], text=True))
            decoded.append(json.loads(value) if isinstance(value, str) else value)
        for field in ("signer", "type", "chainId", "nonce", "gas", "to", "value", "input", "accessList"):
            self.assertEqual(decoded[0].get(field), decoded[1].get(field), field)

    def test_insufficient_funds_finishes_with_eth_shortfall(self):
        _, files, entries = self.run_recovery("funds")
        self.assertNotIn("sends", files)
        self.assertIn("shortfall=", entries[0]["stop_retry"])
        self.assertIn("ETH", entries[0]["stop_retry"])

    def test_explicit_funding_rejection_does_not_wait(self):
        _, files, entries = self.run_recovery("funds_reject")
        self.assertEqual(files["sends"].count("send"), 1)
        self.assertIn("insufficient funds", entries[0]["stop_retry"])

    def test_healthy_visible_transaction_stops_at_expiry(self):
        _, files, entries = self.run_recovery("held", '_recover_pending pending.csv front --expire\n')
        self.assertNotIn("sends", files)
        self.assertIn("non-mined valid tx", entries[0]["stop_retry"])

    def test_uncertain_send_gets_one_status_check_and_fails(self):
        _, files, entries = self.run_recovery("send_unknown")
        self.assertEqual(files["sends"].count("send"), 1)
        self.assertEqual(files["calls"].count("rpc front1 eth_getTransactionByHash"), 1)
        self.assertIn("RPC status error", entries[0]["stop_retry"])

    def test_failed_receipt_lookup_gets_one_recheck_per_endpoint(self):
        _, files, entries = self.run_recovery("rpc_failure")
        self.assertEqual(files["calls"].count("lookup front1 eth_getTransactionReceipt"), 2)
        self.assertEqual(files["calls"].count("lookup direct1 eth_getTransactionReceipt"), 2)
        self.assertNotIn("sends", files)
        self.assertIn("RPC status error", entries[0]["stop_retry"])

    def test_original_wins_before_optional_pool_or_fee_failures(self):
        for scenario in ("original_wins_pool_failure", "original_wins_fee_failure"):
            with self.subTest(scenario=scenario):
                _, files, entries = self.run_recovery("lost_response", f'''
_recover_pending pending.csv front
SCENARIO={scenario}
_recover_pending pending.csv front
''')
                self.assertEqual(files["sends"].count("send"), 1)
                self.assertEqual(entries[0]["fee_bumps"], 1)
                self.assertEqual(entries[0]["current"], self.hash)
                self.assertEqual(files["pending.csv"], "")
                self.assertIn(self.hash, files["mined.csv"])
                self.assertEqual(files["jobs/job/rawtxs.txt"].strip(), self.raw)
                self.assertNotIn("stop_retry", entries[0])

    def test_one_receipt_survives_another_endpoint_failure(self):
        _, files, entries = self.run_recovery("partial_receipt_failure")
        self.assertEqual(files["pending.csv"], "")
        self.assertIn(self.hash, files["mined.csv"])
        self.assertNotIn("stop_retry", entries[0])

    def test_confirmed_competing_nonce_reports_hash(self):
        _, files, entries = self.run_recovery("nonce_other")
        self.assertNotIn("sends", files)
        self.assertIn("nonce used by another transaction", entries[0]["stop_retry"])
        self.assertIn("0xffff", entries[0]["stop_retry"])

    def test_own_consumed_nonce_is_reconciled(self):
        _, files, entries = self.run_recovery("nonce_own", 'NONCE_OWNER=$ORIGINAL\n_recover_pending pending.csv front\n')
        self.assertEqual(files["pending.csv"], "")
        self.assertNotIn("sends", files)
        self.assertNotIn("stop_retry", entries[0])

    def test_reconcile_only_repairs_interrupted_file_updates_without_sending(self):
        _, files, entries = self.run_recovery("lost_response", '''
_recover_pending pending.csv front
# Simulate a crash after journaling the replacement but before all file updates.
printf '%s\\n' "$ORIGINAL" > jobs/job/txs.txt
jq -r --arg h "$ORIGINAL" '.[0].variants[$h]' sent.replacements.json > jobs/job/rawtxs.txt
printf 'job,L1,%s\\n' "$ORIGINAL" > sent.csv
cp sent.csv pending.csv
_recover_pending pending.csv front --reconcile-only
''')
        self.assertEqual(files["sends"].count("send"), 1)
        self.assertEqual(files["jobs/job/txs.txt"].strip(), entries[0]["current"])
        self.assertIn(entries[0]["current"], files["pending.csv"])
        self.assertNotEqual(entries[0]["current"], self.hash)

    def test_deploy_wave_uses_direct_rpc_and_preserves_chain_prefix(self):
        _, files, _ = self.run_recovery(actions='''
mv jobs/job/txs.txt jobs/job/deploy-hashes-wave1.txt
sed 's/^/L1 /' jobs/job/rawtxs.txt > jobs/job/deploytxs-wave1.txt
mv sent.csv deploy-sent-wave1.csv
mv pending.csv deploy-pending-wave1.csv
_recover_pending deploy-pending-wave1.csv direct
_recover_pending deploy-pending-wave1.csv direct
''')
        entries = json.loads(files["deploy-sent-wave1.replacements.json"])
        self.assertNotIn("sends", files)
        self.assertNotIn("front1", files["calls"])
        self.assertEqual(files["jobs/job/deploytxs-wave1.txt"].strip(), "L1 " + self.raw)
        self.assertIn("disappeared tx", entries[0]["stop_retry"])

    def test_missing_does_not_trigger_fee_replacement(self):
        _, files, entries = self.run_recovery("missing_low")
        self.assertNotIn("sends", files)
        self.assertNotIn("eth_gasPrice", files["calls"])
        self.assertTrue(entries[0]["disappeared"])

    def test_disappeared_summary_tracks_late_mining(self):
        result, files, entries = self.run_recovery(actions="_recover_pending pending.csv front\nSCENARIO=partial_receipt_failure\n_recover_pending pending.csv front --reconcile-only\n")
        self.assertNotIn("sends", files)
        self.assertEqual(files["pending.csv"], "")
        self.assertTrue(entries[0]["disappeared"])
        self.assertIn("MINED LATER", result.stdout)

    def test_fees_round_up_ten_percent_and_cover_current_market(self):
        result = subprocess.run(["bash", "-c", 'source "$1"; _recovery_fees 2 100 10 0 0 0; _recovery_fees 0 101 101 200 250 0',
                                 "test", str(E2E / "lib/staged-recovery.sh")], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ["0 110 11", "1 400 0"])


if __name__ == "__main__":
    unittest.main()
