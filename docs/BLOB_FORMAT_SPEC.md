# Standardized Message Format

A binary format for publishing chain activity as a single stream of
messages — no header.
**Everything is a message**: chain-local operations, cross-chain calls, results, reverts,
and transaction boundaries differ only by message type.

Excalidraw: https://excalidraw.com/#json=6wvuE6FrHjoxqAkIlAiUe,0I3IqjvA9xbwOEz1bvDF8Q
---

## 1. Framing

Every message begins with a `message_type` byte, which selects one of two shapes:

* **Content messages** carry data: `message_type | message_len | …fields…`.
* **Marker messages** carry none: a lone `message_type` byte, no length and no fields.

Each type's exact byte layout is defined inline with the type in §2.

### 1.1 Wire encoding

These conventions apply across the per-type layouts in §2:

* All values are **little-endian, fixed-width**: `u8`/`u16`/`u32`/`u64` as written, `bool`
  is one byte, `address` is 20 bytes, `uint256` is 32 bytes. Chain ids are `u64`.
* `message_len` is the byte length of the fields after it — `u16` for most messages, `u32`
  for `ChainOperation`.
* **Blob layout.** The logical byte stream is the batch's EIP-4844 blobs in order,
  concatenated, with the batch `callData` appended after the last blob — one continuous
  stream. A message MAY span a blob boundary: the next blob simply *continues* the stream.
  A `CloseBlob` (§2.8) ends a blob early so the next blob starts a fresh message; the bytes
  between it and the blob boundary are padding. How that stream data is packed into a
  blob's field elements is detailed in §4.

---

## 2. Message types

A chain id is encoded only when it can't be inferred.

Each row gives the complete field layout in wire order; §2.1–2.8 add the prose.

| type | name | fields (in wire order) |
|---|---|---|
| `1` | `ChainOperation` | `u8 message_type` · `u32 message_len` · `u64 chain_id` · `bytes operations` |
| `2` | `InitiateCrossChainTransaction` | `u8 message_type` · `u16 message_len` · `u64 chain_id` · `bytes tx_data` |
| `3` | `Call` | `u8 message_type` · `u16 message_len` · `u64 to_chain` · `bool is_static` · `address fromAddress` · `address toAddress` · `uint256 value` · `bytes data` |
| `4` | `Result` | `u8 message_type` · `u16 message_len` · `bool success` · `bytes return_data` |
| `5` | `Snapshot` | `u8 message_type` |
| `6` | `Revert` | `u8 message_type` |
| `7` | `FinishCrossChainTransaction` | `u8 message_type` |
| `0xFF` | `CloseBlob` | `u8 message_type` |

> **Pairing.** Three pairs always come matched: every `Call` has a `Result`, every
> `Snapshot` a `Revert`, and every `InitiateCrossChainTransaction` a
> `FinishCrossChainTransaction`. `ChainOperation` and `CloseBlob` stand alone.

### 2.1 `ChainOperation`
Carries the operations of a single chain (the `chain_id`). At the protocol level its
payload is **opaque** — an ordered list the executing chain interprets on its own. It uses a
wider `u32` `message_len` since the operations list can be large:

```c
struct ChainOperation {          // type 1
    u8     message_type;         // = 1
    u32    message_len;          // byte length of the fields below (chain_id + operations)
    u64    chain_id;             // the executing chain
    bytes  operations;           // opaque to the protocol; the chain interprets it
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
message_type = 1
message_len  = <u32 byte length of chain_id + operations>
chain_id     = 7
operations   = ChainOpItem[5] {
    [0] NewBlock     { timestamp: 1_700_000_000, ... }   # block 1 opens
    [1] Transaction  rlp_tx_0                            #   |
    [2] Transaction  rlp_tx_1                            #   |  block 1
    [3] NewBlock     { timestamp: 1_700_000_012, ... }   # block 1 closes, block 2 opens
    [4] Transaction  rlp_tx_2                            #   |  block 2
}
```

### 2.2 `InitiateCrossChainTransaction`
Opens one cross-chain transaction. `chain_id` is where the originating tx lives.

```c
struct InitiateCrossChainTransaction {   // type 2
    u8       message_type;   // = 2
    u16      message_len;    // byte length of the fields below
    u64      chain_id;       // where the originating tx lives
    bytes    tx_data;        // the originating transaction (TxData, incl. its signature) — last, u32 length-prefixed
}
```

`InitiateCrossChainTransaction` / `FinishCrossChainTransaction` (§2.7) are **always
paired**, like brackets: every `InitiateCrossChainTransaction` MUST be closed by a matching
`FinishCrossChainTransaction`, a `FinishCrossChainTransaction` requires an open transaction,
and everything the transaction produces lives between the two.

### 2.3 `Call`
A cross-chain call:

```c
struct Call {                // type 3
    u8       message_type;   // = 3
    u16      message_len;    // byte length of the fields below
    u64      to_chain;       // target chain (from_chain is implicit — the executing chain)
    bool     is_static;      // true = read-only STATICCALL (no value; reverts on state write)
    address  fromAddress;
    address  toAddress;
    uint256  value;          // 0 when is_static
    bytes    data;           // dynamic — last; u32 length-prefixed
}
```

`from_chain` is **not encoded** — it is the chain whose context is currently executing,
established by the most recent `InitiateCrossChainTransaction` or `Call`.

### 2.4 `Result` (a.k.a. Return)
The outcome of a finished `Call`, flowing back to the caller — a successful **return**
(`success = true`) or the call's own **revert** (`success = false`). It pairs with the last
outstanding `Call`, so **both** chains (`from` and `to`) are implicit.

```c
struct Result {              // type 4
    u8       message_type;   // = 4
    u16      message_len;    // byte length of the fields below
    bool     success;        // false = the call itself reverted on the callee chain
    bytes    return_data;    // dynamic — last; u32 length-prefixed
}
```

`success = false` means the call **finished by reverting** on the callee: the caller
receives the failure and handles it like a same-chain contract revert. That differs from a
`Snapshot`/`Revert` region (§2.5–2.6), which force-reverts calls that already *succeeded*.

### 2.5 `Snapshot`
Opens a revertable region — a forced-revert bracket. A **bare marker** (§1.1): just the
`message_type` byte, no length and no params.

```c
struct Snapshot { u8 message_type; }          // = 5
```

Everything executed after it (native ops, cross-chain `Call`s, nested regions) is rolled
back when the region's matching `Revert` (§2.6) arrives. `Snapshot` / `Revert` are
**always paired and properly nested**, like balanced brackets: every `Snapshot` is closed
by exactly one `Revert`, a `Revert` must have an open `Snapshot`, and each `Revert` closes
the innermost still-open `Snapshot`.

### 2.6 `Revert`
Closes the region opened by the matching `Snapshot` (§2.5), rolling back every effect —
including any cross-chain `Call`s — executed since it. A **bare marker** (§1.1):

```c
struct Revert { u8 message_type; }            // = 6
```

The region is delimited by the bracket, so no chain id, count, or call identifier is
needed. A `Revert` is **not** a failed `Result`: a call that fails by itself reports
`Result { success: false }` (§2.4). `Revert` is used when calls inside the region completed
with `success = true`, but the chain that initiated them, later reverts that context —
forcing those already-succeeded effects to roll back.

### 2.7 `FinishCrossChainTransaction`
Closes the cross-chain transaction opened by `InitiateCrossChainTransaction` (§2.2). A
**bare marker** (§1.1); the tx ends on the currently-executing chain, which is implicit.

```c
struct FinishCrossChainTransaction { u8 message_type; }   // = 7
```

### 2.8 `CloseBlob`
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
    Call   (to L2_B, ...)                       # from L2_A (implicit)
    Result (success: true, return_data)         # pairs with the Call
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
Call   (to L2_B, is_static: false, ...)        # from L2_A (implicit)
Result (success: true, return_data)            # pairs with the Call
Revert                                         # close region → the call's effects roll back
```

### 3.4 Nested snapshots

Brackets nest; each `Revert` closes the innermost open `Snapshot`:

```
Snapshot                         # outer region opens
Call   (to L2_B, ...)            # from L2_A
Result (success: true)
    Snapshot                     # inner region opens (nested)
    Call   (to L2_C, ...)        # from L2_B
    Result (success: true)
    Revert                       # inner closes → the L2_B → L2_C call rolls back
Revert                           # outer closes → the L2_A → L2_B call (and all nested) rolls back
```

---

## 4. Blob data encoding

The logical byte stream (§1) is not written into a blob verbatim. An EIP-4844 blob is
**4096 field elements of 32 bytes each**, and each element must be a valid BLS12-381
scalar — below the field modulus `r` (`2^254 < r < 2^255`). A raw 32-byte value can exceed
`r`, so the **top bit of every element must stay clear** and arbitrary bytes cannot be
stored directly.

So each field element encodes **31 full bytes plus 7 bits of the 32nd byte** — 255 bits in
place. The remaining **8th (high) bit of the 32nd byte** would land in the element's
top-bit position, which must stay clear; instead it is set aside and re-encoded **at the
end of the blob**:

* **Data elements** carry the stream — 31 bytes + the low 7 bits of the 32nd byte, top bit
  clear — so each represents a full 32 bytes of logical data.
* The one deferred high bit per data element is collected in order. Across the ~4080 data
  elements that is ~4080 bits (**≤ 512 bytes**), which are packed (same 255-bit scheme) into
  the **last ≈ 16 field elements** of the blob.
* **Capacity:** `(4096 − 16) × 32 = 130,560` useful bytes per blob.
* **Read:** decode the ≈16 tail elements to recover the deferred bits, restore each data
  element's full 32nd byte (in-place 7 bits + its deferred bit), concatenate all data
  elements, and parse messages (§1) from the result.
* The trailing `callData` (§1.1) has no field-element constraint — raw bytes, appended to
  the recovered stream as-is.

A `CloseBlob` (§2.8) is evaluated against this *decoded* stream: it ends the blob's payload
early, and the remaining capacity is padding.
