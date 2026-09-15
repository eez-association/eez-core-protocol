- **Beacon proxies for `CrossChainProxy`.** Today proxy logic can never change without
changing every proxy address. A beacon keeps addresses stable but adds ~2.7k gas per call
and needs an upgrade owner; break-even ≈ 70 calls per proxy. Decide.

- **The `gas` field on a call is a cap, not a guarantee:** `_processNCalls` forwards it with `call{gas: callGas}`, and the EVM gives the callee min(callGas, gas available minus 1/64). If the transaction is running low, the destination gets less than the entry committed to, may fail for that reason alone, and the entry then reverts (or is skipped, for an immediate L2Tx) even though the table was correct. Guaranteeing at least `callGas` would require the manager to check `gasleft()` before every proxy call and revert early; that check is not implemented today, so posters must supply enough gas for the whole batch.

- **Root pins do not cover uncommitted context:** a static result whose value depends on a timestamp, block number or other context outside the committed state can still be served while the roots are unchanged. EEZ imposes no expiry of its own; capturing such dependencies is up to the rollup's validity rules or to refreshing the table.
