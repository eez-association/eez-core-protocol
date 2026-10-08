# Chiado Balancer V3 flash-loan mock

Deploys Mock USD (mUSD, 6 decimals) and a single-token Vault implementing the
repository's `IBalancerV3Vault`: `unlock`, `sendTo`, `settle`, `getReservesOf`.
Default available liquidity is 1,000,000 mUSD. Amounts are always base units
(1 mUSD = 1,000,000 units). The token has an unrestricted mint faucet.

This is a test double, not an official Balancer deployment. It supports the
existing borrower's fee-free transfer/repay/settle flow; it has no pools, swaps,
nested unlocks, prepaid credits or multi-caller accounting. Unpaid or unsettled
loans revert the entire transaction. Only the unlocking contract can send/settle.
Only the owner can change available liquidity, and only between loans.

## Deploy

Use your funded Chiado wallet through Foundry's normal signer options. The script
rejects any chain ID other than 10200. First simulate:

```bash
source ./chain.envdevnet
forge script script/balancer/ChiadoMock.s.sol:ChiadoMock \
  --rpc-url "$L1_RPC" --account YOUR_CHIADO_ACCOUNT
```

Add `--broadcast` to deploy after reviewing the simulation. Foundry records
transactions under `broadcast/ChiadoMock.s.sol/10200/`. Preserve those receipts;
rerunning `run` creates new contracts. Set `MOCK_BALANCER_LIQUIDITY` to override
initial liquidity in base units. Output includes token, Vault and owner addresses.

## Change liquidity or mint tokens

```bash
# Set the Vault's total available liquidity to 5,000,000 mUSD (owner only).
cast send "$MOCK_VAULT" "setLiquidity(uint256)" 5000000000000 \
  --rpc-url "$L1_RPC" --account YOUR_CHIADO_ACCOUNT

# Give a wallet 10,000 mUSD (any signer can use the faucet).
cast send "$MOCK_TOKEN" "mint(address,uint256)" "$RECIPIENT" 10000000000 \
  --rpc-url "$L1_RPC" --account YOUR_CHIADO_ACCOUNT

cast call "$MOCK_VAULT" "getReservesOf(address)(uint256)" "$MOCK_TOKEN" \
  --rpc-url "$L1_RPC"
```

Direct token donations do not increase accounted loan capacity; use
`setLiquidity` to set both reserves and actual balance.

## Existing cross-chain borrower

Pass these Vault/token addresses to `BalancerV3FlashBorrower`'s constructor,
along with the correct Chiado EEZ bridge, L2 executor, rollup ID and owner.
Configure a matching L2 executor with the same L1 token address.
The mock deployment script deploys only the token/Vault. Use the devnet entry
point below for the complete cross-chain flow.

## Run the existing Balancer flow on devnet

```bash
bash script/balancer/devnet.sh deploy
bash script/balancer/devnet.sh trigger
bash script/balancer/devnet.sh status
```

`devnet.sh` selects `chain.envdevnet`, Chiado chain 10200 and devnet L2 chain
906969, then calls the existing `run.sh` functions. `Devnet.s.sol` inherits the existing
Foundry deployment/verification functions. Put the deployment addresses in the
ignored `chain.envdevnet` file as `BALANCER_TOKEN`, `BALANCER_VAULT`,
`BALANCER_L1_BRIDGE`, and `BALANCER_L2_BRIDGE`. The bridges must already be
deployed and linked. The runner exports those values for Foundry; do not commit
environment files or deployment journals.

`deploy` deploys/configures the L2 executor/NFT and L1 borrower using the same
three stages as mainnet. It does not deploy or reconfigure bridges.
Addresses, signed transactions and receipts are saved under
`tmp-balancer-devnet/`. Resume using that same journal; completed stages are
skipped. Preflight checks chain IDs, bridge counterparts and composer managers.
Use a separate journal for each network/deployment.

`trigger` borrows 80% of live capacity: 800,000 mUSD with the default liquidity.
It submits only through L2_FRONT with fixed gas. `status` verifies the NFT,
the exact canonical L1 settlement, and the token mint/burn/repayment transfers.
The original mainnet entry point keeps its chain defaults and reads addresses from its selected environment file.

If the wallet has no devnet L2 native funds, fund it with the existing setup:
`bash script/e2e/run/network/setup.sh 0.001 chain.envdevnet`.

For a failed/pending attempt, inspect `status` first. The existing rerun helper
is available as `bash script/balancer/devnet.sh rerun tmp-balancer-devnet [status]`.
A wallet can claim only one NFT per executor deployment; after a successful
claim, use a new `BALANCER_RUN_DIR` and deploy again to run another demonstration.

## Tests

```bash
forge test --match-contract MockBalancerV3VaultTest
```


If no L2 receipt exists, `status` also queries `eez_getCrossChainTransaction` on
`L2_RPC`, prints the composer lifecycle/rejection and saves the full response in
`cross-chain-status.json`. Terminal results exit nonzero; unavailable lookup
results are reported as unknown rather than pending.

The same read-only lookup can be run directly:

```bash
source ./chain.envdevnet
cast rpc --rpc-url "$L2_RPC" eez_getCrossChainTransaction \
  "$TX_HASH"
```
