"""Wallet parsing and credential-file handling, without real keys or RPC calls."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
LIB = REPO / "script/e2e/lib/orchestrator.sh"
ADDRESS = "0x" + "1" * 40
KEY = "0x" + "2" * 64  # Synthetic fixture only; never funded.
WALLET = {"address": ADDRESS, "private_key": KEY}
RECORD = f"{ADDRESS},{KEY}\n"


class WalletTests(unittest.TestCase):
    def shell(self, script, **env):
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail\nsource "$LIB"\n' + script],
            cwd=REPO, env={**os.environ, "LIB": str(LIB), **env},
            capture_output=True, text=True, timeout=10)

    def parse(self, value, rc=0):
        return self.shell("""
cast() {
    [[ "$*" == "wallet new --json" ]] || return 90
    printf '%s' "$PAYLOAD"
    echo SYNTHETIC_PRIVATE_DIAGNOSTIC >&2
    return "$CAST_RC"
}
_new_wallet
""", PAYLOAD=value, CAST_RC=str(rc))

    def test_supported_json_shapes(self):
        for value in ([WALLET], {"success": True, "data": [WALLET]}):
            with self.subTest(value_type=type(value).__name__):
                result = self.parse(json.dumps(value))
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, RECORD)
                self.assertEqual(result.stderr, "")

    def test_invalid_output_and_command_errors_hide_diagnostics(self):
        values = [
            "", " ", "not JSON", "null", "[]",
            json.dumps([WALLET, WALLET]),
            json.dumps({"success": False, "data": [WALLET]}),
            json.dumps([{"address": ADDRESS}]),
            json.dumps([dict(WALLET, address="invalid")]),
            json.dumps([dict(WALLET, private_key="invalid")]),
        ]
        for value, rc in [(value, 0) for value in values] + [(json.dumps([WALLET]), 1)]:
            with self.subTest(payload=value, rc=rc):
                result = self.parse(value, rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(result.stderr, ("Invalid wallet JSON\n", "Wallet creation failed\n"))

    def prepare(self, root, fresh="false", offset="0", fail_chmod=""):
        # Every cast/forge call is intercepted. Abort at unit conversion, before
        # balance queries, deployment, or funding. No real wallet is generated.
        return self.shell("""
umask 022
_E2E_WALLET_STATE_DIR="$ROOT/state"
RUN_DIR="$ROOT/run"
DIRECT=false
NJOBS=1
JOB_NAMES=(job)
FUND_ETH=0.003 FLOOR_ETH=0.0015
MULTISEND_BATCH=100 FUND_BALANCE_WORKERS=1
forge() {
    [[ "$*" == "inspect MultiSend deployedBytecode" ]] || return 90
    echo 0x00
}
cast() {
    case "$*" in
        "wallet new --json") printf '%s' "$PAYLOAD" ;;
        "to-wei 0.003") echo STOP_BEFORE_RPC >&2; return 71 ;;
        *) echo UNEXPECTED_CAST >&2; return 90 ;;
    esac
}
chmod() {
    [[ -z "$FAIL_CHMOD" ]] || return 72
    printf '%s:%s\n' "${3##*/}" "$(stat -c %a -- "$3")" >> "$ROOT/modes"
    command chmod "$@"
}
fund_workers
""", ROOT=str(root), FRESH=fresh, WALLET_OFFSET=offset,
            PAYLOAD=json.dumps({"success": True, "data": [WALLET]}),
            FAIL_CHMOD=fail_chmod)

    def make_dirs(self, root):
        (root / "state").mkdir()
        (root / "run").mkdir()

    def test_new_files_are_private_before_chmod(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_dirs(root)
            result = self.prepare(root)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, "STOP_BEFORE_RPC\n")
            self.assertEqual((root / "modes").read_text().splitlines(),
                             ["faucet.txt:600", "wallet-pool.csv:600", "wallets.csv:600"])
            self.assertEqual((root / "state/wallet-pool.csv").read_text(), RECORD)
            self.assertEqual((root / "run/wallets.csv").read_text(),
                             "job,address,private_key\njob," + RECORD)

    def test_existing_files_are_restricted_and_fresh_appends(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_dirs(root)
            files = {
                root / "state/faucet.txt": f"address: {ADDRESS}\npvtKey:  {KEY}\n",
                root / "state/wallet-pool.csv": RECORD * 2,
                root / "run/wallets.csv": "old run\n",
            }
            for path, value in files.items():
                path.write_text(value)
                path.chmod(0o644)
            result = self.prepare(root, fresh="true")
            self.assertEqual(result.stderr, "STOP_BEFORE_RPC\n")
            self.assertEqual(result.returncode, 1)
            for path in files:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual((root / "state/wallet-pool.csv").read_text(), RECORD * 3)

    def test_malformed_reused_records_report_actual_line(self):
        for row in ("\n", ADDRESS + "\n", f"{ADDRESS},extra,{KEY}\n", RECORD.rstrip() + "\r\n"):
            with self.subTest(row=row), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_dirs(root)
                (root / "state/wallet-pool.csv").write_text(RECORD + row)
                result = self.prepare(root, offset="1")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, "Malformed wallet pool record at line 2\n")

    def test_permission_failure_aborts_before_writing_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_dirs(root)
            result = self.prepare(root, fail_chmod="1")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Cannot secure wallet file:", result.stderr)
            self.assertNotIn("STOP_BEFORE_RPC", result.stderr)
            self.assertEqual((root / "state/faucet.txt").read_text(), "")
            self.assertFalse((root / "state/wallet-pool.csv").exists())
