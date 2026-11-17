#!/usr/bin/env python3
"""Shared, read-only JSON-RPC receipt polling for burst load runs."""
import argparse
import csv
import http.client
import json
from pathlib import Path
import sys
import time
import urllib.request


def fetch_receipts(url, hashes, timeout):
    requests = [{"jsonrpc": "2.0", "id": h, "method": "eth_getTransactionReceipt",
                 "params": [h]} for h in hashes]
    request = urllib.request.Request(url, data=json.dumps(requests).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        replies = json.load(response)
    if not isinstance(replies, list):
        raise ValueError("RPC did not return a batch response")
    # Responses may be out of order, absent, null, or individually rejected.
    results = {}
    seen = set()
    for reply in replies:
        if not isinstance(reply, dict):
            continue
        key = reply.get("id")
        if not isinstance(key, str) or key not in hashes:
            continue
        if key in seen:
            results.pop(key, None)
            continue
        seen.add(key)
        receipt = reply.get("result")
        if "error" in reply or not isinstance(receipt, dict):
            continue
        txhash = receipt.get("transactionHash")
        if not isinstance(txhash, str) or txhash.lower() != key.lower():
            continue
        status = receipt.get("status")
        if status in ("0x1", 1):
            results[key] = "success"
        elif status in ("0x0", 0):
            results[key] = "reverted"
    return results


class Poller:
    def __init__(self, root, rpc, receipt_timeout, request_timeout, batch_size=100):
        self.root = Path(root)
        self.rpc = rpc
        self.receipt_timeout = receipt_timeout
        self.request_timeout = request_timeout
        self.batch_size = batch_size
        self.offsets = {}
        self.pending = {}
        self.last_error = None

    def ingest(self):
        for path in self.root.glob("worker-*.pending"):
            with path.open() as stream:
                stream.seek(self.offsets.get(path, 0))
                while True:
                    offset = stream.tell()
                    line = stream.readline()
                    if not line or not line.endswith("\n"):
                        stream.seek(offset)
                        break
                    worker, index, nonce, txhash, started, accepted = next(csv.reader([line]))
                    self.pending[(worker, index)] = (nonce, txhash, int(started), int(accepted))
                self.offsets[path] = stream.tell()

    def finish(self, key, status):
        nonce, txhash, started, _ = self.pending.pop(key)
        worker, index = key
        elapsed = max(0, int(time.time() * 1000) - started)
        with (self.root / f"worker-{worker}.receipts.csv").open("a") as stream:
            csv.writer(stream, lineterminator="\n").writerow(
                [worker, index, nonce, txhash, status, elapsed])

    def tick(self):
        self.ingest()
        keys = list(self.pending)
        for offset in range(0, len(keys), self.batch_size):
            group = keys[offset:offset + self.batch_size]
            now = int(time.time() * 1000)
            for key in group:
                if now - self.pending[key][3] >= self.receipt_timeout * 1000:
                    self.finish(key, "timeout")
            group = [key for key in group if key in self.pending]
            if not group:
                continue
            hashes = list(dict.fromkeys(self.pending[key][1] for key in group))
            remaining = min(self.receipt_timeout - (now - self.pending[k][3]) / 1000 for k in group)
            try:
                results = fetch_receipts(self.rpc, hashes, max(0.001, min(self.request_timeout, remaining)))
                self.last_error = None
            except (OSError, ValueError, http.client.HTTPException) as error:
                # Never turn an RPC failure or null into a transaction failure.
                message = type(error).__name__
                if message != self.last_error:
                    print(f"Receipt batch failed ({message}); retrying pending hashes", file=sys.stderr, flush=True)
                    self.last_error = message
                results = {}
            for key in group:
                if self.pending[key][1] in results:
                    self.finish(key, results[self.pending[key][1]])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--receipt-timeout", type=int, required=True)
    parser.add_argument("--request-timeout", type=int, default=15)
    args = parser.parse_args()
    poller = Poller(args.run_dir, args.rpc, args.receipt_timeout, args.request_timeout)
    try:
        while True:
            poller.tick()
            if (poller.root / "receipts.stop").exists() and not poller.pending:
                return
            time.sleep(1)
    except Exception:
        (poller.root / "receipts.failed").touch()
        raise


if __name__ == "__main__":
    main()
