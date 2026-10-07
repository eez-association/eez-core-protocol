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


if __name__ == "__main__":
    unittest.main()
