# Cross-chain showcase scenario — read by BlobTools.s.sol:
#
#   forge script script/blob/BlobTools.s.sol --sig "run(string)" script/blob/examples/showcase.dsl
#
# Grammar (case-insensitive, '#' starts a comment):
#   <chain> call <chain> [value <amount> [wei|gwei|ether]]   open a mutable frame
#   <chain> staticCall <chain>                               open a read-only frame
#   <chain> return | returnFail                              close the innermost frame
#   <chain> snapshot ... <chain> revert                      forced-revert region
#   --                                                       transaction separator
# <chain> is L1 or L2_a..L2_z; the leading token is the chain EXECUTING the line.

# Tx 1 (L1 origin): read L2_A, then call it with value; A calls back into L1.
L1 staticCall L2_A
L2_A return
L1 call L2_A value 1 ether
L2_A call L1                 # callback into the origin
L1 return
L2_A return

--

# Tx 2 (L2_A origin): a call into L2_B that executes, then rolls back.
L2_A snapshot
L2_A call L2_B
L2_B return
L2_A revert

--

# Tx 3 (L2_A origin): plain hop into L1 carrying value.
L2_A call L1 value 3 gwei
L1 return
