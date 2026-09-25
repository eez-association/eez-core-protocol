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

# L2: use the ROLLUP_ID printed by L1. EEZL2 is not upgradeable.
forge script deployment/Deploy.s.sol:DeployL2 \
  --rpc-url "$L2_RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --sig 'run(uint64,address,bool)' "$ROLLUP_ID" "$SYSTEM_ADDRESS" "$USE_GAS_LEFT"
```

`SYSTEM_ADDRESS` loads L2 execution tables; `USE_GAS_LEFT` selects observed-gas hashing.

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
