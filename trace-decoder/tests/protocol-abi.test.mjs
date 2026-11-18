import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { ethers } from 'ethers';
import { protocol, parseCall } from '../src/protocol.mjs';
import { batch } from './fixtures/scenarios.mjs';

test('bundled ABI decodes batches encoded by the compiled contract with per-rollup builder data', () => {
  const artifact = JSON.parse(fs.readFileSync(new URL('../../out/EEZ.sol/EEZ.json', import.meta.url)));
  const current = new ethers.Interface(artifact.abi);
  const value = batch([]);
  value.rollupIdsWithProofSystems = [
    { rollupId: 1, proofSystemIndexes: [0], builderData: ethers.zeroPadValue('0x03de', 32) },
    { rollupId: 2, proofSystemIndexes: [0], builderData: ethers.zeroPadValue('0xffffffffffffffff', 32) },
  ];
  const encoded = current.encodeFunctionData('postAndVerifyBatch', [value]);
  const decoded = parseCall(protocol.L1, encoded);
  assert.equal(decoded?.name, 'postAndVerifyBatch');
  assert.deepEqual(decoded.args[0].rollupIdsWithProofSystems.map(r => r.builderData),
    value.rollupIdsWithProofSystems.map(r => r.builderData));
  assert.equal(protocol.L1.encodeFunctionData(decoded.fragment, decoded.args), encoded);
});
