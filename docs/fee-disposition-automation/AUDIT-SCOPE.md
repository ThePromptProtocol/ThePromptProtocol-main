# FeeDispositionModule — Audit Scope

Prepared 2026-09-07 for a third-party security audit (CertiK or equivalent). Contact: Matt Lim, The Prompt Protocol.

## 1. Project summary

The Prompt Protocol (BNB Smart Chain, chainId 56) charges a 15% fee when users redeem vPTC (an off-chain balance) for PTC (ERC20). `FeeDispositionModule` automates what happens to that fee: fee PTC is delivered to the contract daily; once its balance reaches a threshold, **anyone** may call `trigger()`, which in one transaction pays the caller a small incentive, burns 30% of the batch to `0x…dEaD`, sells half of the remaining 70% for USDT on PancakeSwap V2, adds liquidity with the other half, and sends the LP tokens to a fixed recipient (the dead address on mainnet, locked by a one-way owner call). No company key is required for the mechanism to function.

## 2. Repository and commit

- Repository: https://github.com/ThePromptProtocol/ThePromptProtocol-main
- Branch: `feat/fee-disposition-automation` (pull request #1)
- Folder: `fee-disposition-module/` (self-contained Foundry project)
- Frozen commit for audit: see the PR head at the time of engagement; the contract file has been unchanged since commit `81c1509` of the module history (fixes from the internal adversarial review), later commits touch only scripts and docs.

## 3. Files in scope

| File | Lines | Notes |
|---|---|---|
| `src/FeeDispositionModule.sol` | ~600 | The only contract with state and value flow |
| `src/interfaces/IPancakeRouter02.sol` | 30 | Minimal router interface |
| `src/interfaces/IPancakeFactory.sol` | 8 | |
| `src/interfaces/IPancakePair.sol` | 14 | Includes `price0/1CumulativeLast` used by the TWAP guard |

Out of scope: `test/`, `script/`, `lib/` (OpenZeppelin v5.1.0 and forge-std v1.16.2 as installed), the backend jobs in `service-thebook`, and `PTCReserveVault` (already deployed; the module only receives plain ERC20 transfers from it).

## 4. Build

```
forge --version   # 1.8.1 used
solc 0.8.28, evm_version shanghai, optimizer on, runs 200, via_ir false
forge build
forge test --no-match-contract Fork                                   # 49 unit/regression/fuzz tests
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-contract Fork   # 7 mainnet-fork tests
```

## 5. External dependencies and assumptions

- PTC `0x7291B049dC9A16bC75BaD51B0e0AA9EA99cCA2fa`: plain OpenZeppelin ERC20 + Ownable, 18 decimals, no fee-on-transfer, no hooks, no blacklist, no native burn (source: `contracts/PromptCoin.sol` in the same repo).
- USDT (BSC) `0x55d398326f99059fF775485246999027B3197955`: standard BEP20, 18 decimals.
- PancakeSwap V2 router `0x10ED43C718714eb63d5aA57B78B54704E256024E`, factory `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73`, PTC/USDT pair `0x056D41E1022Fd21B51E02c819907f1A0385ce423` (0.25% fee). Pool depth at time of writing ≈ 5.1M PTC / 38k USDT, i.e. shallow.
- Funding source: `PTCReserveVault` `0x9e4cEa5045493A667C7D24B9c3c27042f3Bee025` pays the module via its normal `claim()` path, signed by the backend. The module never calls the vault.

## 6. Deployment parameters (mainnet pilot)

Owner (single EOA) `0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C`; `lpRecipient` = `0x000000000000000000000000000000000000dEaD`, to be locked via `lockLpRecipient()` after deployment.

Config: threshold 3,000 PTC (pilot; 50,000 planned), maxBatch 0 (auto-cap from reserves), minIncentive 30 PTC, burnBps 3000, callerIncentiveBps 30, slippageBps 150, minInterval 3600 s, twapWindow 1800 s, maxTwapDeviationBps 300.

## 7. Trust model and invariants we would like verified

Roles: **owner** (setConfig within hard-coded bounds, setLpRecipient until locked, pause/unpause, rescue of tokens other than PTC/USDT/LP); **anyone** (trigger, updateOracle). `renounceOwnership` is disabled.

Invariants:
1. PTC and USDT can leave the contract only through: caller incentive (≤ 5% of a batch by config bounds), burn to the dead address, router swap, router addLiquidity. Never to the owner.
2. LP tokens are minted only to `lpRecipient`; once `lpRecipientLocked`, it can never change.
3. `incentive + burn + swap + pair == batch` exactly (`computeSplit`), and post-run balances reconcile exactly (`_settle`), else revert.
4. Sale and liquidity-add execution prices are bounded below by `TWAP × (1 − maxTwapDeviationBps)`; TWAP derives from the pair's cumulative prices with a two-slot observation scheme that cannot be starved by frequent `updateOracle()` calls.
5. A single-transaction sandwich (dump → trigger → buy back) by a contract caller cannot profit beyond the configured deviation band.
6. No configuration reachable through `setConfig` can permanently brick `trigger()`; large backlogs drain in slices via `_maxSafeBatch`.
7. Reentrancy through any external call (token, router, pair) cannot double-pay the incentive or bypass accounting.

## 8. Known limitations and prior findings

- Internal adversarial review (2026-09-05) produced 8 findings, all fixed with regression tests in `test/Regression.t.sol`; details in `docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md` §10.
- Residual risk accepted: an attacker able to hold the pool price off TWAP for a full `twapWindow` against arbitrage can extract up to `maxTwapDeviationBps` of one batch's sell leg. At current scale this is a few dollars.
- Slither 0.11.6: no High/Medium; remaining informational items triaged in IMPLEMENTATION-NOTES §9.
- Owner is a single EOA by decision; loss of the key freezes configuration but does not stop the mechanism.
- Oracle reference can become stale if no one calls `updateOracle()`; the backend calls it hourly. A genuine >3% move within the window causes a refused run, retried later.

## 9. Documents

- `docs/fee-disposition-automation/PRD-fee-disposition-automation.md` — requirements
- `docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md` — design decisions, math, review findings, Slither triage
- `docs/fee-disposition-automation/DEPLOYMENT-BRIEF-2026-09-05.md` — operations and deployment
- `HANDOFF.md` — verified on-chain facts about PTC, vault, and pool
