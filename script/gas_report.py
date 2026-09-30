#!/usr/bin/env python3
"""Regenerate the complete gas report and machine-readable measurements."""
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNS = [
    ("isolated execution", ["forge", "test", "--match-path",
     "test/{GasBreakdown,GasExecPaths,GasL2}.t.sol", "--isolate", "--json", "-vv"]),
    ("legacy diagnostics", ["forge", "test", "--match-path",
     "test/{GasCost,GasProbe}.t.sol", "--json", "-vv"]),
]
NUMBER = re.compile(r"^\s*(.+?)\s+(-?\s*\d+)\s*$")

def command(args):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True)

def main():
    tests, metrics = [], []
    for mode, args in RUNS:
        print("Running " + " ".join(args), flush=True)
        run = command(args)
        if run.returncode:
            raise SystemExit(run.stderr + run.stdout)
        for suite, results in json.loads(run.stdout).items():
            for name, test in results["test_results"].items():
                if test["status"] != "Success":
                    raise SystemExit(f"{suite}::{name}: {test.get('reason')}")
                logs = test.get("decoded_logs", [])
                tests.append({"mode": mode, "suite": suite, "test": name,
                              "status": test["status"], "logs": logs,
                              "whole_test_gas_not_operation_gas": test.get("kind", {}).get("Unit", {}).get("gas")})
                for line in logs:
                    match = NUMBER.match(line)
                    if match:
                        metrics.append({"mode": mode, "suite": suite, "test": name,
                                        "metric": " ".join(match[1].split()),
                                        "value": int(match[2].replace(" ", ""))})
    artifact = json.loads((ROOT / "out/EEZ.sol/EEZ.json").read_text())
    meta = artifact["metadata"]
    if isinstance(meta, str):
        meta = json.loads(meta)
    bytecode = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    result = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "git_head": command(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "git_dirty": bool(command(["git", "status", "--porcelain"]).stdout),
        "forge_version": command(["forge", "--version"]).stdout.strip(),
        "compiler": meta["compiler"]["version"], "evm_version": meta["settings"]["evmVersion"],
        "optimizer": meta["settings"]["optimizer"], "via_ir": meta["settings"].get("viaIR", False),
        "eez_runtime_bytes": len(bytecode), "eez_runtime_sha256": hashlib.sha256(bytecode).hexdigest(),
        "production_source_sha256": {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((ROOT / "src").rglob("*.sol"))
        },
        "commands": [{"mode": mode, "command": args} for mode, args in RUNS],
        "tests_passed": len(tests), "measurement_count": len(metrics),
        "tests": tests, "measurements": metrics,
    }
    output = ROOT / "docs"
    output.mkdir(exist_ok=True)
    (output / "gas-benchmarks.json").write_text(json.dumps(result, indent=2) + "\n")
    (output / "GAS_BENCHMARKS.md").write_text(report(result))
    print(f"{len(tests)} tests passed; {len(metrics)} measurements written to docs/GAS_BENCHMARKS.md", flush=True)

def report(result):
    primary = {r["metric"].removeprefix("bench."): r["value"] for r in result["measurements"]
               if r["metric"].startswith("bench.")}
    def gas(key):
        return f"{primary[key]:,}"
    lines = [
        "# Gas benchmarks", "",
        f"Generated: {result['generated_at_utc']}. All {result['tests_passed']} benchmark/diagnostic tests passed.",
        f"{result['measurement_count']} numeric measurements are included below and in [gas-benchmarks.json](gas-benchmarks.json).",
        "", "## Quick summary", "",
        "An entry is one request stored in the batch to run later. A callback means L2 calling back into L1.",
        "These examples use one rollup and reuse existing storage. Posting the batch and running its calls are separate costs.",
        "", "### Posting the batch", "",
        "| Action | Gas |", "|---|---:|",
        f"| Post a batch with no entries | {gas('post.empty.1rollup.steady')} |",
        f"| Add the first entry, with no calls | +{primary['post.deferred.bare.1'] - primary['post.empty.1rollup.steady']:,} → {gas('post.deferred.bare.1')} total |",
        f"| Add a second entry, also with no calls | +{gas('post.deferred.extra_bare_entry')} → {gas('post.deferred.bare.2')} total |",
        f"| Store the data for one extra L2→L1 callback | +{gas('post.deferred.extra_l2_to_l1_record')} |",
        f"| Store the result for one extra L1→L2 call | +{gas('post.deferred.extra_l1_to_l2_record')} |",
        "", "The last two rows cover including that data in the batch, not running the calls.", "",
        "### Running the calls after posting", "",
        "| Action | Gas |", "|---|---:|",
        f"| Run one L1→L2 call without callbacks | {gas('execute.l1_to_l2.no_callback')} |",
        f"| Add the first L2→L1 callback | +{gas('execute.l1_to_l2.first_callback')} → {gas('execute.l1_to_l2.1_callback')} total |",
        f"| Add a second L2→L1 callback | +{gas('execute.l1_to_l2.extra_callback')} → {gas('execute.l1_to_l2.2_callbacks')} total |",
        f"| Make another L1→L2 call from inside a callback | +{gas('execute.extra_nested_l1_to_l2')} |",
        "", "The callback totals build on the call without callbacks. The final row is the measured cost of adding a second L1→L2 call inside the same callback.",
        "All figures are execution gas before refunds. Transaction overhead and real proof checking are extra; the assumptions and other execution paths follow.",
        "", "Regenerate from the repository root:", "", "    python3 script/gas_report.py", "",
        f"Solidity {result['compiler']}; EVM {result['evm_version']}; optimizer runs {result['optimizer']['runs']}; via IR {result['via_ir']}.",
        f"EEZ runtime: {result['eez_runtime_bytes']:,} bytes. Git HEAD: {result['git_head']}; dirty working tree: {result['git_dirty']}.",
        "The JSON records the full tool version, commands, source hashes, tests and console measurements.", "",
        "## Measurement boundaries", "",
        "- Primary results are gross execution gas inside the measured contract call, before refunds. "
        "They exclude transaction intrinsic gas, calldata charges/floors, blob/DA fees and fixture construction.",
        "- Primary suites use Foundry --isolate. GasMeter owns the outer transaction boundary and captures the "
        "nested protocol call. Top-level lastCallGas under --isolate would include transaction costs.",
        "- The 4 KiB no-op calibration must stay below 2,000 execution gas; it catches accidental inclusion "
        "of intrinsic/calldata costs.",
        "- Proofs use MockProofSystem, not a production verifier. Batches contain no blobs. "
        "Actual verification and DA costs must be added separately.",
        "- Dispatch proxies already exist except in the deployment measurement. Independent measurements "
        "start with cold access; repeated calls inside one transaction can reuse warm accounts and slots.",
        "- Steady posting follows a same-shape seed and normally rewrites identical payload values. "
        "The changed-commitments case changes three nonzero scalar fields.",
        "- GasBreakdown uses one rollup and one mock proof system unless the row says otherwise. "
        "GasExecPaths uses two rollups and stateful CounterAndProxy callbacks.",
        "- A saved L1-to-L2 record is an ExpectedL1ToL2Call, not an executed call. Fixed-driver nested-call "
        "measurements retain one L2-to-L1 driver while varying only its nested L1-to-L2 calls.",
        "- L1 cross-chain execution resolves proven/cached results on L1. Destination EVM work is separate. "
        "L2 results use EEZL2 with useGasLeft=false and exclude L2 fee/DA pricing.",
        "- Marginal costs apply to these fixtures. Payloads, root changes, scan positions, callback targets, "
        "proof systems, and account warmth all affect gas.", "",
        "## Base and per-unit figures", "", "| Operation | Execution gas |", "|---|---:|",
    ]
    highlights = [
        ("Base post, one verified rollup", "post.empty.1rollup.steady"),
        ("Base post, two verified rollups", "post.empty.2rollups.steady"),
        ("Additional verified rollup", "post.empty.extra_rollup"),
        ("Full post with one bare deferred entry", "post.deferred.bare.1"),
        ("Additional bare deferred entry", "post.deferred.extra_bare_entry"),
        ("Additional saved L2-to-L1 call record", "post.deferred.extra_l2_to_l1_record"),
        ("Additional saved L1-to-L2 expected-call record", "post.deferred.extra_l1_to_l2_record"),
        ("Additional RollupUpdate (same verified-rollup set)", "post.extra_rollup_update"),
        ("Additional static entry", "post.static.extra_entry"),
        ("Full post with one bare immediate L2Tx", "post.inline.bare.1entry"),
        ("Additional bare immediate L2Tx", "post.inline.extra_bare_entry"),
        ("First inline L2-to-L1 no-op callback", "post.inline.first_l2_to_l1_call"),
        ("Additional inline L2-to-L1 callback, same source/target", "post.inline.extra_l2_to_l1_call"),
        ("Top-level L1-to-L2 request without callbacks", "execute.l1_to_l2.no_callback"),
        ("Top-level L1-to-L2 request with one callback", "execute.l1_to_l2.1_callback"),
        ("First nested L1-to-L2 during immediate execution", "post.inline.first_nested_l1_to_l2"),
        ("Additional nested L1-to-L2 during immediate execution", "post.inline.extra_nested_l1_to_l2"),
        ("First nested L1-to-L2 during deferred consumption", "execute.first_nested_l1_to_l2"),
        ("Additional nested L1-to-L2 during deferred consumption", "execute.extra_nested_l1_to_l2"),
        ("Top-level static read, first matching entry", "static.match_at_position.1"),
        ("Repeated static read in the same transaction", "static.repeat_warm"),
        ("Deploy a cross-chain proxy", "proxy.deploy"),
        ("Return an existing proxy", "proxy.get_existing"),
        ("L2 outgoing request, first table entry", "l2.outgoing.match_at_position.1"),
        ("L2 incoming delivery with one no-op call, including table replacement", "l2.incoming.delivery.1_calls"),
    ]
    lines += [f"| {label} | {gas(key)} |" for label, key in highlights]
    lines += [
        "", "## Queue reset and reuse", "",
        f"- Empty replacement after 1 execution + 1 static entry: {gas('post.reset.1execution_1static')} gas.",
        f"- Empty replacement after 32 execution + 32 static entries: {gas('post.reset.32execution_32static')} gas.",
        f"- Full-entry first write: {gas('post.deferred.full.first_write')} gas; identical reuse: {gas('post.deferred.full.reuse')} gas.",
        f"- Three changed nonzero commitments add {gas('post.deferred.full.changed_commitment_premium')} gas in this fixture.",
        "Deferred queue resets update counters without deleting retained entries. Overwriting shorter nested "
        "arrays/bytes can still clear their old tails. Batch-scoped mapping contents are deleted after the hook.",
        "", "## All isolated operation measurements", "",
        "The metric identifiers below match the JSON. Values are gross execution gas.", "",
    ]
    groups = [
        ("Batch base and batch data", ("post.empty.", "post.batch_data")),
        ("Deferred publishing and return data", ("post.deferred.", "post.extra_rollup")),
        ("Immediate entries and callbacks", ("post.inline.",)),
        ("Static publishing and reset", ("post.static.", "post.reset.")),
        ("L1 execution and scans", ("execute.",)),
        ("Static reads and proxy deployment", ("static.", "proxy.")),
        ("L2", ("l2.",)),
        ("Meter calibration", ("calibration.",)),
    ]
    for name, prefixes in groups:
        lines += [f"### {name}", "", "| Metric | Gas |", "|---|---:|"]
        lines += [f"| {key} | {value:,} |" for key, value in sorted(primary.items()) if key.startswith(prefixes)]
        lines.append("")
    lines += [
        "## Existing execution-path and per-unit scenarios", "",
        "These also use --isolate and GasMeter. The two-rollup, stateful CounterAndProxy fixture differs "
        "from the simpler fixtures above. A saved L2Tx needs a preceding non-L2Tx boundary: its saving delta "
        "subtracts a boundary-only post; execution still scans over the boundary. Save+execute sums omit the base post.",
        "The callback-round-trip marginal includes an extra L2-to-L1 callback and its reentrant L1-to-L2 call. "
        "Use the fixed-driver figures to isolate an additional nested L1-to-L2 call.", "",
    ]
    append_tables(lines, result, "GasExecPaths")
    lines += [
        "## Supplementary legacy scenarios and probes", "",
        "GasCost retains gasleft-based caller regions in the normal Foundry test context. Some regions include "
        "ABI encoding or fixture construction. Do not mix these values with the isolated contract-body tables.",
        "The ERC20 fixture executes test-token code. The swap fixture sends Uniswap-shaped calldata to a permissive "
        "sink; it does not execute a DEX swap. Inline execution versus an unconsumed meta hook compares different "
        "dispatch paths, not the marginal cost of execution.",
        "GasProbe tests observed-gas keying correctness. Whole-test gas for correctness checks is not an operation benchmark.", "",
    ]
    append_tables(lines, result, "GasCost")
    lines += [
        "## Updates made", "",
        "- Corrected cooling order and cooled the same-rollup callback actor/proxy.",
        "- Kept the zero-init control unseeded until its measured write.",
        "- Added the calibrated nested-call meter and isolated comparison states.",
        "- Corrected the saved-L2Tx boundary baseline and callback-round-trip labels.",
        "- Replaced misleading standalone net-fee estimates with signed raw refund counters.",
        "- Added L1/L2 base, unit, payload, scan, static, reset, reuse and deployment measurements.",
        "- No production Solidity changes were made for this benchmark update.", "",
        "Tooling reference: [Foundry cheatcodes at the installed revision]"
        "(https://github.com/foundry-rs/foundry/blob/4072e48705af9d93e3c0f6e29e93b5e9a40caed8/crates/cheatcodes/src/evm.rs). "
        "The calibration and toolchain probes validate the accounting used here.", "",
    ]
    return "\n".join(lines)

def append_tables(lines, result, contract):
    for test in result["tests"]:
        if not test["suite"].endswith(":" + contract):
            continue
        rows = [r for r in result["measurements"] if r["suite"] == test["suite"] and r["test"] == test["test"]]
        if rows:
            lines += [f"### {test['test'].removesuffix('()')}", "",
                      "| Measurement | Gas / raw refund |", "|---|---:|"]
            lines += [f"| {r['metric'].replace('|', '/')} | {r['value']:,} |" for r in rows]
            lines.append("")

if __name__ == "__main__":
    main()
