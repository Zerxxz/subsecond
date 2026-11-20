#!/usr/bin/env python3
"""SUBSECOND demo runner — drives the full reactive loop on testnet and measures latency.

For each iteration: open a price gap with a shock swap on Base Sepolia (origin event),
wait for the Lasna reactive contract to detect it and request a callback, then wait for
the executor's callback on Base Sepolia. Records the full-loop latency (callback timestamp
minus origin timestamp, both Base Sepolia clocks) and whether the arb landed or was missed.

Writes deployments/demo_results.json for the dashboard. Needs DEPLOYER_KEY funded on Base
Sepolia and a deployed system (scripts/deploy.sh).

usage: DEPLOYER_KEY=0x... python3 scripts/demo.py [iterations]
"""
import json, os, sys, time
from pathlib import Path
from web3 import Web3

ROOT = Path(__file__).resolve().parent.parent
BASE_RPC = "https://sepolia.base.org"
LASNA_RPC = "https://lasna-rpc.rnk.dev/"
PK = os.environ.get("DEPLOYER_KEY")
if not PK:
    sys.exit("export DEPLOYER_KEY=0x... first")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 8
SHOCK = 20_000 * 10**18

w3b = Web3(Web3.HTTPProvider(BASE_RPC, request_kwargs={"timeout": 30}))
w3l = Web3(Web3.HTTPProvider(LASNA_RPC, request_kwargs={"timeout": 30}))
acct = w3b.eth.account.from_key(PK)
ADDR = acct.address

origin = json.loads((ROOT / "deployments/origin.json").read_text())
lasna = json.loads((ROOT / "deployments/lasna.json").read_text())
POOL_A = Web3.to_checksum_address(origin["poolA"])
POOL_B = Web3.to_checksum_address(origin["poolB"])
TOKEN1 = Web3.to_checksum_address(origin["token1"])
EXECUTOR = Web3.to_checksum_address(origin["executor"])
REACTIVE = Web3.to_checksum_address(lasna["reactive"])

POOL_ABI = json.loads('[{"name":"swap","type":"function","stateMutability":"nonpayable","inputs":[{"name":"amountIn","type":"uint256"},{"name":"zeroForOne","type":"bool"},{"name":"minOut","type":"uint256"},{"name":"to","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"name":"getReserves","type":"function","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"},{"name":"","type":"uint256"}]}]')
ERC_ABI = json.loads('[{"name":"mint","type":"function","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[]},{"name":"approve","type":"function","stateMutability":"nonpayable","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]},{"name":"balanceOf","type":"function","stateMutability":"view","inputs":[{"name":"","type":"address"}],"outputs":[{"name":"","type":"uint256"}]}]')
REACT_ABI = json.loads('[{"name":"callbacks","type":"function","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"name":"lastGapBps","type":"function","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"name":"lastReactTimestamp","type":"function","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]}]')

pool = w3b.eth.contract(address=POOL_A, abi=POOL_ABI)
poolB = w3b.eth.contract(address=POOL_B, abi=POOL_ABI)
token1 = w3b.eth.contract(address=TOKEN1, abi=ERC_ABI)
reactive = w3l.eth.contract(address=REACTIVE, abi=REACT_ABI)

ARB_EXECUTED = Web3.keccak(text="ArbExecuted(uint8,uint256,uint256,uint256,uint256,uint256,uint256,uint256)").hex()
ARB_MISSED = Web3.keccak(text="ArbMissed(uint8,uint256,uint256,uint256,uint256,uint256,string)").hex()


def send(fn, value=0):
    tx = fn.build_transaction({"from": ADDR, "nonce": w3b.eth.get_transaction_count(ADDR),
                               "gas": 600_000, "gasPrice": w3b.eth.gas_price, "value": value,
                               "chainId": 84532})
    signed = acct.sign_transaction(tx)
    h = w3b.eth.send_raw_transaction(signed.raw_transaction)
    rc = w3b.eth.wait_for_transaction_receipt(h, timeout=120)
    if rc.status != 1:
        raise RuntimeError(f"tx reverted: {h.hex()}")
    return rc


def wait_reactive(before, timeout=70):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if reactive.functions.callbacks().call() > before:
                return reactive.functions.lastReactTimestamp().call(), reactive.functions.lastGapBps().call()
        except Exception:
            pass
        time.sleep(1)
    return None, None


def wait_callback(from_block, timeout=70):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            logs = w3b.eth.get_logs({"address": EXECUTOR, "fromBlock": from_block,
                                     "topics": [[ARB_EXECUTED, ARB_MISSED]]})
            if logs:
                # The profitable arb and a redundant follow-up callback can both land;
                # give them a moment, then prefer the EXECUTED (profitable) one.
                time.sleep(3)
                logs = w3b.eth.get_logs({"address": EXECUTOR, "fromBlock": from_block,
                                         "topics": [[ARB_EXECUTED, ARB_MISSED]]})
                exec_logs = [l for l in logs if l["topics"][0].hex() == ARB_EXECUTED]
                lg = exec_logs[-1] if exec_logs else logs[-1]
                blk = w3b.eth.get_block(lg["blockNumber"])
                data = lg["data"].hex() if isinstance(lg["data"], bytes) else lg["data"]
                raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
                vals = [int.from_bytes(raw[i*32:(i+1)*32], "big") for i in range(len(raw)//32)]
                executed = lg["topics"][0].hex() == ARB_EXECUTED
                return {"executed": executed, "callback_ts": blk["timestamp"], "words": vals,
                        "tx": lg["transactionHash"].hex()}
        except Exception:
            pass
        time.sleep(1)
    return None


def wait_exec(from_block, timeout=45):
    """Watch for the profitable ArbExecuted callback directly (ignores redundant misses)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            logs = w3b.eth.get_logs({"address": EXECUTOR, "fromBlock": from_block,
                                     "topics": [ARB_EXECUTED]})
            if logs:
                lg = logs[-1]
                blk = w3b.eth.get_block(lg["blockNumber"])
                data = lg["data"].hex() if isinstance(lg["data"], bytes) else lg["data"]
                raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
                vals = [int.from_bytes(raw[i*32:(i+1)*32], "big") for i in range(len(raw)//32)]
                return {"callback_ts": blk["timestamp"], "words": vals,
                        "tx": lg["transactionHash"].hex()}
        except Exception:
            pass
        time.sleep(1.5)
    return None


def main():
    print(f"deployer {ADDR}\nreactive {REACTIVE}\nexecutor {EXECUTOR}")
    send(token1.functions.mint(ADDR, SHOCK * (N + 2)))
    send(token1.functions.approve(POOL_A, 2**256 - 1))
    send(token1.functions.approve(POOL_B, 2**256 - 1))
    # Seed a Sync on BOTH pools so the reactive contract holds both reserves. Pool B was
    # provisioned before the reactive subscribed, so without this it never learns B's price.
    send(pool.functions.swap(10**15, False, 0, ADDR))
    send(poolB.functions.swap(10**15, False, 0, ADDR))
    print("seeded Sync on both pools; waiting for reactive to ingest…")
    time.sleep(8)
    results = []
    for i in range(N):
        rc = send(pool.functions.swap(SHOCK, False, 0, ADDR))
        origin_ts = w3b.eth.get_block(rc.blockNumber)["timestamp"]
        ex = wait_exec(rc.blockNumber)
        row = {"iteration": i, "origin_tx": rc.transactionHash.hex(), "origin_ts": origin_ts}
        if ex:
            w = ex["words"]  # dir, amountIn, profit, gapDet, gapExec, originTs, cbTs, latency
            row.update({"status": "executed", "callback_ts": ex["callback_ts"],
                        "callback_tx": ex["tx"], "gap_bps": w[3], "amount_in": w[1],
                        "profit": w[2], "gap_at_execution": w[4],
                        "full_loop_latency": ex["callback_ts"] - origin_ts,
                        "event_latency": w[7]})
        else:
            row["status"] = "no_exec"
        results.append(row)
        lat = row.get("full_loop_latency")
        print(f"[{i+1}/{N}] {row['status']:9s} gap={row.get('gap_bps')}bps "
              f"latency={lat}s profit={row.get('profit',0)/1e18:.4f}", flush=True)
        time.sleep(1)

    executed = [r for r in results if r["status"] == "executed"]
    lats = [r["full_loop_latency"] for r in executed if r.get("full_loop_latency") is not None]
    summary = {"iterations": N, "executed": len(executed),
               "missed": sum(r["status"] == "no_exec" for r in results),
               "avg_latency_s": sum(lats)/len(lats) if lats else None,
               "min_latency_s": min(lats) if lats else None,
               "max_latency_s": max(lats) if lats else None,
               "total_profit": sum(r.get("profit", 0) for r in executed)}
    out = {"summary": summary, "results": results,
           "addresses": {"reactive": REACTIVE, "executor": EXECUTOR, "poolA": POOL_A,
                         "poolB": origin["poolB"], "token0": origin["token0"], "token1": TOKEN1}}
    (ROOT / "deployments/demo_results.json").write_text(json.dumps(out, indent=2))
    print("\nSUMMARY:", json.dumps(summary, indent=2))
    print("wrote deployments/demo_results.json")


if __name__ == "__main__":
    main()
