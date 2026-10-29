import { hex, lower, number, same } from './protocol.mjs';

async function mapConcurrent(items, fn, limit = 8) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  }));
  return results;
}

export function makeRpc(config) {
  if (config.rpc) return config.rpc;
  let id = 0;
  const noBatch = new Set();
  const result = (body, method) => {
    if (body?.error) {
      if (!Number.isInteger(body.error.code) || typeof body.error.message !== 'string') {
        throw Object.assign(new Error(`${method}: malformed JSON-RPC error`), { invalidResponse: true });
      }
      throw Object.assign(new Error(`${method}: ${body.error.message}`), { code: body.error.code });
    }
    if (!body || !Object.hasOwn(body, 'result')) throw Object.assign(new Error(`${method}: missing JSON-RPC result`), { invalidResponse: true });
    return body.result;
  };
  async function post(url, payload, method) {
    let response;
    try {
      response = await (config.fetch || fetch)(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(config.timeoutMs ?? 20000),
      });
    } catch (e) { throw Object.assign(new Error(e.message, { cause: e }), { transport: true, code: e.code }); }
    if (!response.ok) {
      // Some servers reject JSON-RPC batches with HTTP 400 and -32600.
      let body;
      try { body = await response.json(); } catch { /* HTTP error without JSON. */ }
      throw Object.assign(new Error(`${method}: HTTP ${response.status}`), { code: body?.error?.code, transport: true });
    }
    try { return await response.json(); }
    catch (e) {
      if (e instanceof SyntaxError) throw Object.assign(new Error(`${method}: invalid JSON response`, { cause: e }), { invalidResponse: true });
      throw Object.assign(new Error(`${method}: response body unavailable`, { cause: e }), { transport: true, code: e.code });
    }
  }
  const rpc = async (url, method, params = []) => result(await post(url, { jsonrpc: '2.0', id: ++id, method, params }, method), method);
  // Same bounded batches and response-ID validation as the E2E network evidence helpers.
  rpc.batch = async (url, method, params) => {
    const results = [];
    for (let start = 0; start < params.length; start += 100) {
      const chunk = params.slice(start, start + 100);
      if (noBatch.has(url)) {
        results.push(...await mapConcurrent(chunk, p => rpc(url, method, p)));
        continue;
      }
      const requests = chunk.map(p => ({ jsonrpc: '2.0', id: ++id, method, params: p }));
      let body;
      try {
        body = await post(url, requests, method);
        if (!Array.isArray(body) && body?.error) result(body, method);
      } catch (e) {
        if (e.code !== -32600) throw e;
        noBatch.add(url);
        results.push(...await mapConcurrent(chunk, p => rpc(url, method, p)));
        continue;
      }
      const expected = new Set(requests.map(r => r.id)), replies = new Map();
      if (!Array.isArray(body) || body.length !== requests.length) throw new Error(`${method}: incomplete JSON-RPC batch`);
      for (const reply of body) {
        if (reply?.jsonrpc !== '2.0' || !expected.has(reply.id) || replies.has(reply.id)) throw new Error(`${method}: invalid JSON-RPC batch IDs`);
        replies.set(reply.id, result(reply, method));
      }
      results.push(...requests.map(r => replies.get(r.id)));
    }
    return results;
  };
  return rpc;
}

export class ChainReader {
  constructor(chain, url, traceUrl, rpc, report) {
    Object.assign(this, { chain, url, traceUrl: traceUrl || url, rpc, report });
    this.blocks = new Map(); this.receiptBlocks = new Map(); this.traces = new Map();
  }
  // Reads go to the read RPC. When it fails, or reports a transaction, receipt or block as unknown
  // (typical of non-archive nodes), the read is retried on the trace RPC, whose chain ID was
  // verified at start-up. An archive trace endpoint alone then covers historical reads.
  async send(method, params = [], trace = false) {
    if (trace || this.traceUrl === this.url) return this.rpc(trace ? this.traceUrl : this.url, method, params);
    const retryOnNull = ['eth_getTransactionReceipt', 'eth_getTransactionByHash', 'eth_getBlockByNumber', 'eth_getBlockByHash'].includes(method);
    try {
      const result = await this.rpc(this.url, method, params);
      if (result != null || !retryOnNull) return result;
    } catch (e) {
      try { return await this.rpc(this.traceUrl, method, params); } catch { throw e; }
    }
    return this.rpc(this.traceUrl, method, params);
  }
  async block(n) {
    const tag = typeof n === 'string' && (n === 'latest' || n.length === 66) ? n : hex(n);
    if (!this.blocks.has(tag)) this.blocks.set(tag, this.send(tag.length === 66 ? 'eth_getBlockByHash' : 'eth_getBlockByNumber', [tag, true]));
    return this.blocks.get(tag);
  }
  async prefetchBlocks(numbers) {
    const missing = [...new Set(numbers.map(hex))].filter(tag => !this.blocks.has(tag));
    for (let start = 0; start < missing.length; start += 100) {
      const tags = missing.slice(start, start + 100);
      if (this.rpc.batch) {
        let blocks;
        try { blocks = await this.rpc.batch(this.url, 'eth_getBlockByNumber', tags.map(tag => [tag, true])); }
        catch (e) { this.report?.('block-batch-fallback', `${this.chain}: ${e.message}; retrying individual reads`); }
        if (blocks) {
          // Validate the entire chunk before caching it. Correlation still checks every hash.
          if (blocks.length !== tags.length || blocks.some((b, i) => b && (number(b.number) !== number(tags[i]) || !/^0x[0-9a-f]{64}$/i.test(b.hash) || !Array.isArray(b.transactions)))) {
            throw new Error(`${this.chain}: invalid block batch response`);
          }
          await mapConcurrent(tags.map((tag, i) => ({ tag, i })), async ({ tag, i }) => {
            // A null batch slot may be pruned on the read node but present in the archive.
            const b = blocks[i] ?? (this.traceUrl !== this.url ? await this.send('eth_getBlockByNumber', [tag, true], true) : null);
            if (b && (number(b.number) !== number(tag) || !/^0x[0-9a-f]{64}$/i.test(b.hash) || !Array.isArray(b.transactions))) {
              throw new Error(`${this.chain}: invalid archive block response`);
            }
            this.blocks.set(tag, Promise.resolve(b));
          });
          continue;
        }
      }
      // Custom transports or providers without batches retain bounded concurrency and
      // the usual archive fallback in send(). Cache failures for the caller to report.
      await mapConcurrent(tags, async tag => { try { await this.block(tag); } catch { /* Report when read. */ } });
    }
  }
  async receipts(block) {
    if (!block.transactions.length) return [];
    if (!this.receiptBlocks.has(block.hash)) this.receiptBlocks.set(block.hash, (async () => {
      try { return await this.send('eth_getBlockReceipts', [block.hash]); }
      catch { try { return await this.send('eth_getBlockReceipts', [block.number]); } catch { return []; } }
    })());
    return await this.receiptBlocks.get(block.hash) || [];
  }
  async recover(hash, hint = null) {
    const [txResult, receiptResult] = await Promise.allSettled([
      this.send('eth_getTransactionByHash', [hash]), this.send('eth_getTransactionReceipt', [hash]),
    ]);
    let transaction = txResult.status === 'fulfilled' ? txResult.value : null;
    let receipt = receiptResult.status === 'fulfilled' ? receiptResult.value : null;
    const blockNumber = hint ?? receipt?.blockNumber ?? transaction?.blockNumber;
    let block = blockNumber != null ? await this.block(blockNumber) : null;
    if (blockNumber != null && !block) throw new Error(`${this.chain}: canonical transaction block unavailable`);
    const recovery = [];
    let canonicalIndex = null;
    if (block) {
      const index = block.transactions.findIndex(tx => same(typeof tx === 'string' ? tx : tx.hash, hash));
      canonicalIndex = index;
      if (index < 0 || (transaction?.blockHash && !same(transaction.blockHash, block.hash)) || (receipt?.blockHash && !same(receipt.blockHash, block.hash))) {
        throw new Error(`${this.chain}: transaction is not included in the canonical block`);
      }
      if (!transaction && typeof block.transactions[index] === 'object') {
        transaction = { ...block.transactions[index], blockHash: block.hash, blockNumber: block.number, transactionIndex: hex(index) };
        recovery.push('block-transaction');
      }
      if (!receipt) {
        receipt = (await this.receipts(block)).find(r => same(r.transactionHash, hash)) || null;
        if (receipt) recovery.push('block-receipt');
      }
      if ((receipt?.blockHash && !same(receipt.blockHash, block.hash)) ||
          (receipt?.transactionIndex != null && number(receipt.transactionIndex) !== index) ||
          (transaction?.transactionIndex != null && number(transaction.transactionIndex) !== index)) {
        throw new Error(`${this.chain}: recovered transaction/receipt disagrees with canonical inclusion`);
      }
    }
    if (!transaction && !receipt) return null;
    return { chain: this.chain, hash: lower(hash), transaction, receipt,
      blockNumber: block ? number(block.number) : null, blockHash: block?.hash ?? null,
      transactionIndex: canonicalIndex ?? number(transaction?.transactionIndex ?? receipt?.transactionIndex ?? 0), recovery };
  }
  async trace(record) {
    if (this.traces.has(record.hash)) return this.traces.get(record.hash);
    const result = await this.traceUncached(record);
    this.traces.set(record.hash, result);
    return result;
  }
  async traceUncached(record) {
    const options = { tracer: 'callTracer', tracerConfig: { withLog: true } };
    const failures = [];
    try {
      const trace = await this.send('debug_traceTransaction', [record.hash, options], true);
      if (trace && (trace.type || trace.to || trace.from)) return { trace, provenance: 'debug_traceTransaction' };
      failures.push('transaction tracer returned no call tree');
    } catch (e) { failures.push(e.message); }
    if (record.blockHash) {
      for (const method of ['debug_traceBlockByHash', 'debug_traceBlockByNumber']) {
        try {
          const key = `trace:${method}:${record.blockHash}`;
          if (!this.blocks.has(key)) this.blocks.set(key, this.send(method, [method.endsWith('Hash') ? record.blockHash : hex(record.blockNumber), options], true));
          const items = await this.blocks.get(key);
          const block = await this.block(record.blockNumber);
          // Index fallback is allowed only when the tracer returned the complete block.
          const item = items?.find?.(x => same(x.txHash || x.transactionHash, record.hash)) ??
            (Array.isArray(items) && items.length === block.transactions.length &&
              items.every(x => !x.txHash && !x.transactionHash) ? items[record.transactionIndex] : null);
          const trace = item?.result ?? item;
          if (trace && (trace.type || trace.to || trace.from) && !item?.error) return { trace, provenance: method };
          failures.push(`${method}: ${item?.error || 'transaction call tree absent'}`);
        } catch (e) { failures.push(e.message); }
      }
    }
    const reason = failures.some(s => /historical|state|trie|prun|changesets|header not found/i.test(s)) ? 'historical-state-unavailable' : 'trace-unavailable';
    return { trace: null, reason, failures };
  }
  async nearest(timestamp) {
    const head = await this.block('latest');
    if (!head) throw new Error(`${this.chain}: latest block unavailable`);
    let lo = 0, hi = number(head.number);
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2), b = await this.block(mid);
      if (!b) throw new Error(`${this.chain}: block ${mid} unavailable during timestamp search`);
      if (number(b.timestamp) < timestamp) lo = mid + 1; else hi = mid;
    }
    if (lo > 0) {
      const [a, b] = await Promise.all([this.block(lo - 1), this.block(lo)]);
      if (Math.abs(number(a.timestamp) - timestamp) <= Math.abs(number(b.timestamp) - timestamp)) lo--;
    }
    return { block: lo, head: number(head.number) };
  }
}

export async function validateSettlement(raw, readers, requested = {}) {
  if (!raw || raw.canonicalL2 !== true) throw new Error('Settlement does not attest canonical L2 blocks');
  const l1Number = number(raw.l1BlockNumber), first = number(raw.l2Range?.firstBlockNumber), last = number(raw.l2Range?.lastBlockNumber);
  if (first > last || (raw.l2Range.blockCount != null && number(raw.l2Range.blockCount) !== last - first + 1)) throw new Error('Invalid settlement L2 range');
  if (requested.L1 != null && l1Number !== requested.L1) throw new Error('Settlement returned for a different L1 block');
  if (requested.L2 != null && (requested.L2 < first || requested.L2 > last)) throw new Error('Settlement excludes requested L2 block');
  if (requested.blockHash && (requested.L1 != null ? !same(raw.l1BlockHash, requested.blockHash)
    : !same(raw.matchedL2Block?.hash, requested.blockHash) || number(raw.matchedL2Block?.number) !== requested.L2)) {
    throw new Error('Settlement does not match the requested block hash');
  }
  const l1 = await readers.L1.block(l1Number);
  if (!l1 || !same(l1.hash, raw.l1BlockHash)) throw new Error('Noncanonical L1 settlement block hash');
  const index = number(raw.l1TransactionIndex);
  const transaction = l1.transactions[index];
  if (!same(typeof transaction === 'string' ? transaction : transaction?.hash, raw.l1TransactionHash)) throw new Error('Settlement transaction inclusion/index mismatch');
  const checks = new Map([[first, raw.l2Range.firstBlockHash], [last, raw.l2Range.lastBlockHash]]);
  if (!raw.l2Range.firstBlockHash || !raw.l2Range.lastBlockHash) throw new Error('Settlement is missing range boundary hashes');
  if (first === last && !same(raw.l2Range.firstBlockHash,raw.l2Range.lastBlockHash)) throw new Error('Inconsistent single-block settlement boundary hashes');
  for (const b of raw.l2Blocks || []) {
    const n = number(b.number);
    if (n < first || n > last || (checks.has(n) && !same(checks.get(n), b.hash))) throw new Error('Inconsistent settlement L2 block list');
    checks.set(n, b.hash);
  }
  if (raw.matchedL2Block && typeof raw.matchedL2Block === 'object') {
    const n = number(raw.matchedL2Block.number);
    if (requested.L2 != null && n !== requested.L2) throw new Error('Settlement matched a different L2 block');
    if (n < first || n > last || (checks.has(n) && !same(checks.get(n), raw.matchedL2Block.hash))) throw new Error('Inconsistent matched L2 block');
    checks.set(n, raw.matchedL2Block.hash);
  }
  await readers.L2.prefetchBlocks([...checks.keys()]);
  for (const [n, hash] of checks) {
    const b = await readers.L2.block(n);
    if (!b || !same(b.hash, hash)) throw new Error(`Noncanonical L2 block hash at ${n}`);
  }
  return { id: `${lower(raw.l1TransactionHash)}:${first}-${last}`, l1BlockNumber: l1Number,
    l1TransactionHash: lower(raw.l1TransactionHash), firstL2Block: first, lastL2Block: last,
    canonical: true, raw };
}
