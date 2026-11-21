![SUBSECOND](assets/subsecond-logo.svg)

**A sub-second arbitrage reflex on Reactive Omni.** Two AMM pools on Base Sepolia (200ms blocks) drift apart for a fraction of a second; a reactive contract on Reactive Lasna (~1s blocks, instant finality) sees the gap in the event log and fires an authenticated callback that closes it — *before the window shuts*.

Built for the **Reactive Omni Buildathon · "Every Second Counts"** track.

> The thesis is not "arbitrage". It is that **the profit only exists inside a sub-second window**, and that window is only reachable because Omni cut Reactive blocks from ~7s to ~1s. The dashboard measures the full loop and shows, per opportunity, whether a ~7s legacy reaction would have missed it.

---

## Why this is antimainstream

Most time-sensitive DeFi entries are passive monitors or bots that *alert*. SUBSECOND is an **autonomous on-chain reflex**: the decision lives in a reactive contract, the action lives in a callback contract, and the whole loop is provably latency-bound. The destination contract re-reads reserves when the callback lands and reports **`ArbMissed`** if the gap already closed — so the system itself demonstrates the race it is built to win.

## Architecture

```
        Base Sepolia (origin, 200ms blocks)                 Reactive Lasna (~1s, instant finality)
        ┌───────────────┐   Sync(reserve0,reserve1,ts)      ┌──────────────────────────┐
        │  Pool A (x*y=k)│ ───────────────────────────────► │  SubsecondReactive        │
        └───────────────┘                                   │  • rebuilds prices from   │
        ┌───────────────┐   Sync(reserve0,reserve1,ts)      │    logs alone             │
        │  Pool B (x*y=k)│ ───────────────────────────────► │  • gap > fee threshold?   │
        └───────────────┘                                   │  • requestCallbackV_1_0   │
                                                            └─────────────┬────────────┘
        Base Sepolia (destination)                                        │ authenticated callback
        ┌───────────────────────────────────────────────────────────────▼────────────┐
        │  ArbExecutor (AbstractCallback)                                              │
        │  • onlyServiceProvider + onlyCallbackSender                                  │
        │  • re-reads reserves; if gap closed → ArbMissed                              │
        │  • else optimal-size two-leg swap → ArbExecuted(profit, fullLoopLatency)     │
        └──────────────────────────────────────────────────────────────────────────────┘
```

| Contract | Chain | Role |
|---|---|---|
| `MockToken` (sWETH / sUSDC) | Base Sepolia | the two pool assets |
| `ConstantProductPool` ×2 | Base Sepolia | origin event source; emits `Sync` with reserves + origin timestamp |
| `SubsecondReactive` | Reactive Lasna | subscribes to both pools' `Sync`, reconstructs prices, detects the gap, requests the callback |
| `ArbExecutor` | Base Sepolia | authenticated callback; closes the gap with a profit-maximising two-leg swap, measures latency |

### The full-loop latency metric
`fullLoopLatency = callback block.timestamp − origin Swap block.timestamp`. Both timestamps are on **Base Sepolia**, so they are directly comparable; the Reactive hop is what fills the gap. The demo runner records this for every opportunity and the dashboard plots it against the legacy ~7s window.

## Judging criteria

- **Execution** — real reactive transactions and on-chain callbacks. `scripts/demo.py` drives the loop on testnet and records origin → react → callback transaction hashes and timestamps. (Deployed addresses + tx hashes below once live.)
- **Integration** — the reactive contract does the real work: it reconstructs both pool prices from `Sync` logs alone (no cross-chain state read), computes the gap and direction, and decides to fire. The callback is the action, not a bolt-on.
- **Usefulness** — sub-second cross-pool arbitrage / gap-closing is a real DeFi need that ~7s automation cannot serve; the system quantifies exactly which opportunities require ~1s finality.
- **Craft** — readable, commented Solidity; a 6-test Foundry suite covering detection, the profitable loop, the missed-window branch and all auth guards; an elegant live dashboard; reproducible deploy + demo scripts.

## Run it

Prereqs: [Foundry](https://getfoundry.sh), Python 3.11 with `web3`, a deployer key funded with Base Sepolia ETH (and lREACT on Lasna via the faucet).

```bash
forge build && forge test          # compile + 6 passing tests (no funds needed)

export DEPLOYER_KEY=0x...
./scripts/deploy.sh                # origin (Base Sepolia) + reactive (Lasna) + funding
python3 scripts/demo.py 8          # drive 8 loops, measure latency → deployments/demo_results.json

python3 -m http.server 8080   # from the repo root → dashboard at http://localhost:8080/frontend/
```

> Serve from the **repo root**, not `frontend/` — the dashboard reads `deployments/`
> and the brand assets via relative paths; serving only `frontend/` leaves the KPIs empty.

`deploy.sh` predicts the Lasna reactive address from the deployer nonce so the executor's immutable `callbackSender` binds correctly, deploys both sides, funds the reactive contract with lREACT (payable constructor) and the executor with ETH for callback gas.

## Networks

| Chain | ID | RPC | Callback proxy |
|---|---|---|---|
| Base Sepolia | 84532 | https://sepolia.base.org | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Reactive Lasna | 5318007 | https://lasna-rpc.rnk.dev/ | `0x8888888888888888888888888888888888888888` |

Omni patterns: `AbstractReactive` / `AbstractCallback` from [`Reactive-Network/reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni), `SYSTEM.subscribe(...)`, `react(LogRecord) onlySystem`, `SYSTEM.requestCallbackV_1_0(...)`.

## Deployed contracts

| Contract | Chain | Address |
|---|---|---|
| `SubsecondReactive` | Reactive Lasna | [`0x46dc3D0d1b1628426b8bd42cB4f02eC7FD1CE24F`](https://lasna.reactscan.net/address/0x46dc3D0d1b1628426b8bd42cB4f02eC7FD1CE24F) |
| `ArbExecutor` | Base Sepolia | [`0xE93061B12B68199B44F572dE30Dc5Cca992AD713`](https://sepolia.basescan.org/address/0xE93061B12B68199B44F572dE30Dc5Cca992AD713) |
| `ConstantProductPool` A | Base Sepolia | [`0xA3Dc90527f404019024444dbD19E22215750f4Eb`](https://sepolia.basescan.org/address/0xA3Dc90527f404019024444dbD19E22215750f4Eb) |
| `ConstantProductPool` B | Base Sepolia | [`0x69C5d823066904221415888927Db6D79334D6fe3`](https://sepolia.basescan.org/address/0x69C5d823066904221415888927Db6D79334D6fe3) |
| `MockToken` sWETH | Base Sepolia | [`0x46dc3D0d1b1628426b8bd42cB4f02eC7FD1CE24F`](https://sepolia.basescan.org/address/0x46dc3D0d1b1628426b8bd42cB4f02eC7FD1CE24F) |
| `MockToken` sUSDC | Base Sepolia | [`0x77E7bE8c2F4e5b31a917Ef2bdF726154CF828630`](https://sepolia.basescan.org/address/0x77E7bE8c2F4e5b31a917Ef2bdF726154CF828630) |

## Demo video

🎬 **[assets/subsecond-motion-vo.mp4](assets/subsecond-motion-vo.mp4)** — 33s narrated motion demo (1080p): the sub-second window, the reflex arc, and the measured live run.

## Measured result — a live run of 5 loops

Every opportunity below is a real origin → reactive → callback loop on testnet; the reactive
transaction and the callback transaction both exist on-chain.

| # | gap at detection (bps) | full-loop latency | profit (sUSDC) | status |
|---|---|---|---|---|
| 1 | 1031 | 2s | 459.02 | EXECUTED |
| 2 | 1009 | 1s | 448.83 | EXECUTED |
| 3 | 987 | 1s | 439.07 | EXECUTED |
| 4 | 967 | 1s | 429.72 | EXECUTED |
| 5 | 947 | 2s | 420.76 | EXECUTED |

**5 / 5 captured · average full-loop latency 1.4s · range 1–2s · total profit 2,197.39 sUSDC.**

Example loop (iteration 1):
- origin shock swap (Base Sepolia): [`0x4d42cca1…ee81`](https://sepolia.basescan.org/tx/0x4d42cca1bff707e17f1ef5c4b3fc6e8886b92e81e1ebd3d92a036ea3f7e3ee81)
- reactive detect + callback (Lasna): the reactive contract's `GapDetected` / `CallbackRequested` at [`0x46dc…E24F`](https://lasna.reactscan.net/address/0x46dc3D0d1b1628426b8bd42cB4f02eC7FD1CE24F)
- arb callback (Base Sepolia): [`0x579cad26…b7c0`](https://sepolia.basescan.org/tx/579cad2603b9045a3e652f6bd67cd96112929cfa91e93fef77de542cf0eeb7c0)

With a ~7s legacy reaction these ~1s windows would already have closed; Omni's ~1s reaction
lands inside them. Full JSON in `deployments/demo_results.json`.

## License
MIT
