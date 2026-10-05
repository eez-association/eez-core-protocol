"""Exercise the complete setup entry point with fake RPC/Foundry commands."""
import unittest

from rpc_fixtures import E2E, RpcFixture


class SetupTests(RpcFixture):
    def run_setup(self, initial_balance):
        script = r'''
forge() { echo UNEXPECTED_FORGE >> "$CALLS"; return 99; }
timeout() { shift; "$@"; }
cast() {
    case "$1" in
        to-wei) echo 100 ;;
        from-wei) echo "$2" ;;
        wallet) echo 0x4444444444444444444444444444444444444444 ;;
        balance)
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
        result = self.run_bash(script, E2E / "run/network/setup.sh", self.env_file,
                               BALANCE_COUNT=str(self.root / "balance-count"),
                               INITIAL_BALANCE=str(initial_balance))
        self.assert_ok(result)
        log = self.calls.read_text()
        self.assertEqual(log.count("RPC front1 eez_composerInfo"), 1)
        self.assertIn("RPC l1 eth_chainId", log)
        self.assertIn("RPC l2 eth_chainId", log)
        self.assertNotIn("UNEXPECTED", log)
        factory_lines = [line for line in log.splitlines() if "0x4e59b44847b379578588920cA78FbF26c0B4956C" in line]
        self.assertEqual(len(factory_lines), 2)
        self.assertIn("--rpc-url l1", factory_lines[0])
        self.assertIn("--rpc-url l2", factory_lines[1])
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

    def test_funded_wallet_skips_bridge_and_checks_both_factories(self):
        self.assertNotIn("SEND", self.run_setup(100))

    def test_bridges_only_deficit_once_before_checking_factories(self):
        log = self.run_setup(40)
        sends = [line for line in log.splitlines() if line.startswith("SEND")]
        self.assertEqual(len(sends), 1)
        self.assertIn("--value 60", sends[0])
        self.assertIn("--rpc-url front1", sends[0])


if __name__ == "__main__":
    unittest.main()
