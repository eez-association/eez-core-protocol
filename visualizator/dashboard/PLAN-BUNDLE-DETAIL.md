# Bundle Detail View — Remaining Work

## Problem
The BundleDetail view is missing several sections that exist in `index.html`:
- Execution tables (L1 & L2) with per-step add/consume animation
- Contract state panel
- Call flow strip per step
- Node labels are wrong due to address collision between chains (same address on L1 and L2 = different contracts)

## Root Cause: Address Collision
Counter B on L2 = `0xe7f1...` = same address as Rollups on L1.
`bundleArchitecture.ts` uses raw address as node ID → only one entry per address → "Rollups'" proxy label is wrong.

## Phases

### Phase 1: Fix Address System in bundleArchitecture.ts
- Use chain-prefixed node IDs: `l1:0xaddr` / `l2:0xaddr`
- Fix proxy labeling: look up original on the OPPOSITE chain
- Fix edge references and step highlights to use prefixed IDs
- This eliminates the "Rollups'" bug and separates same-address-different-chain nodes

### Phase 2: Add Execution Tables to BundleDetail
- Compute per-step L1/L2 table snapshots from bundle events
- Reuse `processEventForTables` from eventProcessor.ts
- Render two side-by-side table panels with entry status (ja/ok/jc/consumed)
- Show entries expanding/collapsing with decoded action fields

### Phase 3: Add Contract State Panel
- Track rollup state changes from events (BatchPosted stateDeltas, L2ExecutionPerformed, RootUpdated)
- Show per-step state panel in BundleDetail with changed values highlighted

### Phase 4: Call Flow Strip
- Add horizontal call flow diagram per step (like index.html)
- Show: source → proxy → manager → destination with arrow labels
