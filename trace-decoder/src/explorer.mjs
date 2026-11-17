import { ethers } from 'ethers';

const ETHERSCAN_API = 'https://api.etherscan.io/v2/api';
const successful = body => body && (body.status == null || String(body.status) === '1');

function endpoint(base, type = 'auto', apiKey, chainId) {
  let url = new URL(base);
  const etherscanHost = url.hostname === 'etherscan.io' || url.hostname.endsWith('.etherscan.io');
  const provider = type === 'auto'
    ? (etherscanHost || /\/v2\/api\/?$/.test(url.pathname) ? 'etherscan' : 'blockscout')
    : type;
  if (!['blockscout', 'etherscan'].includes(provider)) throw new Error('Unknown explorer type');
  url.hash = '';
  if (provider === 'etherscan') {
    // Website and legacy Etherscan URLs all use the current multichain API.
    if (etherscanHost) {
      const params = url.search;
      url = new URL(ETHERSCAN_API);
      url.search = params;
    } else {
      const path = url.pathname.replace(/\/+$/, '');
      url.pathname = path.endsWith('/api') ? path : path + '/v2/api';
    }
    // Never infer Ethereum mainnet or trust a stale chainid in a configured URL.
    if (chainId == null || BigInt(chainId) <= 0n) return null;
    url.searchParams.set('chainid', BigInt(chainId).toString());
  } else {
    url.pathname = url.pathname.replace(/\/+$/, '').replace(/\/api(?:\/v2)?$/, '');
    url.searchParams.delete('chainid');
  }
  if (apiKey) url.searchParams.set('apikey', apiKey);
  if (provider === 'etherscan' && !url.searchParams.get('apikey')) return null;
  for (const key of ['module', 'action', 'address']) url.searchParams.delete(key);
  return { url, provider };
}

function merge(result, data, provider) {
  if (!data || typeof data !== 'object') return;
  const name = data.name || data.ContractName;
  if (!result.name && typeof name === 'string' && name.trim()) {
    result.name = name.trim(); result.nameProvider = provider;
  }
  if (result.iface) return;
  try {
    const raw = data.abi ?? data.ABI;
    const abi = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (Array.isArray(abi) && abi.length) {
      // Parse first: Interface otherwise logs invalid fragments to stdout, which
      // would corrupt the CLI's JSON document.
      const fragments = abi.map(fragment => ethers.Fragment.from(fragment));
      result.iface = new ethers.Interface(fragments); result.abiProvider = provider;
    }
  } catch { /* Unverified source and malformed responses are not ABIs. */ }
}

// One client per decode invocation; Etherscan requests share a queue across chains.
export class ExplorerClient {
  constructor(config, request) {
    this.config = config; this.request = request;
    this.queue = Promise.resolve(); this.nextRequestAt = 0;
  }
  async json(url, provider) {
    if (provider !== 'etherscan') return this.request(url.href);
    const pending = this.queue.then(async () => {
      const delay = this.nextRequestAt - Date.now();
      if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay));
      this.nextRequestAt = Date.now() + (this.config.etherscanMinIntervalMs ?? 350);
      return this.request(url.href);
    });
    this.queue = pending.catch(() => {});
    return pending;
  }
  async read(endpoint, address, result) {
    const { url, provider } = endpoint;
    const request = async action => {
      const target = new URL(url);
      if (provider === 'blockscout') target.pathname = target.pathname.replace(/\/+$/, '') + '/api';
      target.searchParams.set('module', 'contract');
      target.searchParams.set('action', action);
      target.searchParams.set('address', address);
      try {
        const body = await this.json(target, provider);
        return successful(body) ? body : null;
      } catch { return null; }
    };
    if (provider === 'blockscout') {
      const target = new URL(url);
      target.pathname = target.pathname.replace(/\/+$/, '') + '/api/v2/smart-contracts/' + address;
      try {
        const body = await this.json(target, provider);
        if (successful(body)) merge(result, body, provider);
      } catch { /* Older Blockscout instances expose only the contract RPC API. */ }
    }
    if (!result.name || !result.iface) {
      const body = await request('getsourcecode');
      const data = Array.isArray(body?.result) ? body.result[0] : body?.result;
      merge(result, data, provider);
      // An Etherscan error (bad key, unsupported chain, rate limit) is not fixed
      // by another API action. Blockscout may still expose a working getabi.
      if (!result.iface && (body || provider === 'blockscout')) {
        const abi = await request('getabi');
        merge(result, { abi: abi?.result }, provider);
      }
    }
  }
  async contract(chain, address) {
    const result = { address, name: null, iface: null };
    if (!address || this.config.noExplorer) return result;
    const prefix = chain === 'L1' ? 'l1' : 'l2';
    const base = this.config[prefix + 'Explorer'];
    const chainId = this.config.chainIds?.[chain];
    let primary = null;
    if (base) try {
      const type = this.config[prefix + 'ExplorerType'] || 'auto';
      // The shared Etherscan key must never be sent to a Blockscout instance.
      primary = endpoint(base, type, this.config[prefix + 'ExplorerApiKey'], chainId);
      if (!primary && this.config.etherscanApiKey) {
        primary = endpoint(base, type, this.config.etherscanApiKey, chainId);
      }
    } catch { /* Invalid optional explorer settings preserve the raw trace. */ }
    if (primary) await this.read(primary, address, result);
    if ((!result.name || !result.iface) && primary?.provider !== 'etherscan' && this.config.etherscanApiKey) {
      const fallback = endpoint(ETHERSCAN_API, 'etherscan', this.config.etherscanApiKey, chainId);
      if (fallback) await this.read(fallback, address, result);
    }
    return result;
  }
}
