#!/usr/bin/env node
// Builds SYNTHETIC sample traces for the flow diagram. They start from the
// decoder's callTracer fixtures, add local application calls on both chains, and
// run through the real decoder with a stub Blockscout that serves names/ABIs.
// They are not captured executions; the output labels say so.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { proxyABI } from '../src/protocol.mjs';
import { scenario, frame, address } from '../tests/fixtures/scenarios.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const coder = ethers.AbiCoder.defaultAbiCoder();
const A = n => address(n);

// address → [name, human-readable ABI], per chain.
const CONTRACTS = {
  L1: {
    [A(10)]: ['SwapInitiator', ['function run()']],
    [A(12)]: ['SettlementHook', ['function incrementProxy()']],
    [A(48)]: ['USDC', ['function balanceOf(address) view returns (uint256)', 'function transfer(address to, uint256 amount) returns (bool)', 'function approve(address spender, uint256 amount) returns (bool)']],
    [A(49)]: ['PriceOracle', ['function latestAnswer() view returns (int256)', 'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)']],
    [A(50)]: ['UniswapV2Router02', ['function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[] amounts)', 'function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) returns (uint256[] amounts)']],
    [A(51)]: ['UniswapV2Pair', ['function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)', 'function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes data)', 'function sync()', 'error Locked()']],
    [A(52)]: ['WETH9', ['function transfer(address to, uint256 amount) returns (bool)', 'function balanceOf(address) view returns (uint256)']],
    [A(53)]: ['FeeCollector', ['function collect(address token, uint256 amount) returns (uint256 fee)']],
  },
  L2: {
    [A(11)]: ['L2Router', ['function callNested()', 'function increment() returns (uint256)']],
    [A(13)]: ['Counter', ['function increment() returns (uint256)']],
    [A(64)]: ['YieldVault', ['function deposit(uint256 assets, address receiver) returns (uint256 shares)', 'function previewDeposit(uint256 assets) view returns (uint256 shares)']],
    [A(65)]: ['BridgedUSDC', ['function transferFrom(address from, address to, uint256 amount) returns (bool)', 'function mint(address to, uint256 amount)', 'function balanceOf(address) view returns (uint256)']],
    [A(66)]: ['PositionRegistry', ['function record(bytes32 key, uint256 shares)', 'function positions(bytes32) view returns (uint256)']],
    [A(67)]: ['EventLogger', ['function log(string message)']],
    [A(68)]: ['RewardsDistributor', ['function accrue(address account) returns (uint256 accrued)', 'function rate() view returns (uint256)']],
    [A(69)]: ['StrategyFactory', ['function deploy(bytes32 salt) returns (address strategy)']],
  },
};
for (const chain of ['L1', 'L2']) for (const n of [20, 21, 22, 23, 24, 25]) CONTRACTS[chain][A(n)] = ['CrossChainProxy', JSON.parse(proxyABI.formatJson())];
// Per-sample renames of the fixture's fixed addresses (10 = cross-chain caller, 11 = remote target).
let overrides = { L1: {}, L2: {} };
const lookup = (chain, addr) => overrides[chain][addr] || CONTRACTS[chain][addr];
const iface = (chain, addr) => new ethers.Interface(lookup(chain, addr)[1]);

// One local call frame: encodes calldata and return data from the stub ABIs.
function call(chain, from, to, fn, args = [], result = [], children = [], extra = {}) {
  const i = iface(chain, to), f = i.getFunction(fn);
  const output = extra.error ? extra.output : i.encodeFunctionResult(f, result);
  return frame(from, to, i.encodeFunctionData(f, args), children, { output, ...(f.constant ? { type: 'STATICCALL' } : {}), ...extra });
}
const locked = () => ({ error: 'execution reverted', output: iface('L1', A(51)).encodeErrorResult('Locked', []) });
const stringRevert = msg => ({ error: 'execution reverted', output: '0x08c379a0' + coder.encode(['string'], [msg]).slice(2) });

function stubExplorer(url) {
  const u = new URL(url), chain = u.hostname.startsWith('l1') ? 'L1' : 'L2';
  const m = /\/api\/v2\/smart-contracts\/(0x[0-9a-fA-F]{40})$/.exec(u.pathname);
  const key = m && Object.keys({ ...CONTRACTS[chain], ...overrides[chain] }).find(a => a.toLowerCase() === m[1].toLowerCase());
  const entry = key && [key, lookup(chain, key)];
  if (!entry) return Promise.resolve({ ok: false, status: 404, json: async () => ({}) });
  const abi = Array.isArray(entry[1][1]) && typeof entry[1][1][0] === 'string' ? JSON.parse(new ethers.Interface(entry[1][1]).formatJson()) : entry[1][1];
  return Promise.resolve({ ok: true, status: 200, json: async () => ({ name: entry[1][0], abi }) });
}
const explorerConfig = { noExplorer: false, l1Explorer: 'https://l1-explorer.test', l1ExplorerType: 'blockscout', l2Explorer: 'https://l2-explorer.test', l2ExplorerType: 'blockscout', fetch: stubExplorer };

// Caller → CounterAndProxy (L1) → Counter (L2) → StepSource (L2), then back.
async function counterWithHelper() {
  overrides = {
    L1: { [A(80)]: ['Caller', ['function go()']], [A(10)]: ['CounterAndProxy', ['function incrementProxy()']] },
    L2: { [A(11)]: ['Counter', ['function increment() returns (uint256)']], [A(81)]: ['StepSource', ['function step() view returns (uint256)']] },
  };
  const f = scenario();
  const tx = f.txs.L1.get(f.trigger), outgoing = tx.trace.calls[0];
  const source = call('L1', A(80), A(10), 'incrementProxy', [], [], [outgoing]);
  tx.trace = call('L1', tx.trace.from, A(80), 'go', [], [], [source]);
  Object.assign(tx.transaction, { to: tx.trace.to, input: tx.trace.input });
  const target = f.txs.L2.get(f.deliveries[0]).trace.calls[0].calls[0];
  target.calls = [call('L2', A(11), A(81), 'step', [], [1n])];
  try { return await decodeCrossChainTrace({ ...f.config, ...explorerConfig }, f.trigger); } finally { overrides = { L1: {}, L2: {} }; }
}

// L1 → L2 → L1 → L2 nesting with local work at every level.
async function nestedDeposit() {
  const f = scenario({ deep: true });
  const S = A(10), HOOK = A(12), USDC = A(48), ORACLE = A(49), ROUTER = A(50), PAIR = A(51), FEES = A(53);
  const root = f.txs.L1.get(f.trigger).trace;
  const [outgoing] = root.calls;
  root.calls = [
    call('L1', S, USDC, 'balanceOf', [S], [2_500_000_000n]),
    call('L1', S, ORACLE, 'latestRoundData', [], [110680n, 99_982_000n, 1_760_180_000n, 1_760_180_012n, 110680n]),
    call('L1', S, ROUTER, 'getAmountsOut', [1_000_000_000n, [USDC, A(52)]], [[1_000_000_000n, 394_812_550_000_000_000n]], [
      call('L1', ROUTER, PAIR, 'getReserves', [], [9_400_000_000_000n, 3_712_000_000_000_000_000_000n, 1_760_180_001]),
    ]),
    call('L1', S, USDC, 'approve', [A(20), 1_000_000_000n], [true]),
    outgoing,
    call('L1', S, FEES, 'collect', [USDC, 1_000_000_000n], [500_000n], [
      call('L1', FEES, USDC, 'transfer', [A(77), 500_000n], [true]),
    ]),
  ];
  // The L1 callback runs inside the L1 manager while the L2 call is suspended.
  const callback = outgoing.calls[1].calls[0].calls[0];
  callback.calls = [
    call('L1', HOOK, ORACLE, 'latestAnswer', [], [99_982_000n]),
    call('L1', HOOK, PAIR, 'sync', [], [], [], locked()),
    ...callback.calls,
  ];
  const delivery = f.txs.L2.get(f.deliveries[0]).trace;
  const target = delivery.calls[0].calls[0], VAULT = A(64), BUSDC = A(65), REG = A(66), LOG = A(67), REW = A(68);
  target.calls = [
    call('L2', A(11), BUSDC, 'mint', [A(11), 1_000_000_000n]),
    call('L2', A(11), VAULT, 'deposit', [1_000_000_000n, A(11)], [987_000_000n], [
      call('L2', VAULT, BUSDC, 'transferFrom', [A(11), VAULT, 1_000_000_000n], [true]),
      call('L2', VAULT, REW, 'accrue', [A(11)], [12_400n], [call('L2', REW, REW, 'rate', [], [31n])]),
    ]),
    ...target.calls,
    call('L2', A(11), REG, 'record', [ethers.id('position-1'), 987_000_000n]),
  ];
  const inner = target.calls[2].calls[1].calls[0].calls[0];
  inner.calls = [call('L2', A(13), LOG, 'log', ['counter bumped from L1 hook'])];
  return decodeCrossChainTrace({ ...f.config, ...explorerConfig }, f.trigger);
}

// Three L1 → L2 calls from one transaction, with wide local fan-out on both sides.
async function batchFanOut() {
  const f = scenario({ repeat: 3 });
  const S = A(10), USDC = A(48), ORACLE = A(49), ROUTER = A(50), PAIR = A(51), WETH = A(52), FEES = A(53);
  const root = f.txs.L1.get(f.trigger).trace;
  const outs = root.calls;
  const swap = i => call('L1', S, ROUTER, 'swapExactTokensForTokens', [250_000_000n * BigInt(i + 1), 1n, [USDC, WETH], S, 1_760_190_000n], [[250_000_000n * BigInt(i + 1), 98_700_000_000_000_000n * BigInt(i + 1)]], [
    call('L1', ROUTER, PAIR, 'getReserves', [], [9_400_000_000_000n, 3_712_000_000_000_000_000_000n, 1_760_180_001]),
    call('L1', ROUTER, USDC, 'transfer', [PAIR, 250_000_000n * BigInt(i + 1)], [true]),
    call('L1', ROUTER, PAIR, 'swap', [0n, 98_700_000_000_000_000n * BigInt(i + 1), S, '0x'], [], [
      call('L1', PAIR, WETH, 'transfer', [S, 98_700_000_000_000_000n * BigInt(i + 1)], [true]),
      call('L1', PAIR, USDC, 'balanceOf', [PAIR], [9_400_250_000_000n]),
      call('L1', PAIR, WETH, 'balanceOf', [PAIR], [3_711_901_300_000_000_000_000n]),
    ]),
  ]);
  root.calls = [
    call('L1', S, ORACLE, 'latestAnswer', [], [99_982_000n]),
    swap(0), outs[0],
    swap(1), outs[1],
    call('L1', S, PAIR, 'sync', [], [], [], stringRevert('UniswapV2: LOCKED')),
    swap(2), outs[2],
    call('L1', S, FEES, 'collect', [WETH, 5_000_000_000_000_000n], [25_000_000_000_000n], [call('L1', FEES, WETH, 'transfer', [A(77), 25_000_000_000_000n], [true])]),
  ];
  const VAULT = A(64), BUSDC = A(65), REG = A(66), LOG = A(67), REW = A(68), FACTORY = A(69);
  f.deliveries.forEach((hash, i) => {
    const target = f.txs.L2.get(hash).trace.calls[0].calls[0];
    target.calls = [
      call('L2', A(11), VAULT, 'previewDeposit', [500_000_000n], [493_500_000n]),
      call('L2', A(11), VAULT, 'deposit', [500_000_000n, A(11)], [493_500_000n], [
        call('L2', VAULT, BUSDC, 'transferFrom', [A(11), VAULT, 500_000_000n], [true]),
        call('L2', VAULT, REW, 'accrue', [A(11)], [6_200n * BigInt(i + 1)], [call('L2', REW, REW, 'rate', [], [31n])]),
        ...(i === 1 ? [call('L2', VAULT, FACTORY, 'deploy', [ethers.id('strategy-2')], [A(70)], [frame(FACTORY, A(70), '0x6080604052', [], { type: 'CREATE2', output: '0x6080' })])] : []),
      ]),
      call('L2', A(11), REG, 'record', [ethers.id(`position-${i}`), 493_500_000n]),
      call('L2', A(11), LOG, 'log', [`batch leg ${i + 1} of 3`]),
    ];
  });
  return decodeCrossChainTrace({ ...f.config, ...explorerConfig }, f.trigger);
}

export async function buildSamples() {
  return [
    { label: 'Counter with helper · synthetic', trace: await counterWithHelper() },
    { label: 'Nested deposit · synthetic', trace: await nestedDeposit() },
    { label: 'Three-leg batch · synthetic', trace: await batchFanOut() },
  ];
}

// Usage:
//   node build-samples.mjs [outDir]                         write sample trace JSON files
//   node build-samples.mjs --html out.html [real.json …]    one page: real traces first, then samples
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args[0] === '--html') {
    const { renderFlowHtml } = await import('../flow/render-flow.mjs');
    const { buildFlowModel } = await import('../flow/model.mjs');
    const traces = args.slice(2).filter(a => a !== '--fragment').map(file => ({ model: buildFlowModel(JSON.parse(fs.readFileSync(file, 'utf8'))), source: path.basename(file) }));
    const samples = (await buildSamples()).map(({ label, trace }) => {
      const model = buildFlowModel(JSON.parse(JSON.stringify(trace, (_, v) => typeof v === 'bigint' ? v.toString() : v)));
      model.chains.L1.name = 'Synthetic L1'; model.chains.L2.name = 'Synthetic L2';
      return { label, model, synthetic: true, source: 'synthetic fixture' };
    });
    // The smallest sample opens first; real traces follow it.
    traces.unshift(samples.shift()); traces.push(...samples);
    fs.writeFileSync(path.resolve(args[1]), renderFlowHtml(traces, { fragment: args.includes('--fragment') }));
    console.log(`Wrote ${path.resolve(args[1])} with ${traces.length} traces`);
  } else {
    const out = path.resolve(args[0] || here);
    for (const { label, trace } of await buildSamples()) {
      const file = path.join(out, label.split(' · ')[0].toLowerCase().replace(/[^a-z0-9]+/g, '-') + '.json');
      fs.writeFileSync(file, JSON.stringify(trace, (_, v) => typeof v === 'bigint' ? v.toString() : v));
      console.log(`Wrote ${file}`);
    }
  }
}
