// Pure helpers shared by decoding, text rendering, and the inlined browser model.
export function isPreparedLookup(out) {
  return !!out && out.chain === 'L1' && !out.remoteFrameId &&
    !out.candidates?.length && !out.rejectedCandidates?.length && !!out.entryCandidates?.length &&
    (out.isStatic || out.reverted || out.entryCandidates.every(e => e.success === false));
}

export function isPreparedResult(out) {
  return out?.status === 'prepared-result' ||
    out?.resultKind === 'precomputed-result-only' && isPreparedLookup(out);
}
