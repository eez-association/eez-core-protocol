"""Local state verification must inspect mined state and fail on missing evidence."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

E2E = Path(__file__).resolve().parents[1]
RUNNER = (E2E / "lib/local-scenario.sh").read_text()
HARNESS = r"""
source "$LIB/E2EBase.sh"
start_anvil() { printf 'ANVIL %s %s\n' "$1" "${4:-default}" >> "$CALLS"; }
deploy_infra() { ROLLUPS=registry; PROOF_SYSTEM=proof; L2_MANAGER=manager; MANAGER_L2=manager; }
deploy_contracts() { :; }
execute_l1_same_block() { echo MINED >> "$CALLS"; }
print_broadcast_txs() { :; }
trace_failed_txs() { :; }
decode_block() { :; }
verify_l1_batch() {
    echo EVENTS >> "$CALLS"
    VERIFY_OUT="PASS: committed call identity"
    [[ "${5:-0x}" == 0x ]]
}
verify_l1_zero_hash() {
    echo ZERO_HASH_EVENTS >> "$CALLS"
    [[ "${6:-0x}" == 0x ]] || { VERIFY_OUT="FAIL: unexpected table in event check"; return 1; }
    if [[ "$FAIL_ZERO_HASH" == 1 ]]; then
        VERIFY_OUT="FAIL: missing declared zero-hash completion"
        return 1
    fi
    VERIFY_OUT="PASS: declared zero-hash completions"
}
verify_l1_calldata() { echo CALLDATA >> "$CALLS"; VERIFY_OUT="PASS: posted row with no events"; }
verify_l2_absent() { VERIFY_OUT="PASS: no delivery"; }
cast() {
    case "$1" in
        wallet) echo sender ;;
        block-number) echo 3 ;;
        *) return 99 ;;
    esac
}
forge() {
    case "$2" in
        *:ComputeExpected)
            if [[ "$EXPECTATION_MODE" == zero_hash ]]; then
                echo "EXPECTED_L1_TABLE=$EXPECTED_TABLE"
                echo 'EXPECTED_L1_HASHES=[0x3333333333333333333333333333333333333333333333333333333333333333]'
                return 0
            fi
            if [[ "$EXPECTATION_MODE" != hash_only ]]; then
                echo EXPECTED_L1_TABLE=0x01
                echo 'EVENTLESS_L1_CALL_HASHES=["0x1111111111111111111111111111111111111111111111111111111111111111"]'
                echo 'ABSENT_L2_HASHES=[0x1111111111111111111111111111111111111111111111111111111111111111]'
            fi
            if [[ "$EXPECTATION_MODE" != eventless ]]; then
                echo 'EXPECTED_L1_CALL_HASHES=[0x2222222222222222222222222222222222222222222222222222222222222222]'
            fi
            ;;
        *:VerifyNetwork|*:VerifyNetworkL2)
            local name="${2##*:}"
            printf 'STATE %s %s\n' "$name" "$*" >> "$CALLS"
            if [[ "${FAIL_STATE:-}" == "$name" ]]; then
                echo "Error: missing persisted trigger evidence"
                return 1
            fi
            echo "PASS: $name persisted state"
            ;;
        *) return 99 ;;
    esac
}
"""


class LocalScenarioTests(unittest.TestCase):
    def run_local(self, *, fail_state="", gas_limit=None, compute=True, expectation_mode="eventless",
                  separator=" ", expected_table="0x01", fail_zero_hash=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenario = root / "Scenario.sol"
            contracts = ["Execute", "VerifyNetwork", "VerifyNetworkL2"]
            if compute:
                contracts.append("ComputeExpected")
            source = "".join(f"contract {name}{separator}{{}}\n" for name in contracts)
            if gas_limit is not None:
                source += f"// E2E_LOCAL_L2_BLOCK_GAS_LIMIT: {gas_limit}\n"
            scenario.write_text(source)
            calls = root / "calls"
            script = RUNNER.replace('source "$(dirname "$0")/E2EBase.sh"', HARNESS, 1)
            result = subprocess.run(
                ["bash", "-c", script, "local-scenario", str(scenario)],
                cwd=root, capture_output=True, text=True, timeout=10,
                env={"PATH": os.environ["PATH"], "LIB": str(E2E / "lib"),
                     "CALLS": str(calls), "FAIL_STATE": fail_state, "EXPECTATION_MODE": expectation_mode,
                     "EXPECTED_TABLE": expected_table, "FAIL_ZERO_HASH": "1" if fail_zero_hash else "0"})
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_runs_both_state_checks_after_mining_even_without_l2_delivery(self):
        result, calls = self.run_local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        states = [line for line in calls if line.startswith("STATE ")]
        self.assertEqual(len(states), 2)
        self.assertIn("VerifyNetwork --rpc-url http://localhost:8545 --sender sender", states[0])
        self.assertIn("VerifyNetworkL2 --rpc-url http://localhost:8546 --sender sender", states[1])
        self.assertLess(calls.index("MINED"), calls.index("CALLDATA"))
        self.assertLess(calls.index("CALLDATA"), calls.index(states[0]))

    def test_mixed_entries_leave_completion_checks_to_calldata_verifier(self):
        result, calls = self.run_local(expectation_mode="mixed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(calls.index("EVENTS"), calls.index("CALLDATA"))

    def test_hash_only_scenarios_keep_event_verification(self):
        result, calls = self.run_local(expectation_mode="hash_only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("EVENTS", calls)
        self.assertNotIn("CALLDATA", calls)

    def test_zero_hash_expectations_are_checked_with_or_without_a_table(self):
        empty_table = "0x" + format(32, "064x") + format(0, "064x")
        # Calldata is mocked to pass: even an empty/incomplete table must not
        # suppress a failure for an explicitly declared execution hash.
        for table in ("0x", empty_table, "0x01"):
            for missing in (False, True):
                with self.subTest(table=table, missing=missing):
                    result, calls = self.run_local(
                        expectation_mode="zero_hash", expected_table=table, fail_zero_hash=missing)
                    self.assertEqual(result.returncode, 1 if missing else 0, result.stdout + result.stderr)
                    self.assertIn("ZERO_HASH_EVENTS", calls)
                    if table != "0x":
                        self.assertLess(calls.index("ZERO_HASH_EVENTS"), calls.index("CALLDATA"))
                    else:
                        self.assertNotIn("CALLDATA", calls)
                    if missing:
                        self.assertIn("missing declared zero-hash completion", result.stdout)

    def test_contract_discovery_accepts_braces_tabs_and_line_breaks(self):
        for separator in ("", "\t", "\n"):
            with self.subTest(separator=separator):
                result, calls = self.run_local(separator=separator, fail_state="VerifyNetwork")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VerifyNetwork VERIFICATION FAILED", result.stdout)
                self.assertLess(calls.index("MINED"), calls.index("CALLDATA"))
                self.assertEqual(sum(line.startswith("STATE ") for line in calls), 2)

    def test_unused_eventless_row_cannot_pass_a_failed_persisted_state_check(self):
        for name in ("VerifyNetwork", "VerifyNetworkL2"):
            with self.subTest(name=name):
                result, calls = self.run_local(fail_state=name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("PASS: posted row with no events", result.stdout)
                self.assertIn(f"{name} VERIFICATION FAILED", result.stdout)
                self.assertIn("missing persisted trigger evidence", result.stdout)
                self.assertEqual(sum(line.startswith("STATE ") for line in calls), 2)

    def test_state_checks_also_run_without_compute_expected(self):
        result, calls = self.run_local(compute=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum(line.startswith("STATE ") for line in calls), 2)

    def test_gas_override_is_applied_only_to_l2(self):
        result, calls = self.run_local(gas_limit="60000000")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[:2], ["ANVIL 8545 default", "ANVIL 8546 60000000"])
        result, calls = self.run_local()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[:2], ["ANVIL 8545 default", "ANVIL 8546 default"])

    def test_invalid_or_duplicate_gas_limits_fail_before_starting_anvil(self):
        for limit in ("0", "-1", "invalid", "60000000\n// E2E_LOCAL_L2_BLOCK_GAS_LIMIT: 60000000"):
            with self.subTest(limit=limit):
                result, calls = self.run_local(gas_limit=limit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be one positive decimal integer", result.stdout)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
