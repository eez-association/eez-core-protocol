"""Offline runner checks: real Foundry signing, mocked network, no chain.env access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "script/balancer/run.sh"
KEY = "0x" + "1".zfill(64)  # Public test key, never the user's credentials.
HARNESS = r'''
source "$RUNNER"
RUN_DIR=$TEST_DIR
# Synthetic fixture addresses only; never read real deployment settings.
BALANCER_TOKEN=0x6666666666666666666666666666666666666666
BALANCER_VAULT=0x7777777777777777777777777777777777777777
BALANCER_L1_BRIDGE=0x8888888888888888888888888888888888888888
BALANCER_L2_BRIDGE=0x9999999999999999999999999999999999999999
load_balancer_addresses
PK=$TEST_KEY
WALLET=$("$REAL_CAST" wallet address --private-key "$PK")
MAX_FEE_WEI=2000000000000000
L1_RPC=direct1 L2_RPC=direct2 L1_FRONT=front1 L2_FRONT=front2
FOUNDRY_BROADCAST=$RUN_DIR/broadcast
jq -n --arg wallet "$WALLET" '{wallet:$wallet,executor:"0x1111111111111111111111111111111111111111",borrower:"0x2222222222222222222222222222222222222222"}' > "$RUN_DIR/state.json"
forge() {
    printf 'forge %s\n' "$*" >> "$RUN_DIR/calls"
    [[ "$*" != *--broadcast* ]] || return 90
}
cast() {
    case "$1" in
        call)
            case "$3" in
                'nft()(address)') echo 0x3333333333333333333333333333333333333333 ;;
                'hasClaimed(address)(bool)') if [[ "$SCENARIO" == already_claimed ]]; then echo true; else echo false; fi ;;
                'availableLoan()(uint256)')
                    case "$SCENARIO" in
                        low_liquidity) echo 12499999999 ;;
                        large_liquidity) echo 1000000000000000000000000 ;;
                        *) echo '40000000000 [4e10]' ;;
                    esac ;;
                *) return 91 ;;
            esac ;;
        nonce)
            [[ "$SCENARIO" != nonce_failure ]] || return 42
            if [[ "$SCENARIO" == legacy_ready ]]; then echo 5;
            elif [[ "${!#}" == front2 ]]; then echo 7; else echo 5; fi ;;
        gas-price)
            if [[ "$SCENARIO" == excessive_fee ]]; then echo 1000000000; else echo 100; fi ;;
        balance) echo 1000000000000000000 ;;
        block-number) echo 100 ;;
        rpc)
            [[ "$2" == eth_sendRawTransaction && "${!#}" == front2 ]] || return 92
            echo 'SEND front2' >> "$RUN_DIR/calls"
            [[ "$SCENARIO" != lost_response ]] || return 43
            "$REAL_CAST" keccak "$3" | jq -R . ;;
        decode-transaction)
            if [[ "$SCENARIO" == wrong_signer ]]; then
                "$REAL_CAST" "$@" | jq 'if type=="string" then fromjson else . end | .signer="0x4444444444444444444444444444444444444444"'
            else "$REAL_CAST" "$@"; fi ;;
        estimate|estimate-gas) echo 'FORBIDDEN GAS ESTIMATE' >> "$RUN_DIR/calls"; return 93 ;;
        mktx)
            [[ "$*" != *--rpc-url* ]] || return 94
            "$REAL_CAST" "$@" ;;
        *) "$REAL_CAST" "$@" ;;
    esac
}
'''


class RunnerTests(unittest.TestCase):
    def run_case(self, scenario="success", action="trigger", directory=None):
        env = {"PATH": os.environ["PATH"], "RUNNER": str(RUNNER), "TEST_DIR": str(directory),
               "TEST_KEY": KEY, "REAL_CAST": shutil.which("cast"), "SCENARIO": scenario}
        return subprocess.run(["bash", "-c", HARNESS + "\n" + action], env=env,
                              text=True, capture_output=True, timeout=25)

    def test_real_signature_fixed_gas_and_only_l2_front(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case(directory=d)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            raw = (Path(d) / "trigger.raw").read_text().strip()
            tx = json.loads(subprocess.check_output(["cast", "decode-transaction", raw], text=True))
            if isinstance(tx, str):
                tx = json.loads(tx)
            self.assertEqual(int(tx["chainId"], 16), 696990)
            self.assertEqual(int(tx["gas"], 16), 2_500_000)
            self.assertEqual(int(tx["nonce"], 16), 7)
            self.assertEqual(int(tx["value"], 16), 0)
            expected = subprocess.check_output(["cast", "calldata", "start(uint256)", "32000000000"], text=True).strip()
            self.assertEqual(tx["input"], expected)
            state = json.loads((Path(d) / "state.json").read_text())
            self.assertEqual(state["observed_available_loan"], "40000000000")
            self.assertEqual(state["requested_amount"], "32000000000")
            calls = (Path(d) / "calls").read_text()
            self.assertEqual(calls.count("SEND front2"), 1)
            self.assertNotIn("FORBIDDEN", calls)
            self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_buffer_below_nft_minimum_never_signs_or_sends(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case("low_liquidity", directory=d)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("80% loan request is below NFT minimum", result.stderr)
            self.assertFalse((Path(d) / "trigger.raw").exists())
            self.assertNotIn("SEND", (Path(d) / "calls").read_text())

    def test_amount_calculation_exceeds_bash_integer_range(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case("large_liquidity", directory=d)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            state = json.loads((Path(d) / "state.json").read_text())
            self.assertEqual(state["requested_amount"], "800000000000000000000000")

    def test_legacy_trigger_signs_minimum_and_records_variable_amount_mode(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case("legacy_ready", action="trigger legacy", directory=d)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            state = json.loads((Path(d) / "state.json").read_text())
            self.assertEqual(state["loan_mode"], "legacy")
            self.assertEqual(state["requested_minimum"], "10000000000")
            self.assertNotIn("requested_amount", state)
            tx = json.loads(subprocess.check_output(["cast", "decode-transaction", (Path(d) / "trigger.raw").read_text().strip()], text=True))
            if isinstance(tx, str): tx = json.loads(tx)
            expected = subprocess.check_output(["cast", "calldata", "start(uint256)", "10000000000"], text=True).strip()
            self.assertEqual(tx["input"], expected)

    def test_legacy_trigger_refuses_pending_wallet_transaction(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case(action="trigger legacy", directory=d)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Pending wallet transaction", result.stderr)
            self.assertFalse((Path(d) / "trigger.raw").exists())

    def test_duplicate_trigger_stops_before_second_send(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case(directory=d, action="trigger\ntrigger")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already signed/submitted", result.stderr)
            self.assertEqual((Path(d) / "calls").read_text().count("SEND front2"), 1)

    def test_unknown_submission_is_not_retried(self):
        with tempfile.TemporaryDirectory() as d:
            first = self.run_case("lost_response", directory=d)
            self.assertNotEqual(first.returncode, 0)
            self.assertTrue((Path(d) / "trigger.hash").exists())
            second = self.run_case(directory=d)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual((Path(d) / "calls").read_text().count("SEND front2"), 1)

    def test_fee_nonce_and_signature_failures_never_send(self):
        for scenario in ("excessive_fee", "nonce_failure", "wrong_signer"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as d:
                result = self.run_case(scenario, directory=d)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("SEND", (Path(d) / "calls").read_text())

    def test_fee_balance_precision_and_boundaries(self):
        for balance, expected in [("1999999999999999", 1), ("2000000000000000", 0),
                                  ("1000000000000000000000000000000000", 0)]:
            with self.subTest(balance=balance), tempfile.TemporaryDirectory() as d:
                result = self.run_case(directory=d, action=f"fee_check 2500000 800000000 {balance}")
                self.assertEqual(bool(result.returncode), bool(expected), result.stdout + result.stderr)

    def test_redacts_credentials_from_command_logs(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_case(directory=d, action='safe_run "$RUN_DIR/redacted" printf "%s %s\\n" "$PK" "$L1_RPC"')
            self.assertEqual(result.returncode, 0)
            self.assertEqual((Path(d) / "redacted").read_text().strip(), "[redacted] [redacted]")

    def test_stage_refuses_uncertain_prior_broadcast(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "deploy-l2.started").write_text("{}")
            result = self.run_case(directory=d, action="stage deploy-l2 direct2 696990 'deployL2(address)' \"$WALLET\"")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already attempted", result.stderr)
            self.assertFalse((Path(d) / "calls").exists())


if __name__ == "__main__":
    unittest.main()
