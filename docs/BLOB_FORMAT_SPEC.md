# Standardized Message Format

A binary format for publishing chain activity as a single stream of
messages — no header.
**Everything is a message**: chain-local operations, cross-chain calls, results, reverts,
and transaction boundaries differ only by message type.

Excalidraw: https://excalidraw.com/#json=0Efuogd9EmGs1-dtl7VQs,6TO97Ut9nvF7ePynMCBd-Q
---

## 1. Framing

Every message begins with a `message_type` byte, which selects one of two shapes:

* **Content messages** carry data: `message_type | …fields…`.
* **Marker messages** carry none: a lone `message_type` byte, no fields.

Each type's exact byte layout is defined inline with the type in §2.

### 1.1 Wire encoding

These conventions apply across the per-type layouts in §2:

* All scalar values are **little-endian, fixed-width**: `u8`/`u16`/`u32`/`u64` as written,
  `bool` is one byte, `address` is 20 bytes, `uint256` is 32 bytes.
* A `bytes` field is length-prefixed, then carries exactly that many bytes. The length is a
  single leading byte that either holds the length directly or announces how many following
  little-endian bytes do:

  | leading byte | the length is… |
  |---|---|
  | `0`–`251` | the leading byte itself (`0`–`251`) |
  | `252` | the next **2** bytes, little-endian |
  | `253` | the next **3** bytes, little-endian |
  | `254` | the next **4** bytes, little-endian |
  | `255` | reserved |

  **All byte fields are encoded this way** — whether the protocol parses their contents or
  treats them as opaque. 
* A `u256` field (`Call.value`) is serialized with the **compressed `uint256` codec** — a
  self-describing, variable-length encoding (1–33 bytes) defined in
  [`U256_COMPRESSED_CODEC.md`](./U256_COMPRESSED_CODEC.md). The codec is self-delimiting, so no separate length prefix is
  needed.
* A `chain_id` field reuses a similar **leading-byte length-prefix** as `bytes`: the leading byte gives the byte length of the little-endian value that follows, and
  its range also picks whether or not `CHAIN_ID_OFFSET` is applied:

  | leading byte | the chain id is… |
  |---|---|
  | `0`–`8` | the next `leading` bytes, little-endian (**raw**) |
  | `9`–`12` | `CHAIN_ID_OFFSET +` the next `leading − 8` bytes, little-endian (**offset**) |
  | `13`–`255` | reserved |

  Self-delimiting, so no separate length prefix is needed (1–9 bytes total). Raw ids reach
  `2^64 − 1`; offset ids reach `2^32 + 2^32 − 1`. `CHAIN_ID_OFFSET` is a protocol constant
  (`2^32`) — the base auto-assigned ids start from, so a large id like `2^32 + 5` collapses
  to one payload byte (`09 05`).
* **Blob layout.** The logical byte stream is the batch's EIP-4844 blobs in order,
  concatenated, with the batch `callData` appended after the last blob — one continuous
  stream. A message MAY span a blob boundary: the next blob simply *continues* the stream.
  A `CloseBlob` (§2.9) ends a blob early so the next blob starts a fresh message; the bytes
  between it and the blob boundary are padding. How that stream data is packed into a
  blob's field elements is detailed in §4.

  The `callData` tail is part of the same stream: if the **last** blob ends with a
  `CloseBlob`, its padding is skipped and the stream **resumes in `callData`**. A
  `CloseBlob` cannot appear inside `callData` itself — there is no blob boundary to
  close, so a `0xFF` type byte there is invalid (§5).

### 1.2 The current executing chain (context stack)

Several fields are never encoded because they are implied by **where execution currently
is**: a `Call`'s `from_chain` (§2.4), both endpoints of a `return_success` / `return_fail`
(§2.5), and the chain a cross-chain transaction ends on (§2.8). All of them read the same
stream-level state — the **currently executing chain** — tracked by a **context stack**
that evolves deterministically with each message. Because it feeds the cross-chain call
hash (as `sourceRollupId`), every implementation MUST evolve it identically:

| message | effect on the context stack |
|---|---|
| `InitiateCrossChainTransaction` | pushes its `chain_id` — the root context (stack was empty) |
| `Call` / `Call_static` | its `from_chain` **is the current top**; then pushes its `to_chain` — subsequent messages execute on the callee |
| `return_success` / `return_fail` | pops — execution resumes on the caller |
| `FinishCrossChainTransaction` | pops the root `chain_id`; the stack MUST then be empty (every call already returned) |
| `ChainOperation`, `Snapshot`, `Revert`, `OpenBlobStream`, `CloseBlob` | no effect on the stack |

Equivalently: the current chain is the one established by the most recent **non-finalized**
`InitiateCrossChainTransaction` or `Call` / `Call_static` — "non-finalized" meaning its
matching return (or finish) has not yet arrived.

**Example** — nested calls, a return, then a sibling call:

```
InitiateCrossChainTransaction (chain_id: R1)    # stack: [R1]
Call (to_chain: R2)   # from = R1 (top of stack)          → stack: [R1, R2]
Call (to_chain: R3)   # from = R2 (last call's to_chain)  → stack: [R1, R2, R3]
return_success        # R3 returns to R2 — pop            → stack: [R1, R2]
Call (to_chain: R4)   # from = R2 — the most recent NON-FINALIZED call's to_chain
                      #  (the R2→R3 call already returned)→ stack: [R1, R2, R4]
return_success        # R4 returns to R2 — pop            → stack: [R1, R2]
return_success        # R2 returns to R1 — pop            → stack: [R1]
FinishCrossChainTransaction                     # stack: []
```

---

## 2. Message types

A chain id is encoded only when it can't be inferred.

Each row gives the complete field layout in wire order; §2.1–2.9 add the prose.

| type | name | fields (in wire order) |
|---|---|---|
| `0` | — **reserved, invalid** — | never begins a message |
| `1` | `OpenBlobStream` | `u8 message_type` |
| `2` | `ChainOperation` | `u8 message_type` · `chain_id` (compressed, §1.1) · `bytes operations` |
| `3` | `InitiateCrossChainTransaction` | `u8 message_type` · `chain_id` (compressed, §1.1) · `bytes tx_data` |
| `4` | `Call` | `u8 message_type` · `to_chain` (compressed, §1.1) · `address fromAddress` · `address toAddress` · `u256 value` (compressed) · `bytes data` |
| `5` | `Call_static` | `u8 message_type` · `to_chain` (compressed, §1.1) · `address fromAddress` · `address toAddress` · `bytes data` |
| `6` | `return_success` | `u8 message_type` · `bytes return_data` |
| `7` | `return_fail` | `u8 message_type` · `bytes return_data` |
| `8` | `Snapshot` | `u8 message_type` |
| `9` | `Revert` | `u8 message_type` |
| `10` | `FinishCrossChainTransaction` | `u8 message_type` |
| `0xFF` | `CloseBlob` | `u8 message_type` |

> **Type `0` is reserved as invalid** so zero padding never parses as messages — a blob
> missing its `CloseBlob` fails at the first padding byte instead of decoding it as valid
> markers.

> **Pairing.** Three pairs always come matched: every `Call` / `Call_static` has a result —
> `return_success` (`6`) or `return_fail` (`7`); every `Snapshot` a `Revert`; and every
> `InitiateCrossChainTransaction` a `FinishCrossChainTransaction`. `ChainOperation`,
> `OpenBlobStream`, and `CloseBlob` stand alone.

### 2.1 `OpenBlobStream`
Opens the whole message stream — emitted once, as the very first message, before any content.
It is **not** the per-blob counterpart of `CloseBlob` (§2.9): `CloseBlob` ends the *current*
blob early, whereas `OpenBlobStream` is stream-level, spanning **all** blobs (§1.1 blob
layout). It reserves the position to signal the format **version**
in the future; for now it is a **bare marker** (§1.1) carrying no fields.

```c
struct OpenBlobStream { u8 message_type; }          // = 1
```

### 2.2 `ChainOperation`
Carries the operations of a single chain (the `chain_id`). At the protocol level its
payload is **opaque** — an ordered list the executing chain interprets on its own. The
operations list can be large, but its length prefix scales to a 4-byte size when needed:

```c
struct ChainOperation {          // type 2
    u8       message_type;       // = 2
    chain_id chain_id;           // the executing chain, compressed (§1.1)
    bytes    operations;         // opaque to the protocol; the chain interprets it (length-prefixed)
}
```

> **Reference implementation (not protocol).** Everything about how `operations` is
> structured is up to the chain. The reference implementation encodes it as a `ChainOpItem[]`
> (a `u32` count, then items), each item a transaction or a new-block marker, where a
> `NewBlock` implicitly closes the previous block. None of this is mandated — it only makes
> the examples below concrete.
>
> ```c
> ChainOpItem { u8 item_type; bytes item_data; }   // 1 = Transaction, 2 = NewBlock
> // Transaction: rlp_transaction   |   NewBlock: block_params (e.g. timestamp)
> ```
>
> Whether a `Transaction`'s `rlp_transaction` carries a signature is **up to the chain** —
> some chains include it, others omit it. The format does not
> mandate either way; the chain that interprets `operations` knows what to expect.

**Example** — chain `7` opens a block, runs two txs, opens a second block, runs one more:

```
message_type = 2
chain_id     = 7
operations   = ChainOpItem[5] {
    [0] NewBlock     { timestamp: 1_700_000_000, ... }   # block 1 opens
    [1] Transaction  rlp_tx_0                            #   |
    [2] Transaction  rlp_tx_1                            #   |  block 1
    [3] NewBlock     { timestamp: 1_700_000_012, ... }   # block 1 closes, block 2 opens
    [4] Transaction  rlp_tx_2                            #   |  block 2
}
```

### 2.3 `InitiateCrossChainTransaction`
Opens one cross-chain transaction. `chain_id` is where the originating tx lives.

```c
struct InitiateCrossChainTransaction {   // type 3
    u8       message_type;   // = 3
    chain_id chain_id;       // where the originating tx lives, compressed (§1.1)
    bytes    tx_data;        // opaque — the chain decides what goes here; trailing, length-prefixed
}
```

What `tx_data` contains is **up to the chain** — like `operations` (§2.2), the protocol
treats it as opaque bytes (e.g. an RLP transaction with or without its signature).

`InitiateCrossChainTransaction` / `FinishCrossChainTransaction` (§2.8) are **always
paired**, like brackets: every `InitiateCrossChainTransaction` MUST be closed by a matching
`FinishCrossChainTransaction`, a `FinishCrossChainTransaction` requires an open transaction,
and everything the transaction produces lives between the two.

### 2.4 `Call` / `Call_static`
A cross-chain call. Instead of an `is_static` flag, read-only calls are a **distinct message
type** — `Call_static` (`5`), a `STATICCALL` that carries no value and reverts on state
write. A value-bearing `Call` (`4`) and a static `Call_static` (`5`) differ only by the
absence of `value`:

```c
struct Call {                // type 4
    u8       message_type;   // = 4
    chain_id to_chain;       // target chain, compressed (§1.1); from_chain is implicit — the executing chain
    address  fromAddress;
    address  toAddress;
    u256     value;          // compressed uint256 (see U256_COMPRESSED_CODEC.md)
    bytes    data;           // the call's exact calldata; last, length-prefixed
}

struct Call_static {         // type 5 — read-only STATICCALL
    u8       message_type;   // = 5
    chain_id to_chain;       // target chain, compressed (§1.1); from_chain is implicit — the executing chain
    address  fromAddress;
    address  toAddress;
    bytes    data;           // the call's exact calldata; last, length-prefixed (no value)
}
```

Unlike `operations` / `tx_data`, `data` is **not** chain-defined: it is exactly the
calldata of the cross-chain call.

`from_chain` is **not encoded** — it is the **currently executing chain**: the top of the
context stack (§1.2) at the moment the `Call` is emitted.

### 2.5 `return_success` / `return_fail` (the Call's result)
The outcome of a finished `Call`, flowing back to the caller. Instead of one `Result` with a
`success` flag, the outcome is carried by **two distinct message types** — `return_success`
(`6`) for a successful **return** and `return_fail` (`7`) for the call's own **revert**.
Either pairs with the last outstanding `Call` / `Call_static`, so **both** chains (`from`
and `to`) are implicit — the return pops the context stack (§1.2), resuming execution on
the caller. The payload layout is identical for both:

```c
struct return_success {      // type 6
    u8       message_type;   // = 6
    bytes    return_data;    // the call's exact return value; last, length-prefixed
}

struct return_fail {         // type 7
    u8       message_type;   // = 7
    bytes    return_data;    // the call's exact revert data; last, length-prefixed
}
```

Like `Call.data`, `return_data` is **not** chain-defined: it is exactly the call's return
(or revert) data.

`return_fail` means the call **finished by reverting** on the callee: the caller receives
the failure and handles it like a same-chain contract revert. That differs from a
`Snapshot`/`Revert` region (§2.6–2.7), which force-reverts calls that already *succeeded*.

### 2.6 `Snapshot`
Opens a revertable region — a forced-revert bracket. A **bare marker** (§1.1): just the
`message_type` byte, no length and no params.

```c
struct Snapshot { u8 message_type; }          // = 8
```

Everything executed after it (native ops, cross-chain `Call`s, nested regions) is rolled
back when the region's matching `Revert` (§2.7) arrives. `Snapshot` / `Revert` are
**always paired and properly nested**, like balanced brackets: every `Snapshot` is closed
by exactly one `Revert`, a `Revert` must have an open `Snapshot`, and each `Revert` closes
the innermost still-open `Snapshot`.

A `Snapshot` can only open **inside** an open `InitiateCrossChainTransaction` …
`FinishCrossChainTransaction` bracket — never outside a cross-chain transaction (§5,
condition 7) — and its matching `Revert` must arrive before that bracket closes.

### 2.7 `Revert`
Closes the region opened by the matching `Snapshot` (§2.6), rolling back every effect —
including any cross-chain `Call`s — executed since it. A **bare marker** (§1.1):

```c
struct Revert { u8 message_type; }            // = 9
```

The region is delimited by the bracket, so no chain id, count, or call identifier is
needed. A `Revert` is **not** a failed result: a call that fails by itself reports a
`return_fail` (§2.5). `Revert` is used when calls inside the region completed with a
`return_success`, but the chain that initiated them, later reverts that context — forcing
those already-succeeded effects to roll back.

### 2.8 `FinishCrossChainTransaction`
Closes the cross-chain transaction opened by `InitiateCrossChainTransaction` (§2.3). A
**bare marker** (§1.1); the tx ends on the currently-executing chain, which is implicit
(§1.2).

```c
struct FinishCrossChainTransaction { u8 message_type; }   // = 10
```

### 2.9 `CloseBlob`
Ends a blob early: marks the end of meaningful content in the current EIP-4844 blob so the
next blob starts a **fresh** message instead of continuing the current one (§1.1). A
**bare marker** with the reserved type byte `0xFF`:

```c
struct CloseBlob { u8 message_type; }         // = 0xFF
```

Any bytes after `CloseBlob`, up to the blob boundary, are padding and MUST be ignored.

---

## 3. Reference examples

### 3.1 Normal flow: open blocks → cross-chain → close blocks

The canonical shape of a slot. Each chain first runs its native txs and **opens** a
cross-chain block; the cross-chain transactions are processed between the open blocks; once
all are done, each chain **closes** its block (one `ChainOperation` per chain):

```
# 1. L2_A: native txs + open its cross-chain block
ChainOperation (chain_id: L2_A, operations: [ NewBlock{ts}, Tx, Tx ])

# 2. L2_B: native txs + open its cross-chain block
ChainOperation (chain_id: L2_B, operations: [ NewBlock{ts}, Tx, Tx ])

# 3. process the cross-chain transaction(s) between the open blocks
InitiateCrossChainTransaction (chain_id: L2_A, TxData)
    Call           (to L2_B, ...)               # from L2_A (implicit)
    return_success (return_data)                # pairs with the Call
FinishCrossChainTransaction                     # ends on L2_A (implicit)

# 4. all cross-chain done — close both blocks (a fresh NewBlock auto-closes the open one)
ChainOperation (chain_id: L2_A, operations: [ NewBlock{ts'} ])   # closeBlock for L2_A
ChainOperation (chain_id: L2_B, operations: [ NewBlock{ts'} ])   # closeBlock for L2_B
```

### 3.2 Stand-alone vs. framed

* **`ChainOperation` is stand-alone and self-closing** — no pair.

* **`InitiateCrossChainTransaction` MUST always be terminated by a
  `FinishCrossChainTransaction`** — everything the tx produces lives between the two
  markers, and the tx is not complete until its `FinishCrossChainTransaction` arrives (see
  §3.1, step 3).

### 3.3 Snapshot / Revert around a call

A `Snapshot` … `Revert` bracket forces everything inside it to roll back:

```
Snapshot                                       # open revertable region
Call           (to L2_B, ...)                  # from L2_A (implicit)
return_success (return_data)                    # pairs with the Call
Revert                                         # close region → the call's effects roll back
```

### 3.4 Nested snapshots

Brackets nest; each `Revert` closes the innermost open `Snapshot`:

```
Snapshot                         # outer region opens
Call           (to L2_B, ...)    # from L2_A
return_success
    Snapshot                     # inner region opens (nested)
    Call           (to L2_C, ...) # from L2_B
    return_success
    Revert                       # inner closes → the L2_B → L2_C call rolls back
Revert                           # outer closes → the L2_A → L2_B call (and all nested) rolls back
```

---

## 4. Blob data encoding

The logical byte stream (§1) is not written into a blob verbatim. An EIP-4844 blob is
**4096 field elements of 32 bytes each**, and each element must be a valid BLS12-381
scalar — below the field modulus `r` (`2^254 < r < 2^255`). A raw 32-byte value can exceed
`r`, so arbitrary bytes cannot be stored directly. Since `2^254 < r`, keeping the **top
two bits of every element clear** is the safe choice: every element is then `< 2^254 < r`
regardless of bit pattern.

So each field element encodes **31 full bytes plus the low 6 bits of the 32nd byte** —
254 bits in place. The remaining **two high bits of the 32nd byte** would land in the
element's top-two-bit positions, which must stay clear; instead they are set aside and
re-encoded **at the end of the blob**:

* **Data elements** carry the stream — 31 bytes + the low 6 bits of the 32nd byte, top two
  bits clear — so each still represents a full 32 bytes of logical data.
* The two deferred high bits per data element are collected in order. Across the 4064 data
  elements that is `2 × 4064 = 8,128` bits (**1,016 bytes**), which are packed (same
  254-bit scheme) into the **last 32 field elements** of the blob — an exact fit:
  `32 × 254 = 8,128` bits, no slack.
* **Capacity:** `(4096 − 32) × 32 = 130,048` useful bytes per blob.
* **Read:** decode the 32 tail elements to recover the deferred bits, restore each data
  element's full 32nd byte (in-place 6 bits + its two deferred bits), concatenate all data
  elements, and parse messages (§1) from the result.
* The trailing `callData` (§1.1) has no field-element constraint — raw bytes, appended to
  the recovered stream as-is.

A `CloseBlob` (§2.9) is evaluated against this *decoded* stream: it ends the blob's payload
early, and the remaining capacity is padding.

---

## 5. Validity — a malformed stream is rejected whole

A blob stream is either **entirely valid or entirely invalid**. If *any* condition below is
violated at *any* point, the **whole stream is rejected** — every blob of the batch and the
trailing `callData`, not just the offending blob or the suffix after the violation. 
In practice this check falls on the **prover**: a valid proof simply cannot be produced
over a malformed stream, so publishing one is equivalent to publishing nothing.

The stream is valid iff **all** of the following hold:

1. **Encoding layer (§4).** Every field element of every blob is a valid BLS12-381 scalar
   with its top two bits clear.
2. **Opening.** The first message of the stream is `OpenBlobStream` (`1`), and it appears nowhere
   else.
3. **Known types.** Every message begins with an assigned type byte: `1`–`10` or `0xFF`.
   A `0`, or any of `11`–`254`, is invalid — in particular, zero padding is never reachable
   by a well-formed stream except after a `CloseBlob` (§2.9). Inside the `callData` tail,
   `0xFF` is invalid too — there is no blob boundary to close (§1.1).
4. **No truncation.** Every message's fields decode completely within the stream; the
   stream ends exactly at a message boundary with no bracket still open (condition 6).
5. **Invalid encodings.** Every field decodes exactly as its encoding defines.
6. **Bracket discipline.** Every `InitiateCrossChainTransaction` is closed by a matching
   `FinishCrossChainTransaction`; every `Snapshot` by a properly nested `Revert`; every
   `Call` / `Call_static` has its `return_success` / `return_fail`. A closer with no open
   counterpart (a bare `Revert`, a return with no outstanding call, a
   `FinishCrossChainTransaction` with calls still open — §1.2's context stack) is invalid.
7. **Placement.** `Call` / `Call_static`, `return_success` / `return_fail`, `Snapshot` /
   `Revert` appear only inside
   an open `InitiateCrossChainTransaction` … `FinishCrossChainTransaction` bracket (a `Call`
   needs an executing context for its implicit `from_chain`, §1.2; a `Snapshot` cannot open
   outside a cross-chain transaction, §2.6).
8. **Minimal encodings — 🗣 to discuss.** The encoder always emits the shortest form: a
   `bytes` length in the smallest prefix that holds it (length `5` as `05`, never `252` +
   `05 00`), a `chain_id` payload with no zero-padded high bytes (id `5` as `01 05`,
   never `02 05 00`; id `0` as `00`, never `01 00`), and the offset form whenever it is
   shorter (ids in `[2^32, 2^33)` are encodable both raw and offset). Open question: MUST
   the verifier assert this (a non-minimal encoding invalidates the whole stream), or is
   minimality only an encoder-side rule and a decoder accepts non-minimal forms?
   Trade-off: without enforcement the same logical stream has several byte
   representations, so nothing hashed over the raw bytes is canonical.
