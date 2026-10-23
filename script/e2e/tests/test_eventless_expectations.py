"""Structured expectation parsing and configuration failures without RPC access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / "lib"


class EventlessExpectationTests(unittest.TestCase):
    def run_shell(self, script, value=""):
        return subprocess.run(
            ["bash", "-c", 'source "$LIB/E2EBase.sh"\n' + script],
            env={**os.environ, "LIB": str(LIB), "TEST_VALUE": value},
            text=True, capture_output=True, timeout=10)

    def test_multiple_keys_with_spaces_are_preserved_and_canonicalized(self):
        keys = ["0x" + "A" * 64, "0x" + "b" * 64]
        result = self.run_shell('extract_expected_outputs "$TEST_VALUE" >/dev/null; printf "%s\\n" "$EVENTLESS_L1_CALL_HASHES"',
                                "  EVENTLESS_L1_CALL_HASHES=" + json.dumps(keys))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [key.lower() for key in keys])

    def test_malformed_and_duplicate_exports_are_configuration_errors(self):
        key = "0x" + "1" * 64
        values = ["", '["' + key + '",', "{}", "[1]", '["0x12"]',
                  '[]\nEVENTLESS_L1_CALL_HASHES=[]']
        for value in values:
            with self.subTest(value=value):
                result = self.run_shell('extract_expected_outputs "$TEST_VALUE" >/dev/null; printf "%s\\n" "$EVENTLESS_L1_CALL_HASHES"',
                                       "EVENTLESS_L1_CALL_HASHES=" + value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR: EVENTLESS_L1_CALL_HASHES", result.stderr)

    def test_absent_export_clears_previous_keys(self):
        result = self.run_shell('''
extract_expected_outputs "EVENTLESS_L1_CALL_HASHES=$TEST_VALUE" >/dev/null
extract_expected_outputs "other output" >/dev/null
printf '%s\\n' "$EVENTLESS_L1_CALL_HASHES"
''', json.dumps(["0x" + "a" * 64]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[]")

    def test_both_static_tables_normalize_empty_encoding_only(self):
        result = self.run_shell('''empty_table=$(cast abi-encode 'table(uint256[])' '[]')
extract_expected_outputs "EXPECTED_L1_STATIC_TABLE=$empty_table
EXPECTED_L2_STATIC_TABLE=$empty_table" >/dev/null
printf '%s %s\\n' "$EXPECTED_L1_STATIC_TABLE" "$EXPECTED_L2_STATIC_TABLE"
extract_expected_outputs 'EXPECTED_L1_STATIC_TABLE=0x1234
EXPECTED_L2_STATIC_TABLE=0x5678' >/dev/null
printf '%s %s\\n' "$EXPECTED_L1_STATIC_TABLE" "$EXPECTED_L2_STATIC_TABLE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["0x 0x", "0x1234 0x5678"])

    def test_preflight_uses_forge_array_syntax_without_json_quotes(self):
        key = "0x" + "1" * 64
        result = self.run_shell('''forge() {
    printf '%s\\n' "${@: -1}" >&2
    [[ "${@: -1}" == "[$TEST_VALUE]" ]]
}
validate_l1_eventless_expectations 0x1234 "[\\\"$TEST_VALUE\\\"]"
''', key)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_local_invalid_configuration_stops_before_candidate_discovery(self):
        result = self.run_shell('''forge() {
    [[ "$*" == *'validateExpectations(bytes,bytes32[])'* ]] || { echo UNEXPECTED_DISCOVERY; return 1; }
    echo 'Error: duplicate eventless L1 key'
    return 1
}
cast() { echo UNEXPECTED_RPC; return 1; }
if verify_l1_calldata rpc 1 registry 0x1234 0x 0x '["0x01"]'; then exit 9; fi
printf '%s\\n' "$VERIFY_OUT"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("invalid EVENTLESS_L1_CALL_HASHES configuration", result.stdout)
        self.assertIn("duplicate eventless L1 key", result.stdout)
        self.assertNotIn("UNEXPECTED", result.stdout)

    def test_eventless_opt_in_requires_persisted_state_check(self):
        with tempfile.TemporaryDirectory() as directory:
            scenario = Path(directory) / "Scenario.sol"
            scenario.write_text("contract ComputeExpected {}\n")
            script = 'EVENTLESS_L1_CALL_HASHES=\'["0x01"]\'\nrequire_eventless_l1_state_check "$TEST_VALUE"'
            result = self.run_shell(script, str(scenario))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("require VerifyNetwork", result.stderr)
            for separator in (" ", "\t", "\n"):
                with self.subTest(separator=separator):
                    scenario.write_text(f"contract VerifyNetwork{separator}{{}}\n")
                    result = self.run_shell(script, str(scenario))
                    self.assertEqual(result.returncode, 0, result.stderr)
