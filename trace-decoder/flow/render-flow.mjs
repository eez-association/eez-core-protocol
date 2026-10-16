#!/usr/bin/env node
// Renders the cross-chain call-flow diagram as one self-contained HTML file.
//
//   node trace-decoder/flow/render-flow.mjs <TX_HASH> [decoder options] [--open] [-o out.html]
//   node trace-decoder/flow/render-flow.mjs trace.json [more.json …] [--open] [-o out.html]
//
// A tx hash is decoded first with decodeCrossChainTrace (same options and env files
// as decode-trace.mjs), which also finds the related L1/L2 transactions. JSON files
// are results of `decode-trace.mjs --json`. --views picks the diagram types
// (flow, layers, sequence, timeline, or all; default flow,sequence). --open shows
// the page in the default browser. --l1-explorer-url / --l2-explorer-url set the
// explorer websites used for verify links (otherwise known chains or the configured explorers).
// Every transaction found must have a call trace; otherwise it exits with an error and writes
// nothing but <hash>.partial.json. --allow-partial draws the incomplete flow instead.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { buildFlowModel } from './model.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const ALL_VIEWS = ['flow', 'layers', 'sequence', 'timeline'];
export const DEFAULT_VIEWS = ['flow', 'sequence'];

const safeJson = value => JSON.stringify(value).replaceAll('<', '\\u003c').replaceAll('>', '\\u003e').replaceAll('&', '\\u0026');

export function renderFlowHtml(traces, { fragment = false, views = ALL_VIEWS } = {}) {
  const data = safeJson(traces.map(t => ({ label: t.label || t.model.label, synthetic: !!t.synthetic, source: t.source || null, model: t.model })));
  const model = fs.readFileSync(path.join(here, 'model.mjs'), 'utf8').replace(/^export /gm, '');
  const viewer = fs.readFileSync(path.join(here, 'viewer/viewer.js'), 'utf8');
  const script = `${model}\n${viewer}`.replace(/<\/script/gi, '<\\/script');
  const body = fs.readFileSync(path.join(here, 'viewer/template.html'), 'utf8')
    .replace('__FLOW_DATA__', () => data).replace('__FLOW_CONFIG__', () => safeJson({ views }))
    .replace('__FLOW_SCRIPT__', () => script);
  if (fragment) return body;
  const csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'";
  return `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<meta http-equiv="Content-Security-Policy" content="${csp}">\n${body.replace(/<\/title>/, '</title>\n</head>\n<body>')}\n</body>\n</html>\n`;
}

// What the decoder found, so the terminal says which transactions the page covers.
function summary(model, source) {
  const lines = [`Trace ${source}: ${model.label}`];
  for (const tx of model.transactions) {
    lines.push(`  ${tx.chain}  ${tx.label.padEnd(38)} ${tx.hash}  block ${tx.block ?? '?'}  ${tx.status}${tx.requested ? '  [requested]' : ''}${tx.relatedSettlement ? '  [settles requested transaction]' : tx.inFlow === false && !tx.requested ? '  [not part of this flow]' : tx.inFlow === null ? '  [link unknown: no trace]' : ''}${tx.traced ? '' : ` (no trace: ${tx.traceReason || 'unavailable'})`}`);
    if (tx.evidence?.length) lines.push(`        ${tx.evidence.join('; ')}`);
  }
  const { crossings, matched } = model.stats;
  lines.push(`  crossings matched: ${matched}/${crossings} · application calls: ${model.nodes.filter(n => !n.protocol).length}`);
  for (const u of model.unresolved) lines.push(`  unresolved: ${u.code}: ${u.message}`);
  return lines.join('\n');
}

function openInBrowser(file) {
  const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'cmd' : 'xdg-open';
  const args = process.platform === 'win32' ? ['/c', 'start', '', file] : [file];
  try {
    const child = spawn(cmd, args, { detached: true, stdio: 'ignore' });
    child.on('error', () => console.error(`Could not open a browser; open ${file} manually.`));
    child.unref();
  } catch { console.error(`Could not open a browser; open ${file} manually.`); }
}

const isHash = s => /^0x[0-9a-fA-F]{64}$/.test(s);

// Explorer websites for re-rendered JSON: --env-file, then DEVNET_ENV, then chain.env,
// with exported variables taking precedence, as for the decoder. Only EXPLORER_L1/L2 are used.
async function explorersFromEnv(decoderArgs) {
  const { parseEnv } = await import('../src/config.mjs');
  const i = decoderArgs.indexOf('--env-file');
  const file = path.resolve(i >= 0 ? decoderArgs[i + 1] : process.env.DEVNET_ENV || 'chain.env');
  let values = {};
  try { if (fs.existsSync(file)) values = parseEnv(fs.readFileSync(file, 'utf8'), process.env); } catch { /* Links are optional. */ }
  return { L1: process.env.EXPLORER_L1 || values.EXPLORER_L1, L2: process.env.EXPLORER_L2 || values.EXPLORER_L2 };
}

async function main(argv) {
  let out = null, fragment = false, open = false, views = DEFAULT_VIEWS, allowPartial = false;
  const siteFlags = {};
  const inputs = [], decoderArgs = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-o' || a === '--out') out = argv[++i];
    else if (a === '--fragment') fragment = true;
    else if (a === '--open') open = true;
    else if (a === '--allow-partial') allowPartial = true;
    else if (a === '--l1-explorer-url' || a === '--l2-explorer-url') siteFlags[a.slice(2, 4).toUpperCase()] = argv[++i];
    else if (a === '--views') {
      const v = argv[++i] || '';
      views = v === 'all' ? ALL_VIEWS : v.split(',').map(s => s.trim()).filter(Boolean);
      const bad = views.filter(x => !ALL_VIEWS.includes(x));
      if (bad.length || !views.length) throw new Error(`--views takes a comma list of ${ALL_VIEWS.join(', ')} (or all)`);
    } else if (a === '-h' || a === '--help') {
      console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 12).map(l => l.replace(/^\/\/ ?/, '')).join('\n'));
      return;
    } else if (!a.startsWith('-') && (a.endsWith('.json') || isHash(a))) inputs.push(a);
    else {
      // Everything else belongs to the decoder (same flags as decode-trace.mjs).
      decoderArgs.push(a);
      if (argv[i + 1] && !argv[i + 1].startsWith('-') && !isHash(argv[i + 1]) && !argv[i + 1].endsWith('.json')) decoderArgs.push(argv[++i]);
    }
  }
  if (!inputs.length) throw new Error('Pass a transaction hash or one or more trace JSON files (see --help).');
  const traces = [];
  for (const input of inputs) {
    let trace, explorers = { ...siteFlags };
    if (isHash(input)) {
      const { loadConfig } = await import('../src/config.mjs');
      const { decodeCrossChainTrace } = await import('../src/engine.mjs');
      const config = loadConfig([input, ...decoderArgs]);
      // Link bases for the page: the configured explorers, reduced to scheme/host/path in model.mjs.
      explorers = { L1: siteFlags.L1 || config.l1Explorer, L2: siteFlags.L2 || config.l2Explorer };
      console.error(`Decoding ${input} and searching the other chain…`);
      trace = await decodeCrossChainTrace({ ...config, onDiagnostic: ({ code, message }) => console.error(`  ${code}: ${message}`) }, input);
    } else {
      trace = JSON.parse(fs.readFileSync(input, 'utf8'));
      const env = await explorersFromEnv(decoderArgs);
      explorers = { L1: siteFlags.L1 || env.L1, L2: siteFlags.L2 || env.L2 };
    }
    const model = buildFlowModel(trace, { explorers });
    const source = isHash(input) ? input : path.basename(input);
    console.log(summary(model, source));
    // Every transaction found must be traced; a page without part of the flow is misleading.
    const untraced = model.transactions.filter(t => !t.traced);
    const linkFailure = (trace.unresolved || []).find(u => ['invalid-transaction-links', 'transaction-links-pending'].includes(u.code));
    if ((untraced.length || linkFailure) && !allowPartial) {
      if (isHash(input)) {
        const partial = path.resolve(out ? out.replace(/\.html$/, '') : path.join(here, '..', '..', 'tmp', 'flow-diagrams', input)) + '.partial.json';
        fs.mkdirSync(path.dirname(partial), { recursive: true });
        fs.writeFileSync(partial, JSON.stringify(trace, (_, v) => typeof v === 'bigint' ? v.toString() : v));
        console.error(`Incomplete result saved to ${partial} (nothing else was written).`);
      }
      if (linkFailure) throw new Error(`Cross-chain transaction links are incomplete: ${linkFailure.message}. Use --allow-partial to inspect the partial result.`);
      throw new Error([
        `No call trace for ${untraced.length} transaction${untraced.length === 1 ? '' : 's'}:`,
        ...untraced.map(t => `  ${t.chain} ${t.hash}${t.requested ? ' (requested)' : ''}: ${t.traceReason || 'trace unavailable'}`),
        `None of the configured ${[...new Set(untraced.map(t => t.chain))].join('/')} endpoints could trace ${untraced.length === 1 ? 'it' : 'them'}.`,
        `Set an archive endpoint: ${[...new Set(untraced.map(t => t.chain))].map(c => `${c}_TRACE_RPC (or --${c.toLowerCase()}-trace-rpc URL), plus ${c}_RPC if it cannot return receipts`).join('; ')}.`,
        'Use --allow-partial to draw the incomplete flow anyway.',
      ].join('\n'));
    }
    traces.push({ model, source, raw: isHash(input) ? trace : null, explorers });
  }
  // Default output: <repo>/tmp/flow-diagrams/, which git ignores.
  const file = path.resolve(out || path.join(here, '..', '..', 'tmp', 'flow-diagrams',
    isHash(inputs[0]) ? `${inputs[0]}.html` : `${path.basename(inputs[0], '.json')}-flow.html`));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // Keep the decoded trace beside the page so it can be re-rendered without new RPC calls.
  // A run that saw less (e.g. without an archive RPC) never replaces a more complete trace:
  // it is saved as .partial.json and the page is drawn from the complete one.
  for (const t of traces) if (t.raw) {
    const json = file.replace(/\.html$/, '') + (traces.length > 1 ? `-${t.source.slice(0, 10)}` : '') + '.json';
    const score = tr => [(tr.transactions || []).filter(x => x.trace?.available !== false).length, (tr.outgoing || []).filter(o => o.status === 'matched').length];
    let previous = null;
    try { if (fs.existsSync(json)) previous = JSON.parse(fs.readFileSync(json, 'utf8')); } catch { /* Unreadable: replace it. */ }
    const [nt, nm] = score(t.raw), [pt, pm] = previous ? score(previous) : [-1, -1];
    const text = JSON.stringify(t.raw, (_, v) => typeof v === 'bigint' ? v.toString() : v);
    if (previous && (pt > nt || pm > nm)) {
      const partial = json.replace(/\.json$/, '.partial.json');
      fs.writeFileSync(partial, text);
      console.error(`This run saw less than the saved trace (${nt} traced txs / ${nm} matched crossings vs ${pt} / ${pm}).`);
      console.error(`Kept ${json}; this run is in ${partial}. The page uses the complete trace.`);
      t.model = buildFlowModel(previous, { explorers: t.explorers });
    } else {
      fs.writeFileSync(json, text);
      console.log(`Saved decoded trace ${json}`);
    }
  }
  fs.writeFileSync(file, renderFlowHtml(traces, { fragment, views }));
  console.log(`Wrote ${file} (${fs.statSync(file).size.toLocaleString('en-US')} bytes; views: ${views.join(', ')})`);
  if (open) openInBrowser(file);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(e => { console.error(e.message); process.exit(1); });
}
