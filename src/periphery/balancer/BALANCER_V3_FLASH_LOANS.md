# L2-initiated Balancer V3 flash loan

This demo follows the existing `FlashLoanBridgeExecutor` pattern:
**borrow → bridge to L2 → claim NFT → bridge back → repay**.
The user starts on L2. The existing EEZ bridges carry the tokens. There is no
trading strategy or expected token profit; the result is the NFT.

## Three contracts, one file each

- [BalancerV3FlashBorrower.sol](./BalancerV3FlashBorrower.sol):
  the L1 borrower directly implements the fixed bridge/claim/return sequence.
  There is no extra L1 executor or user-supplied list of arbitrary calls.
- [BalancerFlashLoanL2.sol](./BalancerFlashLoanL2.sol):
  the L2 entry point and callback. `start(minAmount)` remembers the initiating
  wallet, calls the borrower through its EEZ proxy, and requires the callback to
  complete. `claimAndBridgeBack(amount)` claims for that wallet and burns exactly
  the borrowed amount through the L2 bridge.
- [BalancerFlashLoanNFT.sol](./BalancerFlashLoanNFT.sol):
  permissionless `claimFor(recipient)`. The caller must hold the required wrapped
  token balance; nobody can use a third party's balance. Each recipient can claim
  once. Tokens are not consumed or locked, so a holder may qualify more than one
  recipient. This is an intentional temporary-balance demonstration.

The three small Balancer interfaces live in `src/periphery/balancer/interfaces/`,
one interface per file.

## Flow

1. A wallet calls `start(minAmount)` on L2.
2. The L2 executor calls the L1 borrower's `execute(minAmount)` through EEZ.
3. The borrower checks the requested amount against the lesser of Balancer's
   accounted reserves and actual token balance, then borrows exactly that amount
   through `unlock`. The L2 executor applies the NFT minimum before calling L1.
4. The Vault calls `onFlashLoan(amount)`. The borrower calls `sendTo` and approves
   the existing L1 bridge for the exact amount, then calls `bridgeTokens`.
5. The existing L2 bridge mints wrapped USDC to the L2 executor. The borrower calls
   the executor's authenticated callback through EEZ.
6. The executor calls the public NFT claim and the existing L2 bridge. The bridge
   burns wrapped USDC and the L1 bridge releases USDC directly to the borrower.
7. The borrower transfers USDC back to Balancer and calls `settle`, all before the
   same L1 Vault unlock returns. A missing return reverts the operation.

The [Balancer V3 flash-loan guide](https://docs.balancer.fi/concepts/vault/flash-loans.html)
describes this unlock/send/repay/settle API. Configure the token, Vault and
existing bridge addresses in your ignored environment file using
`BALANCER_TOKEN`, `BALANCER_VAULT`, `BALANCER_L1_BRIDGE` and `BALANCER_L2_BRIDGE`.

It uses `10_000e6` as the NFT minimum. The runner selects 80% of observed full
usable liquidity once and signs that exact amount. Execution checks current
capacity without resizing the loan; insufficient capacity reverts. Wrapped USDC is resolved from the
bridge, including on the first transfer. No prefunding is required. Any existing
borrower or executor token balance must survive the round trip.

## Ownership and callbacks

Both the borrower and the L2 executor use OpenZeppelin `Ownable`. The L2 owner
calls `configure(borrowerL1)` once after deploying the borrower; that binding
cannot be changed even after an ownership transfer. Claims and L2 `start` are
public. The borrower accepts loan initiation only from its configured L2 executor
proxy, and the executor accepts callbacks only from its configured borrower
proxy. The Vault callback must match the active amount and can run only once.

`withdrawToken(token, recipient, amount)` is owner-only recovery of leftover
funds between loans. It is not repayment or part of the NFT flow. OpenZeppelin
`ReentrancyGuard` blocks recovery while a loan is active. The fixed strategy uses
`SafeERC20.forceApprove` and clears its bridge allowance.

## Local verification

```bash
forge test --match-path 'test/periphery/**/Balancer*.t.sol' -vv
```

These tests run the actual Bridge mint/burn implementation with simulated
synchronous transport and a small Vault accounting mock. They cover the round
trip, permissionless claims, authentication, ownership, incomplete callbacks,
rollback, preserved old balances, fixed sizing across changing liquidity,
and rejection when capacity falls below the request.

For the mainnet-fork test, set `MAINNET_RPC_URL` and optionally
`MAINNET_FORK_BLOCK`, then run:

```bash
forge test --match-contract BalancerCrossChainForkTest -vv
```

The fork test uses actual Balancer/USDC with local Bridge instances and simulated
EEZ transport. It skips when no RPC is supplied and does not send live
transactions. Live EEZ composer execution remains unvalidated. The contracts
inherit the existing experimental Bridge's trust assumptions and are outside
the protocol audit scope.

## Deployment tooling

The borrower constructor takes `(vault, token, bridgeL1, executorL2, l2RollupId, owner)`.
The L2 executor constructor takes `(bridgeL2, tokenL1, nftMinimum, owner)` and
creates the NFT. Deployment order is L2 executor/NFT, L1 borrower, then one-time
L2 configuration. [Mainnet.s.sol](../../../script/balancer/Mainnet.s.sol) contains
all deployment/configuration and verification functions in one script contract.
[run.sh](../../../script/balancer/run.sh) orchestrates them and submits the L2
trigger through `L2_FRONT` with an explicit gas limit; it does not estimate the
cross-chain trigger. The old Python runner has been removed. See the
[runner documentation](../../../script/balancer/README.md) for commands, fee checks,
journals, recovery and tests. `deploy` and `trigger` broadcast real transactions;
existing deployment journals must be preserved. A configured executor cannot be
rebound, so deploying a changed borrower requires a fresh executor/NFT pair and a
new run directory. The runner checks the exact signed fee budget and canonical
settlement mapping before reporting success.
