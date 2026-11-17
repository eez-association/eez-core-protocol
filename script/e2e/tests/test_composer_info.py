"""Composer discovery, validation, and exported network configuration."""
import json
import unittest

from rpc_fixtures import E2E, RpcFixture


class ComposerInfoTests(RpcFixture):
    def discover(self):
        return self.run_bash(
            'bash "$1" --l1-front front1 --l1-rpc l1 --l2-rpc l2 --env',
            E2E / "lib/composer-info.sh")

    def test_discovers_once_from_l1_front_and_checks_both_chain_ids(self):
        result = self.discover()
        self.assert_ok(result)
        values = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(values, {
            "ROLLUPS": "0x" + "1" * 40,
            "EEZ_ROLLUP_MANAGER": "0x" + "2" * 40,
            "MANAGER_L2": "0x" + "3" * 40,
            "EXPECTED_L1_CHAIN_ID": "1", "EXPECTED_L2_CHAIN_ID": "31337",
            "COMPOSER_VERSION": "v1.2.3-test"})
        self.assertEqual(self.calls.read_text().splitlines(), [
            "RPC front1 eez_composerInfo", "RPC l1 eth_chainId", "RPC l2 eth_chainId"])

    def test_config_replaces_stale_addresses_and_exports_source_key_fallback(self):
        result = self.run_bash('''
source "$1"
load_network_config "$2" || exit 1
bash -c 'printf "%s\n" "$ROLLUPS" "$MANAGER_L2" "$PK" "$L1_RPC" "$L2_RPC"'
''', E2E / "lib/network-config.sh", self.env_file)
        self.assert_ok(result)
        self.assertEqual(result.stdout.splitlines(), ["0x" + "1" * 40, "0x" + "3" * 40,
                                                       "fake-key", "l1", "l2"])
        self.assertIn("ROLLUPS=stale", self.env_file.read_text())

    def test_batcher_setting_from_env_file_is_exported_to_workers(self):
        batcher = "0x" + "b" * 40
        with self.env_file.open("a") as f:
            f.write(f"\nEEZ_POST_BATCHER={batcher}\n")
        result = self.run_bash('''
source "$1"
load_network_config "$2" || exit 1
bash -c 'printf "%s" "$EEZ_POST_BATCHER"'
''', E2E / "lib/network-config.sh", self.env_file)
        self.assert_ok(result)
        self.assertEqual(result.stdout, batcher)

    def test_each_chain_mismatch_stops_without_exporting_configuration(self):
        for url in ("l1", "l2"):
            with self.subTest(url=url):
                path = self.root / f"{url}-eth_chainId.json"
                original = path.read_text()
                self.response(url, "eth_chainId", "0x2")
                result = self.discover()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("disagrees", result.stderr)
                path.write_text(original)

    def test_rejects_invalid_metadata(self):
        cases = [
            ("eezContracts", "eezRegistryAddress", "0x" + "0" * 40),
            ("eezContracts", "eezL2Address", "0x1234"),
            ("eezContracts", "eezRollupManagerAddress", None),
            ("supportedNetworks", "eezL1", 1.5),
            ("supportedNetworks", "eezL2", 9007199254740992),
            ("supportedNetworks", "eezL2", "31337"),
        ]
        for section, field, value in cases:
            with self.subTest(field=field, value=value):
                info = json.loads(json.dumps(self.info))
                info[section][field] = value
                self.response("front1", "eez_composerInfo", info)
                result = self.discover()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_rejects_version_with_assignment_or_shell_syntax(self):
        for version in ("v1\nPK=bad", "$(touch unexpected)", "", "v1;exit"):
            with self.subTest(version=version):
                self.response("front1", "eez_composerInfo", dict(self.info, version=version))
                result = self.discover()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertFalse((self.root / "unexpected").exists())

    def test_transport_rpc_and_malformed_response_fail_closed(self):
        path = self.root / "front1-eez_composerInfo.json"
        for response in (None, "not JSON", '{"jsonrpc":"2.0","error":{"message":"offline"}}',
                         '{"jsonrpc":"2.0"}'):
            with self.subTest(response=response):
                if response is None:
                    path.unlink()
                else:
                    path.write_text(response)
                result = self.discover()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_missing_explicit_env_file_fails_before_discovery(self):
        result = self.run_bash('source "$1"; load_network_config "$2"',
                               E2E / "lib/network-config.sh", self.root / "missing.env")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing environment file", result.stderr)
        self.assertEqual(self.calls.read_text(), "")

    def test_discovers_non_one_rollup_id(self):
        result = self.run_bash('source "$1"; load_network_config "$2" && echo "$L2_ROLLUP_ID"',
                               E2E / "lib/network-config.sh", self.env_file)
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "2")
        self.assertIn("rollups(uint64)(address,bytes32,uint256) 2", self.calls.read_text())

    def test_explicit_id_must_match_discovery(self):
        for configured in ("1", "2"):
            result = self.run_bash('source "$1"; load_network_config "$2"',
                                   E2E / "lib/network-config.sh", self.env_file, L2_ROLLUP_ID=configured)
            self.assertEqual(result.returncode == 0, configured == "2", result.stderr)

    def test_invalid_discovered_id_fails_closed(self):
        for value in ("0", "-1", "18446744073709551616", "garbage"):
            (self.root / "rollup-id").write_text(value)
            result = self.run_bash('source "$1"; load_network_config "$2"',
                                   E2E / "lib/network-config.sh", self.env_file)
            self.assertNotEqual(result.returncode, 0, value)

    def test_registration_must_match_composer(self):
        for address in ("0x" + "0" * 40, "0x" + "4" * 40):
            (self.root / "registered-manager").write_text(address + "\n")
            result = self.run_bash('source "$1"; load_network_config "$2"',
                                   E2E / "lib/network-config.sh", self.env_file)
            self.assertNotEqual(result.returncode, 0, address)

    def test_resume_uses_snapshot_identity_and_rejects_changed_l2(self):
        snapshot = self.root / "saved"
        snapshot.mkdir()
        (snapshot / "devnet.env").write_text(
            'ROLLUPS=0x' + '1' * 40 + '\nMANAGER_L2=0x' + '3' * 40 +
            '\nEEZ_ROLLUP_MANAGER=0x' + '2' * 40 + '\nL2_ROLLUP_ID=2\n')
        script = 'source "$1"; load_network_config "$2" "$3" && echo "$L2_ROLLUP_ID"'
        result = self.run_bash(script, E2E / "lib/network-config.sh", self.env_file, snapshot)
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "2")
        self.assertNotIn("eez_composerInfo", self.calls.read_text())
        (self.root / "rollup-id").write_text("3")
        result = self.run_bash(script, E2E / "lib/network-config.sh", self.env_file, snapshot)
        self.assertNotEqual(result.returncode, 0)


    def test_metadata_only_discovery_needs_only_front(self):
        result = self.run_bash('bash "$1" --l1-front front1 --env', E2E / "lib/composer-info.sh")
        self.assert_ok(result)
        self.assertEqual(self.calls.read_text().splitlines(), ["RPC front1 eez_composerInfo"])

    def test_full_discovery_requires_read_rpcs_before_querying_composer(self):
        result = self.run_bash('source "$1"; load_composer_info',
                               E2E / "lib/network-config.sh", L1_FRONT="front1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires L1_RPC and L2_RPC", result.stderr)
        self.assertEqual(self.calls.read_text(), "")

    def test_decimal_ids_are_canonicalized_before_comparison_and_export(self):
        (self.root / "rollup-id").write_text("02\n")
        result = self.run_bash('source "$1"; load_network_config "$2" && echo "$L2_ROLLUP_ID"',
                               E2E / "lib/network-config.sh", self.env_file, L2_ROLLUP_ID="002")
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "2")
        self.assertIn("rollups(uint64)(address,bytes32,uint256) 2 ", self.calls.read_text())

    def test_cli_identity_ignores_unbound_inherited_manager(self):
        result = self.run_bash(r"""
source "$1"
load_network_env "$2"
export ROLLUPS=0x1111111111111111111111111111111111111111
export MANAGER_L2=0x3333333333333333333333333333333333333333
resolve_network_rollup_id && echo "$EEZ_ROLLUP_MANAGER"
""", E2E / "lib/network-config.sh", self.env_file,
            EEZ_ROLLUP_MANAGER="0x" + "4" * 40)
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "0x" + "2" * 40)
        self.assertNotIn("eez_composerInfo", self.calls.read_text())

    def test_workers_preserve_bound_manager_assertion(self):
        result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf '%s\n' 0x4444444444444444444444444444444444444444 > "$TEST_ROOT/registered-manager"
bash -c 'source "$1"; resolve_network_rollup_id' worker "$1"
""", E2E / "lib/network-config.sh", self.env_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("composer/snapshot identity", result.stderr)

    def test_cli_override_invalidates_other_network_manager_assertion(self):
        for field, value in (
            ("L1_RPC", "other-l1"), ("L2_RPC", "other-l2"),
            ("ROLLUPS", "0x" + "5" * 40), ("MANAGER_L2", "0x" + "6" * 40),
        ):
            with self.subTest(field=field):
                (self.root / "rollup-id").write_text("2\n")
                (self.root / "registered-manager").write_text("0x" + "2" * 40 + "\n")
                result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf '%s\n' 0x4444444444444444444444444444444444444444 > "$TEST_ROOT/registered-manager"
printf '3\n' > "$TEST_ROOT/rollup-id"
export "$OVERRIDE_FIELD=$OVERRIDE_VALUE"
bash -c 'source "$1"; resolve_network_rollup_id && printf "%s\n" "$EEZ_ROLLUP_MANAGER" "$L2_ROLLUP_ID"' worker "$1"
""", E2E / "lib/network-config.sh", self.env_file,
                    OVERRIDE_FIELD=field, OVERRIDE_VALUE=value)
                self.assert_ok(result)
                self.assertEqual(result.stdout.splitlines(), ["0x" + "4" * 40, "3"])

    def test_workers_reject_id_change_in_same_network_context(self):
        result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf '3\n' > "$TEST_ROOT/rollup-id"
bash -c 'source "$1"; resolve_network_rollup_id' worker "$1"
""", E2E / "lib/network-config.sh", self.env_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees with L2 manager", result.stderr)

    def test_loading_new_config_does_not_pin_previous_discovery(self):
        result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf '3\n' > "$TEST_ROOT/rollup-id"
load_network_config "$2" && echo "$L2_ROLLUP_ID"
""", E2E / "lib/network-config.sh", self.env_file)
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "3")

    def test_env_file_id_remains_explicit_after_previous_discovery(self):
        result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf 'L2_ROLLUP_ID=2\n' >> "$2"
printf '3\n' > "$TEST_ROOT/rollup-id"
load_network_config "$2"
""", E2E / "lib/network-config.sh", self.env_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees with L2 manager", result.stderr)

    def test_explicit_id_is_preserved_across_network_override(self):
        result = self.run_bash(r"""
source "$1"
load_network_config "$2" || exit 1
printf '3\n' > "$TEST_ROOT/rollup-id"
export L2_RPC=other-l2
resolve_network_rollup_id
""", E2E / "lib/network-config.sh", self.env_file, L2_ROLLUP_ID="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees with L2 manager", result.stderr)

    def test_snapshot_manager_assertion_is_preserved(self):
        snapshot = self.root / "saved"
        snapshot.mkdir()
        (snapshot / "devnet.env").write_text(
            "ROLLUPS=0x" + "1" * 40 + "\nMANAGER_L2=0x" + "3" * 40 +
            "\nEEZ_ROLLUP_MANAGER=0x" + "4" * 40 + "\nL2_ROLLUP_ID=2\n")
        result = self.run_bash('source "$1"; load_network_config "$2" "$3"',
                               E2E / "lib/network-config.sh", self.env_file, snapshot)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("composer/snapshot identity", result.stderr)
        self.assertNotIn("eez_composerInfo", self.calls.read_text())

    def test_old_snapshot_does_not_inherit_unrelated_manager_assertion(self):
        snapshot = self.root / "saved"
        snapshot.mkdir()
        (snapshot / "devnet.env").write_text(
            "ROLLUPS=0x" + "1" * 40 + "\nMANAGER_L2=0x" + "3" * 40 + "\nL2_ROLLUP_ID=2\n")
        result = self.run_bash('source "$1"; load_network_config "$2" "$3"',
                               E2E / "lib/network-config.sh", self.env_file, snapshot,
                               EEZ_ROLLUP_MANAGER="0x" + "4" * 40)
        self.assert_ok(result)

    def run_rollup_transport(self, mode, message="Error: tcp connect error: connection reset"):
        for name in ("attempt-id", "attempt-registry"):
            (self.root / name).unlink(missing_ok=True)
        self.calls.write_text("")
        return self.run_bash(r"""
sleep() { echo SLEEP >> "$CALLS"; }
cast() {
    local kind count=0
    case "$*" in
        *'ROLLUP_ID()(uint64)'*) kind=id ;;
        *'rollups(uint64)(address,bytes32,uint256)'*) kind=registry ;;
        *) return 99 ;;
    esac
    [[ ! -f "$TEST_ROOT/attempt-$kind" ]] || read -r count < "$TEST_ROOT/attempt-$kind"
    count=$((count + 1))
    echo "$count" > "$TEST_ROOT/attempt-$kind"
    echo "ATTEMPT $kind" >> "$CALLS"
    if [[ "$TEST_MODE" != once || "$count" == 1 ]]; then
        echo "$TEST_ERROR" >&2
        return 1
    fi
    _fixture_rollup_call "$@"
}
source "$1"
load_network_config "$2"
""", E2E / "lib/network-config.sh", self.env_file, TEST_MODE=mode, TEST_ERROR=message)

    def test_both_identity_reads_retry_transient_failures(self):
        result = self.run_rollup_transport("once")
        self.assert_ok(result)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count("ATTEMPT id"), 2)
        self.assertEqual(calls.count("ATTEMPT registry"), 2)
        self.assertEqual(calls.count("SLEEP"), 2)

    def test_transport_retry_exhaustion_is_bounded(self):
        result = self.run_rollup_transport("permanent")
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count("ATTEMPT id"), 3)
        self.assertEqual(calls.count("ATTEMPT registry"), 0)
        self.assertEqual(calls.count("SLEEP"), 2)
        self.assertIn("tcp connect error", result.stderr)

    def test_contract_errors_are_not_retried_even_with_transport_words(self):
        for message in (
            "Error: execution reverted: timeout",
            "Error: server returned an error response: error code -32601: timeout",
            '{"error":{"code":-32602,"message":"connection reset"}}',
            "Error: could not decode output",
        ):
            with self.subTest(message=message):
                result = self.run_rollup_transport("terminal", message)
                self.assertNotEqual(result.returncode, 0)
                calls = self.calls.read_text().splitlines()
                self.assertEqual(calls.count("ATTEMPT id"), 1)
                self.assertNotIn("SLEEP", calls)


if __name__ == "__main__":
    unittest.main()
