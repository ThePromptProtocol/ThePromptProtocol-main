# Fee Disposition Module — handoff (written 2026-09-04 by the Quill chat; continue in a NEW chat opened in this folder)

Goal: build `FeeDispositionModule` per `docs/fee-disposition-automation/PRD-fee-disposition-automation.md`
(30% burn / 70% → PTC-USDT liquidity, permissionless `trigger()` with caller incentive, bootstrap cron fallback).
Nothing has been written yet. Everything below was VERIFIED on 2026-09-04 unless marked "unknown".

## 1. Tooling on this Mac
- Foundry 1.8.1 installed (forge / cast / anvil) at `~/.foundry/bin` — add to PATH: `export PATH="$HOME/.foundry/bin:$PATH"`.
- Node 24 + npx available. NO Hardhat project exists. NO contracts repo exists locally — the engineer's PTC contract repo location is UNKNOWN; ask Matt/engineer where the vault & PTC sources live (they are NOT publicly verified — Sourcify has nothing, Etherscan v2 needs an API key).
- Recommended: `forge init` here (this folder), OpenZeppelin via `forge install`, fork tests against BSC mainnet RPC `https://bsc-dataseed.binance.org` (public; rate-limited — a paid RPC key would be better for CI).

## 2. On-chain facts (BSC mainnet, chainId 56)
| Thing | Address | Verified facts |
|---|---|---|
| PTC token (PromptCoin) | `0x7291B049dC9A16bC75BaD51B0e0AA9EA99cCA2fa` | Plain ERC20 + Ownable (12 selectors only: name/symbol/decimals/totalSupply/balanceOf/transfer/transferFrom/approve/allowance/owner/renounceOwnership/transferOwnership). 18 decimals. totalSupply 10,000,000,000. **NO fee-on-transfer** (fork test: sent 1,000 → received exactly 1,000; totalSupply unchanged). **NO native burn()** → burn = transfer to `0x000000000000000000000000000000000000dEaD`. Plain `swapExactTokensForTokens` is fine (no fee-on-transfer variants needed). |
| PTCReserveVault | `0x9e4cEa5045493A667C7D24B9c3c27042f3Bee025` | Functions recovered from bytecode: `claim(address,uint256,bytes32,uint256,bytes)`, `batchClaim(address[],uint256[],bytes32[],uint256[],bytes[])`, `deposit(uint256)`, `setSigner(address)`, `claimSigner()`, `setCaps(uint256,uint256)`, `perTxCap()`, `dailyCap()`, `pause()/unpause()/paused()`, `guardian()/setGuardian`, `proposeEmergencyWithdraw(address,uint256)/executeEmergencyWithdraw()/cancelEmergencyWithdraw()/emergencyWithdrawDelay()`, `vaultBalance()`, `totalWithdrawn()`, `usedRequestId(bytes32)`, `eip712Domain()`, `owner()`, `renounceOwnership`, `transferOwnership`; 3 unresolved selectors `0x09dc1c33 0x2e64db75 0x68e5aa43` (one is probably the `hasWithdrawnToday`-style check the backend calls). **There is NO fee-recipient / fee logic in the vault at all.** owner() = `0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C` (an EOA — the address Matt calls "node stake collection"; NOT a multisig despite an older note). paused()=false. Balance ~506k PTC and falling ~17k/day (redemptions). |
| PancakeSwap V2 router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | standard |
| PancakeSwap V2 factory | `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` | standard |
| USDT (BSC) | `0x55d398326f99059fF775485246999027B3197955` | 18 decimals on BSC |
| PTC/USDT V2 pair | `0x056d41e1022fd21b51e02c819907f1a0385ce423` | reserves ~5.10M PTC / ~38.2k USDT → ~$0.0075. SHALLOW: slippage + sandwich exposure are real. |
| Distribution wallet (contract) | `0xbB7309e8798b2Ae40592DB315C1a14E64715A53c` | holds 99.41% of PTC — useful as the impersonated funding source in fork tests (`vm.prank` / `anvil_impersonateAccount`). |

## 3. The PRD's core assumption is WRONG — the fee is not on-chain PTC
Redemption flow (service-thebook `VptcWithDrawService` + `PTCVaultTools`): the user's vPTC is debited in the DB (`subUserVptcV2`), the 15% fee is recorded off-chain on `user_vptc_record` (`feeRate`, `feeNumber`), and the vault `claim()` is signed for **`realNumber` = the NET amount**. So the fee never leaves the vault as a PTC transfer — it simply stays in the vault as PTC that is no longer owed to anyone. Nothing "sends the fee anywhere".

Funding-path options for the module (decision needed — put to Matt/engineer):
- **(a) Recommended, automatic, no vault change:** the backend already holds the vault `claimSigner` key and a relayer key. Add a daily job that sums completed-redemption `feeNumber` for the day and signs ONE `claim(to = FeeDispositionModule, amount = feeSum, requestId, deadline)` → vault pays the fee PTC to the module. Uses existing authority, no new key, no vault redeploy. MUST CONFIRM against vault source: does `claim` restrict `to`/`msg.sender`? do `perTxCap`/`dailyCap`/`hasWithdrawnToday` (one claim per address per UTC day) constrain it? A contract recipient is fine for ERC20 transfers.
- (b) Modify the vault to forward fees → needs source + re-audit; PRD explicitly wants to avoid this.
- (c) Manual owner transfer → defeats the PRD's purpose; only as bridge.

## 4. Economics warning (flag to Matt before design freeze)
Fee volume ≈ 15% of ~20k PTC/day gross ≈ **~3,000 PTC/day ≈ $22/day**. Caller incentive at the PRD's 20–50 bps of a ~3k batch = 6–15 PTC ≈ **$0.05–0.11**, versus BSC gas for burn+swap+addLiquidity ≈ **$0.30–1.00**. No external keeper will ever call it at these sizes. Options: (i) threshold sized to weeks of fees (e.g. 50k–100k PTC), (ii) a MINIMUM absolute incentive (e.g. `minIncentivePTC`) so the caller is always made whole, (iii) accept that the bootstrap cron carries it for now. Recommend (i)+(ii). Needs Matt's decision.

## 5. Decisions still open (from the PRD's "sensitive points") + recommendations
1. Incentive paid **off the top in PTC before the split** (recommended: simplest, exact 30/70 on the remainder, no extra USDT transfer) vs from USDT after swap.
2. `lpRecipient` must be a real, final address — dead address if LP-burn is decided, a lock contract if lock; NEVER default to a mutable EOA. Make it a required constructor arg; deploy script must refuse zero/EOA.
3. `threshold` default — see §4. `slippageBps` default 100–200, tune on fork against the real pool.
4. MEV: consider a minimum interval between triggers and/or letting the caller pass `amountOutMin` bounded by the on-chain quote − slippage (never a hardcoded min).
5. Funding path — §3(a) needs engineer confirmation with the vault source.

## 6. Build plan (for the new chat)
1. `forge init --no-git` here; `forge install OpenZeppelin/openzeppelin-contracts`; pin solc 0.8.2x.
2. `src/FeeDispositionModule.sol`: Ownable2Step, ReentrancyGuard, SafeERC20; immutable PTC/USDT/router/dead; state per PRD; `trigger()` = checks-effects-interactions, all amounts computed from the contract's PTC balance at call time, assertion that post-run PTC balance == 0 (or dust bound), single event with every amount; `IPancakeRouter02` minimal interface (`getAmountsOut`, `swapExactTokensForTokens`, `addLiquidity`).
3. Tests (Foundry): pure split math to the wei across sizes (fuzz); revert below threshold; any-EOA can call; incentive once; reentrancy attempt via malicious token/callback; slippage revert; **fork test** on BSC: deal PTC from the distribution wallet to the module, cross threshold, call from a random EOA, assert dead-address delta, pair reserves moved, LP landed at `lpRecipient` only, module balance 0.
4. `slither .` and triage.
5. Bootstrap cron: service-thebook (it already holds `ptcRelayerKey` + `ptcClaimSignerKey` from nacos) — scheduled job that (a) if §3(a) adopted, signs the daily fee claim to the module, (b) calls `trigger()` if callable; never errors when below threshold; keys only from config, never in repo.
6. Docs: keep the PRD in `docs/fee-disposition-automation/`; add a bilingual engineer note (中文 first, English after, ☐ checklist) when handing over — see memory `engineer-note-format`.

## 7. Repo/process rules that apply
Branch from the engineer's base (`dev`) as `feat/fee-disposition-automation`; never commit to dev/master; never commit keys; PRD must live in `docs/<feature>/`; commits Conventional + Chinese description. Matt's standing principle: every operational parameter (threshold, bps, slippage, recipients) must be owner-configurable, nothing hardcoded.
