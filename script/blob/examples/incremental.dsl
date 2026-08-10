# Incremental case catalog — every DSL shape, from the simplest call upward.
# Read by BlobTools.s.sol:
#
#   forge script script/blob/BlobTools.s.sol --sig "run(string)" script/blob/examples/incremental.dsl
#
# Grammar (case-insensitive, '#' starts a comment):
#   <chain> call <chain> [value <amount> [wei|gwei|ether]]   open a mutable frame
#   <chain> staticCall <chain>                               open a read-only frame
#   [<chain>] return | returnFail                            close the innermost frame
#   [<chain>] snapshot ... revert                            forced-revert region
#   --                                                       transaction separator
# <chain> is L1 or L2_a..L2_z; the leading token is the chain EXECUTING the line
# (optional on return/returnFail/snapshot/revert; validated when present).
#
# Each transaction below is one self-contained case; complexity grows section by
# section: plain calls → static reads → value → nesting → nesting + static →
# nesting + static + value → returnFail → snapshot/revert regions → combinations.

# ═══════════════════════════════════ 1. PLAIN CALLS ═══════════════════════════

# 1.1 — a single call
L1 call L2_A
L2_A return

--

# 1.2 — two sibling calls
L1 call L2_A
L2_A return
L1 call L2_A
L2_A return

--

# 1.3 — three sibling calls, two different targets
L1 call L2_A
L2_A return
L1 call L2_B
L2_B return
L1 call L2_A
L2_A return

--

# 1.4 — L2 origin: one call into L1, one into a sibling L2
L2_A call L1
L1 return
L2_A call L2_B
L2_B return

--

# ═══════════════════════════════════ 2. STATIC READS ══════════════════════════

# 2.1 — a single top-level static read
L1 staticCall L2_A
L2_A return

--

# 2.2 — two static reads, two targets
L1 staticCall L2_A
L2_A return
L1 staticCall L2_B
L2_B return

--

# 2.3 — call, then two static reads in the same tx
L1 call L2_A
L2_A return
L1 staticCall L2_A
L2_A return
L1 staticCall L2_B
L2_B return

--

# 2.4 — top-level static read carrying two sub-reads of the reader chain
L1 staticCall L2_A
L2_A staticCall L1
L1 return
L2_A staticCall L1
L1 return
L2_A return

--

# 2.5 — static read from an L2 origin, with a sub-read back into it
L2_B staticCall L1
L1 staticCall L2_B
L2_B return
L1 return

--

# ══════════════════════════════════ 3. CALLS WITH VALUE ═══════════════════════

# 3.1 — L1 → L2 with value (ether unit): value is minted on the L2
L1 call L2_A value 1 ether
L2_A return

--

# 3.2 — L2 → L1 with value (gwei unit): paid out of the rollup's L1 balance
L2_A call L1 value 3 gwei
L1 return

--

# 3.3 — L2 → L2 with value (wei unit): balances shift between rollups on L1
L2_A call L2_B value 5 wei
L2_B return

--

# 3.4 — two sibling value calls in one tx
L1 call L2_A value 100 wei
L2_A return
L1 call L2_B value 2 gwei
L2_B return

--

# ══════════════════════════════════ 4. NESTED CALLS ═══════════════════════════

# 4.1 — one nested hop: L1 → A → B
L1 call L2_A
L2_A call L2_B
L2_B return
L2_A return

--

# 4.2 — callback into the origin: L1 → A → L1 (reentrant row on L1)
L1 call L2_A
L2_A call L1
L1 return
L2_A return

--

# 4.3 — three-deep chain across three L2s
L1 call L2_A
L2_A call L2_B
L2_B call L2_C
L2_C return
L2_B return
L2_A return

--

# 4.4 — ping-pong: L1 → A → L1 → A (nested callback of a callback)
L1 call L2_A
L2_A call L1
L1 call L2_A
L2_A return
L1 return
L2_A return

--

# 4.5 — nested siblings: one frame fires two sequential sub-calls
L1 call L2_A
L2_A call L2_B
L2_B return
L2_A call L2_B
L2_B return
L2_A return

--

# 4.6 — five-deep chain
L1 call L2_A
L2_A call L2_B
L2_B call L2_C
L2_C call L2_D
L2_D call L2_E
L2_E return
L2_D return
L2_C return
L2_B return
L2_A return

--

# ═══════════════════════════ 5. NESTED CALLS + STATIC ═════════════════════════

# 5.1 — reentrant static read of the origin inside a mutable frame
L1 call L2_A
L2_A staticCall L1
L1 return
L2_A return

--

# 5.2 — read a third chain, then call it, in the same frame
L1 call L2_A
L2_A staticCall L2_B
L2_B return
L2_A call L2_B
L2_B return
L2_A return

--

# 5.3 — static read fired two levels deep
L1 call L2_A
L2_A call L2_B
L2_B staticCall L2_A
L2_A return
L2_B return
L2_A return

--

# ═══════════════════════ 6. NESTED CALLS + STATIC + VALUE ═════════════════════

# 6.1 — value call whose frame does a static read, then a nested value call
L1 call L2_A value 1 ether
L2_A staticCall L1
L1 return
L2_A call L2_B value 2 gwei
L2_B return
L2_A return

--

# 6.2 — value callback: L2 → L1 with value, read back, nested value hop
L2_A call L1 value 7 wei
L1 staticCall L2_A
L2_A return
L1 call L2_B value 9 wei
L2_B return
L1 return

--

# ════════════════════════ 7. RETURNFAIL (the call reverts) ════════════════════

# 7.1 — top-level fail: the delivery runs, verifies, then reverts
L1 call L2_A
L2_A returnFail

--

# 7.2 — nested fail caught by the parent, which still commits
L1 call L2_A
L2_A call L2_B
L2_B returnFail
L2_A return

--

# 7.3 — failing frame whose sub-call also fails: both roll back
L1 call L2_A
L2_A call L2_B
L2_B returnFail
L2_A returnFail

--

# 7.4 — failing frame that did a static read first (reads fold nothing)
L1 call L2_A
L2_A staticCall L2_B
L2_B return
L2_A returnFail

--

# 7.5 — top-level static read that reverts (pool entry, success = false)
L1 staticCall L2_A
L2_A returnFail

--

# 7.6 — reentrant static read that reverts inside a committing frame
L1 call L2_A
L2_A staticCall L1
L1 returnFail
L2_A return

--

# ═══════════════ 8. SNAPSHOT / REVERT (force-revert the last N calls) ═════════

# 8.1 — revert ×1: the call executes, then its state rolls back
L1 snapshot
L1 call L2_A
L2_A return
L1 revert

--

# 8.2 — revert ×2
L1 snapshot
L1 call L2_A
L2_A return
L1 call L2_B
L2_B return
L1 revert

--

# 8.3 — revert ×3 from an L2 origin
L2_A snapshot
L2_A call L1
L1 return
L2_A call L2_B
L2_B return
L2_A call L2_B
L2_B return
L2_A revert

--

# 8.4 — region inside a nested frame (host frame still commits)
L1 call L2_A
L2_A snapshot
L2_A call L2_B
L2_B return
L2_A revert
L2_A return

--

# 8.5 — region covering a whole nested subtree (call call return return, revert)
L1 snapshot
L1 call L2_A
L2_A call L2_B
L2_B return
L2_A return
L1 revert

--

# 8.6 — commit, reverted region, commit again
L1 call L2_A
L2_A return
L1 snapshot
L1 call L2_A
L2_A return
L1 revert
L1 call L2_A
L2_A return

--

# 8.7 — the same shape repeated right after a reverted region
L2_A snapshot
L2_A call L2_B
L2_B return
L2_A revert
L2_A call L2_B
L2_B return

--

# 8.8 — two independent regions in one tx
L1 snapshot
L1 call L2_A
L2_A return
L1 revert
L1 snapshot
L1 call L2_B
L2_B return
L1 revert

--

# ═══════════════════════════════ 9. COMBINATIONS ══════════════════════════════

# 9.1 — static read, then a reverted region holding a value call with a nested
#       hop, then a committing callback chain
L1 staticCall L2_A
L2_A return
L1 snapshot
L1 call L2_A value 1 gwei
L2_A call L2_B
L2_B return
L2_A return
L1 revert
L1 call L2_A
L2_A call L1
L1 return
L2_A return

--

# 9.2 — kitchen sink: static read, value callback with a reentrant read and a
#       caught nested failure, a reverted deep value region, then a clean retry
L2_A staticCall L1
L1 return
L2_A call L1 value 2 gwei
L1 staticCall L2_A
L2_A return
L1 call L2_B
L2_B returnFail
L1 return
L2_A snapshot
L2_A call L2_B value 4 wei
L2_B call L2_C
L2_C return
L2_B return
L2_A revert
L2_A call L2_B
L2_B return
