"""Audit regressions: exact planned gas, old journal continuation, and settlement correlation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_run import HARNESS, KEY, ROOT, RUNNER


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


DEPLOY_MOCK = r'''
env() {
    local assignment=$1; shift
    FOUNDRY_BROADCAST=${assignment#*=} "$@"
}
forge() {
    [[ "$*" != *--broadcast* ]] || return 90
    [[ "$*" == *deployL1* || "$*" == *configureL2* ]] || return 0
    local method=deployL1 chain=1 target=null kind=CREATE input=0x60006000f3
    if [[ "$*" == *configureL2* ]]; then
        method=configureL2 chain=696990 target=$(field executor) kind=CALL
        input=$("$REAL_CAST" calldata 'configure(address)' "$(field borrower)")
    fi
    echo "PLAN $method" >> "$RUN_DIR/calls"
    mkdir -p "$FOUNDRY_BROADCAST/Mainnet.s.sol/$chain/dry-run"
    jq -n --arg sender "$WALLET" --arg chain "$("$REAL_CAST" to-hex "$chain")" --arg target "$target" --arg kind "$kind" --arg input "$input" '
      {transactions:[{transactionType:$kind,contractAddress:"0x2222222222222222222222222222222222222222",
      transaction:{from:$sender,to:(if $target=="null" then null else $target end),input:$input,gas:"0x5208",nonce:"0x5",value:"0x0",chainId:$chain}}]}' \
      > "$FOUNDRY_BROADCAST/Mainnet.s.sol/$chain/dry-run/$method-latest.json"
}
cast() {
    case "$1" in
        gas-price) echo 100 ;;
        balance) echo 1000000000000000000 ;;
        nonce) echo 5 ;;
        rpc)
            if [[ "$2" == eth_sendRawTransaction ]]; then
                local endpoint=${!#} raw=$3 hash
                hash=$("$REAL_CAST" keccak "$raw")
                echo "SEND $endpoint" >> "$RUN_DIR/calls"
                "$REAL_CAST" decode-transaction "$raw" | jq 'if type=="string" then fromjson else . end' > "$RUN_DIR/signed-$endpoint.json"
                printf '"%s"\n' "$hash"
            elif [[ "$*" == *eth_getTransactionReceipt* ]]; then
                jq -n --arg h "${!#}" '{status:"0x1",transactionHash:$h,contractAddress:"0x2222222222222222222222222222222222222222"}'
            else return 91; fi ;;
        *) "$REAL_CAST" "$@" ;;
    esac
}
'''

STATUS_MOCK = r'''
verify() { :; }
read_call() { echo 0x3333333333333333333333333333333333333333; }
cast() {
    if [[ "$1" != rpc ]]; then "$REAL_CAST" "$@"; return; fi
    case "$3:$4" in
        front2:eth_getTransactionReceipt) cat "$RUN_DIR/l2.json" ;;
        direct2:eez_getSettlementByL2Block) cat "$RUN_DIR/correlation.json" ;;
        10:--rpc-url) [[ "$5:$6" == direct2:eez_getCrossChainTransaction ]] || return 94; cat "$RUN_DIR/composer.json" ;;
        direct1:eth_getTransactionReceipt)
            [[ "$5" == "$(jq -r '.l1TransactionHash' "$RUN_DIR/correlation.json")" ]] || return 91
            cat "$RUN_DIR/l1.json" ;;
        direct1:eth_getBlockByNumber) cat "$RUN_DIR/l1-block.json" ;;
        *:eth_getLogs) echo 'FORBIDDEN AMOUNT SCAN' >&2; return 92 ;;
        *) return 93 ;;
    esac
}
'''

CREATE2_MOCK = r'''
MANAGER_L2=0x5555555555555555555555555555555555555555
forge() {
    [[ "$*" != *--broadcast* ]] || return 90
    if [[ "$*" == *prepareL1Create2* ]]; then
        echo '{"returns":{"predicted":{"value":"0x2222222222222222222222222222222222222222"},"payload":{"value":"0x000000000000000000000000000000000000000000000000000000000000000060006000f3"}}}'
    fi
}
cast() {
    case "$1" in
        code) if [[ "$2" == 0x4444444444444444444444444444444444444444 ]]; then echo 0x6000; else echo 0x; fi ;;
        call) echo 0x4444444444444444444444444444444444444444 ;;
        nonce) if [[ "${!#}" == front2 ]]; then echo 7; else echo 5; fi ;;
        gas-price) echo 100 ;;
        balance) echo 1000000000000000000 ;;
        mktx) [[ "$*" != *--rpc-url* ]] || return 91; "$REAL_CAST" "$@" ;;
        rpc)
            if [[ "$2" == eth_sendRawTransaction ]]; then
                [[ "${!#}" == front2 ]] || return 92
                echo 'SEND front2' >> "$RUN_DIR/calls"
                "$REAL_CAST" keccak "$3" | jq -R .
            elif [[ "$*" == *eez_getSettlementByL2Block* ]]; then
                echo '{"canonicalL2":true,"matchedL2Block":{"number":"0x20","hash":"0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"l1BlockNumber":"0x64","l1BlockHash":"0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","l1TransactionHash":"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
            elif [[ "$*" == *eth_getBlockByNumber* ]]; then
                echo '{"hash":"0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
            elif [[ "$*" == *eth_getTransactionReceipt* ]]; then
                if [[ "$*" == *front2* ]]; then
                    jq -n --arg hash "$(cat "$RUN_DIR/deploy-l1-via-l2.hash")" --arg owner "$WALLET" '{status:"0x1",transactionHash:$hash,from:$owner,to:"0x4444444444444444444444444444444444444444",blockNumber:"0x20",blockHash:"0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
                else
                    echo '{"status":"0x1","transactionHash":"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","blockNumber":"0x64","blockHash":"0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
                fi
            else return 93; fi ;;
        estimate|estimate-gas) return 94 ;;
        *) "$REAL_CAST" "$@" ;;
    esac
}
'''


class AuditRegressions(unittest.TestCase):
    def run_shell(self, directory, extra, action):
        return subprocess.run(["bash", "-c", HARNESS + extra + "\n" + action], text=True,
            capture_output=True, timeout=25, env={"PATH": os.environ["PATH"], "RUNNER": str(RUNNER),
            "TEST_DIR": str(directory), "TEST_KEY": KEY, "REAL_CAST": shutil.which("cast"), "SCENARIO": "audit"})

    def test_exact_plan_is_signed_once_and_budget_cannot_be_reestimated(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_shell(d, DEPLOY_MOCK, 'MAX_FEE_WEI=4200000\nstage deploy-l1 direct1 1 "deployL1(address,address)" "$WALLET" "$(field executor)"')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            tx = json.loads((Path(d) / "signed-direct1.json").read_text())
            self.assertEqual(int(tx["gas"], 16), 21000)
            self.assertEqual(int(tx["gas"], 16) * int(tx["gasPrice"], 16), 4200000)
            self.assertEqual((Path(d) / "calls").read_text().splitlines(), ["PLAN deployL1", "SEND direct1"])

    def test_partial_run_continues_without_resending_l2_deployment(self):
        with tempfile.TemporaryDirectory() as d:
            # The legacy .done format remains accepted, including the already mined transaction.
            marker = "0x" + "a" * 64 + "\n"
            (Path(d) / "deploy-l2.done").write_text(marker)
            result = self.run_shell(d, DEPLOY_MOCK, "deploy")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = (Path(d) / "calls").read_text().splitlines()
            self.assertEqual(calls, ["PLAN deployL1", "SEND direct1", "PLAN configureL2", "SEND direct2"])
            self.assertEqual((Path(d) / "deploy-l2.done").read_text(), marker)
            self.assertEqual(json.loads((Path(d) / "state.json").read_text())["executor"], "0x" + "1" * 40)

    def test_create2_path_only_sends_l2_and_resumes_without_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            marker = "existing-l2-deployment\n"
            (Path(d) / "deploy-l2.done").write_text(marker)
            result = self.run_shell(d, CREATE2_MOCK,
                'deploy_l1_via_l2\nmv "$RUN_DIR/deploy-l1.done" "$RUN_DIR/completed.backup"\ndeploy_l1_via_l2')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((Path(d) / "calls").read_text().splitlines(), ["SEND front2"])
            self.assertEqual((Path(d) / "deploy-l2.done").read_text(), marker)
            state = json.loads((Path(d) / "state.json").read_text())
            self.assertEqual(state["borrower"], "0x" + "2" * 40)
            self.assertEqual(state["executor"], "0x" + "1" * 40)
            self.assertEqual(state["l1_deployment_mode"], "create2-via-l2")
            tx = json.loads(cast("decode-transaction", (Path(d) / "deploy-l1-via-l2.raw").read_text().strip()))
            if isinstance(tx, str): tx = json.loads(tx)
            self.assertEqual(int(tx["chainId"], 16), 696990)
            self.assertEqual(int(tx["gas"], 16), 3_500_000)
            self.assertEqual(int(tx["nonce"], 16), 7)
            self.assertEqual(tx["to"], "0x" + "4" * 40)

    def test_create2_path_refuses_uncertain_direct_l1_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "deploy-l1.started").write_text("{}")
            result = self.run_shell(d, CREATE2_MOCK, "deploy_l1_via_l2")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("reconcile", result.stderr)
            self.assertFalse((Path(d) / "calls").exists())

    def test_unmined_trigger_uses_composer_lifecycle(self):
        cases = [
            ("terminal", "terminal", "SimulationFailed", 1, "L2 trigger terminal"),
            ("active", "queued", None, 0, "L2 trigger pending"),
        ]
        for lifecycle, state, reason, code, message in cases:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.fixture(root)
                (root / "l2.json").write_text("null")
                details = {"hash": "0x" + "a" * 64, "lifecycle": lifecycle,
                           "ownership": {"state": state, "reason": reason,
                                         "rejection": {"source": {"output": "0x34041dc6"}}}}
                (root / "composer.json").write_text(json.dumps(details))
                result = self.run_shell(d, STATUS_MOCK, "status")
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertEqual(json.loads((root / "cross-chain-status.json").read_text()), details)
                if code:
                    self.assertIn("SimulationFailed", result.stdout)
                    self.assertIn("0x34041dc6", result.stdout)
                    self.assertNotIn("L2 trigger pending", result.stdout)

    def test_unavailable_composer_status_does_not_claim_pending(self):
        for details in [None, "rpc-error"]:
            with self.subTest(details=details), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.fixture(root)
                (root / "l2.json").write_text("null")
                if details is None:
                    (root / "composer.json").write_text("null")
                result = self.run_shell(d, STATUS_MOCK, "status")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("composer status unavailable", result.stdout)
                self.assertNotIn("L2 trigger pending", result.stdout)

    def test_composer_status_must_match_trigger(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.fixture(root)
            (root / "l2.json").write_text("null")
            (root / "composer.json").write_text(json.dumps({"hash": "0x" + "f" * 64}))
            result = self.run_shell(d, STATUS_MOCK, "status")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Composer status hash mismatch", result.stderr)

    def fixture(self, root):
        owner = cast("wallet", "address", "--private-key", KEY).lower()
        executor, borrower, wrapped = ["0x" + c * 40 for c in "123"]
        usdc = "0x" + "6" * 40
        vault = "0x" + "7" * 40
        bridge = "0x" + "8" * 40
        zero = "0x" + "0" * 40
        amount = "0x" + format(36_000_000_000, "064x")
        topic_address = lambda a: "0x" + "0" * 24 + a[2:].lower()
        transfer_topic = cast("keccak", "Transfer(address,address,uint256)")
        def transfer(token, sender, recipient):
            return {"address": token, "topics": [transfer_topic, topic_address(sender), topic_address(recipient)], "data": amount}
        trigger, settlement, l2_hash, l1_hash = ["0x" + c * 64 for c in "abcd"]
        completion = {"address": executor, "topics": [cast("keccak", "FlashLoanCompleted(address,uint256,uint256)"), topic_address(owner), "0x" + "0" * 63 + "1"], "data": amount}
        paid = {"address": borrower, "topics": [cast("keccak", "FlashLoanExecuted(address,uint256)"), topic_address(usdc)], "data": amount}
        files = {
            "l2.json": {"status": "0x1", "transactionHash": trigger, "blockNumber": "0x20", "blockHash": l2_hash,
                        "logs": [completion, transfer(wrapped, zero, executor), transfer(wrapped, executor, zero)]},
            "correlation.json": {"canonicalL2": True, "matchedL2Block": {"number": "0x20", "hash": l2_hash},
                                 "l1TransactionHash": settlement, "l1BlockNumber": "0x64", "l1BlockHash": l1_hash},
            "l1.json": {"status": "0x1", "transactionHash": settlement, "blockNumber": "0x64", "blockHash": l1_hash,
                        "logs": [paid] + [transfer(usdc, a, b) for a, b in [(vault, borrower), (borrower, bridge), (bridge, borrower), (borrower, vault)]]},
            "l1-block.json": {"hash": l1_hash},
        }
        for name, value in files.items(): (root / name).write_text(json.dumps(value))
        (root / "trigger.hash").write_text(trigger)
        return files

    def test_only_correlated_canonical_settlement_can_complete(self):
        with tempfile.TemporaryDirectory() as d:
            self.fixture(Path(d))
            result = self.run_shell(d, STATUS_MOCK, "status")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified:", result.stdout)

    def test_completion_must_match_fixed_request(self):
        with tempfile.TemporaryDirectory() as d:
            self.fixture(Path(d))
            result = self.run_shell(d, STATUS_MOCK, 'set_field requested_amount 32000000000\nstatus')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Completed amount differs from signed request", result.stderr)

    def test_legacy_completion_checks_minimum_instead_of_exact_amount(self):
        for minimum, expected_success in [(10000000000, True), (40000000000, False)]:
            with self.subTest(minimum=minimum), tempfile.TemporaryDirectory() as d:
                self.fixture(Path(d))
                result = self.run_shell(d, STATUS_MOCK, f"set_field loan_mode legacy\nset_field requested_minimum {minimum}\nstatus")
                self.assertEqual(result.returncode == 0, expected_success, result.stdout + result.stderr)

    def test_same_amount_elsewhere_cannot_complete_pending_settlement(self):
        with tempfile.TemporaryDirectory() as d:
            self.fixture(Path(d))
            # An unrelated successful receipt exists, but our block is not settled.
            (Path(d) / "correlation.json").write_text("null")
            result = self.run_shell(d, STATUS_MOCK, "status")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("pending", result.stdout)
            self.assertNotIn("Verified:", result.stdout)

    def test_reorg_or_wrong_settlement_receipt_is_rejected(self):
        mutations = [
            ("correlation.json", lambda x: x.update(canonicalL2=False)),
            ("correlation.json", lambda x: x["matchedL2Block"].update(hash="0x" + "f" * 64)),
            ("l1.json", lambda x: x.update(transactionHash="0x" + "f" * 64)),
            ("l1-block.json", lambda x: x.update(hash="0x" + "f" * 64)),
            ("l1.json", lambda x: x["logs"].pop(0)),
        ]
        for name, mutate in mutations:
            with self.subTest(file=name), tempfile.TemporaryDirectory() as d:
                files = self.fixture(Path(d))
                mutate(files[name]); (Path(d) / name).write_text(json.dumps(files[name]))
                result = self.run_shell(d, STATUS_MOCK, "status")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("Verified:", result.stdout)


if __name__ == "__main__":
    unittest.main()
