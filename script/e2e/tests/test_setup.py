"""Exercise the complete setup entry point with fake RPC/Foundry commands."""
import json
import shutil
import unittest

from rpc_fixtures import E2E, RpcFixture


class SetupTests(RpcFixture):
    def setUp(self):
        super().setUp()
        # Keep quote evidence and locks inside the fixture, away from real runs.
        self.runner = self.root / "script/e2e/run/network/setup.sh"
        self.runner.parent.mkdir(parents=True)
        shutil.copy2(E2E / "run/network/setup.sh", self.runner)
        shutil.copytree(E2E / "lib", self.root / "script/e2e/lib")
        self.env_file.write_text(self.env_file.read_text().replace(
            "fake-key", "0x" + "01".zfill(64)))  # Public test-only key.

    def run_setup(self, initial_balance, reject_quote=False):
        script = r'''
forge() { echo UNEXPECTED_FORGE >> "$CALLS"; return 99; }
timeout() { shift; "$@"; }
cast() {
    case "$1" in
        to-wei) echo 100 ;;
        from-wei) echo "$2" ;;
        wallet|to-dec|decode-transaction|keccak|mktx) command cast "$@" ;;
        chain-id) echo 1 ;;
        nonce) echo 0 ;;
        gas-price) echo 1 ;;
        rpc)
            echo "QUOTE $*" >> "$CALLS"
            [[ "$*" == *eez_quoteFee* ]] || return 99
            [[ "$REJECT_QUOTE" != 1 ]] || { echo 'quote disabled' >&2; return 1; }
            jq -nc --arg expires "$(printf '0x%x' $(($(date +%s) + 300)))" \
                '{version:1,chainId:"0x1",nonce:"0x0",expiresAt:$expires,
                  options:[{type:"0x0",gas:"0x5208",gasPrice:"0x2",estimatedFee:"0xa410",requestHash:("0x"+("a"*64))}]}' ;;
        publish)
            echo "PUBLISH $*" >> "$CALLS"
            command cast decode-transaction "$2" > "$TEST_ROOT/published.json"
            command cast keccak "$2" ;;
        balance)
            if [[ "$*" == *l1* ]]; then echo 1000000000000000000; return; fi
            if [[ -f "$BALANCE_COUNT" ]]; then echo 100
            else touch "$BALANCE_COUNT"; echo "$INITIAL_BALANCE"; fi ;;
        call) echo 0x5555555555555555555555555555555555555555 ;;
        code) echo "CODE $*" >> "$CALLS"; echo 0x6000 ;;
        send) echo "SEND $*" >> "$CALLS"; printf '0x%064d\n' 1 ;;
        receipt) echo '{"status":"0x1"}' ;;
        *) echo "UNEXPECTED_CAST $*" >> "$CALLS"; return 99 ;;
    esac
}
export -f forge timeout cast
bash "$1" 0.1 "$2"
'''
        result = self.run_bash(script, self.runner, self.env_file,
                               BALANCE_COUNT=str(self.root / "balance-count"),
                               INITIAL_BALANCE=str(initial_balance),
                               REJECT_QUOTE=str(int(reject_quote)), TMPDIR=str(self.root))
        if reject_quote:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("eez_quoteFee failed", result.stderr)
        else:
            self.assert_ok(result)
        log = self.calls.read_text()
        self.assertEqual(log.count("RPC front1 eez_composerInfo"), 1)
        self.assertIn("RPC l1 eth_chainId", log)
        self.assertIn("RPC l2 eth_chainId", log)
        self.assertNotIn("UNEXPECTED", log)
        self.assertNotIn("0x4e59b44847b379578588920cA78FbF26c0B4956C", log)
        self.assertIn("ROLLUPS=stale", self.env_file.read_text())
        return log

    def test_chain_mismatch_stops_setup_before_sending(self):
        self.response("l2", "eth_chainId", "0x2")
        result = self.run_bash('''
cast() { echo UNEXPECTED_CAST >> "$CALLS"; return 99; }
forge() { echo UNEXPECTED_FORGE >> "$CALLS"; return 99; }
export -f cast forge
bash "$1" 0.1 "$2"
''', E2E / "run/network/setup.sh", self.env_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees", result.stderr)
        self.assertNotIn("UNEXPECTED", self.calls.read_text())

    def test_funded_wallet_skips_bridge_and_factory_setup(self):
        log = self.run_setup(100)
        for operation in ("SEND", "QUOTE", "PUBLISH"):
            self.assertNotIn(operation, log)

    def test_bridges_only_deficit_without_factory_setup(self):
        log = self.run_setup(40)
        self.assertEqual(log.count("PUBLISH"), 1)
        self.assertIn("eez_quoteFee", log)
        self.assertIn("--rpc-url front1", log)
        self.assertNotIn("SEND", log)
        published = json.loads((self.root / "published.json").read_text())
        if isinstance(published, str):
            published = json.loads(published)
        self.assertEqual(published["to"].lower(), "0x" + "5" * 40)
        self.assertEqual(published["input"], "0x")
        for field, expected in (("value", 60), ("nonce", 0), ("chainId", 1),
                                ("gas", 21000), ("gasPrice", 2)):
            self.assertEqual(int(published[field], 16), expected, field)
        evidence = json.loads((self.root / "tmp/e2e-network/setup-fee-quote-0.json").read_text())
        self.assertEqual(evidence["feeSource"], "composer")
        self.assertEqual(evidence["intent"]["from"].lower(), published["signer"].lower())

    def test_quote_failure_stops_bridge_submission(self):
        log = self.run_setup(40, reject_quote=True)
        self.assertIn("eez_quoteFee", log)
        self.assertNotIn("PUBLISH", log)
        self.assertNotIn("SEND", log)



if __name__ == "__main__":
    unittest.main()
