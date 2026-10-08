# Balancer mainnet runner

For the Chiado mock and `chain.envdevnet`, use `bash script/balancer/devnet.sh`
with `deploy`, `trigger`, or `status`. See [Chiado instructions](CHIADO_MOCK.md).
The devnet entry point reuses this runner with its own contracts and journal.

Two entry files replace the Python runner:

- `Mainnet.s.sol`: one Foundry script contract with deployment, configuration,
  preflight and verification functions.
- `run.sh`: sources the existing `chain.env` through the E2E configuration loader,
  invokes Foundry, journals progress and submits the L2 trigger with `cast`.

No packages need installing. Dependencies are the repository's existing Foundry,
Bash, jq, curl, bc and flock tools. Each deployed contract and interface remains
in its own file under `src/periphery/balancer/`.

## Commands

From the repository root:

```bash
bash script/balancer/run.sh preflight
bash script/balancer/run.sh deploy
bash script/balancer/run.sh trigger
bash script/balancer/run.sh status
```

`preflight` and `status` do not send transactions. `deploy` and `trigger` do.
No `all` action implicitly deploys and starts a loan. All artifacts go to the
ignored `tmp-balancer-mainnet/` directory with restrictive file permissions.
Override that destination with `BALANCER_RUN_DIR`.

For the one-time alternative **deploy on L1 from L2**, replace `deploy` with:

```bash
bash script/balancer/run.sh deploy-via-l2
```

This keeps the same journal and completed L2 executor/NFT. It prepares the L1
borrower's deterministic CREATE2 recipe, verifies the common L1 factory's exact
bytecode, and creates the factory's EEZ proxy on L2 if missing. A fixed-gas L2
transaction sends the raw `salt + initCode` payload through `L2_FRONT`. The borrower
is created on Ethereum L1, with the wallet explicitly passed as owner. No custom
deployment helper contract is added. The normal configuration and flash-loan
steps remain the same.

L1 execution gas still exists and is paid by the composer for this route; its
admission/sponsorship policy determines whether it will accept the deployment.
The runner does not silently fall back to a wallet-paid L1 transaction. Before
configuring L2 it requires a successful L2 receipt, the canonical L1 settlement
mapping, and the expected borrower's on-chain configuration. The existing
`deploy-l1.done` marker is written only after these checks.

The recipe is pinned in `create2-recipe.json`; changing bytecode or constructor
arguments mid-run stops the runner. If a remote submission times out, rerun
`deploy-via-l2` with the same directory: it verifies the saved transaction hash
without resending. An uncertain direct L1 attempt blocks switching paths until
it is reconciled. The CREATE2 trigger uses `BALANCER_CREATE2_GAS` (default 3,500,000)
and is never estimated as a normal local L2 transaction.

Deployment addresses are read from the selected ignored environment file:
`BALANCER_TOKEN`, `BALANCER_VAULT`, `BALANCER_L1_BRIDGE`, and
`BALANCER_L2_BRIDGE`. Use `DEVNET_ENV=chain.envmainnet` to select your local
mainnet configuration. RPC URLs, signer credentials and actual deployment
addresses belong in that file, never in committed source or documentation.

Neither bridge is deployed or reconfigured. Preflight checks each bridge's rollup,
counterpart and manager against the composer. USDC is the native L1 token; the NFT
threshold is `10_000e6`. `availableLoan()` exposes 100% of the lesser of accounted
reserves and actual Vault balance. The runner selects 80% once, records the observed
capacity and requested amount in `state.json`, and signs that exact request. The
borrower checks live capacity and borrows exactly the request. A request below the
NFT minimum stops before signing; falling liquidity below the request reverts.

## Run a fresh loan using an existing deployment

```bash
bash script/balancer/rerun.sh tmp-balancer-mainnet
bash script/balancer/rerun.sh tmp-balancer-mainnet status
```

The separate `rerun.sh` helper loads `chain.env` and uses the contracts and wallet
recorded in the supplied deployment directory. It never deploys contracts. Each
attempt saves its own state, signed transaction, hash and receipts under
`DEPLOYMENT_DIR/reruns/attempt.*`; `status` selects the latest attempt. The original
transaction artifacts remain intact. Both deployment routes remain available:
`run.sh deploy` sends directly to each chain, while `run.sh deploy-via-l2` creates
the L1 borrower through L2.

New deployments record fixed-amount behavior. Original journals without that
marker use the old borrower's minimum semantics. The helper signs a fresh request
with current nonce/fees: 80% of observed capacity for the updated borrower, or the
10,000 USDC minimum for the original borrower. It refuses reported pending wallet
transactions and already-claimed NFTs. If an unmined prior attempt still has the
current nonce, it raises the gas price at least 12.5% plus 1 wei, within the usual
fee cap. No automatic resend follows a submission error. Inspect status first.
A successful claim cannot be repeated for the same wallet/NFT deployment.

## Transaction routing and E2E compatibility

`deploy` runs `deployL2`, `deployL1`, then `configureL2`, as separate Foundry
invocations on `L2_RPC`, `L1_RPC`, and `L2_RPC`. Each is first simulated without
broadcast. The runner checks the planned sender, nonce, gas, cost and wallet
balance, then signs that exact Foundry plan with explicit gas/fee fields using
`cast mktx`, as the E2E staged runner does. It does not run a second Foundry
broadcast simulation that could change the gas after the fee check. The decoded
signature is checked against the plan before submission to the direct chain RPC.
Foundry dry-run plans and runner raw transactions/hashes/receipts are retained.
Read-only verification checks owners, token, Vault, bridges, NFT parameters and
both proxy bindings. Existing legacy Foundry deployment journals remain valid.

The cross-chain trigger follows `script/e2e/lib/E2EBase.sh`:

- No `eth_estimateGas`, `cast estimate`, or Foundry execution simulation of
  `start()` is attempted. The composer supplies the required execution table.
- A fixed 2,500,000 gas limit is provided, overridable with `E2E_TRIGGER_GAS`.
- The higher nonce from the direct L2 node and `L2_FRONT` is used. A failed nonce
  query stops the runner, rather than silently selecting zero.
- `cast mktx` signs with explicit chain, nonce, gas and fee fields, without RPC
  estimation. The decoded sender, target, chain, value, calldata, nonce and fees
  are checked before sending.
- A local copy of the E2E `_send_raw_tx` helper submits **only to `L2_FRONT`**. No direct
  L2 RPC fallback is used. `L1_FRONT` supplies composer metadata, not this trigger.
- `status` looks up the L2 receipt through `L2_FRONT`, falling back to `L2_RPC`
  when the front has no receipt or is unavailable. The remote deployment wait
  uses the same fallback. Receipt lookups never resend transactions.

The default gas-cost budget is 0.002 ETH per transaction, configurable with
`BALANCER_MAX_FEE_WEI`. Both deployments and the trigger bind that budget to the
exact signed gas-limit and gas-price fields. Gas prices are twice the RPC's
suggested legacy price; funding the wallet does not override the cap. No native
ETH value is transferred by the trigger. A changed borrower needs a fresh executor/NFT if the old executor is already
configured. Use a new `BALANCER_RUN_DIR`; preserve previous deployment journals.

## Completion and recovery

A successful L2 receipt alone is insufficient. `status` requires the L2 completion
event and NFT ownership. It queries `eez_getSettlementByL2Block` on `L2_RPC`,
requires the receipt's exact L2 block number/hash to be canonical, and checks the
mapped L1 transaction and block hashes against the canonical L1 chain. It then
requires the successful repayment event in that exact receipt and the four exact
USDC transfers (Vault → borrower → bridge → borrower → Vault), the L2 wrapped-token
mint/burn, zero leftover executor funds and a cleared bridge allowance. An
unavailable, pending or mismatched mapping cannot report success; there is no
amount-only scan fallback. Canonical settlement is not a claim of irreversible
Ethereum finality.

Deployment stages are marked before broadcast. An interrupted or uncertain stage
stops on rerun: inspect its Foundry journal and receipts before recovering it.
Likewise, `trigger.hash` is saved before submission. A timeout does not authorize a
new nonce or duplicate send. The signed raw trigger is kept for manual inspection;
no private key is written to these logs. The wallet journal is locked to prevent
concurrent use of the same run directory. Use the same run directory for recovery.
The existing `deploy-l2.done`, deployment receipt and executor address are
preserved by the audit fixes: rerunning `deploy` skips that completed step.

To resume using an existing mainnet journal and your configured fee cap:

```bash
export BALANCER_RUN_DIR="$PWD/tmp-balancer-mainnet"
export DEVNET_ENV=chain.envmainnet
bash script/balancer/run.sh preflight
bash script/balancer/run.sh deploy
bash script/balancer/run.sh trigger
bash script/balancer/run.sh status
```

Run these commands from the repository root, in order; proceed to the next one
only after the previous succeeds. A pending status can be checked again without
resending `trigger`. Do not delete the journal or `.started`/`.done` files.

## Local tests

```bash
forge test --match-contract 'BalancerMainnetTest|BalancerCrossChainTest|BalancerV3FlashBorrowerTest'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/balancer/tests -v
```

Solidity tests execute the actual deployment functions against local fixtures at
the configured addresses. Runner tests use a public test key and real offline
Foundry signing with a mocked network. They never load `chain.env` or broadcast to
mainnet. Synchronous bridge integration tests model EEZ transport; live composer
execution remains unvalidated.

## Audit regression coverage

The audit reproduced and fixed two runner defects: accepting another same-amount
loan's L1 receipt, and allowing a second broadcast simulation to change gas after
the budget check. `tests/test_audit_regressions.py` covers exact signed deployment
fees, continuation from an L2-complete journal, canonical settlement matching,
pending correlation and reorg/mismatched-receipt rejection. No E2E source files
were changed, and no contracts need redeploying for these runner fixes.
