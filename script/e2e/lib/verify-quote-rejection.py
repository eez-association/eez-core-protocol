#!/usr/bin/env python3
"""Verify historical fee-quote rejection evidence, not execution or settlement."""
import argparse
import csv
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess

CODE = "unsupported_transaction"
MESSAGE = "unsupported quote: gas estimation or final effect validation failed"


class EvidenceError(ValueError):
    """A fixed diagnostic safe to display without exposing input data."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON object field")
        result[key] = value
    return result


def parse_json(value):
    return json.loads(value, object_pairs_hook=unique_object)


def quantity(value):
    require(isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]+", value), "invalid quote quantity")
    return int(value, 16)


def validate_record(record, tx):
    intent = {"from": tx["signer"], "to": tx["to"], "data": tx["input"],
              "value": tx["value"], "nonce": tx["nonce"]}
    require(record["intent"] == intent, "quote intent differs from prepared trigger")
    require(record["transactionType"] == tx["type"] and tx["type"] in ("0x0", "0x2"),
            "quote transaction type differs from prepared trigger")
    require(quantity(record["preparedNonce"]) == quantity(tx["nonce"]), "prepared nonce mismatch")
    quote = parse_json(record["rawResponse"])
    require(type(quote["version"]) is int and quote["version"] == 1, "unsupported quote version")
    require(quantity(quote["chainId"]) == quantity(tx["chainId"]), "quote chain mismatch")
    require(quantity(quote["nonce"]) == quantity(tx["nonce"]), "quote nonce mismatch")
    require(isinstance(record["receivedAt"], str), "invalid quote timestamp")
    received = datetime.fromisoformat(record["receivedAt"].replace("Z", "+00:00"))
    require(received.tzinfo is not None, "quote timestamp lacks timezone")
    # Verify validity when captured, not at a later --verify-only invocation.
    require(quantity(quote["expiresAt"]) > received.timestamp(), "quote was expired when received")
    require(isinstance(quote["options"], list), "malformed quote options")
    options = [option for option in quote["options"] if option["type"] == tx["type"]]
    require(len(options) == 1, "expected exactly one matching quote option")
    option = options[0]
    require(set(option) == {"type", "error"}, "quote succeeded or has conflicting option fields")
    require(option["error"]["code"] == CODE and option["error"]["message"] == MESSAGE,
            "quote rejection is not the expected code and message")


def verify_job(root, name):
    job = root / "jobs" / name
    require(re.fullmatch(r"[A-Za-z0-9_-]+", name), "invalid job name")
    for path in (job / "txs.txt", *job.glob("txs.txt.attempt*")):
        require(not path.exists() or not path.read_text().strip(), "a trigger submission is recorded")
    for path in (root / "sent.csv", root / "mined.csv", *root.glob("sent.csv.attempt*")):
        if path.exists():
            with path.open() as stream:
                require(not any(row and row[0] == name for row in csv.reader(stream)),
                        "a trigger submission or receipt is recorded")
    require(not (job / "fee-quote-1.json").exists(), "signed quote evidence exists")
    raw = (job / "rawtxs.txt").read_text().splitlines()
    require(len(raw) == 1 and re.fullmatch(r"0x[0-9a-fA-F]+", raw[0]),
            "expected exactly one prepared trigger")
    result = subprocess.run(["cast", "decode-transaction", raw[0]], capture_output=True, text=True, timeout=10)
    require(result.returncode == 0, "cannot decode prepared trigger")
    tx = parse_json(result.stdout)
    if isinstance(tx, str):
        tx = parse_json(tx)
    records = (job / "fee-quote-1.responses.jsonl").read_text().splitlines()
    require(bool(records), "no quote response was captured")
    start = job / "quote-probe-start.txt"
    if start.exists():
        count = int(start.read_text())
        require(count >= 0 and len(records) == count + 1, "latest quote attempt has no unique new response")
    # A later success, malformed response or different refusal cannot reuse an old pass.
    validate_record(parse_json(records[-1]), tx)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("job")
    args = parser.parse_args()
    try:
        verify_job(args.run_dir, args.job)
    except EvidenceError as exc:
        print("FAIL: " + str(exc))
        return 1
    except (OSError, ValueError, KeyError, TypeError, IndexError, OverflowError, subprocess.TimeoutExpired):
        print("FAIL: missing or malformed quote evidence")
        return 1
    print("PASS: expected fee-quote rejection: " + CODE + ": " + MESSAGE)
    print("No trigger submission recorded; this verifies quoting only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
