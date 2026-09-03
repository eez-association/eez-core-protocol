# Dashboard Evolution Plan

## Context

**Goal**: Transform the dashboard from a raw event-monitoring tool into a full **cross-chain transaction explorer** that mirrors the visual richness of `visualizator/index.html` — but driven by **live chain data** instead of hardcoded scenarios.

The `index.html` visualizer is a step-by-step execution replay with:
- Scenario tabs (L1→L2, L2→L1, L2→L1→L2, L1→L2→L1)
- A persistent **architecture SVG diagram** with L1/L2 lanes, nodes (contracts, proxies, EOAs, system), edges with arrows, and **active highlighting + glow** per step
- **Side-by-side execution tables** (L1 / L2) showing entries being added (cyan glow) and consumed (red strikethrough)
- **Contract state panels** tracking counter values and root transitions
- A **call flow strip** showing the chain of calls with arrow diagrams
- **Expandable entry details**: full Action struct fields, next action, state deltas
- Step-by-step playback with prev/next/play controls and keyboard nav

The dashboard already has most of this infrastructure (architecture diagram, tables, events, replay), but is missing the "transaction bundling" and "detail view" experiences that make index.html so useful.

---

## What Already Exists (Dashboard)

| Feature | Status |
|---|---|
| Event streaming from L1 + L2 chains | Done |
| Real-time table evolution (add/consume) | Done |
| Architecture diagram with active highlighting | Done |
| Node/edge auto-discovery from events | Done |
| Rollup state tracking | Done |
| Event replay / time-travel | Done |
| Transaction introspection (logs) | Done |
| Cross-chain event correlation (by actionHash) | Done (lib, not in UI) |
| CallFlowStrip component | Done (unused) |
| Keyboard navigation | Done |

---

## What's Missing — Feature Plan

### 1. Cross-Chain Transaction Bundling

**Problem**: Events appear as a flat list. The user can't see which events form a single cross-chain transaction (e.g., a BatchPosted + ExecutionTableLoaded + multiple ExecutionConsumed that all relate to the same operation).

**Solution**: Group events into **Transaction Bundles**.

#### 1.1 Bundle Detection (`lib/crossChainCorrelation.ts`)
- Already has `findCorrelatedPairs()` (matches ExecutionConsumed by actionHash across chains) and `findCorrelatedEntries()` (matches BatchPosted entries with ExecutionTableLoaded entries by actionHash)
- **Add**: `buildTransactionBundles(events)` function that:
  1. Groups events by shared actionHashes
  2. A bundle = all events that share at least one actionHash (transitive closure)
  3. Each bundle gets: `id`, `title` (auto-generated like "L1→L2 Call" based on action types), `events[]`, `actionHashes[]`, `chains[]` (which chains involved), `direction` (L1→L2, L2→L1, L1→L2→L1, etc.)
  4. Single-event bundles for standalone events (RollupCreated, etc.)

#### 1.2 Bundle List View (`components/BundleList.tsx`)
- Replace or augment the EventTimeline with a **bundled view**
- Each bundle card shows:
  - Direction badge (L1→L2, etc.) with color
  - Summary: "Alice calls A.increment() → B on L2"
  - Number of events involved
  - Chains touched
  - Status: complete (all consumed) / in-progress (some pending)
  - Timestamp / block range
- Clicking a bundle opens the **Bundle Detail View**

#### 1.3 Toggle: Flat Events vs Bundled View
- Add a toggle in the EventTimeline header: `Events | Bundles`
- Flat = current behavior, Bundles = grouped view

---

### 2. Bundle Detail View (index.html-style)

**Problem**: When a user clicks a bundled transaction, they need to see the full execution flow — like index.html's per-scenario view but populated from real chain data.

**Solution**: A **modal or expanded panel** that mirrors index.html's layout.

#### 2.1 Detail Panel (`components/BundleDetail.tsx`)
When a bundle is clicked, show:

1. **Header**: Direction, summary, block range, tx hashes involved
2. **Architecture Diagram** (reuse existing `ArchitectureDiagram.tsx`):
   - Filter to only show nodes/edges relevant to this bundle
   - Step-through highlighting as user navigates events within the bundle
3. **Call Flow Strip** (use existing `CallFlowStrip.tsx`):
   - Build a horizontal arrow diagram showing the full call chain
   - Nodes: EOA → Contract → Proxy → Manager → (cross-chain) → Proxy → Contract
   - Arrows with labels (function selectors, return data)
   - Reconstruct from the Action structs in the execution entries
4. **Execution Tables snapshot**:
   - Show only entries involved in this bundle
   - Step through add→consume lifecycle
5. **Step-by-step playback** within the bundle:
   - Prev/Next buttons to walk through the bundle's events
   - Each step highlights the active nodes/edges/entries
   - Matches index.html's step list on the left

#### 2.2 Call Flow Reconstruction (`lib/callFlowBuilder.ts`)
- New file that builds a call flow from a bundle's events:
  1. Extract all Actions from ExecutionConsumed events
  2. Order by scope (root call first, then nested)
  3. Build a tree: CALL → (nested CALL → RESULT) → RESULT
  4. Flatten tree into a linear flow for the strip diagram
  5. Include: source address, destination, function selector, return data, chain

#### 2.3 Step List (`components/BundleStepList.tsx`)
- Vertical list of steps within the bundle (like index.html's `.steps` section)
- Each step shows:
  - Step number (circle)
  - Chain badge (L1/L2)
  - Title (auto-generated from action: "Alice calls A.increment()")
  - Detail text (what happens: "B'.fallback() → Rollups.executeCrossChainCall")
  - Table changes: "+L1 CALL...", "-L2 consumed"
- Clickable to jump to that step
- Active step highlighted

---

### 3. Action Hash Decoding

**Problem**: Action hashes are opaque `bytes32`. The user wants to see what action produced that hash.

**Solution**: Compute and display the decoded action hash.

#### 3.1 Action Hash Computation (`lib/actionHashDecoder.ts`)
- The actionHash = `keccak256(abi.encode(Action))` where Action is the struct
- Given an Action struct (from ExecutionConsumed event args, or from table entries), compute:
  1. `abi.encode(action)` — pack the Action struct fields
  2. `keccak256(result)` — hash it
  3. Display both the hash and the decoded fields side by side
- Use viem's `encodeAbiParameters` + `keccak256` to compute in the browser
- **Verify**: computed hash should match the stored actionHash

#### 3.2 UI: Hash Decoder in Table Entries (`components/TableEntryRow.tsx`)
- Currently shows `actionHash` as a truncated hex
- **Add**: Expand to show decoded action fields:
  ```
  actionHash: 0xabcd...1234
  ├─ decoded from:
  │  actionType: CALL
  │  rollupId: 1 (L2)
  │  destination: 0x5678... (Counter on L2)
  │  value: 0
  │  data: 0xd09de08a (increment())
  │  sourceAddress: 0x1234... (CounterAndProxy)
  │  sourceRollup: 0 (Mainnet)
  │  scope: []
  └─ hash verified: yes
  ```
- For entries from BatchPosted/ExecutionTableLoaded: the action data IS available in the entry's action field
- For ExecutionConsumed: the action is in the event args

#### 3.3 UI: Hash Decoder in Event Cards
- For ExecutionConsumed events, show the decoded action inline
- For BatchPosted events, show each entry's action hash with decoded breakdown
- Color-code: green checkmark if computed hash matches, red X if mismatch

#### 3.4 Function Selector Decoding
- Bonus: decode `data` field's first 4 bytes as function selector
- Maintain a local map of known selectors (from the test contracts: `increment()` = `0xd09de08a`, etc.)
- Show human-readable name next to raw data

---

### 4. Visual Polish — Match index.html Aesthetic

#### 4.1 Color & Typography (already close)
- Both use the same dark theme palette (bg: `#0a0a0f`, l1: `#3b82f6`, l2: `#a855f7`)
- Both use monospace fonts (JetBrains Mono)
- Dashboard is already visually aligned

#### 4.2 Entry Detail Styling
- Match index.html's `.te-details` expandable sections:
  - Section headers (uppercase, accent color, letter-spacing)
  - Key-value grid (90px label column + value column)
  - Highlighted values in cyan for important fields
- The dashboard's `TableEntryRow.tsx` already does this but could be more polished:
  - Add the "Action (hashed as actionHash)" / "Next Action (returned on match)" section headers
  - Add state delta section below

#### 4.3 Architecture Diagram Enhancements
- index.html uses quadratic bezier curves for same-lane edges with arc above/below
- Dashboard already implements this in `ArchitectureDiagram.tsx`
- **Add**: Edge labels (function names) rendered at arc apex when edge is active
- **Add**: Cross-chain boundary label ("L1" / "L2" in lane corners)

#### 4.4 Animation
- Match index.html's entry add/consume animations (already have CSS animations)
- Add smooth SVG transitions for node/edge highlighting (already have 0.3s transitions)

---

### 5. Transaction Hash Display

#### 5.1 Tx Hash in Event Cards (partial — exists in TxDetails)
- Show the transaction hash prominently on each event card
- Make it clickable (copy to clipboard)
- In bundle view: list ALL tx hashes involved

#### 5.2 Tx Hash in Bundle Detail
- Group by chain: "L1 Transactions: 0xabc..., 0xdef..." / "L2 Transactions: 0x123..."
- Each clickable to expand full receipt (reuse TxDetails component)

---

## Implementation Order

### Phase 1: Action Hash Decoding (standalone, high value)
1. Create `lib/actionHashDecoder.ts`
2. Update `TableEntryRow.tsx` to show decoded action hash
3. Update `EventCard.tsx` to show decoded hash for ExecutionConsumed

### Phase 2: Transaction Bundling
1. Add `buildTransactionBundles()` to `lib/crossChainCorrelation.ts`
2. Create `components/BundleList.tsx`
3. Add toggle in `EventTimeline.tsx` header
4. Create new types in `types/visualization.ts`

### Phase 3: Bundle Detail View
1. Create `lib/callFlowBuilder.ts`
2. Create `components/BundleDetail.tsx`
3. Create `components/BundleStepList.tsx`
4. Integrate `CallFlowStrip.tsx` (already exists, wire it up)
5. Add scoped architecture diagram (filter nodes/edges per bundle)

### Phase 4: Visual Polish
1. Edge labels on architecture diagram
2. Enhanced entry detail styling
3. Copy-to-clipboard for hashes/addresses
4. Tx hash prominence

---

## Key Files to Modify

| File | Changes |
|---|---|
| `src/lib/actionHashDecoder.ts` | **NEW** — keccak256 computation, ABI encoding, verification |
| `src/lib/callFlowBuilder.ts` | **NEW** — build call flow tree from bundle events |
| `src/lib/crossChainCorrelation.ts` | Add `buildTransactionBundles()` |
| `src/components/TableEntryRow.tsx` | Add decoded action hash display |
| `src/components/EventCard.tsx` | Add decoded hash for ExecutionConsumed |
| `src/components/BundleList.tsx` | **NEW** — grouped transaction list |
| `src/components/BundleDetail.tsx` | **NEW** — full detail view (modal/panel) |
| `src/components/BundleStepList.tsx` | **NEW** — step-by-step within bundle |
| `src/components/EventTimeline.tsx` | Add Events/Bundles toggle |
| `src/components/ArchitectureDiagram.tsx` | Edge labels, scoped filtering |
| `src/components/CallFlowStrip.tsx` | Wire up with real data from callFlowBuilder |
| `src/types/visualization.ts` | Add Bundle, BundleStep types |
| `src/App.tsx` | Add BundleDetail panel/modal |

---

## How Action Hash is Computed (Reference)

From Solidity (`Rollups.sol` / `EEZL2.sol`):
```solidity
bytes32 actionHash = keccak256(abi.encode(action));
```

Where `action` is:
```solidity
struct Action {
    ActionType actionType;  // uint8 enum
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    bool failed;
    address sourceAddress;
    uint256 sourceRollup;
    uint256[] scope;
}
```

In viem/TypeScript:
```typescript
import { encodeAbiParameters, keccak256 } from 'viem';

const encoded = encodeAbiParameters(
  [{ type: 'tuple', components: [
    { name: 'actionType', type: 'uint8' },
    { name: 'rollupId', type: 'uint256' },
    { name: 'destination', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'data', type: 'bytes' },
    { name: 'failed', type: 'bool' },
    { name: 'sourceAddress', type: 'address' },
    { name: 'sourceRollup', type: 'uint256' },
    { name: 'scope', type: 'uint256[]' },
  ]}],
  [action]
);
const hash = keccak256(encoded);
```

---

## Verification

1. **Action hash decoding**: Deploy contracts locally (anvil), run a scenario, verify computed hash matches on-chain actionHash
2. **Bundling**: Run multi-step scenarios (S3, S4), verify events are correctly grouped
3. **Detail view**: Compare visual output with index.html for same scenario data
4. **Replay**: Step through a bundle, verify architecture diagram highlights match index.html's activeNodes/activeEdges per step
