---
title: A Compact Byte Encoding for 256-bit Integers
tags: [encoding, compression, evm, uint256]
description: A self-describing, byte-oriented variable-length codec for any value in [0, 2^256-1]. Literal form plus a scientific (mantissa × base^exp) form whose exponent range is tuned per mantissa length to exactly span 10^28.
---

# A Compact Byte Encoding for 256-bit Integers

[TOC]

## 1. Motivation

We want to serialize any integer in `[0, 2^256 − 1]` (an EVM word) into the
**shortest practical byte string**, while keeping the format:

- **self-describing** — decodable with no external length prefix,
- **byte-oriented** — no bit twiddling, trivial in any language,
- **lossless and total** — every value has an encoding,
- **great on "round" numbers** — `1 ETH = 10^18` wei, `1 RAY = 10^27`, token
  amounts, byte-aligned hashes, … collapse to ~2 bytes.

The idea: a round number carries almost no information in its trailing zeros.
Storing a small **mantissa** `m` and an **exponent** `exp` so that
`value = m × base^exp` throws those zeros away.

## 2. Wire format

Each value is **one format byte** followed by **0–32 payload bytes**:

```
┌────────────┬─────────────────────────────┐
│ format (1) │ payload (0 … 32 bytes, LE)   │
└────────────┴─────────────────────────────┘
```

| Format byte | Family         | Payload                          | Decoded value      |
|-------------|----------------|----------------------------------|--------------------|
| `0 … 32`    | **literal**    | `N = format` bytes (LE)          | `int(payload)`     |
| `33 … 252`  | **scientific** | `L` bytes (LE), the mantissa `m` | `m × base^exp`     |
| `253 … 255` | **reserved**   | —                                | invalid (room to grow) |

All multi-byte integers (payloads and mantissas) are **little-endian (LE)**.

### 2.1 Literal family (`0 … 32`)

The format byte *is* the payload length `N`; the value is the little-endian
integer of the next `N` bytes.

- `0x00` → `0` (no payload, the empty number)
- `0x01 2a` → `42`
- `0x20` + 32 bytes → any full-width word (the universal fallback)

Since `N` reaches 32, **every** value is encodable as a literal. The scientific
family is therefore a pure optimization, used only when it is shorter.

### 2.2 Scientific family (`33 … 252`)

A scientific format encodes

```
value = mantissa × base^exp
```

The format byte fixes the **base**, the **exponent** `exp`, and the **mantissa
length** `L` (bytes); the mantissa `m` is the `L` payload bytes.

Two bases — two "ladders":

| Base  | Effect                                       | Use case                            |
|-------|----------------------------------------------|-------------------------------------|
| `10`  | strip trailing **decimal** zeros             | token amounts, `10^18`, `10^27`, …  |
| `256` | strip trailing **zero bytes** (`256^exp` = shift left by `exp` bytes) | byte-aligned values, padded hashes |

#### Exponent range is tuned *per mantissa length*

This is the key design rule. For a given length `L`, the exponent runs over
**every value `1 … X(base, L)`**, where `X(base, L)` is **the smallest exponent
with which an `L`-byte mantissa can still build `10^28`** — our chosen ceiling
for "round" magnitudes.

Formally:

```
X(base, L) = min { exp ≥ 1 : (2^(8L) − 1) · base^exp  ≥  10^28 }
```

For **base 10** this is exactly the intuitive statement "express `10^28` as
`m · 10^exp` with `m` fitting in `L` bytes, using the *smallest* exponent
(i.e. the largest mantissa)":

- `L = 1`: `10^28 = 100 · 10^26`, and `100` fits in 1 byte (`1000` would not) → **X = 26**.
- `L = 2`: `10^28 = 10000 · 10^24`, and `10000` fits in 2 bytes → **X = 24**.
- `L = 3`: `10^28 = 10^7 · 10^21` → **X = 21**, … and so on.

A longer mantissa absorbs more magnitude, so it needs **fewer** exponent steps —
the ladders get shorter as `L` grows, and stop once `10^28` fits in `L` bytes
outright (`L = 12`, where no exponent is needed). The result is a *descending
triangle* of codes, with no wasted entries.

> **Note on base 256.** `10^28 = 2^28·5^28` is only divisible by `256^exp`
> (= `2^{8·exp}`) for `exp ≤ 3`, so you cannot *exactly* build `10^28` from a
> byte-shift for larger exponents. The formula above uses the **reach**
> criterion (largest representable value `≥ 10^28`), which coincides with the
> exact-build statement for base 10 and is the natural generalization for
> base 256.

### 2.3 Reserved family (`253 … 255`)

3 unused codes. Natural extensions: a base-10 ladder for exponents `> 28` (to
cover round numbers up to `2^256`), wider mantissas, or a signed/fixed-point flag.

## 3. The complete format table

### Literals — codes `0–32`

Format byte = payload length `N`; value = `int.from_bytes(payload, "little")`.

### Base 10 — codes `33–186` (`value = m × 10^exp`), 154 codes

Each row is a length `L`; it contributes `X` consecutive codes for `exp = 1 … X`.

| L | X(10,L) | exponents | codes     |
|---|---------|-----------|-----------|
| 1 | 26      | 1 … 26    | 33 … 58   |
| 2 | 24      | 1 … 24    | 59 … 82   |
| 3 | 21      | 1 … 21    | 83 … 103  |
| 4 | 19      | 1 … 19    | 104 … 122 |
| 5 | 16      | 1 … 16    | 123 … 138 |
| 6 | 14      | 1 … 14    | 139 … 152 |
| 7 | 12      | 1 … 12    | 153 … 164 |
| 8 | 9       | 1 … 9     | 165 … 173 |
| 9 | 7       | 1 … 7     | 174 … 180 |
| 10| 4       | 1 … 4     | 181 … 184 |
| 11| 2       | 1 … 2     | 185 … 186 |

### Base 256 — codes `187–252` (`value = m × 256^exp`), 66 codes

| L | X(256,L) | exponents | codes     |
|---|----------|-----------|-----------|
| 1 | 11       | 1 … 11    | 187 … 197 |
| 2 | 10       | 1 … 10    | 198 … 207 |
| 3 | 9        | 1 … 9     | 208 … 216 |
| 4 | 8        | 1 … 8     | 217 … 224 |
| 5 | 7        | 1 … 7     | 225 … 231 |
| 6 | 6        | 1 … 6     | 232 … 237 |
| 7 | 5        | 1 … 5     | 238 … 242 |
| 8 | 4        | 1 … 4     | 243 … 246 |
| 9 | 3        | 1 … 3     | 247 … 249 |
| 10| 2        | 1 … 2     | 250 … 251 |
| 11| 1        | 1 … 1     | 252 … 252 |

### Reserved — codes `253–255`

**Code assignment order** (how a code maps to `(base, exp, L)`): base 10 first
then base 256; within a base, ascending `L`; within a length, ascending `exp`.
The Python `_build_tables()` below is the normative definition.

## 4. Canonical encoding rule

A value can have several valid encodings (e.g. `1280 = 5·256 = 128·10`, or
`10^27 = 100·10^25 = 10·10^26`). The encoder is deterministic: among all valid
candidates it picks the one with

1. the **fewest total bytes**, then
2. **base 256 ("base-2") before base 10**, and either before a literal, then
3. the **lowest exponent** (equivalently, the largest mantissa).

This gives a unique canonical form per value (handy for hashing / equality on
the encoded bytes).

## 5. Python reference implementation

```python
"""Compact byte codec for integers in [0, 2**256 - 1]
   (length-tuned mantissa/exponent table spanning 10**28)."""

# ----------------------------------------------------------------- config
BASES       = (10, 256)        # ladder bases
LITERAL_MAX = 32               # codes 0..32 are literals
TARGET      = 10**28           # magnitude the ladders must span
MAX_U256    = (1 << 256) - 1

# --------------------------------------------------------- table builder
def _max_exp(base, L):
    """Smallest exp >= 1 such that an L-byte mantissa * base**exp can reach
       TARGET. Returns 0 when TARGET already fits in L bytes (ladder ends)."""
    m_max = (1 << (8 * L)) - 1
    if m_max >= TARGET:
        return 0
    exp = 1
    while m_max * base ** exp < TARGET:
        exp += 1
    return exp

def _build_tables():
    code, code_to_sci, sci_to_code = 33, {}, {}
    for base in BASES:
        L = 1
        while True:
            x = _max_exp(base, L)
            if x < 1:                       # ladder for this base is complete
                break
            for exp in range(1, x + 1):
                code_to_sci[code] = (base, exp, L)
                sci_to_code[(base, exp, L)] = code
                code += 1
            L += 1
    assert code <= 256, "format codes overflow a byte"
    return code_to_sci, sci_to_code

CODE_TO_SCI, SCI_TO_CODE = _build_tables()
# largest exponent that appears for each base (bounds the encoder's search)
_MAX_EXP = {b: max(e for (bb, e, _l) in SCI_TO_CODE if bb == b) for b in BASES}

def _byte_len(n):
    """Minimal little-endian byte length of a non-negative int (0 -> 0)."""
    return (n.bit_length() + 7) // 8

# --------------------------------------------------------------- encoder
def encode(value):
    """Encode an int in [0, 2**256-1] to its canonical compressed bytes."""
    if not (0 <= value <= MAX_U256):
        raise ValueError("value out of range [0, 2**256-1]")

    # candidate 1: literal  (key rank 2 = lowest priority at equal size)
    n = _byte_len(value)
    best, best_key = bytes([n]) + value.to_bytes(n, "little"), (1 + n, 2, 0)

    # candidates 2..: scientific (only when value == m * base**exp exactly)
    # tie-break key: (size, base rank [256 first], exponent ascending)
    for base in BASES:
        for exp in range(1, _MAX_EXP[base] + 1):
            p = base ** exp
            if value % p:
                continue
            m = value // p
            if m == 0:
                continue
            L = _byte_len(m)
            code = SCI_TO_CODE.get((base, exp, L))   # exists only if exp <= X
            if code is None:
                continue
            cand = bytes([code]) + m.to_bytes(L, "little")
            key = (1 + L, 0 if base == 256 else 1, exp)
            if key < best_key:
                best, best_key = cand, key
    return best

# --------------------------------------------------------------- decoder
def decode(stream, offset=0):
    """Decode one value at `offset`; returns (value, next_offset)."""
    f = stream[offset]
    offset += 1
    if f <= LITERAL_MAX:                                   # literal
        chunk = stream[offset:offset + f]
        if len(chunk) != f:
            raise ValueError("truncated literal payload")
        return int.from_bytes(chunk, "little"), offset + f
    if f in CODE_TO_SCI:                                   # scientific
        base, exp, L = CODE_TO_SCI[f]
        chunk = stream[offset:offset + L]
        if len(chunk) != L:
            raise ValueError("truncated mantissa")
        value = int.from_bytes(chunk, "little") * base ** exp
        if value > MAX_U256:
            raise ValueError("decoded value exceeds 2**256-1")
        return value, offset + L
    raise ValueError(f"reserved/invalid format byte {f}")  # 253..255

# ------------------------------------------------------- stream helpers
def encode_stream(values):
    return b"".join(encode(v) for v in values)

def decode_stream(stream):
    out, off = [], 0
    while off < len(stream):
        v, off = decode(stream, off)
        out.append(v)
    return out
```

### Self-test

```python
if __name__ == "__main__":
    import random

    def roundtrip(v):
        enc = encode(v)
        dec, off = decode(enc)
        assert dec == v and off == len(enc), (v, enc.hex(), dec)
        return enc

    print("special codes:", len(CODE_TO_SCI),
          "-> range 33..%d, reserved %d..255"
          % (32 + len(CODE_TO_SCI), 33 + len(CODE_TO_SCI)))

    for v in [0, 1, 255, 256, 10**18, 10**27, 10**28, 5 * 10**26,
              0xDEADBEEF, 3 * 256**11, 2**255, MAX_U256]:
        print(f"{v:<32} -> {roundtrip(v).hex():<14} ({len(encode(v))} B)")

    random.seed(0)
    for _ in range(300_000):
        roundtrip(random.randrange(0, MAX_U256 + 1))
    for exp in range(29):                       # bias toward round decimals
        for _ in range(3000):
            v = random.randrange(1, 10**8) * 10**exp
            if v <= MAX_U256:
                roundtrip(v)
    print("all round-trips OK")

    xs = [0, 42, 10**18, 1 << 200, 7 * 256**9]
    assert decode_stream(encode_stream(xs)) == xs
    print("stream OK")
```

## 6. Worked examples

| Value                    | Encoding (hex)   | Bytes | Format chosen                          |
|--------------------------|------------------|-------|----------------------------------------|
| `0`                      | `00`             | 1     | literal, N=0                           |
| `42`                     | `01 2a`          | 2     | literal, N=1                           |
| `256`                    | `bb 01`          | 2     | base 256, exp 1, m=1                    |
| `1280` (= `5·256` = `128·10`) | `bb 05`     | 2     | base 256, exp 1, m=5 (base 256 wins tie) |
| `10^18` (1 ETH in wei)   | `30 64`          | 2     | base 10, exp 16, m=100 (`=100·10^16`)  |
| `10^27` (1 RAY)          | `39 64`          | 2     | base 10, exp 25, m=100 (`=100·10^25`)  |
| `10^28`                  | `3a 64`          | 2     | base 10, exp 26, m=100 (`=100·10^26`)  |
| `5·10^26`                | `39 32`          | 2     | base 10, exp 25, m=50                   |
| `123456789·10^12`        | `72 d2 02 96 49` | 5     | base 10, exp 11, m=1234567890          |
| `0xDEADBEEF`             | `04 ef be ad de` | 5     | literal, N=4 (not round)               |
| `2^256−1`                | `20` + 32×`ff`   | 33    | literal, N=32 (worst case)             |

Note the tie-break in action: `1280` chooses the base-256 form `5·256` over the
equal-length base-10 form `128·10`, and the decimals use the **lowest** exponent
(largest mantissa) — e.g. `10^27 = 100·10^25` (`exp 25`) rather than `10·10^26`.

### 6.1 Test vectors

[`U256_COMPRESSED_CODEC_VECTORS.json`](./U256_COMPRESSED_CODEC_VECTORS.json) carries
machine-readable vectors generated with the reference implementation above (§5):

* **`edge_cases`** — canonical `value ↔ hex` pairs for boundary and round values
  (including every worked example from §6).
* **`per_format_code`** — one canonical vector for **each** assigned format byte
  `0 … 252`: all 33 literal lengths and all 220 scientific codes.
* **`decode_only`** — well-formed but **non-canonical** encodings: a decoder accepts
  them, a canonical encoder (§4) never emits them (each entry carries the
  `canonical_hex` it should have used).
* **`invalid`** — inputs a decoder MUST reject: reserved format bytes `253`–`255`,
  truncated literal payloads, truncated mantissas.
* **`streams`** — concatenated values, exercising self-delimiting decode.

A conforming implementation must round-trip every `edge_cases` / `per_format_code` /
`streams` entry exactly, decode every `decode_only` entry to its `value`, and reject
every `invalid` entry.

## 7. Properties & trade-offs

- **Total & lossless.** Every value has a literal fallback, so `decode(encode(v)) == v`
  for all `v ∈ [0, 2^256−1]`.
- **Overhead bound.** Worst case `+1` byte over the raw minimal big-int (32-byte
  word → 33 bytes). Round numbers → ~2 bytes.
- **Canonical.** §4 gives exactly one encoding per value.
- **Self-delimiting.** Each value knows its own length; values concatenate into a
  stream with no separators.
- **Compact table.** 154 (base 10) + 66 (base 256) = **220** scientific codes,
  occupying `33 … 252`; `253 … 255` (3 codes) remain reserved. `10^28` is the
  largest power-of-ten ceiling that fits in one byte of formats — `10^29` would
  need 244 scientific codes and overflow.
- **Coverage ceiling (by design).** The ladders span exactly up to `10^28`; round
  numbers between `~10^28` and `2^256` fall back to literals.

## 8. Possible extensions (reserved codes `253–255`)

- A base-10 ladder for exponents `> 28`, to compress round decimals up to `2^256`.
- Wider mantissas / higher precision.
- A base-2 (bit-shift) ladder for sub-byte alignment.
- A signed or fixed-point flavor.