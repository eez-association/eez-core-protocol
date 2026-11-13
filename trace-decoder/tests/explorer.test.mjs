import assert from 'node:assert/strict';
import test from 'node:test';
import { ethers } from 'ethers';
import { AbiDecoder } from '../src/abi-decoder.mjs';
import { loadConfig, parseEnv } from '../src/config.mjs';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { renderTrace } from '../src/logical.mjs';
import { scenario, address, app, hash, M } from './fixtures/scenarios.mjs';

const abi = new ethers.Interface([
  'function setValue(uint256 value) returns (uint256 previous)',
  'error Denied(address caller)',
  'event Updated(uint256 value)',
]);
const target = address(0xabcdef);
const call = { chain: 'L1', to: target, input: abi.encodeFunctionData('setValue', [42]),
  output: abi.encodeFunctionResult('setValue', [7]) };
const response = body => ({ ok: true, json: async () => body });
const verified = name => ({ status: '1', result: [{ ContractName: name, ABI: abi.formatJson() }] });
const unavailable = { status: '0', message: 'NOTOK', result: 'Contract source code not verified' };
const chainIds = { L1: '1', L2: '8453' };

function decoder(config, handler) {
  const requests = [];
  const instance = new AbiDecoder({ no4byte: true, chainIds, etherscanMinIntervalMs: 0, ...config,
    fetch: async input => {
      const url = new URL(input); requests.push(url);
      return handler(url);
    } }, M);
  return { instance, requests };
}

for (const suffix of ['', '/', '/api', '/api/', '/api/v2', '/api/v2/']) {
  test('Blockscout verified metadata decodes calls from URL suffix ' + JSON.stringify(suffix), async () => {
    const { instance, requests } = decoder({ l1Explorer: 'https://scout.example/chain' + suffix }, url => {
      assert.equal(url.pathname, '/chain/api/v2/smart-contracts/' + target);
      return response({ name: 'VerifiedCounter', abi: JSON.parse(abi.formatJson()) });
    });
    const decoded = await instance.decode(call);
    assert.equal(decoded.contractName, 'VerifiedCounter');
    assert.equal(decoded.signature, 'setValue(uint256)');
    assert.equal(decoded.arguments[0].value, '42');
    assert.equal(decoded.returns[0].value, '7');
    assert.equal(decoded.provenance.provider, 'blockscout');
    assert.equal(decoded.nameProvenance.provider, 'blockscout');
    assert.equal(requests.length, 1);
  });
}

for (const arrayResult of [true, false]) {
  test('Blockscout legacy source metadata accepts ' + (arrayResult ? 'array' : 'object') + ' results', async () => {
    const { instance, requests } = decoder({ l1Explorer: 'https://scout.example' }, url => {
      assert.ok(!url.pathname.startsWith('//'));
      if (url.pathname.includes('/smart-contracts/')) return { ok: false, status: 404 };
      assert.equal(url.searchParams.get('action'), 'getsourcecode');
      const data = verified('LegacyCounter');
      if (!arrayResult) data.result = data.result[0];
      return response(data);
    });
    assert.equal((await instance.decode(call)).contractName, 'LegacyCounter');
    assert.equal(requests.length, 2);
  });
}

test('Blockscout can retrieve an ABI separately while preserving the verified name', async () => {
  const { instance } = decoder({ l1Explorer: 'https://scout.example/api?apikey=old&network=dev', l1ExplorerApiKey: 'scout-key' }, url => {
    assert.equal(url.searchParams.get('apikey'), 'scout-key');
    assert.equal(url.searchParams.get('network'), 'dev');
    if (url.pathname.includes('/smart-contracts/')) return response({ name: 'Counter', abi: [] });
    if (url.searchParams.get('action') === 'getsourcecode') return response({ status: '1', result: { ContractName: 'Counter', ABI: 'invalid' } });
    return response({ status: '1', result: abi.formatJson() });
  });
  const decoded = await instance.decode(call);
  assert.equal(decoded.contractName, 'Counter');
  assert.equal(decoded.signature, 'setValue(uint256)');
});

for (const base of ['https://etherscan.io', 'https://sepolia.etherscan.io/', 'https://api.etherscan.io/api',
  'https://api.etherscan.io/v2/api?chainid=999&action=old#ignored']) {
  test('Etherscan V2 normalizes ' + base + ' and uses the RPC chain ID', async () => {
    const { instance, requests } = decoder({ l1Explorer: base, etherscanApiKey: 'shared-key' }, url => {
      assert.equal(url.origin + url.pathname, 'https://api.etherscan.io/v2/api');
      assert.equal(url.searchParams.get('chainid'), '1');
      assert.equal(url.searchParams.get('apikey'), 'shared-key');
      assert.equal(url.searchParams.get('action'), 'getsourcecode');
      assert.equal(url.searchParams.get('address'), target);
      assert.equal(url.hash, '');
      return response(verified('EtherscanCounter'));
    });
    const decoded = await instance.decode(call);
    assert.equal(decoded.contractName, 'EtherscanCounter');
    assert.equal(decoded.provenance.provider, 'etherscan');
    assert.equal(decoded.returns[0].value, '7');
    assert.equal(requests.length, 1);
  });
}

test('Blockscout finishes before Etherscan fallback; keys and names stay scoped to each provider', async () => {
  const { instance, requests } = decoder({
    l1Explorer: 'https://scout.example', l1ExplorerApiKey: 'scout-key', etherscanApiKey: 'shared-key',
  }, url => {
    if (url.hostname === 'scout.example') {
      assert.equal(url.searchParams.get('apikey'), 'scout-key');
      return response(url.pathname.includes('smart-contracts') ? { name: 'ScoutCounter' } : unavailable);
    }
    assert.equal(url.searchParams.get('apikey'), 'shared-key');
    return response(verified('EtherscanCounter'));
  });
  const decoded = await instance.decode(call);
  assert.equal(decoded.contractName, 'ScoutCounter');
  assert.equal(decoded.nameProvenance.provider, 'blockscout');
  assert.equal(decoded.provenance.provider, 'etherscan');
  assert.deepEqual(requests.map(u => u.hostname), ['scout.example', 'scout.example', 'scout.example', 'api.etherscan.io']);
  assert.ok(!JSON.stringify(decoded).includes('shared-key'));
});

test('complete Blockscout metadata avoids Etherscan and never receives its key', async () => {
  const { instance, requests } = decoder({ l1Explorer: 'https://scout.example', etherscanApiKey: 'secret' }, url => {
    assert.equal(url.hostname, 'scout.example');
    assert.equal(url.searchParams.has('apikey'), false);
    return response({ name: 'Counter', abi: abi.formatJson() });
  });
  await instance.decode(call);
  assert.equal(requests.length, 1);
});

test('Etherscan alone caches by chain and case-insensitive address, including concurrent lookups', async () => {
  const { instance, requests } = decoder({ etherscanApiKey: 'key' }, url =>
    response(verified('Counter' + url.searchParams.get('chainid'))));
  const [first, again, other] = await Promise.all([
    instance.decode(call), instance.decode({ ...call, to: target.toLowerCase() }),
    instance.decode({ ...call, chain: 'L2' }),
  ]);
  assert.equal(first.contractName, 'Counter1');
  assert.equal(again.contractName, 'Counter1');
  assert.equal(other.contractName, 'Counter8453');
  assert.equal(requests.length, 2);
});

test('custom Etherscan endpoints accept per-chain keys without malformed paths', async () => {
  const { instance } = decoder({ l1Explorer: 'https://scan.example/', l1ExplorerType: 'etherscan',
    l1ExplorerApiKey: 'l1-key', etherscanApiKey: 'shared-key' }, url => {
    assert.equal(url.origin + url.pathname, 'https://scan.example/v2/api');
    assert.equal(url.searchParams.get('apikey'), 'l1-key');
    return response(verified('CustomCounter'));
  });
  assert.equal((await instance.decode(call)).contractName, 'CustomCounter');
});

test('observed Etherscan implementation ABI decodes returns and custom errors', async () => {
  const implementation = address(9);
  const { instance } = decoder({ etherscanApiKey: 'key' }, url =>
    response(url.searchParams.get('address') === implementation ? verified('Implementation') : unavailable));
  const decoded = await instance.decode(call, [implementation]);
  assert.equal(decoded.contractName, 'Implementation');
  assert.equal(decoded.provenance.source, 'explorer-delegatecall');
  assert.equal(decoded.provenance.provider, 'etherscan');
  assert.equal(decoded.nameProvenance.address, implementation);
  assert.equal(decoded.returns[0].value, '7');
  const reverted = await instance.decode({ ...call, error: 'execution reverted',
    output: abi.encodeErrorResult('Denied', [target]) }, [implementation]);
  assert.equal(reverted.error.name, 'Denied');
  assert.equal(reverted.error.arguments[0].value, target);
});

for (const failure of ['unverified', 'rate-limit', 'http', 'network', 'malformed']) {
  test('Etherscan ' + failure + ' preserves raw data and allows validated signature fallback', async () => {
    const { instance, requests } = decoder({ etherscanApiKey: 'key', no4byte: false }, url => {
      if (url.hostname === 'www.4byte.directory') return response({ results: [{ text_signature: 'setValue(uint256)' }] });
      if (failure === 'network') throw new Error('network failed');
      if (failure === 'http') return { ok: false, status: 429 };
      if (failure === 'malformed') return response({ status: '1', result: [{ ABI: '{bad JSON' }] });
      return response(failure === 'rate-limit' ? { status: '0', result: 'Max rate limit reached' } : unavailable);
    });
    const decoded = await instance.decode(call);
    assert.equal(decoded.contractName, 'Unknown contract');
    assert.equal(decoded.signature, 'setValue(uint256)');
    assert.equal(decoded.provenance.source, '4byte.directory');
    assert.equal(decoded.rawInput, call.input);
    assert.equal(decoded.rawOutput, call.output);
    assert.equal(requests.at(-1).hostname, 'www.4byte.directory');
  });
}

for (const config of [
  { noExplorer: true, etherscanApiKey: 'key', l1Explorer: 'https://scout.example' },
  { etherscanApiKey: 'key', chainIds: {} },
  { l1Explorer: 'https://api.etherscan.io/v2/api' },
]) {
  test('disabled or unconfigured explorer requests are skipped: ' + JSON.stringify(config), async () => {
    const { instance, requests } = decoder(config, () => { throw new Error('Must not fetch'); });
    const decoded = await instance.decode(call);
    assert.equal(requests.length, 0);
    assert.equal(decoded.rawInput, call.input);
    assert.equal(decoded.contractName, 'Unknown contract');
  });
}

test('explorer CLI/env configuration preserves precedence and the wallet-key exclusion', () => {
  assert.deepEqual(parseEnv('ETHERSCAN_API_KEY=file-key\nL1_EXPLORER_API_KEY=scout-key\nPRIVATE_KEY=wallet-secret'), {
    ETHERSCAN_API_KEY: 'file-key', L1_EXPLORER_API_KEY: 'scout-key',
  });
  const config = loadConfig([hash('tx'), '--etherscan-api-key', 'cli-key', '--l1-explorer-type', 'etherscan',
    '--l1-explorer-api-key', 'per-chain'], {
    L1_RPC: 'one', L2_RPC: 'two', ETHERSCAN_API_KEY: 'env-key', L2_EXPLORER_TYPE: 'blockscout',
  }, '/nonexistent');
  assert.equal(config.etherscanApiKey, 'cli-key');
  assert.equal(config.l1ExplorerApiKey, 'per-chain');
  assert.equal(config.l1ExplorerType, 'etherscan');
  assert.equal(config.l2ExplorerType, 'blockscout');
  assert.throws(() => loadConfig([hash('tx'), '--l1-explorer-type', 'invalid'],
    { L1_RPC: 'one', L2_RPC: 'two' }, '/nonexistent'), /Invalid l1ExplorerType/);
});

test('engine passes verified chain IDs to Etherscan and renders names, calls and decoded events', async () => {
  const f = scenario();
  const event = abi.encodeEventLog(abi.getEvent('Updated'), [42]);
  f.txs.L2.get(f.deliveries[0]).receipt.logs.push({ ...event, address: f.target, logIndex: '0x99' });
  const requests = [];
  const result = await decodeCrossChainTrace({ ...f.config, noExplorer: false,
    chainIds: { L1: '999', L2: '999' }, etherscanApiKey: 'engine-secret', etherscanMinIntervalMs: 0,
    fetch: async input => {
      const url = new URL(input); requests.push(url);
      return response({ status: '1', result: [{
        ContractName: 'Counter' + url.searchParams.get('chainid'),
        ABI: JSON.stringify([...JSON.parse(app.formatJson()), ...JSON.parse(abi.formatJson())]),
      }] });
    },
  }, f.trigger);
  assert.deepEqual(new Set(requests.map(u => u.searchParams.get('chainid'))), new Set(['100', '200']));
  assert.equal(result.outgoing[0].remoteCall.contractName, 'Counter200');
  assert.equal(result.outgoing[0].remoteCall.signature, 'increment()');
  assert.match(renderTrace(result), /Counter200/);
  const decodedEvent = result.events.find(e => e.address === f.target && e.decoded?.name === 'Updated');
  assert.equal(decodedEvent.decoded.arguments[0].value, '42');
  assert.equal(decodedEvent.decoded.provider, 'etherscan');
  assert.ok(!JSON.stringify(result).includes('engine-secret'));
});

test('mixed providers cache the same address separately and never cross provider credentials', async () => {
  const { instance, requests } = decoder({
    l1Explorer: 'https://api.etherscan.io/v2/api', l1ExplorerApiKey: 'l1-secret',
    l2Explorer: 'https://l2-scout.example', l2ExplorerApiKey: 'l2-secret',
  }, url => {
    if (url.hostname === 'api.etherscan.io') {
      assert.equal(url.searchParams.get('apikey'), 'l1-secret');
      assert.equal(url.searchParams.get('chainid'), '1');
      return response(verified('L1Counter'));
    }
    assert.equal(url.hostname, 'l2-scout.example');
    assert.equal(url.searchParams.get('apikey'), 'l2-secret');
    return response({ name: 'L2Counter', abi: abi.formatJson() });
  });
  const l1 = await instance.decode(call), l2 = await instance.decode({ ...call, chain: 'L2' });
  assert.equal(l1.contractName, 'L1Counter');
  assert.equal(l2.contractName, 'L2Counter');
  assert.equal(l1.provenance.provider, 'etherscan');
  assert.equal(l2.provenance.provider, 'blockscout');
  await instance.decode(call);
  await instance.decode({ ...call, chain: 'L2' });
  assert.equal(requests.length, 2);
});

for (const etherscanChain of ['L1', 'L2']) for (const direction of ['L1', 'L2']) {
  test(direction + ' trigger decodes with Etherscan on ' + etherscanChain + ' and Blockscout on the other chain', async () => {
    const f = scenario({ direction });
    const explorerEnv = {};
    for (const chain of ['L1', 'L2']) {
      explorerEnv['EXPLORER_' + chain] = chain === etherscanChain ? 'https://api.etherscan.io/v2/api' : 'https://scout.example';
      explorerEnv[chain + '_EXPLORER_TYPE'] = chain === etherscanChain ? 'etherscan' : 'blockscout';
      if (chain === etherscanChain) explorerEnv[chain + '_EXPLORER_API_KEY'] = 'scan-secret';
    }
    const cli = loadConfig([f.trigger], { L1_RPC: 'l1-rpc', L2_RPC: 'l2-rpc', ...explorerEnv }, '/nonexistent');
    const seen = new Set();
    const result = await decodeCrossChainTrace({ ...f.config, ...cli, noExplorer: false, etherscanMinIntervalMs: 0,
      fetch: async input => {
        const url = new URL(input), scan = url.hostname === 'api.etherscan.io';
        const chain = scan ? etherscanChain : (etherscanChain === 'L1' ? 'L2' : 'L1');
        seen.add(chain);
        if (scan) {
          assert.equal(url.pathname, '/v2/api');
          assert.equal(url.searchParams.get('chainid'), chain === 'L1' ? '100' : '200');
          assert.equal(url.searchParams.get('apikey'), 'scan-secret');
          return response({ status: '1', result: [{ ContractName: chain + 'Counter', ABI: app.formatJson() }] });
        }
        assert.equal(url.hostname, 'scout.example');
        assert.equal(url.searchParams.has('apikey'), false);
        assert.match(url.pathname, /^\/api\/v2\/smart-contracts\//);
        return response({ name: chain + 'Counter', abi: app.formatJson() });
      },
    }, f.trigger);
    assert.deepEqual(seen, new Set(['L1', 'L2']));
    assert.equal(result.outgoing[0].status, 'matched');
    const remote = direction === 'L1' ? 'L2' : 'L1';
    assert.equal(result.outgoing[0].remoteCall.contractName, remote + 'Counter');
    assert.equal(result.outgoing[0].remoteCall.provenance.provider, remote === etherscanChain ? 'etherscan' : 'blockscout');
    assert.match(renderTrace(result), new RegExp(remote + 'Counter'));
    assert.ok(!JSON.stringify(result).includes('scan-secret'));
  });
}
