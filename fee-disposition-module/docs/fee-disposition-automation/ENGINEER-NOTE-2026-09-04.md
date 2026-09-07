主题 / TOPIC：手续费处置合约 FeeDispositionModule — 首版交付待审 / FeeDispositionModule (30% burn / 70% liquidity) — v1 ready for review
时间：2026-09-04 23:10 (GMT+8)

———

【中文】

已完成
仓库：~/ThePromptProtocol/fee-disposition-module（独立 Foundry 项目，尚无远程；建议放进合约仓库或单独建仓）
分支：feat/fee-disposition-automation
提交：1c1d4d3（合约 + 测试 + 脚本 + 文档）
需求文档：docs/fee-disposition-automation/PRD-fee-disposition-automation.md
实现说明：docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md（请先看这份，PRD 悬而未决的点都在里面给了决定和理由）

做了什么
1. src/FeeDispositionModule.sol：Solidity 0.8.28 + OpenZeppelin 5.1.0。Ownable2Step / ReentrancyGuard / Pausable。任何人可调 trigger(minUsdtOut)：激励先从整批扣（PTC）、剩余按 burnBps 拆、70% 的一半卖成 USDT、与另一半 addLiquidity，LP 打到 lpRecipient。每次逐项对账，账对不上直接 revert。
2. 参数全部 owner 可改（setConfig）：threshold、maxBatch、minIncentive、burnBps、callerIncentiveBps、slippageBps、minInterval。PRD 之外多了三个：minIncentive（激励绝对下限，否则小批次没人来调）、maxBatch（积压太多时分批消化，不砸池）、minInterval（PRD 建议的最小频率）。
3. owner 不能取走 PTC / USDT（rescueToken 明确拒绝），只能 pause。
4. 测试：单元 31 项 + fuzz 全绿；BSC 主网 fork 端到端 4 项全绿（真实 PTC、真实 PancakeSwap 池、随机 EOA 调用 → 黑洞增量、池子变深、LP 只到 lpRecipient、合约只剩尘埃）。
5. Slither 0.11.6：无 High / Medium；divide-before-multiply 已修，其余 Informational 已逐条分类写在实现说明 §9。
6. 脚本：script/Deploy.s.sol（参数全走环境变量，EOA 作 lpRecipient 会被拒绝）、script/Trigger.s.sol 与 script/bootstrap-trigger.sh（引导 cron 参考实现，供后端照抄逻辑）。

链上实测（2026-09-04）
- trigger() gas ≈ 466k；BSC gas price 0.05 gwei，BNB ≈ $713 → 一次调用成本 ≈ $0.017
- PTC ≈ $0.0075；池子 5.10M PTC / 38.2k USDT
- 脚本默认：阈值 50,000 PTC（≈17 天手续费）、激励 30 bps 且下限 150 PTC（≈ $1.12）、滑点 150 bps、间隔 1 小时

⚠️ PRD 的核心假设不成立，需要你确认资金来源
15% 赎回手续费只在 DB 记账（user_vptc_record.feeNumber），vault 的 claim() 签的是净额，手续费 PTC 从未离开 vault，不存在「vault 转手续费给模块」这条路。推荐方案：后端每日任务把当天已完成赎回的 feeNumber 求和，用现有 claimSigner 签一笔 claim(to = 模块地址, amount = feeSum)。不改 vault、不加 key。需要你对照 vault 源码确认：claim 是否限制 to / msg.sender，perTxCap / dailyCap / 每地址每日一次是否卡住，合约地址作为 to 是否允许。

工程师待办 / Engineer to-do
☐ 1. 审阅 src/FeeDispositionModule.sol（逐行；涉及资金自动流转，按 10-测试规范 §5.4 标准）
☐ 2. 用 vault 源码确认上面「资金来源」的三个问题，回复能否走「每日 claim 到模块」方案
☑ 3. lpRecipient 已定：LP 销毁，部署时 LP_RECIPIENT=0x000000000000000000000000000000000000dEaD（Matt 2026-09-04 拍板，无需再议）
☐ 4. 和 Matt 定阈值 / minIncentive 两个数（实现说明 §5 有经济性数据）
☐ 5. 在 service-thebook 加两个定时任务：(a) 每日 fee claim 到模块；(b) 每日 canTrigger() → 为 true 时 previewTrigger() 算 minUsdtOut 再发 trigger()。逻辑照 script/Trigger.s.sol；key 只从 nacos 取
☐ 6. 决定合约代码放哪个仓库（把本目录整体挪进去，保留提交记录即可）
☐ 7. 测试网部署 + BscScan 验证（forge script script/Deploy.s.sol … --verify）
☐ 8. 安排审计（合约自动、无权限地动钱，PRD 明确要求过审计再上主网）

回归测试重点
- 阈值以下 revert、随机 EOA 可调、激励只付一次
- 池子深度变化：PTC 与 k 变深，USDT 基本持平（机制是卖出再加回，不是净买入）
- maxBatch 分批消化大额积压；PriceImpactTooHigh 在批次过大时 revert

———

【English】

Done
Repo: ~/ThePromptProtocol/fee-disposition-module (standalone Foundry project, no remote yet; suggest moving it into the contracts repo or creating one)
Branch: feat/fee-disposition-automation
Commit: 1c1d4d3 (contract + tests + scripts + docs)
PRD: docs/fee-disposition-automation/PRD-fee-disposition-automation.md
Implementation notes: docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md (read this first: every open point in the PRD has a decision and a reason there)

What was built
1. src/FeeDispositionModule.sol: Solidity 0.8.28 + OpenZeppelin 5.1.0. Ownable2Step / ReentrancyGuard / Pausable. Anyone can call trigger(minUsdtOut): incentive comes off the top in PTC, the remainder is split by burnBps, half of the 70% is sold for USDT and paired with the other half via addLiquidity, LP goes to lpRecipient. Every run reconciles balances line by line and reverts on any mismatch.
2. All parameters are owner-configurable (setConfig): threshold, maxBatch, minIncentive, burnBps, callerIncentiveBps, slippageBps, minInterval. Three additions beyond the PRD: minIncentive (absolute floor, otherwise nobody calls small batches), maxBatch (drain a big backlog in slices instead of dumping on the pool), minInterval (the minimum-frequency cap the PRD suggested).
3. The owner cannot withdraw PTC or USDT (rescueToken refuses both); the only emergency lever is pause.
4. Tests: 31 unit tests + fuzz green; 4 BSC mainnet fork end-to-end tests green (real PTC, real PancakeSwap pool, random EOA caller → dead-address delta, pool deepened, LP only at lpRecipient, module left with dust only).
5. Slither 0.11.6: no High / Medium; divide-before-multiply fixed, remaining informational items triaged one by one in implementation notes §9.
6. Scripts: script/Deploy.s.sol (all params via env, refuses an EOA as lpRecipient), script/Trigger.s.sol and script/bootstrap-trigger.sh (bootstrap cron reference logic for the backend to mirror).

On-chain measurements (2026-09-04)
- trigger() gas ≈ 466k; BSC gas price 0.05 gwei, BNB ≈ $713 → one call ≈ $0.017
- PTC ≈ $0.0075; pool 5.10M PTC / 38.2k USDT
- Script defaults: threshold 50,000 PTC (≈17 days of fees), incentive 30 bps with a 150 PTC floor (≈ $1.12), slippage 150 bps, interval 1 hour

⚠️ The PRD's core assumption does not hold; funding path needs your confirmation
The 15% redemption fee is only recorded in the DB (user_vptc_record.feeNumber); the vault claim() is signed for the net amount, so fee PTC never leaves the vault. There is no "vault forwards the fee to the module" path. Recommended: a daily backend job sums feeNumber of completed redemptions and signs one claim(to = module, amount = feeSum) with the existing claimSigner. No vault change, no new key. Please confirm against the vault source: does claim restrict to / msg.sender, do perTxCap / dailyCap / one-claim-per-address-per-day block it, and is a contract address allowed as to.

Engineer to-do
☐ 1. Review src/FeeDispositionModule.sol line by line (it moves funds automatically; same bar as vault code)
☐ 2. Answer the three funding-path questions above against the vault source; confirm whether "daily claim to module" is viable
☑ 3. lpRecipient decided: LP burn, deploy with LP_RECIPIENT=0x000000000000000000000000000000000000dEaD (Matt, 2026-09-04, settled)
☐ 4. Settle threshold / minIncentive with Matt (economics in implementation notes §5)
☐ 5. Add two scheduled jobs in service-thebook: (a) daily fee claim to the module; (b) daily canTrigger() → if true, previewTrigger() to compute minUsdtOut, then send trigger(). Mirror script/Trigger.s.sol; keys only from nacos
☐ 6. Decide which repo hosts the contract code (move this folder in wholesale, keep the history)
☐ 7. Testnet deploy + BscScan verification (forge script script/Deploy.s.sol … --verify)
☐ 8. Schedule the audit (the contract moves money permissionlessly; the PRD requires an audit before mainnet)

Regression focus
- Reverts below threshold, callable by a random EOA, incentive paid exactly once
- Pool depth: PTC and k increase, USDT roughly flat (the mechanism sells then adds back; it is not a net buy)
- maxBatch drains a large backlog in slices; PriceImpactTooHigh reverts when a batch is too big for the pool
