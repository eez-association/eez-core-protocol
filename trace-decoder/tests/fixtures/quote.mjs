// Synthetic debug-quote response. Repeated runs deliberately reuse frame IDs.
export function quoteFixture() {
  const address = n => '0x' + n.toString(16).padStart(40, '0');
  const bytes = hex => ({ hex, length: (hex.length - 2) / 2, truncated: false });
  const frame = (id, parentId, chainId, extra = {}) => ({
    id, parentId, chainId, kind: 'CALL', from: address(10 + id), to: address(20 + id), codeAddress: address(20 + id),
    gas: '0x10000', gasUsed: '0x100', value: '0x0', input: bytes('0x12345678'),
    output: bytes('0x' + '02'.padStart(64, '0')), status: 'success', result: 'Return',
    isStatic: false, crossChain: false, executionRoot: parentId == null, ...extra,
  });
  const frames = [frame(0, null, '0x2'), frame(1, 0, '0x2'), frame(2, 1, '0x1', { crossChain: true, executionRoot: true }), frame(3, 2, '0x1')];
  const run = (id, phase, purpose, pass = 1) => ({ id, phase, purpose, pass, type: '0x2', chainId: '0x2', complete: true,
    transaction: { from: address(10), to: address(20), input: '0x12345678' }, frames: structuredClone(frames) });
  return { version: 1, chainId: '0x2', nonce: '0x2b', expiresAt: '0xffffffff',
    options: [{ type: '0x2', gas: '0x1a4eb', maxFeePerGas: '0xd7ee0e8e', maxPriorityFeePerGas: '0xd7ee0e5d', estimatedFee: '0x14a8c1051c9ea', requestHash: '0x' + '12'.repeat(32) }],
    diagnostics: { options: [], trace: { format: 'eez-quote-call-trace', version: 1,
      context: { l1ChainId: '0x1', l2ChainId: '0x2', rollupId: 1, simulation: true },
      request: { from: address(10), to: address(20), data: '0x12345678' },
      gasAccounting: 'inclusive_frame_execution_gas', truncated: false, omittedRuns: 0, omittedFrames: 0,
      runs: [run(0, 'gas_estimation', 'composition'), run(1, 'fee_simulation', 'settlement'), run(2, 'final_validation', 'composition')] } } };
}
