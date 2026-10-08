# Deployment

Run from the repository root. Set the variables below; use **proxy addresses** in integrations.
`PRIVATE_KEY` must belong to the Rollup owner for registration, or the relevant ProxyAdmin
owner for upgrades. Remove `--broadcast` to simulate. Receipts: `broadcast/`.

## Full deployment

L1: upgradeable EEZ + upgradeable Rollup + ECDSA proof system + registration (threshold 1).
`PROOF_OWNER` controls signer rotation; `PROOF_SIGNER` signs proofs. `VKEY` is nonzero
bytes32; `INITIAL_ROOT` is the bytes32 genesis root. Broadcast as `ROLLUP_OWNER`.

```bash
forge script deployment/Deploy.s.sol:DeployL1 \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,address,address,address,address,bytes32,bytes32)' \
  "$RECOVERY_ADDRESS" "$EEZ_UPGRADE_OWNER" "$ROLLUP_OWNER" "$ROLLUP_UPGRADE_OWNER" \
  "$PROOF_OWNER" "$PROOF_SIGNER" "$VKEY" "$INITIAL_ROOT"

# L2: use the ROLLUP_ID printed by L1. EEZL2 is deployed behind a transparent upgradeable proxy.
forge script deployment/Deploy.s.sol:DeployL2 \
  --rpc-url "$L2_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(uint64,address,bool,address,address)' "$ROLLUP_ID" "$SYSTEM_ADDRESS" "$USE_GAS_LEFT" "$L2_RECOVERY_ADDRESS" "$L2_UPGRADE_OWNER"
```

`L2_UPGRADE_OWNER` owns the L2 ProxyAdmin. Use the printed `EEZ_L2_PROXY` address in integrations.
The script also prints `EEZ_L2_IMPLEMENTATION` and `EEZ_L2_PROXY_ADMIN`.

`SYSTEM_ADDRESS` loads L2 execution tables and receives outgoing call value; `USE_GAS_LEFT` selects observed-gas hashing. `L2_RECOVERY_ADDRESS` is a separate nonzero immutable recipient for ETH swept from prefunded proxies. Set it to the system address explicitly if both recipients should coincide.

## Individual deployments

Use these instead of `DeployL1` for separate setup or additional rollups.

```bash
forge script deployment/Deploy.s.sol:DeployEEZ \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address)' "$RECOVERY_ADDRESS" "$EEZ_UPGRADE_OWNER"

forge script deployment/Deploy.s.sol:DeployProofSystem \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address)' "$PROOF_OWNER" "$PROOF_SIGNER"

# Deploy and initialize; registration is separate.
forge script deployment/Deploy.s.sol:DeployRollup \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,address,uint256,address[],bytes32[])' \
  "$EEZ_PROXY" "$ROLLUP_OWNER" "$ROLLUP_UPGRADE_OWNER" "$THRESHOLD" "[$PROOF_SYSTEM]" "[$VKEY]"

forge script deployment/Deploy.s.sol:RegisterRollup \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,bytes32)' "$EEZ_PROXY" "$ROLLUP_PROXY" "$INITIAL_ROOT"
```

For multiple proof systems, use parallel arrays: `"[$PS1,$PS2]"`, `"[$VK1,$VK2]"`.
`RollupDeployment.sol` is a Solidity helper for tests/devnets, not a CLI script.
Optional test bridges: [DeployBridge.s.sol](../script/DeployBridge.s.sol).

## Upgrades

Check storage compatibility first. Deploy updated implementations, then upgrade using
the respective ProxyAdmin owner's key. `0x` means no migration call; do not reinitialize.
The scripts check unchanged recovery/EEZ addresses and EEZ's cross-chain proxy bytecode
hash. They do not validate storage layouts.

```bash
forge create src/EEZ.sol:EEZ \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast --constructor-args "$RECOVERY_ADDRESS"
forge create src/rollupContract/Rollup.sol:Rollup \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast --constructor-args "$EEZ_PROXY"

forge script deployment/Upgrade.s.sol:UpgradeEEZ \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,bytes)' "$EEZ_PROXY" "$NEW_EEZ_IMPLEMENTATION" 0x
forge script deployment/Upgrade.s.sol:UpgradeRollup \
  --rpc-url "$L1_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,bytes)' "$ROLLUP_PROXY" "$NEW_ROLLUP_IMPLEMENTATION" 0x
```

For L2, deploy the replacement with the same immutable configuration, then run as `L2_UPGRADE_OWNER`:

```bash
forge create src/L2/EEZL2.sol:EEZL2 \
  --rpc-url "$L2_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$ROLLUP_ID" "$SYSTEM_ADDRESS" "$USE_GAS_LEFT" "$L2_RECOVERY_ADDRESS"
forge script deployment/Upgrade.s.sol:UpgradeEEZL2 \
  --rpc-url "$L2_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(address,address,bytes)' "$EEZ_L2_PROXY" "$NEW_EEZ_L2_IMPLEMENTATION" 0x
```

The L2 upgrade script checks the rollup ID, system address, gas mode, recovery recipient,
and cross-chain proxy bytecode hash. Storage compatibility still requires review.
Existing direct deployments cannot be converted in place; a new proxy has its own state
and deterministic cross-chain proxy addresses.

## Mainnet upgrade to 9744950

Run from the repository root. Replace the placeholders locally; no env file is needed.
The owner must control both ProxyAdmins and have gas funds on both chains.

```bash
bash deployment/upgrade-mainnet.sh \
  --l1-rpc '<Ethereum mainnet RPC>' \
  --l2-rpc '<L2 RPC for chain 696990>' \
  --l1-manager '<L1 manager proxy address>' \
  --l2-manager '<L2 manager proxy address>' \
  --owner '<ProxyAdmin owner address>'
```

This simulates only. To upgrade, stop composer submissions, drain pending work,
then rerun with `--broadcast --traffic-paused`. The runner privately prompts for
an **0x-prefixed private key**, or uses exported `UPGRADE_PRIVATE_KEY`.
Keep traffic paused until both upgrades verify. If interrupted, preserve and reuse
`tmp-mainnet-upgrade-9744950/`; inspect receipts before retrying.

## Signing keys

### Recommended: import into an encrypted keystore (non-interactive)

Inject secrets through your cloud secret manager; keep them out of source control and logs.

```bash
CAST_UNSAFE_PASSWORD="$KEYSTORE_PASSWORD" \
  cast wallet import deployer --private-key "$PRIVATE_KEY"
```

Then replace `--private-key "$PRIVATE_KEY"` in any command with:

```bash
--account deployer --password-file "$KEYSTORE_PASSWORD_FILE"
```

The file must contain the import password. Select the appropriate owner's account.
