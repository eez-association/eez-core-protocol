"""Infrastructure deployment must validate registration output and retain errors."""
import unittest

from rpc_fixtures import E2E, RpcFixture


class DeployInfraTests(RpcFixture):
    def run_deploy(self, *, rollup_id="2", fail="", requested=""):
        self.calls.write_text("")
        return self.run_bash(r"""
source "$1"
forge() {
    case "$2" in
        *:DeployEEZL1)
            echo L1 >> "$CALLS"
            if [[ "$FAIL_DEPLOY" == L1 ]]; then echo 'L1 deployment diagnostic'; return 1; fi
            echo 'L1 successful deployment diagnostic'
            echo ROLLUPS=registry
            echo PROOF_SYSTEM=proof
            echo L2_MANAGER=manager
            [[ -z "$REGISTERED_ID" ]] || echo "L2_ROLLUP_ID=$REGISTERED_ID"
            return 0 ;;
        *:DeployManagerL2)
            echo "L2 $*" >> "$CALLS"
            if [[ "$FAIL_DEPLOY" == L2 ]]; then echo 'L2 deployment diagnostic'; return 1; fi
            echo MANAGER_L2=l2manager ;;
        *) return 99 ;;
    esac
}
deploy_infra l1 fake-key l2 "$REQUESTED_ID"
bash -c 'echo "EXPORTED_ID=$L2_ROLLUP_ID"'
""", E2E / "lib/E2EBase.sh", REGISTERED_ID=rollup_id, FAIL_DEPLOY=fail, REQUESTED_ID=requested)

    def test_assigned_id_is_exported_and_used_for_l2_deployment(self):
        result = self.run_deploy()
        self.assert_ok(result)
        self.assertIn("EXPORTED_ID=2", result.stdout)
        self.assertIn("--sig run(uint64,address,address) 2 ", self.calls.read_text())

    def test_invalid_registration_stops_before_l2_and_keeps_diagnostics(self):
        for value in ("", "0", "-1", "garbage", "18446744073709551616"):
            with self.subTest(value=value):
                result = self.run_deploy(rollup_id=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("valid L2_ROLLUP_ID", result.stderr)
                self.assertIn("L1 successful deployment diagnostic", result.stderr)
                self.assertEqual(self.calls.read_text().splitlines(), ["L1"])

    def test_failed_deployments_print_captured_forge_error(self):
        for side in ("L1", "L2"):
            with self.subTest(side=side):
                result = self.run_deploy(fail=side)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{side} deployment diagnostic", result.stderr)
                if side == "L1":
                    self.assertEqual(self.calls.read_text().splitlines(), ["L1"])

    def test_requested_id_is_compared_as_canonical_decimal(self):
        result = self.run_deploy(requested="002")
        self.assert_ok(result)
        self.assertIn("EXPORTED_ID=2", result.stdout)

    def test_requested_id_mismatch_stops_before_l2_deployment(self):
        result = self.run_deploy(requested="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees with registration", result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["L1"])


if __name__ == "__main__":
    unittest.main()
