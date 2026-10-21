"""Setup receipts can move before trigger preparation; use the settled inclusion."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / "lib"
TX = "0x" + "1" * 64
OLD_BLOCK = "0x" + "2" * 64
SECOND_TX = "0x" + "6" * 64

TRANSPORT = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys
root = pathlib.Path(os.environ["TEST_ROOT"])
clock = int((root / "clock").read_text())
mode = os.environ.get("TEST_MODE", "reorg")
args = sys.argv[1:]
payload = args[args.index("--data") + 1]
if payload == "@-":
    payload = sys.stdin.read()
request = json.loads(payload)
def respond(item):
    method, params = item["method"], item["params"]
    with (root / "rpc-calls").open("a") as output:
        output.write(json.dumps([clock, method, params]) + "\n")
    result = None
    if method == "eth_getBlockByNumber":
        if mode == "unsupported" and params[0] == "safe":
            return {"jsonrpc":"2.0", "id":item["id"], "error":{"code":-32602,"message":"unsupported safe"}}
        if mode == "malformed":
            result = {"number":"invalid", "hash":"0x"}
        else:
            number = 9 if params[0] == "safe" and (clock < 1004 or mode == "stalled") else 10
            if mode in ("orphaned", "safe_reorg") and params[0] == "safe":
                number = 10
            if params[0] != "safe":
                number = int(params[0], 16)
            block_hash = "0x" + ("3" if number == 10 else "4") * 64
            if params[0] != "safe" and ((mode == "orphaned" and number == 9) or
                                         (mode == "safe_reorg" and number == 10)):
                block_hash = "0x" + "5" * 64
            result = {"number":hex(number), "hash":block_hash}
    elif method == "eth_getTransactionReceipt":
        if mode != "missing" and clock >= 1002 and not (mode == "missing_second" and params[0] == os.environ["SECOND_TX"]):
            height = 9 if mode in ("orphaned", "safe_reorg") else 10
            result = {"transactionHash":params[0], "blockNumber":hex(height),
                      "blockHash":"0x" + ("3" if height == 10 else "4") * 64,
                      "status":"0x0" if mode == "reverted" else "0x1"}
        if mode == "wrong_hash" and result:
            result["transactionHash"] = "0x" + "9" * 64
    else:
        raise AssertionError(item)
    return {"jsonrpc":"2.0", "id":item["id"], "result":result}
print(json.dumps([respond(item) for item in reversed(request)] if isinstance(request,list) else respond(request)))
'''

COMMANDS = r'''
RPC=l1 L1_RPC=l1 L2_RPC=l2 L1_FRONT=l1 L2_FRONT=l2
SOL=scenario.sol
PK=test-key
date() { cat "$TEST_ROOT/clock"; }
sleep() { echo "$(( $(cat "$TEST_ROOT/clock") + $1 ))" > "$TEST_ROOT/clock"; }
cast() {
    case "$1" in
        wallet) echo 0x1111111111111111111111111111111111111111 ;;
        chain-id) echo 2 ;;
        nonce)
            if (( $(cat "$TEST_ROOT/clock") < 1004 )); then echo 3; else echo 4; fi ;;
        mktx) printf '%s\n' "$*" >> "$TEST_ROOT/signs"; echo 0x1234 ;;
        *) echo "Unexpected cast: $*" >&2; return 99 ;;
    esac
}
forge() {
    if [[ "$*" == *' --broadcast '* ]]; then
        local path="${FOUNDRY_BROADCAST:-broadcast}/scenario.sol/2"
        mkdir -p "$path"
        printf '{"transactions":[{"hash":"%s"}],"receipts":[{"transactionHash":"%s","blockHash":"%s","blockNumber":"0xa","status":"0x1"}]}\n' \
            "$SETUP_TX" "$SETUP_TX" "$OLD_BLOCK" > "$path/run-latest.json"
        if [[ "${TEST_MODE:-}" == missing_second ]]; then
            jq --arg hash "$SECOND_TX" '.transactions += [{hash:$hash}]' "$path/run-latest.json" > "$path/second.json"
            mv "$path/second.json" "$path/run-latest.json"
        fi
        case "${TEST_MODE:-}" in
            manifest_invalid) echo '{"transactions":[{"hash":"invalid"}]}' > "$path/run-latest.json" ;;
            manifest_empty) echo '{"transactions":[]}' > "$path/run-latest.json" ;;
        esac
        printf '%s\n' "$path" >> "$TEST_ROOT/broadcast-paths"
        echo 'APP=0x1111111111111111111111111111111111111111'
    else
        printf 'TARGET=0x1111111111111111111111111111111111111111\nVALUE=0\nCALLDATA=0x1234\n'
    fi
}
'''


class NetworkSetupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "clock").write_text("1000")
        (self.root / "bin").mkdir()
        transport = self.root / "bin/curl"
        transport.write_text(TRANSPORT)
        transport.chmod(0o755)
        (self.root / "scenario.sol").write_text("contract DeployL2 {}\ncontract ExecuteNetworkL2 {}\n")

    def run_shell(self, script, mode="reorg", **env):
        prefix = 'source "$LIB/E2EBase.sh"\n'
        prefix += '[[ ! -f "$LIB/network-setup.sh" ]] || source "$LIB/network-setup.sh"\n'
        return subprocess.run(["bash", "-c", prefix + COMMANDS + script], cwd=self.root,
            env={**os.environ, "LIB":str(LIB), "TEST_ROOT":str(self.root), "TEST_MODE":mode,
                 "SETUP_TX":TX, "SECOND_TX":SECOND_TX, "OLD_BLOCK":OLD_BLOCK, "E2E_SETUP_TIMEOUT":"6",
                 "TMPDIR":str(self.root), "PATH":str(self.root / "bin") + os.pathsep + os.environ["PATH"], **env},
            text=True, capture_output=True, timeout=15)

    def prepare_trigger(self, mode="reorg", **env):
        source = (LIB / "network-scenario.sh").read_text()
        start = source.index('network_trigger_front "$SOL" >/dev/null')
        end = source.index('\n# ═', source.index('build_trigger_txs "$SOL" network', start))
        return self.run_shell(source[start:end], mode, **env)

    def calls(self):
        return [json.loads(line) for line in (self.root / "rpc-calls").read_text().splitlines()]

    def test_trigger_preparation_after_setup_reorg_waits_for_settled_reinclusion(self):
        result = self.prepare_trigger()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--nonce 4 ", (self.root / "signs").read_text())
        self.assertEqual((self.root / "clock").read_text().strip(), "1004")
        receipt_calls = [call for call in self.calls() if call[1] == "eth_getTransactionReceipt"]
        self.assertTrue(receipt_calls)
        self.assertTrue(all(call[2] == [TX] for call in receipt_calls))
        self.assertNotIn(OLD_BLOCK, json.dumps(self.calls()))

    def test_missing_unsafe_or_orphaned_setup_never_signs(self):
        for mode in ("missing", "stalled", "orphaned", "safe_reorg", "missing_second"):
            with self.subTest(mode=mode):
                (self.root / "clock").write_text("1000")
                result = self.prepare_trigger(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "signs").exists())
                self.assertEqual((self.root / "clock").read_text().strip(), "1006")
                if mode == "missing_second":
                    self.assertTrue(any(call[1:] == ["eth_getTransactionReceipt", [SECOND_TX]] for call in self.calls()))

    def test_reverted_malformed_or_unsupported_setup_fails_without_signing(self):
        for mode in ("reverted", "malformed", "unsupported", "wrong_hash", "manifest_invalid", "manifest_empty"):
            with self.subTest(mode=mode):
                (self.root / "clock").write_text("1000")
                result = self.prepare_trigger(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "signs").exists())
                self.assertLess(int((self.root / "clock").read_text()), 1006)

    def test_invalid_setup_timeout_never_signs(self):
        result = self.prepare_trigger(E2E_SETUP_TIMEOUT="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid E2E_SETUP_TIMEOUT", result.stderr)
        self.assertFalse((self.root / "signs").exists())

    def test_repeated_scenarios_use_private_broadcast_directories_and_remove_them(self):
        result = self.run_shell('network_deploy_setup scenario.sol l1 l2 "$PK"\n'
                                'network_deploy_setup scenario.sol l1 l2 "$PK"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        paths = (self.root / "broadcast-paths").read_text().splitlines()
        self.assertEqual(len(paths), 2)
        self.assertNotEqual(paths[0], paths[1])
        self.assertTrue(all(not Path(path).exists() for path in paths))
        self.assertFalse((self.root / "broadcast").exists())

    def test_l1_only_setup_does_not_require_l2_safe_support(self):
        (self.root / "scenario.sol").write_text("contract DeployL1 {}\ncontract ExecuteNetwork {}\n")
        result = self.run_shell('network_deploy_setup scenario.sol l1 l2 "$PK"', "unsupported")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "rpc-calls").exists())


if __name__ == "__main__":
    unittest.main()
