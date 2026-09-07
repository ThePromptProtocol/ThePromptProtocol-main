# PRD — Fee Disposition Automation

- Date: 2026-09-04
- Proposed by: Matt (founder, generated via AI chat)
- Status: pending engineer review
- Affected repos: `<PTC smart-contract repo>` — new module/contract · `<backend service>` — bootstrap caller job, no changes to redemption flow logic itself · `<PTCReserveVault integration point>` — confirm fee-forwarding path (see Sensitive Points)

---

## Background (Why)

Today the 15% redemption fee (vPTC→PTC) is sold for cash and treated as the company's only revenue mechanism. That's being downgraded from "the model" to "a bridge" — see the Tokenomics & Policy doc, Revenue Model and Fee Disposition sections. Once the fee stops being counted as revenue, its proceeds need somewhere to go that's provable on-chain rather than dependent on a person remembering to act. Decided split: **30% burned, 70% used to deepen the PTC/USDT liquidity pool** (sell half of the 70% for USDT, pair with the remaining PTC, add liquidity — LP tokens never withdrawn).

Doing this manually (send to dead address, swap on PancakeSwap, add liquidity, three separate actions by a person) is exactly the kind of "trust us" mechanism the rest of this token's design has been trying to move away from — the same reasoning behind burning or locking the LP tokens instead of just holding them. This PRD automates it.

## Goal

A smart contract mechanism that, once accumulated redemption-fee PTC crosses a threshold, executes the full 30/70 split — burn, swap, pair, add liquidity — in one atomic call, triggerable by **anyone**, with a small incentive paid to whoever calls it. No company key required for the mechanism to function; a company-run scheduled call exists only as a bootstrap fallback until the call is reliably picked up by outside bots.

## Approach

**New contract: `FeeDispositionModule`** (companion contract, not a modification of `PTCReserveVault`'s core redemption logic — keeps blast radius small and avoids touching audited code that's already live).

**State:**
| Variable | Purpose | Notes |
|---|---|---|
| `accumulatedFeePTC` | PTC balance held by this contract, pending disposition | Funded by fee transfers — see Sensitive Points on the integration path |
| `threshold` | Minimum accumulated PTC before `trigger()` becomes callable | Owner/Admin-multisig configurable; propose a starting value sized to ~1 day of typical fee volume |
| `burnBps` | 3000 (30.00%) | Owner/Admin-multisig configurable, default fixed at this value |
| `liquidityBps` | 7000 (70.00%) | Derived as `10000 - burnBps` |
| `callerIncentiveBps` | Reward paid to whoever calls `trigger()`, taken from the batch | Propose default 20–50 bps (0.2–0.5%) — must exceed typical BSC gas cost for the call by a comfortable margin, or no bot will bother |
| `lpRecipient` | Address that receives LP tokens from `addLiquidity` | **Not** the caller. Should point at whatever address the LP-burn-or-lock decision (open item in the policy doc) resolves to — this PRD does not decide burn vs. lock, it just needs a fixed destination address as an input |
| `slippageBps` | Max acceptable slippage on the swap and the liquidity add | Propose default 100–200 bps (1–2%); needs real testnet tuning against actual pool depth |

**`trigger()` — permissionless, callable by any address once `accumulatedFeePTC >= threshold`:**
1. Read `accumulatedFeePTC`, compute `burnAmount = accumulatedFeePTC * burnBps / 10000`.
2. Compute `liquidityPortion = accumulatedFeePTC - burnAmount`; split it in half: `swapAmount = liquidityPortion / 2`, `pairAmount = liquidityPortion - swapAmount`.
3. Compute `incentiveAmount = accumulatedFeePTC * callerIncentiveBps / 10000`, paid to `msg.sender` — decide (flagged below) whether this comes off the top in PTC before the split, or out of the resulting USDT after the swap.
4. Send `burnAmount` PTC to the burn address (`0x000...dEaD`, or call the token's native burn function if PTC supports one — confirm which).
5. Swap `swapAmount` PTC for USDT via the PancakeSwap Router (`swapExactTokensForTokens`), with `amountOutMin` computed from `router.getAmountsOut()` at call time minus `slippageBps` — never a hardcoded minimum.
6. Call `addLiquidity` with `pairAmount` PTC and the USDT just received, `amountMin` values on both sides again derived from current reserves minus `slippageBps`, `to = lpRecipient`.
7. Reset `accumulatedFeePTC` to zero (minus whatever was paid out as burn/swap/incentive/liquidity — should net to zero, add an assertion).
8. Emit an event with every computed amount, for the Treasury & Reporting dashboard to pick up.

**Funding path (needs confirmation against the actual live `PTCReserveVault` code — flagged below):** ideally the vault's redemption function sends the 15% fee straight to `FeeDispositionModule`'s address instead of (or via) whatever wallet currently receives it, so `accumulatedFeePTC` grows automatically on every redemption with no separate step.

**Bootstrap caller (small piece, backend repo):** a scheduled job (daily) signed by the Relayer key that calls `trigger()` if it's callable and hasn't been called externally — pure fallback, forgoes the incentive to whichever bot beats it, exists only so the mechanism doesn't stall while waiting for organic keeper-bot discovery in the early weeks.

## Acceptance criteria

- [ ] `FeeDispositionModule` deployed on testnet, verified on BscScan
- [ ] `trigger()` reverts below threshold, succeeds at/above it, callable from any address (test with a non-owner wallet)
- [ ] Burn, swap, and addLiquidity amounts match the 30/70 split (and the 50/50 sub-split of the 70%) to the wei, across a range of `accumulatedFeePTC` sizes including very small and very large
- [ ] Caller incentive paid correctly and only once per trigger; contract balance nets to zero after each run (assertion test)
- [ ] Swap and liquidity-add both revert cleanly if slippage exceeds `slippageBps` rather than executing at a bad price
- [ ] Reentrancy test: `trigger()` cannot be re-entered mid-execution to drain funds or double-pay the incentive
- [ ] LP tokens land at `lpRecipient` and nowhere else
- [ ] Bootstrap cron job calls `trigger()` correctly and does not error when the threshold hasn't been met
- [ ] Full test suite green; static analysis (Slither) run and findings triaged
- [ ] Local end-to-end on testnet: accumulate fee → cross threshold → external wallet calls `trigger()` → verify burn address balance, pool reserves, and `lpRecipient` LP balance all moved correctly

## Sensitive points for technical review

- **Integration with the live `PTCReserveVault`.** This PRD assumes the vault can be pointed at a new fee-recipient address without redeploying or re-auditing its core logic. If the current contract hardcodes the fee destination, this needs its own smaller change (and its own review) before `FeeDispositionModule` has anything to act on. Needs the actual current source, not this spec, to confirm.
- **This contract moves money automatically and permissionlessly — it needs its own audit pass before mainnet**, same bar as anything else touching the vault. Do not treat "it's just a companion contract" as a reason to skip that.
- **MEV/sandwich exposure on the swap.** Any on-chain swap of a predictable size at a predictable-ish time is a sandwich target. `slippageBps` is the main defense; consider whether the trigger condition should have some randomization or a minimum-frequency cap so batch sizes aren't perfectly predictable.
- **Incentive amount tuning.** Too low and no bot bothers (mechanism stalls, bootstrap cron carries all the weight, undermining the point of doing this permissionlessly); too high and it's a real ongoing cost. Needs real BSC gas-price data to size correctly, not a guess.
- **Where the incentive is paid from** (PTC off the top vs. USDT after the swap) changes the exact math of the 30/70 split slightly — needs an explicit decision, not left implicit in the code.
- **`lpRecipient` must exist and be correct before this ships.** The burn-vs-lock decision for LP tokens is still an open item in the policy doc — this contract just needs a valid address, but shipping this before that decision is made risks LP tokens landing at a throwaway or mutable address by default.
- **PTC transfer-fee behavior.** If PTC has any transfer tax or fee-on-transfer mechanic, the router calls need the fee-on-transfer-safe variants (`swapExactTokensForTokensSupportingFeeOnTransferTokens`), or amounts will be silently wrong. Confirm PTC's actual token contract behavior before implementation.

## Explicitly out of scope

- The burn-vs-lock decision for the resulting LP tokens (separate open decision, tracked in the Tokenomics & Policy doc)
- Formal integration with a third-party keeper network (Chainlink Automation / Gelato) — the bootstrap cron job is the v1 fallback; a keeper network can replace it later without changing `FeeDispositionModule` itself
- Any change to the 15% redemption fee rate, or to how much of it is diverted here vs. kept as operating cash during the bridge period (that trigger — brand take-rate covering 50% of opex — is a policy decision, not part of this build)
- Brand vPTC pricing, dividend policy, and the external de-identification standard (all separate open items in the policy doc, unrelated to this mechanism)
