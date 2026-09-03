# Cross-Chain Dashboard — Testing & Deployment Guide

## Quick Start (E2E)

```bash
# From the project root (sync-rollups/)
bash visualizator/dashboard/scripts/run-e2e.sh
```

This single command:
1. Starts 2 local Anvil chains (L1 on :8545, L2 on :8546)
2. Deploys all contracts in the correct order
3. Runs Scenario 1 (L1 -> L2 cross-chain call)
4. Updates `public/config.json` with deployed addresses
5. Keeps Anvil nodes alive (Ctrl+C to stop)

Then in a separate terminal:
```bash
cd visualizator/dashboard
npm run dev
```

Open http://localhost:5173 and click **Connect**. You should see 11 events stream in.

## What You Should See

### Architecture Diagram
- **L1 lane**: Rollups (Manager), Rollups' (proxy for B on L2), Prover, 0x5fc8 (caller A)
- **L2 lane**: ManagerL2, proxy for C, SYSTEM, proxy for A
- Active nodes glow cyan/blue/purple depending on the current step
- Edge labels (postBatch, loadTable, call, proxy, execIncoming) appear in cyan when active

### Execution Tables
- **L1 Table**: 1 entry added at step 3 (BatchPosted), consumed at step 7 (ExecutionConsumed)
- **L2 Table**: 1 entry added at step 8 (ExecutionTableLoaded), consumed at step 11 (ExecutionConsumed)
- Entries expand to show full call details (targetAddress, data, sourceAddress, sourceRollupId, etc.)
- Entry states: cyan glow = just added, red border + strikethrough = just consumed, dimmed = old consumed

### Contract State
- Rollup 1 root changes from initial to post-increment state

### Step Timeline (right sidebar)
- 11 steps total, each with step number, chain badge (L1/L2), event name, and description
- Table change indicators: `+L1` (entry added), `-L1 consumed` (entry consumed)

## Navigation

| Key | Action |
|-----|--------|
| Arrow Up / Arrow Left | Previous step |
| Arrow Down / Arrow Right | Next step |
| Escape | Go to latest (live) |
| Click "Latest" button | Return to live view |
| Click any step | Jump to that step |

## Deployment Scripts

### Prerequisites
- [Foundry](https://book.getfoundry.sh/) installed (`forge`, `cast`, `anvil`)
- Node.js 18+

### Multi-Stage Deployment (run-e2e.sh)

The script deploys contracts across L1 and L2 in 5 stages using Forge scripts:

| Stage | Script | Chain | What It Does |
|-------|--------|-------|-------------|
| 1 | `DeployL2Base` | L2 | Deploys ManagerL2 + Counter (B) |
| 2 | `DeployL1` | L1 | Deploys ZK Verifier, Rollups, creates rollup, Counter (C), proxy B', CounterAndProxy (A) |
| 3 | `DeployL2Apps` | L2 | Deploys proxy C', CounterAndProxy (D) |
| 4 | `Scenario1_L2` | L2 | Loads execution table + executes incoming cross-chain call (as SYSTEM) |
| 5 | `Scenario1_L1` | L1 | Posts batch + Alice calls A.increment() |

Addresses are passed between stages via environment variables.

### SYSTEM Impersonation

The L2 execution table is loaded by the SYSTEM address (`0xFFfF...FfFf`). On Anvil:
```bash
# Fund SYSTEM
cast send --private-key $PK --rpc-url $L2 $SYSTEM --value 10ether

# Impersonate
cast rpc anvil_impersonateAccount $SYSTEM --rpc-url $L2

# Run as SYSTEM (Forge script)
forge script Deploy.s.sol:Scenario1_L2 --rpc-url $L2 --sender $SYSTEM --unlocked --broadcast

# Stop impersonating
cast rpc anvil_stopImpersonatingAccount $SYSTEM --rpc-url $L2
```

## Configuration

### config.json (default addresses)

`public/config.json` is loaded on startup and populates the connection fields:

```json
{
  "l1RpcUrl": "http://localhost:8545",
  "l2RpcUrl": "http://localhost:8546",
  "l1ContractAddress": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  "l2ContractAddress": "0x5FbDB2315678afecb367f032d93F642f64180aa3"
}
```

The run-e2e.sh script auto-updates this file after deployment. You can also edit it manually or change values in the UI before connecting.

## Event Flow (Scenario 1: L1 -> L2)

```
Step  Chain  Event                           Table Change
  1   L1    RollupCreated                    -
  2   L1    CrossChainProxyCreated           -              (B' proxy deployed)
  3   L1    BatchPosted                      +L1 entry      (1 deferred entry)
  4   L2    CrossChainProxyCreated           -              (C' proxy deployed)
  5   L1    CrossChainCallExecuted           -              (A calls B')
  6   L1    EntryExecuted                    -              (entry rolling-hash verified)
  7   L1    ExecutionConsumed                -L1 entry      (CALL matched)
  8   L2    ExecutionTableLoaded             +L2 entry      (SYSTEM loads table)
  9   L2    CrossChainCallExecuted           -              (B.increment() runs)
 10   L2    CrossChainProxyCreated           -              (A' proxy auto-created)
 11   L2    ExecutionConsumed                -L2 entry      (RESULT matched)
```

## Cross-Chain Correlation

When the same `crossChainCallHash` appears in `ExecutionConsumed` events on both L1 and L2, these events represent the same cross-chain operation. The dashboard shows a correlation indicator on matched events.

## Build & Development

```bash
cd visualizator/dashboard
npm install          # Install deps
npm run dev          # Dev server (port 5173)
npm run build        # Production build
npx tsc -b --noEmit  # Type check
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "0 events" after connecting | Check that Anvil nodes are running and config.json has correct addresses |
| Ports in use | Kill existing processes: `lsof -ti:8545 \| xargs kill -9` |
| Forge script fails | Run with `-vvv` flag for verbose output |
| Table entries not showing | Verify BatchPosted/ExecutionTableLoaded events appear in timeline |
| Node labels show raw addresses | This is expected for auto-discovered contracts; proxy nodes show meaningful labels |
