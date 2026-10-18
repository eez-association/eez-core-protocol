import { ethers } from 'ethers';
import { ExplorerClient } from './explorer.mjs';
import { lower, named, parseCall, protocol, proxyABI, shortAddress } from './protocol.mjs';

// All caches belong to one invocation and are keyed by chain + address. Selectors
// never identify an application contract; only an explorer can supply its name.
export class AbiDecoder {
  constructor(config, managers) {
    this.config = config; this.managers = managers;
    this.contracts = new Map(); this.signatures = new Map();
    this.explorer = new ExplorerClient(config, url => this.json(url));
  }
  async json(url) {
    const r = await (this.config.fetch || fetch)(url, { signal: AbortSignal.timeout(this.config.explorerTimeoutMs ?? 5000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }
  async contract(chain, address) {
    const key = `${chain}:${lower(address)}`;
    if (!this.contracts.has(key)) this.contracts.set(key, this.explorer.contract(chain, address));
    return this.contracts.get(key);
  }
  async candidates(selector) {
    if (this.config.no4byte) return [];
    if (!this.signatures.has(selector)) this.signatures.set(selector, (async () => {
      const signatures = new Set();
      try {
        let next = `https://www.4byte.directory/api/v1/signatures/?hex_signature=${selector}`;
        const seen = new Set();
        while (next) {
          const url = new URL(next);
          if (url.origin !== 'https://www.4byte.directory' || seen.has(url.href)) break;
          seen.add(url.href);
          const data = await this.json(url.href);
          for (const r of data.results || []) signatures.add(r.text_signature);
          if (data.next === next) break;
          next = data.next;
        }
      } catch { /* An unavailable signature service leaves raw data. */ }
      return [...signatures];
    })());
    return this.signatures.get(selector);
  }
  async decode(frame, implementations = []) {
    const address = frame.to, chain = frame.chain;
    const contract = await this.contract(chain, address);
    const result = { contractName: contract.name || 'Unknown contract', address: address || null,
      displayAddress: shortAddress(address), functionName: null, signature: null,
      arguments: [], returns: null, error: frame.error ? { message: frame.error, data: frame.output || '0x' } : null,
      provenance: null, candidates: [], rawInput: frame.input || '0x', rawOutput: frame.output || '0x' };
    if (contract.name) result.nameProvenance = { source: 'explorer', provider: contract.nameProvider, address };
    const interfaces = [];
    if (contract.iface) interfaces.push({ iface: contract.iface, source: 'explorer', provider: contract.abiProvider, address });
    for (const implementation of [...new Set(implementations)]) {
      const impl = await this.contract(chain, implementation);
      if (impl.iface) interfaces.push({ iface: impl.iface, source: 'explorer-delegatecall', provider: impl.abiProvider, address: implementation });
      if (!contract.name && impl.name) { result.contractName = impl.name; result.nameProvenance = { source: 'observed-delegatecall', provider: impl.nameProvider, address: implementation }; }
    }
    if (frame.role === 'manager') {
      interfaces.push({ iface: protocol[chain], source: 'local-protocol', address });
      result.contractName = chain === 'L1' ? 'EEZ' : 'EEZL2';
      result.nameProvenance = { source: 'local-protocol', address };
    } else if (frame.role === 'incoming-proxy' || frame.role === 'static-probe') {
      interfaces.push({ iface: proxyABI, source: 'local-protocol', address });
      result.contractName = 'CrossChainProxy';
      result.nameProvenance = { source: 'local-protocol', address };
    }
    if (frame.role === 'system-value-transfer') {
      result.contractName = 'L2 system';
      result.nameProvenance = { source: 'SYSTEM_ADDRESS', address, blockNumber: frame.blockNumber };
    }
    const decoded = [];
    for (const item of interfaces) {
      const parsed = parseCall(item.iface, frame.input);
      if (parsed) { decoded.push({ ...item, parsed }); break; }
    }
    if (!decoded.length && (frame.input || '').length >= 10) {
      for (const signature of await this.candidates(frame.input.slice(0, 10))) try {
        const iface = new ethers.Interface([`function ${signature}`]);
        const parsed = parseCall(iface, frame.input);
        // Round-trip validation rejects trailing bytes and malformed/ambiguous
        // ABI offsets; a selector match alone does not validate a signature.
        if (parsed && lower(iface.encodeFunctionData(parsed.fragment, parsed.args)) === lower(frame.input)) {
          decoded.push({ iface, parsed, source: '4byte.directory', address: null });
        }
      } catch { /* Invalid signature or calldata. */ }
    }
    result.candidates = decoded.map(d => ({ signature: d.parsed.signature, arguments: named(d.parsed.fragment.inputs, d.parsed.args), provenance: { source: d.source, address: d.address, ...(d.provider ? { provider: d.provider } : {}) } }));
    if (decoded.length === 1) {
      const { iface, parsed, source, provider, address: abiAddress } = decoded[0];
      result.functionName = parsed.name; result.signature = parsed.signature;
      result.arguments = named(parsed.fragment.inputs, parsed.args);
      result.provenance = { source, address: abiAddress, ...(provider ? { provider } : {}) };
      if (!frame.error && source !== '4byte.directory') try {
        result.returns = named(parsed.fragment.outputs, iface.decodeFunctionResult(parsed.fragment, frame.output || '0x'));
      } catch { /* ABI or return bytes incomplete. */ }
    }
    if (frame.error) for (const { iface, source, provider } of interfaces) try {
      const error = iface.parseError(frame.output || '0x');
      if (error) { result.error = { ...result.error, name: error.name, signature: error.signature, arguments: named(error.fragment.inputs, error.args), provenance: source, ...(provider ? { provider } : {}) }; break; }
    } catch { /* Keep raw revert bytes. */ }
    return result;
  }
}
