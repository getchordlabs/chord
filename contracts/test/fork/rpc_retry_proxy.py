#!/usr/bin/env python3
"""Local JSON-RPC shim so `forge test --fork-url` works against the owner's BNB gateway (moltnode.ag/bnb).

Measured 2026-09-30 (docs/bnb-contracts-deploy.md §6), three gateway behaviours forge cannot cope with:
  1. EIP-1898 block params (`{"blockHash": …}`, which forge sends for eth_getCode) answer `-32000 not supported`
     on every call -> rewritten to the block NUMBER (looked up once per hash).
  2. State is kept for ~128 blocks only (~57 s on BNB): head-100 served, head-200 `not supported` every time,
     and one of the two backends intermittently refuses even recent blocks -> each request is retried; a state
     read that still fails after 4 tries is re-issued at `latest`. The fork then mixes slots read up to a test
     run apart (seconds). The count is printed on stderr so a run can be judged.
  3. Cloudflare answers some calls with an HTML 502 -> retried.
Usage:  python3 test/fork/rpc_retry_proxy.py https://moltnode.ag/bnb 18654
        forge test --match-path 'test/fork/BnbForkTest.t.sol' --fork-url http://127.0.0.1:18654 -vv
Local only (binds 127.0.0.1); read-only JSON-RPC pass-through — it never signs or sends a transaction itself.
"""
import json
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = sys.argv[1]
PORT = int(sys.argv[2])
FLAKY = ("not supported", "header not found", "missing trie node")
STATE_METHODS = {"eth_getCode", "eth_getBalance", "eth_getTransactionCount", "eth_getStorageAt", "eth_call",
                 "eth_getProof"}
HASH2NUM = {}
LATEST_REWRITES = [0]


def post(data: bytes) -> bytes:
    req = urllib.request.Request(
        UPSTREAM, data=data, headers={"Content-Type": "application/json", "User-Agent": "curl/8.7"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def flaky(body: bytes) -> bool:
    try:
        d = json.loads(body)
    except Exception:
        return True  # HTML 502 etc.
    for it in d if isinstance(d, list) else [d]:
        err = it.get("error") if isinstance(it, dict) else None
        if err and any(s in str(err.get("message", "")).lower() for s in FLAKY):
            return True
    return False


def block_number_of(h: str) -> str:
    if h not in HASH2NUM:
        for _ in range(25):
            try:
                d = json.loads(post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByHash",
                                                "params": [h, False]}).encode()))
                if d.get("result"):
                    HASH2NUM[h] = d["result"]["number"]
                    break
            except Exception:
                pass
            time.sleep(0.1)
    return HASH2NUM.get(h, "latest")


def rewrite_block_hashes(data: bytes) -> bytes:
    try:
        d = json.loads(data)
    except Exception:
        return data
    changed = False
    for it in d if isinstance(d, list) else [d]:
        ps = it.get("params") if isinstance(it, dict) else None
        if isinstance(ps, list):
            for i, p in enumerate(ps):
                if isinstance(p, dict) and "blockHash" in p and len(p) <= 2:
                    ps[i] = block_number_of(p["blockHash"])
                    changed = True
    return json.dumps(d).encode() if changed else data


def to_latest(data: bytes) -> bytes:
    try:
        d = json.loads(data)
    except Exception:
        return data
    for it in d if isinstance(d, list) else [d]:
        if isinstance(it, dict) and it.get("method") in STATE_METHODS and isinstance(it.get("params"), list):
            ps = it["params"]
            if ps and isinstance(ps[-1], str) and ps[-1].startswith("0x"):
                ps[-1] = "latest"
                LATEST_REWRITES[0] += 1
                sys.stderr.write(f"state read re-issued at latest (#{LATEST_REWRITES[0]}): {it['method']}\n")
    return json.dumps(d).encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        data = rewrite_block_hashes(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        body = b""
        for attempt in range(25):
            try:
                body = post(data)
                if not flaky(body):
                    break
            except Exception:
                body = b""
            if attempt == 3:
                data = to_latest(data)
            time.sleep(0.05 * (attempt + 1))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
