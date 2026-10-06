"""Exercise settlement destination checks and the real network calldata phase."""
import os
from pathlib import Path
import subprocess
import unittest

E2E = Path(__file__).resolve().parents[1]
REGISTRY = "0x" + "a" * 40
BATCHER = "0x" + "b" * 40
OTHER = "0x" + "c" * 40
RUNNER = (E2E / "lib/network-scenario.sh").read_text()
CALLDATA_PHASE = RUNNER.split("_L1_TABLES_PRESENT=false", 1)[1].split("\n# ═", 1)[0]
CALLDATA_PHASE = "_L1_TABLES_PRESENT=false" + CALLDATA_PHASE


class SettlementTargetTests(unittest.TestCase):
    def run_check(self, *, phase=False, **settings):
        env = {
            "PATH": os.environ["PATH"], "TARGET": BATCHER, "BOUND": REGISTRY,
            "ROLLUPS": REGISTRY, "RPC": "fixture-rpc", "EEZ_POST_BATCHER": "",
            "HELPER": str(E2E / "lib/settlement-target.sh"), **settings,
        }
        script = r"""
set -euo pipefail
source "$HELPER"
cast() {
    case "$1" in
        call)
            echo "GETTER $*" >&2
            [[ "${GETTER_FAIL:-0}" != 1 ]] || return 1
            echo "$BOUND" ;;
        tx)
            case "$3" in
                input) echo "${INPUT:-0xe4a480e400}" ;;
                to) echo "$TARGET" ;;
                *) return 99 ;;
            esac ;;
        receipt) echo 123 ;;
        *) return 99 ;;
    esac
}
forge() {
    echo "NOTE: DECODE $*"
    if [[ "${DECODE_FAIL:-0}" == 1 ]]; then echo 'Error: invalid calldata'; return 1; fi
    echo 'PASS: posted entries and execution evidence match'
}
"""
        if phase:
            script += r"""
EXPECTED_L1_TABLE=0x01 EXPECTED_L1_STATIC_TABLE=0x EXPECTED_L1_STEPS=0x
_HAS_COMPUTE=true EXPECTED_L1_CALL_HASHES='[]' L1_BATCH_TX=0xtx
L1_VERIFY='' _CORR_TX='' _TRIGGER_CHAIN="${TRIGGER_CHAIN:-L1}"
_L1_CONTRACT=VerifyL1BatchInRange
if [[ "$_TRIGGER_CHAIN" == L2 ]]; then
    _L1_CONTRACT=VerifyL1SettlementTxsInRange
    _CORR_TX=0xtx
fi
""" + CALLDATA_PHASE + '\necho "FAILED=${FAILED:-false}"\n'
        else:
            script += 'verify_settlement_target "$RPC" 123 "$TARGET" "$ROLLUPS"\n'
        return subprocess.run(["bash", "-c", script], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_direct_registry_needs_no_getter_even_with_pin(self):
        result = self.run_check(TARGET=REGISTRY.upper().replace("0X", "0x"),
                                EEZ_POST_BATCHER=BATCHER, GETTER_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_auto_detects_batcher_at_settlement_block(self):
        result = self.run_check(BOUND=REGISTRY.upper().replace("0X", "0x"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("accepted EEZ batcher", result.stdout)
        self.assertIn("at block 123", result.stdout)

    def test_pin_still_requires_correct_getter(self):
        for settings in ({}, {"BOUND": OTHER}, {"GETTER_FAIL": "1"}):
            with self.subTest(settings=settings):
                result = self.run_check(EEZ_POST_BATCHER=BATCHER, **settings)
                self.assertEqual(result.returncode, 0 if not settings else 1)

    def test_rejects_unpinned_destination_even_with_matching_getter(self):
        result = self.run_check(EEZ_POST_BATCHER=OTHER)
        self.assertEqual(result.returncode, 1)
        self.assertIn("neither ROLLUPS nor EEZ_POST_BATCHER", result.stdout)

    def test_rejects_reverted_malformed_and_wrong_getters(self):
        for settings in ({"GETTER_FAIL": "1"}, {"BOUND": ""},
                         {"BOUND": "0x1234"}, {"BOUND": OTHER}):
            with self.subTest(settings=settings):
                self.assertEqual(self.run_check(**settings).returncode, 1)

    def test_getter_uses_historical_block_and_source_rpc(self):
        # Override cast to assert the exact lookup arguments before returning EEZ.
        script = r"""
source "$1"
cast() {
    [[ "$*" == "call $TARGET eez()(address) --rpc-url fixture-rpc --block 123" ]] || return 1
    echo "$ROLLUPS"
}
verify_settlement_target fixture-rpc 123 "$TARGET" "$ROLLUPS"
"""
        result = subprocess.run(["bash", "-c", script, "bash", str(E2E / "lib/settlement-target.sh")],
                                env={"PATH": os.environ["PATH"], "TARGET": BATCHER,
                                     "ROLLUPS": REGISTRY}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_calldata_phase_verifies_both_destinations_and_directions(self):
        for target in (REGISTRY, BATCHER):
            for chain in ("L1", "L2"):
                with self.subTest(target=target, chain=chain):
                    result = self.run_check(phase=True, TARGET=target, TRIGGER_CHAIN=chain)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("FAILED=false", result.stdout)
                    self.assertIn("Matched settlement tx 0xtx", result.stdout)
                    self.assertIn('DECODE script', result.stdout)
                    self.assertIn(f"0xe4a480e400 {REGISTRY} 0x01 0x 0x false", result.stdout)

    def test_rejected_or_missing_candidates_cannot_pass_in_either_direction(self):
        for settings in ({"BOUND": OTHER}, {"GETTER_FAIL": "1"}, {"INPUT": "0x"},
                         {"EEZ_POST_BATCHER": OTHER}):
            for chain in ("L1", "L2"):
                with self.subTest(settings=settings, chain=chain):
                    result = self.run_check(phase=True, TRIGGER_CHAIN=chain, **settings)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("FAILED=true", result.stdout)
                    self.assertIn("L1 BATCH CALLDATA VERIFICATION FAILED", result.stdout)
                    self.assertNotIn("DECODE", result.stdout)

    def test_matching_getter_does_not_bypass_calldata_verification(self):
        result = self.run_check(phase=True, DECODE_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAILED=true", result.stdout)
        self.assertIn("invalid calldata", result.stdout)


if __name__ == "__main__":
    unittest.main()
