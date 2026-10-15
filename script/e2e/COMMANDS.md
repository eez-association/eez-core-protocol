# E2E commands

Run from the repository root using the existing network configuration.
[Setup](README.md#network-mode) · [Detailed examples and explanations](RUNNER_GUIDE.md) ·
[All composer RPCs, including fee quotes](RPC.md)

## Build and local check

```bash
forge build
bash script/e2e/run/local/parallel.sh counter counterL2
```

## Network runs

```bash
# Quick check
bash script/e2e/run/network/staged.sh counter:1 counterL2:1

# All enabled scenarios
bash script/e2e/run/network/staged.sh all:1

# Send now, verify later
bash script/e2e/run/network/staged.sh --no-verify counter:10

# Repeat with five workers
bash script/e2e/run/network/staged.sh --workers 5 counter:10 counterL2:10

# Load test; checks receipts only
bash script/e2e/run/network/load-testing.sh --workers 20 --txs-per-wallet 100 counter
```

## Continue or verify a saved run

Replace RUN_DIRECTORY with the saved run's directory name.

Transaction links are required by default. Set `E2E_TX_LINKS=auto` explicitly for
older servers that need compatibility discovery. Verification-only runs refresh
evidence without sending transactions.

```bash
bash script/e2e/run/network/staged.sh --resume tmp/e2e-staged-net/RUN_DIRECTORY
bash script/e2e/run/network/staged.sh --verify-only tmp/e2e-staged-net/RUN_DIRECTORY
```

## Notes

- `all` skips excluded scenarios; explicit names still select them.
- Run `bridge:1` successfully before `bridgeL2`; fund enough escrow for repeated withdrawals.
- Use `--fund` and `--floor` to adjust wallet funding.
- Cross-chain triggers on both chains try a fee quote, then node fees if unavailable. Deployments use node fees directly.
- Avoid simultaneous runs sharing the same wallet pool.
- [Funding](RUNNER_GUIDE.md#funding-and-bridge-setup) · [Recovery and saved runs](RUNNER_GUIDE.md#recovery-and-saved-artifacts).
- [Fee request and response](RPC.md#eez_quotefee) · [Transaction status](RPC.md#eez_getcrosschaintransaction).
- See the [README](README.md) for setup and verification limits.
