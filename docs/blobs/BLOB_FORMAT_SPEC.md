# Standardized Message Format

A binary format for publishing rollup activity as a single stream of
messages — no header.
**Everything is a message**: rollup-local operations, cross-rollup calls, results, reverts,
and transaction boundaries differ only by message type. The one exception is the first
byte of each stream — the reserved version byte (§6).

Excalidraw: https://excalidraw.com/#json=0Efuogd9EmGs1-dtl7VQs,6TO97Ut9nvF7ePynMCBd-Q

---

## 1. Framing

The very first byte of the stream is the **protocol version** (§6) — hardcoded `00` for
this version. It is reserved in every stream, including calldata-only streams, and
**not encoded as a message** — the
one exception. Everything after it is messages.

Every message begins with a `message_type` byte, which selects one of two shapes:

* **Content messages** carry data: `message_type | …fields…`.
* **Marker messages** carry none: a lone `message_type` byte, no fields.

Each type's exact byte layout is defined inline with the type in §2.

### 1.1 Wire encoding

These conventions apply across the per-type layouts in §2:

* All scalar values are **little-endian, fixed-width**: `u8`/`u16`/`u32`/`u64`/`u128`/`u256`
  as written, `bool` is one byte, `address` is 20 bytes.
* A `bytes` field is encoded as **protobuf** encodes its own `bytes` fields — a
  [varint](https://protobuf.dev/programming-guides/encoding/#varints) length, then
  exactly that many payload bytes:

  ```
  ac 02                  ← varint(300), 2 bytes
  d0 9e … (300 bytes)    ← the payload itself, as-is
  ```

  Lengths fit a `u32` (prefix 1–5 bytes). **All four `bytes` fields (`operations`,
  `tx_data`, `data`, `return_data`) are encoded this way** — whether their contents are
  protocol-defined or opaque to it.
* **Blob layout.** The logical byte stream is the batch's EIP-4844 blobs in order,
  concatenated, with the batch `callData` appended after the last blob — one continuous
  stream. A message MAY span a blob boundary: the next blob simply *continues* the stream.
  When the batch contains one or more blobs, a `CloseBlobStream` (§2.1) ends the blob
  portion — it MUST appear exactly once: every
  byte after it, up to the end of the last blob, is zero padding. How that stream data is packed into a blob's field
  elements is detailed in §4.

  The `callData` tail is part of the same stream: after a `CloseBlobStream`, the padding
  is skipped and the stream **resumes in `callData`**. A `CloseBlobStream` cannot appear
  inside `callData` itself — there are no blobs left to close, so its type byte there is
  invalid (§5).

  **Zero-blob batches (calldata only).** If the batch contains no blobs, the stream
  starts directly in `callData` with the protocol version byte (`00`), followed by
  messages. `CloseBlobStream` MUST be omitted: there is no blob portion to close.
  The stream ends at the end of `callData`, with no padding.

### 1.2 The current executing rollup (context stack)

Several fields are never encoded because they are implied by **where execution currently
is**: a `Call`'s `from_rollup` (§2.4), both endpoints of a `ReturnSuccess` / `ReturnFail`
(§2.5), and the rollup a cross-rollup transaction ends on (§2.8). All of them read the same
stream-level state — the **currently executing rollup** — tracked by a **context stack**
that evolves deterministically with each message. Because it feeds the cross-rollup call
hash (as `sourceRollupId`), every implementation MUST evolve it identically:

| message | effect on the context stack |
|---|---|
| `InitiateCrossRollupTransaction` | pushes its `rollup_id` — the root context; the stack MUST be empty (transactions never nest) |
| `Call` / `StaticCall` | its `from_rollup` **is the current top**; then pushes its `to_rollup` — subsequent messages execute on the callee |
| `ReturnSuccess` / `ReturnFail` | pops — execution resumes on the caller |
| `FinishCrossRollupTransaction` | pops the root `rollup_id`; the stack MUST then be empty (every call already returned) |
| `RollupOperation`, `Snapshot`, `Revert`, `CloseBlobStream` | no effect on the stack |

Equivalently: the current rollup is the one established by the most recent **non-finalized**
`InitiateCrossRollupTransaction` or `Call` / `StaticCall` — "non-finalized" meaning its
matching return (or finish) has not yet arrived.

**Example** — nested calls, a return, then a sibling call:

```
InitiateCrossRollupTransaction (rollup_id: R1)    # stack: [R1]
Call (to_rollup: R2)   # from = R1 (top of stack)          → stack: [R1, R2]
Call (to_rollup: R3)   # from = R2 (last call's to_rollup)  → stack: [R1, R2, R3]
ReturnSuccess         # R3 returns to R2 — pop            → stack: [R1, R2]
Call (to_rollup: R4)   # from = R2 — the most recent NON-FINALIZED call's to_rollup
                      #  (the R2→R3 call already returned)→ stack: [R1, R2, R4]
ReturnSuccess         # R4 returns to R2 — pop            → stack: [R1, R2]
ReturnSuccess         # R2 returns to R1 — pop            → stack: [R1]
FinishCrossRollupTransaction                     # stack: []
```

---

## 2. Message types

A rollup id is encoded only when it can't be inferred.

Each row gives the complete field layout in wire order; §2.1–2.8 add the prose.

| type | name | fields (in wire order) |
|---|---|---|
| `0` | — **reserved, invalid** — | never begins a message |
| `1` | `CloseBlobStream` | `u8 message_type` |
| `2` | `RollupOperation` | `u8 message_type` · `u64 rollup_id` · `bytes operations` |
| `3` | `InitiateCrossRollupTransaction` | `u8 message_type` · `u64 rollup_id` · `bytes tx_data` |
| `4` | `Call` | `u8 message_type` · `u64 to_rollup` · `address from_address` · `address to_address` · `u256 value` · `u64 gas` · `bytes data` |
| `5` | `StaticCall` | `u8 message_type` · `u64 to_rollup` · `address from_address` · `address to_address` · `u64 gas` · `bytes data` |
| `6` | `ReturnSuccess` | `u8 message_type` · `bytes return_data` |
| `7` | `ReturnFail` | `u8 message_type` · `bytes return_data` |
| `8` | `Snapshot` | `u8 message_type` |
| `9` | `Revert` | `u8 message_type` |
| `10` | `FinishCrossRollupTransaction` | `u8 message_type` |

> **Type `0` is reserved as invalid** so zero padding never parses as messages — a stream
> with blobs but missing its `CloseBlobStream` fails at the first padding byte instead of decoding it as
> valid markers.

> **Pairing.** Three pairs always come matched: every `Call` / `StaticCall` has a result —
> `ReturnSuccess` (`6`) or `ReturnFail` (`7`); every `Snapshot` a `Revert`; and every
> `InitiateCrossRollupTransaction` a `FinishCrossRollupTransaction`. `RollupOperation` and
> `CloseBlobStream` stand alone.

### 2.1 `CloseBlobStream`
Marks the end of meaningful content in the **blob portion** of the stream — **mandatory,
emitted exactly once when the batch contains one or more blobs**; such a stream without
it is invalid (§5). For zero-blob batches it MUST be omitted (§1.1), and it MUST NOT
appear in `callData`, including the tail of a batch with blobs. Every byte after it, up to
the end of the last blob, is padding and MUST be **zeroed out** (readers skip it
regardless); the stream continues in the `callData` tail (§1.1). A **bare marker** (§1.1):

```c
struct CloseBlobStream { u8 message_type; }   // = 1
```

### 2.2 `RollupOperation`
Carries the operations of a single rollup (the `rollup_id`). At the protocol level its
payload is **opaque** — an ordered list the executing rollup interprets on its own. The
operations list can be large; its varint length prefix (§1.1) scales accordingly.

A `RollupOperation` MUST NOT appear inside an `InitiateCrossRollupTransaction` …
`FinishCrossRollupTransaction` bracket (§5, condition 7): between a `Call` and its return
the only legal messages are the cross-rollup ones themselves (`Call` / `StaticCall`,
`ReturnSuccess` / `ReturnFail`, `Snapshot` / `Revert`).

```c
struct RollupOperation {          // type 2
    u8       message_type;       // = 2
    u64      rollup_id;           // the executing rollup
    bytes    operations;         // opaque to the protocol; the rollup interprets it (length-prefixed)
}
```

> **Reference implementation (not protocol).** Everything about how `operations` is
> structured is up to the rollup. The reference implementation encodes it as a `RollupOpItem[]`
> (a `u32` count, then items), each item a transaction or a new-block marker, where a
> `NewBlock` implicitly closes the previous block. None of this is mandated — it only makes
> the examples below concrete.
>
> ```c
> RollupOpItem { u8 item_type; bytes item_data; }   // 1 = Transaction, 2 = NewBlock
> // Transaction: rlp_transaction   |   NewBlock: block_params (e.g. timestamp)
> ```
>
> Whether a `Transaction`'s `rlp_transaction` carries a signature is **up to the rollup** —
> some rollups include it, others omit it. The format does not
> mandate either way; the rollup that interprets `operations` knows what to expect.

**Example** — rollup `7` opens a block, runs two txs, opens a second block, runs one more:

```
message_type = 2
rollup_id     = 7
operations   = RollupOpItem[5] {
    [0] NewBlock     { timestamp: 1_700_000_000, ... }   # block 1 opens
    [1] Transaction  rlp_tx_0                            #   |
    [2] Transaction  rlp_tx_1                            #   |  block 1
    [3] NewBlock     { timestamp: 1_700_000_012, ... }   # block 1 closes, block 2 opens
    [4] Transaction  rlp_tx_2                            #   |  block 2
}
```

### 2.3 `InitiateCrossRollupTransaction`
Opens one cross-rollup transaction. `rollup_id` is where the originating tx lives.

```c
struct InitiateCrossRollupTransaction {   // type 3
    u8       message_type;   // = 3
    u64      rollup_id;       // where the originating tx lives
    bytes    tx_data;        // opaque — the rollup decides what goes here; last, length-prefixed
}
```

What `tx_data` contains is **up to the rollup** — like `operations` (§2.2), the protocol
treats it as opaque bytes (e.g. an RLP transaction with or without its signature).

An `InitiateCrossRollupTransaction` requires an **empty context stack** (§1.2) — verified,
not assumed: transactions never nest (§5, condition 6). It MUST be closed by a matching
`FinishCrossRollupTransaction` (§2.8); everything the transaction produces lives between
the two.

### 2.4 `Call` / `StaticCall`
A cross-rollup call. Instead of an `is_static` flag, read-only calls are a **distinct message
type** — `StaticCall` (`5`), a `STATICCALL` that carries no value and reverts on state
write. A value-bearing `Call` (`4`) and a `StaticCall` (`5`) differ only by the
absence of `value`:

```c
struct Call {                // type 4
    u8       message_type;   // = 4
    u64      to_rollup;       // target rollup; from_rollup is implicit — the executing rollup
    address  from_address;
    address  to_address;
    u256     value;          // 32 bytes, little-endian (§1.1)
    u64      gas;            // gas limit forwarded to the call
    bytes    data;           // the call's exact calldata; last, length-prefixed
}

struct StaticCall {          // type 5 — read-only STATICCALL
    u8       message_type;   // = 5
    u64      to_rollup;       // target rollup; from_rollup is implicit — the executing rollup
    address  from_address;
    address  to_address;
    u64      gas;            // gas limit forwarded to the call
    bytes    data;           // the call's exact calldata; last, length-prefixed (no value)
}
```

Unlike `operations` / `tx_data`, `data` is **not** rollup-defined: it is exactly the
calldata of the cross-rollup call.

`from_rollup` is **not encoded** — it is the **currently executing rollup**: the top of the
context stack (§1.2) at the moment the `Call` is emitted.

### 2.5 `ReturnSuccess` / `ReturnFail` (the Call's result)
The outcome of a finished `Call`, flowing back to the caller. Instead of one `Result` with a
`success` flag, the outcome is carried by **two distinct message types** — `ReturnSuccess`
(`6`) for a successful **return** and `ReturnFail` (`7`) for the call's own **revert**.
Either pairs with the last outstanding `Call` / `StaticCall`, so **both** rollups (`from`
and `to`) are implicit — the return pops the context stack (§1.2), resuming execution on
the caller. The payload layout is identical for both:

```c
struct ReturnSuccess {       // type 6
    u8       message_type;   // = 6
    bytes    return_data;    // the call's exact return value; last, length-prefixed
}

struct ReturnFail {          // type 7
    u8       message_type;   // = 7
    bytes    return_data;    // the call's exact revert data; last, length-prefixed
}
```

Like `Call.data`, `return_data` is **not** rollup-defined: it is exactly the call's return
(or revert) data.

`ReturnFail` means the call **finished by reverting** on the callee: the caller receives
the failure and handles it like a same-rollup contract revert. That differs from a
`Snapshot`/`Revert` region (§2.6–2.7), which force-reverts calls that already *succeeded*.

### 2.6 `Snapshot`
Opens a revertable region — a forced-revert bracket. A **bare marker** (§1.1):

```c
struct Snapshot { u8 message_type; }          // = 8
```

Everything executed after it (native ops, cross-rollup `Call`s, nested regions) is rolled
back when the region's matching `Revert` (§2.7) arrives. `Snapshot` / `Revert` are
**always paired and properly nested**, like balanced brackets: every `Snapshot` is closed
by exactly one `Revert`, a `Revert` must have an open `Snapshot`, and each `Revert` closes
the innermost still-open `Snapshot`.

A `Snapshot` is only needed around calls that `ReturnSuccess` and must be rolled back
later. A call that ends in `ReturnFail` already implies its effects reverted (§2.5), so a
region whose only content is that call is unnecessary — don't emit one.

A `Snapshot` can only open **inside** an open `InitiateCrossRollupTransaction` …
`FinishCrossRollupTransaction` bracket — never outside a cross-rollup transaction (§5,
condition 7) — and its matching `Revert` must arrive before that bracket closes, at the
same context-stack level the `Snapshot` opened at (§2.7).

### 2.7 `Revert`
Closes the region opened by the matching `Snapshot` (§2.6), rolling back everything
executed since it. A **bare marker** (§1.1):

```c
struct Revert { u8 message_type; }            // = 9
```

The region is delimited by the bracket, so no rollup id, count, or call identifier is
needed.

A `Revert` must arrive at the **same context-stack level** (§1.2) as its matching
`Snapshot`: every `Call` opened since the `Snapshot` already has its result
(`ReturnSuccess` / `ReturnFail`), and the stack never drops below the `Snapshot`'s depth
inside the region. A `Revert` straight after an unreturned `Call` is therefore invalid
(§5, condition 6) — a call must have finished before its effects can be force-reverted.

A `Revert` is **not** a failed result: a call that fails by itself reports a
`ReturnFail` (§2.5). `Revert` is used when calls inside the region completed with a
`ReturnSuccess`, but the rollup that initiated them, later reverts that context — forcing
those already-succeeded effects to roll back.

### 2.8 `FinishCrossRollupTransaction`
Closes the cross-rollup transaction opened by `InitiateCrossRollupTransaction` (§2.3). A
**bare marker** (§1.1); the tx ends on the currently-executing rollup, which is implicit
(§1.2).

```c
struct FinishCrossRollupTransaction { u8 message_type; }   // = 10
```

---

## 3. Reference examples

### 3.1 Normal flow: open blocks → cross-rollup → close blocks

The canonical shape of a slot. Each rollup first runs its native txs and **opens** a
cross-rollup block; the cross-rollup transactions are processed between the open blocks; once
all are done, each rollup **closes** its block (one `RollupOperation` per rollup):

```
# 1. L2_A: native txs + open its cross-rollup block
RollupOperation (rollup_id: L2_A, operations: [ NewBlock{ts}, Tx, Tx ])

# 2. L2_B: native txs + open its cross-rollup block
RollupOperation (rollup_id: L2_B, operations: [ NewBlock{ts}, Tx, Tx ])

# 3. process the cross-rollup transaction(s) between the open blocks
InitiateCrossRollupTransaction (rollup_id: L2_A, TxData)
    Call           (to L2_B, ...)               # from L2_A (implicit)
    ReturnSuccess  (return_data)                # pairs with the Call
FinishCrossRollupTransaction                     # ends on L2_A (implicit)

# 4. all cross-rollup done — close both blocks (a fresh NewBlock auto-closes the open one)
RollupOperation (rollup_id: L2_A, operations: [ NewBlock{ts'} ])   # closeBlock for L2_A
RollupOperation (rollup_id: L2_B, operations: [ NewBlock{ts'} ])   # closeBlock for L2_B
```

### 3.2 Snapshot / Revert around a call

A `Snapshot` … `Revert` bracket forces everything inside it to roll back:

```
InitiateCrossRollupTransaction (rollup_id: L2_A) # the bracket the region lives in (§2.6)
Snapshot                                       # open revertable region
Call           (to L2_B, ...)                  # from L2_A (implicit)
ReturnSuccess  (return_data)                   # pairs with the Call
Revert                                         # close region → the call's effects roll back
FinishCrossRollupTransaction
```

### 3.3 Nested snapshots

Brackets nest; each `Revert` closes the innermost open `Snapshot`:

```
InitiateCrossRollupTransaction (rollup_id: L2_A)
Snapshot                         # outer region opens
Call           (to L2_B, ...)    # from L2_A
ReturnSuccess
    Snapshot                     # inner region opens (nested)
    Call           (to L2_C, ...) # from L2_A — the L2_B call already returned (§1.2)
    ReturnSuccess
    Revert                       # inner closes → the L2_A → L2_C call rolls back
Revert                           # outer closes → the L2_A → L2_B call (and all nested) rolls back
FinishCrossRollupTransaction
```

---

## 4. Blob data encoding

The logical byte stream (§1) is not written into a blob verbatim. An EIP-4844 blob is
**4096 field elements of 32 bytes each**, and each element must be a valid BLS12-381
scalar — below the field modulus `r` (`2^254 < r < 2^255`). A raw 32-byte value can exceed
`r`, so arbitrary bytes cannot be stored directly.

Each field element carries **31 bytes of stream data**, and its **last (32nd) byte is
unused and MUST be zero**. Elements are read as **little-endian** scalars, like every
scalar in this format (§1.1), so the zero byte is the most significant one — every
element is `< 2^248 < r` regardless of its 31 data bytes.

**Physical byte order.** Blob bytes are read from the **least significant byte to the
most significant byte** of each field element: stream byte `k` sits at byte
significance `k`, and the unused zero byte is the last one read. This is not just the
§1.1 scalar convention — it is the *physical* layout of stream data in the element.

* **Capacity:** `4096 × 31 = 126,976` useful bytes per blob.
* **Read:** for each element, read its 31 data bytes from least significant to most
  significant and drop the 32nd (most significant, zero) byte; concatenate the chunks of
  all elements of all blobs in order, and parse the version byte and messages (§1) from
  the result. A `CloseBlobStream` (§2.1) is evaluated against this *decoded* stream.
* The trailing `callData` (§1.1) has no field-element constraint — raw bytes, appended to
  the recovered stream as-is.

---

## 5. Validity — a malformed stream is rejected whole

A blob stream is either **entirely valid or entirely invalid**. If *any* condition below is
violated at *any* point, the **whole stream is rejected** — every blob of the batch and the
trailing `callData`, not just the offending blob or the suffix after the violation. 
In practice this check falls on the **prover**: a valid proof simply cannot be produced
over a malformed stream, so publishing one is equivalent to publishing nothing.

The stream is valid iff **all** of the following hold:

1. **Encoding layer (§4).** Every field element of every blob has its last (32nd) byte
   zero — a valid BLS12-381 scalar.
2. **Version and stream close.** The first byte of the stream is a known protocol
   version (§6) — for this spec, `00`. If the batch contains one or more blobs,
   `CloseBlobStream` (`1`) appears exactly once, in the blob portion. If the batch
   contains no blobs, the version byte is the first byte of `callData`, and
   `CloseBlobStream` MUST be omitted.
3. **Known types.** Every message begins with an assigned type byte: `1`–`10` — a `0`
   (padding, §2) or any of `11`–`255` is invalid. Inside `callData` (whether the entire stream or a tail),
   `CloseBlobStream` is invalid too (§1.1).
4. **No truncation.** Every message's fields decode completely within the stream; the
   stream ends exactly at a message boundary with no bracket still open (condition 6).
5. **Invalid encodings.** Every field decodes exactly as its encoding defines.
6. **Bracket discipline.** Every `InitiateCrossRollupTransaction` is closed by a matching
   `FinishCrossRollupTransaction`; every `Snapshot` by a properly nested `Revert`; every
   `Call` / `StaticCall` has its `ReturnSuccess` / `ReturnFail`. A closer with no open
   counterpart (a bare `Revert`, a return with no outstanding call, a
   `FinishCrossRollupTransaction` with calls still open — §1.2's context stack) is invalid,
   as is an `InitiateCrossRollupTransaction` on a non-empty stack (nested transaction).
   A `Revert` closes its `Snapshot` at the **same context-stack depth** it opened at
   (§2.7): a `Revert` while a `Call` opened after the `Snapshot` is still unreturned is
   invalid.
7. **Placement.** `Call` / `StaticCall`, `ReturnSuccess` / `ReturnFail`, `Snapshot` /
   `Revert` appear only inside
   an open `InitiateCrossRollupTransaction` … `FinishCrossRollupTransaction` bracket (a `Call`
   needs an executing context for its implicit `from_rollup`, §1.2; a `Snapshot` cannot open
   outside a cross-rollup transaction, §2.6). Conversely, `RollupOperation` appears only
   **outside** such a bracket (§2.2) — a `RollupOperation` between a `Call` and its return
   is invalid.
8. **Minimal encodings — NOT enforced.** An honest encoder always emits the shortest form, but
   the verifier does not assert it: non-minimal encodings still decode and do not
   invalidate the stream. Consequence: raw stream bytes are not canonical.

---

## 6. Versioning

The first byte of the stream is the **protocol version** — reserved, decoded on its
own, never a message (§1). This holds in every version of the format. This document
defines version **`00`**. A future version MUST use a different version byte, and may
define an entirely different format for everything after it. A verifier that does not recognize the version byte rejects the
stream (§5, condition 2), so a newer-format stream can never be misparsed under this
spec's rules.

---

## 7. Future optimizations

Several size optimizations are planned but not part of this version: a compressed
`rollup_id` encoding, a compressed `u256` for `Call.value`, and a denser blob packing
(254 bits per field element, ~2.4% more capacity). They are specified in
[`FUTURE_OPTIMIZATIONS.md`](./FUTURE_OPTIMIZATIONS.md).
