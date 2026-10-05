"""Fake only the HTTP transport; exercise the actual Bash RPC/parser code."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

E2E = Path(__file__).resolve().parents[1]
CURL = r'''
curl() {
    local url arg method
    for arg in "$@"; do
        case "$arg" in l1|l2|front1|front2) url="$arg" ;; esac
    done
    method=$(jq -r .method <<< "${!#}") || return 1
    printf 'RPC %s %s\n' "$url" "$method" >> "$CALLS"
    [[ -f "$TEST_ROOT/$url-$method.json" ]] || return 22
    cat "$TEST_ROOT/$url-$method.json"
}
export -f curl
'''


class RpcFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.calls = self.root / "calls"
        self.calls.touch()
        self.info = {
            "version": "v1.2.3-test",
            "eezContracts": {
                "eezRegistryAddress": "0x" + "1" * 40,
                "eezRollupManagerAddress": "0x" + "2" * 40,
                "eezL2Address": "0x" + "3" * 40,
            },
            "supportedNetworks": {"eezL1": 1, "eezL2": 31337},
        }
        self.response("front1", "eez_composerInfo", self.info)
        self.response("l1", "eth_chainId", "0x1")
        self.response("l2", "eth_chainId", "0x7a69")
        self.env_file = self.root / "chain.env"
        self.env_file.write_text(
            "L1_RPC=l1\nL2_RPC=l2\nL1_FRONT=front1\nL2_FRONT=front2\n"
            "SOURCE_PK=fake-key\nROLLUPS=stale\nMANAGER_L2=stale\n")

    def response(self, url, method, result):
        path = self.root / f"{url}-{method}.json"
        path.write_text(json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}))
        return path

    def run_bash(self, script, *args, **env):
        return subprocess.run(
            ["bash", "-c", CURL + script, "test", *map(str, args)],
            cwd=self.root, capture_output=True, text=True, timeout=15,
            env={"PATH": os.environ["PATH"], "TEST_ROOT": str(self.root),
                 "CALLS": str(self.calls), **env})

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
