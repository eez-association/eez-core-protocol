# Integration Test Plan — Flat Execution Model

## Context

Integration tests cover cross-chain execution scenarios using the flat calls/rolling-hash model. Each test constructs `ExecutionEntry` structs with flat `calls[]` arrays, computes rolling hashes with the 4 tagged events, and verifies end-to-end execution across L1 (Rollups) and L2 (CrossChainManagerL2).

## Legend

- **A** = CounterAndProxy on L1 (calls a proxy target, updates local counter)
- **B** = Counter on L2 (simple increment)
- **C** = Counter on L1 (simple increment)
- **D** = CounterAndProxy on L2 (calls a proxy target, updates local counter)
- **X'** = CrossChainProxy for X

## Test Files

| File | Tests | Coverage |
|---|---|---|
| `IntegrationTest.t.sol` | 4 scenarios | Core cross-chain calls |
| `IntegrationTestBridge.t.sol` | 3 tests | Bridge ether/token/roundtrip |
| `IntegrationTestFlashLoan.t.sol` | 1 test | Cross-chain atomic flash loan |

---

## IntegrationTest.t.sol — 4 Scenarios

### Scenario 1: L1 calls L2 (simple deferred entry)

**Flow:** Alice calls A, A calls B' proxy on L1, entry consumed with pre-computed result.

- 1 deferred `ExecutionEntry` on L1 with `actionHash` matching `(rollupId=L2, dest=B, source=A, sourceRollup=MAINNET)`
- `calls[]` is empty (simple consumption, no sub-calls)
- `returnData = abi.encode(1)` (pre-computed result of B.increment())
- Triggered by Alice calling B' proxy, which calls `executeCrossChainCall`

### Scenario 2: L2 calls L1 (simple deferred entry)

**Flow:** Alice calls D on L2, D calls C' proxy, entry consumed.

- 1 deferred `ExecutionEntry` on L2 loaded via `loadExecutionTable`
- Same pattern: empty `calls[]`, pre-computed `returnData`
- Triggered by Alice calling C' proxy on L2

### Scenario 3: Nested L2 entry (cross-manager)

**Flow:** L2 entry has `calls[]` that execute A.incrementProxy() via A' proxy. Inside A, a call crosses into Rollups (different manager), consuming a separate L1 deferred entry.

- L2 entry with 1 call in `calls[]`, `callCount=1`
- Rolling hash computed with CALL_BEGIN(1) + CALL_END(1)
- L1 has a separate deferred entry consumed by the cross-manager call

### Scenario 4: Nested L1 entry (cross-manager)

**Flow:** Mirror of Scenario 3. L1 entry with `calls[]` triggering execution on L2 via cross-manager call.

- L1 entry with 1 call in `calls[]`, `callCount=1`, with state deltas
- Rolling hash computed with CALL_BEGIN(1) + CALL_END(1)
- L2 has a separate entry consumed by the cross-manager call

---

## IntegrationTestBridge.t.sol — 3 Tests

### test_BridgeEther_L1toL2

ETH bridge from L1 to L2. Posts a batch on L1 that locks ETH, loads an L2 entry that delivers ETH to destination via Bridge.receiveTokens.

### test_BridgeTokens_L1toL2

ERC20 token bridge. L1 entry locks tokens in Bridge. L2 entry delivers wrapped tokens via Bridge.receiveTokens, deploying WrappedToken on L2.

### test_BridgeTokens_Roundtrip

Full lock -> mint -> burn -> release cycle. 4 phases:
1. L1: lock tokens via Bridge.bridgeTokens (deferred entry)
2. L2: mint wrapped tokens via Bridge.receiveTokens (system loads entry)
3. L2: burn wrapped tokens via Bridge.bridgeTokens (deferred entry)
4. L1: release original tokens via immediate entry in postBatch

---

## IntegrationTestFlashLoan.t.sol — 1 Test

### test_CrossChainFlashLoan

Atomic cross-chain flash loan using Bridge + FlashLoan + FlashLoanBridgeExecutor + FlashLoanersNFT.

Phase 1: Bridge tokens from L1 to L2, fund executor
Phase 2: Execute flash loan — borrow tokens on L1, bridge to L2, claim NFT, bridge back, repay

---

## Rolling Hash Construction

All entries with `calls[]` need a pre-computed `rollingHash`. Start with `bytes32(0)`:

```
For each call (1-indexed callNumber):
  hash = keccak256(abi.encodePacked(hash, uint8(1), uint256(callNumber)))   // CALL_BEGIN
  hash = keccak256(abi.encodePacked(hash, uint8(2), uint256(callNumber), success, retData))  // CALL_END

For nested actions (wrap inner calls):
  hash = keccak256(abi.encodePacked(hash, uint8(3), uint256(nestedNumber)))  // NESTED_BEGIN
  ... inner calls ...
  hash = keccak256(abi.encodePacked(hash, uint8(4), uint256(nestedNumber)))  // NESTED_END
```

## API Reference

```solidity
postBatch(ExecutionEntry[] entries, StaticCall[] staticCalls, uint256 transientCount, uint256 transientStaticCallCount, uint256 blobCount, bytes callData, bytes proof)
loadExecutionTable(ExecutionEntry[] entries, StaticCall[] staticCalls)
executeL2TX()  // no arguments, consumes next entry with actionHash == 0
```

## Verification

```bash
forge test --match-contract IntegrationTest -vvv
forge test --match-contract IntegrationTestBridge -vvv
forge test --match-contract IntegrationTestFlashLoan -vvv
```
