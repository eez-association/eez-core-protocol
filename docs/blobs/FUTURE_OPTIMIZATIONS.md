# Future Optimizations

Deferred size optimizations for the blob message format
([`BLOB_FORMAT_SPEC.md`](./BLOB_FORMAT_SPEC.md)). Version 1 of the format deliberately
uses the simple encodings — plain `u64` chain ids, plain 32-byte `u256` values, 31 data
bytes per blob field element. Each section below is a drop-in candidate for a future
version of the format (spec §6: a new version means a new leading version byte).

## 1. Compressed `chain_id`

Replaces the fixed `u64` with a self-delimiting, variable-length encoding (1–9 bytes): a
leading byte gives the byte length of the little-endian value that follows, and its range
picks whether `CHAIN_ID_OFFSET` is applied:

| leading byte | the chain id is… |
|---|---|
| `0`–`8` | the next `leading` bytes, little-endian (**raw**) |
| `9`–`12` | `CHAIN_ID_OFFSET +` the next `leading − 8` bytes, little-endian (**offset**) |
| `13`–`255` | reserved |

Raw ids reach `2^64 − 1`; offset ids reach `2^32 + 2^32 − 1`. `CHAIN_ID_OFFSET` is a
protocol constant (`2^32`) — the base auto-assigned ids start from, so a large id like
`2^32 + 5` collapses to one payload byte (`09 05`), and id `0` is a single byte (`00`).

## 2. Compressed `u256` (`Call.value`)

Replaces the fixed 32-byte `u256` with the **compressed `uint256` codec** — a
self-describing, self-delimiting, variable-length encoding (1–33 bytes) defined in
[`U256_COMPRESSED_CODEC.md`](./U256_COMPRESSED_CODEC.md), with conformance test vectors
in [`U256_COMPRESSED_CODEC_VECTORS.json`](./U256_COMPRESSED_CODEC_VECTORS.json). Typical
values (zero, round ether amounts) compress to a few bytes.

## 3. Dense blob packing (254 bits per field element)

V1 stores 31 bytes per field element and zeroes the 32nd (most significant) byte —
`4096 × 31 = 126,976` useful bytes per blob. Since the BLS12-381 modulus satisfies
`2^254 < r < 2^255`, an element can safely carry **254 bits** (top two bits clear), not
just 248:

* **Data elements** carry 31 bytes **plus the low 6 bits of the 32nd byte** — top two
  bits clear — so each represents a full 32 bytes of logical data.
* The **two deferred high bits** per data element are collected in order. Across the
  4064 data elements that is `2 × 4064 = 8,128` bits (1,016 bytes), packed (same 254-bit
  scheme) into the **last 32 field elements** of the blob — an exact fit:
  `32 × 254 = 8,128` bits, no slack.
* **Capacity:** `(4096 − 32) × 32 = 130,048` useful bytes per blob — **+3,072 bytes
  (~2.4%)** over v1.
* **Read:** decode the 32 tail elements to recover the deferred bits, restore each data
  element's full 32nd byte (in-place low 6 bits + its two deferred bits), concatenate all
  data elements in order, and parse the stream from the result.

## Canonicality note

All three encodings admit non-minimal forms (like the varint length prefixes already in
v1). If adopted, the spec's stance stays that of §5, condition 8: the encoder emits the
shortest form, the verifier does not assert it.
