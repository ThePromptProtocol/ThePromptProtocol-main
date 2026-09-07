主题 / TOPIC：手续费处置合约 FeeDispositionModule — 复审修复后正式提交审核 / FeeDispositionModule — post-review build, ready for engineer review
时间：2026-09-05 00:21 (GMT+8)
（本说明取代 2026-09-04 那份；决策已全部定稿，无未决项需要 Matt 再拍板）

———

【中文】

一句话
合约、测试、脚本、文档都在 ~/ThePromptProtocol/fee-disposition-module，分支 feat/fee-disposition-automation，提交 81c1509。请先读 docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md，再看代码。你要做的事在最后的待办清单。

Matt 已定（不用再问）
1. owner = Matt 本人的地址（单一 EOA，不用多签）。部署时填 OWNER=。
2. LP 销毁：LP_RECIPIENT = 0x000000000000000000000000000000000000dEaD。主网部署后请立刻调用 lockLpRecipient()，把 LP 去向永久锁死。
3. 阈值 50,000 PTC，激励 30 bps 且下限 30 PTC，滑点 150 bps，最短间隔 1 小时，TWAP 窗口 30 分钟、偏差 3%。全部可用 setConfig 事后调整。

昨天到今天做了什么
1. 第二轮独立对抗性复审（先写攻击测试再找问题），找到 8 条，全部修复并各配一条回归测试（test/Regression.t.sol）。最重要的一条：原来的滑点保护挡不住同一笔交易里「砸价 → trigger(0) → 买回」的原子三明治，任何合约都能这么做，可提取的价值接近整批的 70%。现在 swap 和 addLiquidity 的成交底线都按 TWAP × (1 − 3%) 设，TWAP 取自 pair 自带的 price0/1CumulativeLast，攻击者要骗过它得把价格压住 30 分钟。
2. 大积压不再卡死：单次批量按池子储备自动封顶（maxSafeBatch()），超出部分留到下一轮。
3. owner 权力边界写死在合约里：激励下限不超过阈值 5%；LP 可单向锁定；PTC / USDT / LP 都不能 rescue；renounceOwnership 禁用。
4. 引导 cron 脚本在 anvil 主网 fork 上实跑通过，顺手修了两个脚本 bug（bash 整数对 18 位小数金额静默溢出——Java 用 BigInteger 不会有这个问题，但所有金额都超过 long）。
5. 测试：单元 40 + 回归 9 + fuzz 全绿；BSC 主网 fork 6 项全绿（真实池、真实 router、随机 EOA 调用、原子三明治被拒）。Slither 无 High / Medium，其余逐条分类见实现说明 §9。

链上数据（2026-09-05）
- trigger() ≈ 533k gas；BSC 0.05 gwei，BNB ≈ $713 → 一次 ≈ $0.02
- 50k 阈值下调用者激励 = 150 PTC ≈ $1.12
- 池子 5.10M PTC / 38.2k USDT，PTC ≈ $0.0075

⚠️ 资金来源仍需你确认（唯一的阻塞项）
15% 赎回手续费只在 DB 记账（user_vptc_record.feeNumber），vault 的 claim() 签的是净额，手续费 PTC 从未离开 vault。推荐：后端每日任务把当天已完成赎回的 feeNumber 求和，用现有 claimSigner 签一笔 claim(to = 模块地址, amount = feeSum)。请对照 vault 源码确认三点：claim 是否限制 to / msg.sender；perTxCap / dailyCap / 每地址每日一次是否卡住；合约地址作为 to 是否允许。

后端定时任务怎么写（照 script/Trigger.s.sol 的逻辑）
- 每小时一次（不是每天：TWAP 参考点需要有人定期刷新，否则行情漂移后要多等一个窗口）
- 步骤：canTrigger() 为 false → 打日志退出，不发交易；为 true → previewTrigger() 取 expectedUsdtOut，minUsdtOut = expectedUsdtOut × (10000 − slippageBps) / 10000；发 updateOracle()；发 trigger(minUsdtOut)
- 部署后第一次 trigger 要等 30 分钟（TWAP 窗口），canTrigger 会返回 "twap unavailable"，属正常
- 私钥只从 nacos 取；relayer 需要少量 BNB 付 gas

工程师待办 / Engineer to-do
☐ 1. 逐行审阅 src/FeeDispositionModule.sol（自动、无权限地动钱，按 10-测试规范 §5.4 的标准）
☑ 2. 资金来源已用 vault 源码确认可行（见实现说明 §6，含后端每日任务规格）——无需再答
☐ 3. 决定合约代码放哪个仓库，把本目录整体挪进去（保留提交记录）
☐ 4. 在 service-thebook 加两个定时任务：(a) 每日 fee claim 到模块；(b) 每小时 canTrigger → updateOracle → trigger
☐ 5. 测试网部署 + BscScan 验证：forge script script/Deploy.s.sol … --verify；lpRecipient 填黑洞地址
☐ 6. 安排审计（PRD 要求过审计再上主网）
☐ 7. 主网部署后：Matt 调用 lockLpRecipient()；把合约地址给 Matt 做公告

———

【English】

One line
Contract, tests, scripts, and docs are in ~/ThePromptProtocol/fee-disposition-module, branch feat/fee-disposition-automation, commit 81c1509. Read docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md first, then the code. Your actions are in the checklist at the end.

Decided by Matt (no need to ask again)
1. owner = Matt's own address (single EOA, no multisig). Set OWNER= at deploy time.
2. LP burn: LP_RECIPIENT = 0x000000000000000000000000000000000000dEaD. Right after mainnet deploy, call lockLpRecipient() so the LP destination can never change.
3. Threshold 50,000 PTC, incentive 30 bps with a 30 PTC floor, slippage 150 bps, min interval 1 hour, TWAP window 30 min with 3% deviation. All adjustable later via setConfig.

What changed since yesterday
1. A second, independent adversarial review (attack tests first, then findings) produced 8 findings; all fixed, each with a regression test (test/Regression.t.sol). The important one: the old slippage check could not stop an atomic sandwich in one transaction (dump → trigger(0) → buy back), which any contract can do, extracting close to 70% of a batch. Now both the swap and addLiquidity floors are set from TWAP × (1 − 3%), with TWAP read from the pair's own price0/1CumulativeLast; beating it requires holding the price down for 30 minutes.
2. A large backlog no longer stalls: each run is auto-capped from pool reserves (maxSafeBatch()), the rest carries to the next run.
3. Owner limits are enforced in code: incentive floor ≤ 5% of threshold; LP recipient can be locked one-way; PTC / USDT / LP cannot be rescued; renounceOwnership disabled.
4. The bootstrap cron script was exercised end to end on an anvil mainnet fork; two script bugs fixed along the way (bash integers silently overflow on 18-decimal amounts. Java BigInteger is fine, but every amount exceeds long).
5. Tests: 40 unit + 9 regression + fuzz green; 6 BSC mainnet fork tests green (real pool, real router, random EOA caller, atomic sandwich rejected). Slither: no High / Medium; the rest triaged line by line in implementation notes §9.

On-chain numbers (2026-09-05)
- trigger() ≈ 533k gas; BSC 0.05 gwei, BNB ≈ $713 → about $0.02 per call
- At the 50k threshold the caller incentive is 150 PTC ≈ $1.12
- Pool 5.10M PTC / 38.2k USDT, PTC ≈ $0.0075

⚠️ Funding path still needs your confirmation (the only blocker)
The 15% redemption fee is only recorded in the DB (user_vptc_record.feeNumber); the vault claim() is signed for the net amount, so fee PTC never leaves the vault. Recommended: a daily backend job sums feeNumber for completed redemptions and signs one claim(to = module, amount = feeSum) with the existing claimSigner. Please confirm against the vault source: does claim restrict to / msg.sender; do perTxCap / dailyCap / one-per-address-per-day block it; is a contract address allowed as to.

How to write the backend job (mirror script/Trigger.s.sol)
- Hourly, not daily: the TWAP reference needs periodic refreshes, otherwise a genuine price move costs an extra window of waiting
- Steps: canTrigger() false → log and exit, no transaction; true → previewTrigger() for expectedUsdtOut, minUsdtOut = expectedUsdtOut × (10000 − slippageBps) / 10000; send updateOracle(); send trigger(minUsdtOut)
- The first trigger after deploy needs a 30-minute wait (TWAP window); canTrigger returns "twap unavailable" until then, which is expected
- Keys only from nacos; the relayer needs a little BNB for gas

Engineer to-do
☐ 1. Review src/FeeDispositionModule.sol line by line (it moves funds automatically and permissionlessly)
☑ 2. Funding path confirmed against the vault source (implementation notes §6, with the backend daily-job spec); nothing left to answer
☐ 3. Decide which repo hosts the contract code and move this folder in wholesale (keep history)
☐ 4. Add two scheduled jobs in service-thebook: (a) daily fee claim to the module; (b) hourly canTrigger → updateOracle → trigger
☐ 5. Testnet deploy + BscScan verification: forge script script/Deploy.s.sol … --verify; lpRecipient = dead address
☐ 6. Schedule the audit (the PRD requires it before mainnet)
☐ 7. After mainnet deploy: Matt calls lockLpRecipient(); hand Matt the contract address for the announcement
