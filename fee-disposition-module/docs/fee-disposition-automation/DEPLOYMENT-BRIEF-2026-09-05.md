主题 / TOPIC：手续费处置自动化 —— 部署简报（主网小规模试运行） / Fee Disposition Automation — deployment brief (mainnet pilot, start small)
时间：2026-09-05 18:55 (GMT+8)
（这是完整交接：做了什么、怎么运作、怎么部署、怎么验证。所有代码都已在远端，PR / MR 链接在第三节。）

———

【中文】

一、Matt 的决定（已定，无需再议）
1. 现在就部署到 BSC 主网试运行，趁项目还小、流动性还浅先把机制跑通。
2. 试运行阈值 3,000 PTC（约一天的手续费），跑顺、审计过后再用 setConfig 调到 50,000。
3. owner = Matt 的 MetaMask 0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C（与主网 vault 的 owner 同一地址），单一 EOA，不用多签。
4. LP 销毁：lpRecipient = 0x000000000000000000000000000000000000dEaD；部署后 Matt 调用 lockLpRecipient() 永久锁定 LP 去向。
5. 测试环境今后一律用 BSC 测试网，不再用 Conflux。

二、做了什么
1. 合约 FeeDispositionModule（Solidity 0.8.28，OpenZeppelin 5.1）
   - 任何人可调 trigger(minUsdtOut)：先从合约的 PTC 余额付调用者激励，剩余 30% 转黑洞地址销毁，70% 的一半在 PancakeSwap 卖成 USDT、与另一半 addLiquidity，LP 打到黑洞地址。每轮逐项对账，对不上直接 revert。
   - 防三明治：现价必须在 30 分钟 TWAP ±3% 内，且 swap / addLiquidity 的成交底线按 TWAP 设定；单次批量按池子深度自动封顶；两次触发最短间隔 1 小时。
   - owner 权力边界写死在合约里：能调参（激励下限不超过阈值 5%）、换 / 锁定 LP 地址、暂停恢复、救援无关代币；不能取走 PTC / USDT / LP，不能放弃所有权。
   - 测试：单元 40 + 回归 9 + fuzz，主网 fork 7（真实 PTC、真实池、真实 vault 的 claim → 模块 → trigger 全流程），Slither 无 High / Medium；两轮独立复审共 8 条发现，全部修复并有回归测试。
2. 后端 service-thebook（两个定时任务）
   - FeeDispositionClaimTask：每日 UTC 00:10，把前一日已完成赎回（status=1、feeNumber>0、沉淀 ≥ 2 小时、7 天内、未纳入过）的手续费合计成一笔，用现有 claimSigner 签 claim(user = 模块地址) 交给 vault，relayer 付 gas。vault 每地址每 UTC 日只能领一次，所以一天一笔。新表 fee_disposition_claim / _item 保证一条赎回只算一次、失败下一轮重算。
   - FeeDispositionTriggerTask：每小时 05 分，观测点够老就 updateOracle() → canTrigger() → previewTrigger() 算 minUsdtOut = 报价 ×(1 − 1.5%) → trigger(minUsdtOut)。阈值未到只打日志。
   - 开关 book_config.feeDispositionEnabled（默认 0）、地址 FeeDispositionModuleContract。链配置改读独立的 book.ptcVault.chainType（缺省回落 book.nft.chainType，现有环境零变化）。
   - 已用真实 Java 代码对着 anvil 主网 fork 上的模块跑通 trigger（gas 532,697），单元测试 4 项通过。
3. 代码位置（全部已在远端）
   - 合约：GitHub PR #1 https://github.com/ThePromptProtocol/ThePromptProtocol-main/pull/1（分支 feat/fee-disposition-automation → main，17 个提交，目录 fee-disposition-module/）。
   - 后端：GitLab service-thebook 分支 fix/ptc-vault-chain-config（提交 890d9d65）与 feat/fee-disposition-automation（最新 eda650d8）。请先合并前者。MR 请在 GitLab 上建。
   - 阅读顺序：fee-disposition-module/docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md → 合约源码 → 后端两个 Task。

三、上线后怎么运作（以一笔 100 vPTC 赎回为例）
1. 用户赎回 100 vPTC：后端扣 100 vPTC，记 feeNumber = 15，签 85 PTC 的 vault 凭证，用户收到 85。15 PTC 留在 vault 里，不再属于任何人。这一步与现在完全一样。
2. 次日 UTC 00:10：后端把前一日所有 feeNumber 合计（例如 200 笔 ≈ 3,000 PTC），签一张 claim 给模块地址，vault 付 3,000 PTC 到模块。
3. 模块余额 ≥ 阈值（试运行 3,000）后，下一个整点 05 分后端触发（外部 keeper 也可能先触发）。以 3,000 PTC 一批为例：调用者得 30 PTC；891 PTC 销毁；1,040 PTC 卖成约 7.8 USDT；1,039 PTC 与这些 USDT 配对加入池子；LP 到黑洞地址。
4. 链上可见：黑洞地址的 PTC 与 LP 余额增加（BscScan token 页面加 ?a=0x…dEaD）、模块的 FeeDisposed 事件、totalBurned / totalPtcToLiquidity 等累计值。
5. 价格影响：卖出那一步让价格微跌（3,000 批次约 −0.04%，50,000 批次约 −0.7%），加流动性不改价格；池子 USDT 基本持平、PTC 变深。对外口径是「销毁 + 永久加深流动性」，不要说「支撑币价」。
6. 安全行为：30 分钟内价格波动超 3% 时本轮拒绝、下小时重试；积压太多时自动分批消化。

四、部署步骤（主网试运行）
前置：合约 PR 至少审阅完；部署私钥只在部署者本机，绝不进仓库。
1. 环境：cd fee-disposition-module && export PATH="$HOME/.foundry/bin:$PATH" && cp .env.example .env（填 BSC_RPC_URL、BSCSCAN_API_KEY）
2. 部署 + 验证（默认值已是试运行参数：阈值 3,000、激励 30 bps 下限 30 PTC、滑点 150、间隔 1 小时、TWAP 30 分钟 / 3%、owner 0xEecc…F81C、LP → 黑洞）：
   forge script script/Deploy.s.sol --rpc-url $BSC_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
   记下输出里的 FeeDispositionModule 地址，发给 Matt。部署约 0.005 BNB。
3. Matt 用 0xEecc…F81C 在 BscScan「Write Contract」调用 lockLpRecipient()（一次，永久）。
4. 后端（生产）
   - book 库执行 src/main/resources/sql/fee-disposition-automation.sql（两张表 + 两个 book_config）。
   - book_config.FeeDispositionModuleContract = 步骤 2 的地址；feeDispositionEnabled 先保持 0。
   - Nacos：book.ptcVault.chainType 可不配（回落 bnb）；确认 haitun（relayer）≥ 0.02 BNB。
   - 发布包含两个分支的 service-thebook；观察一轮无异常后把 feeDispositionEnabled 置 1。
5. 第一天验证
   - 次日 UTC 00:10 后：fee_disposition_claim 出现一行 status 3→1，txHash 在 BscScan 上是 vault → 模块的 Claimed 事件；模块 Read Contract 的 accumulatedFeePTC 增加。
   - 余额 ≥ 3,000 后的下一个整点 05 分：日志「feeDisposition trigger submitted」，模块 triggerCount = 1，黑洞地址 PTC 与 LP 余额从 0 变正。
   - 日志「twap unavailable」在部署后 30 分钟内属正常；「price deviates from twap」等下小时。
   - 把 claim 与 trigger 两个 txHash 回给 Matt。

五、试运行的风险与边界（Matt 已知悉）
- 尚未做第三方审计（PRD 要求主网前审计）。试运行期间合约里最多约一天手续费（≈ 3,000 PTC ≈ 22 美元），最坏损失以此为上限；阈值调大前须完成审计。
- owner 为单一 EOA：私钥丢失则参数永久冻结（机制仍照常运行）。
- vault 余额每天因 claim 少约 3,000 PTC，Backing Ratio 略降，属预期。

六、参数（全部 owner 可用 setConfig 改，9 个字段按顺序：threshold、maxBatch、minIncentive、burnBps、callerIncentiveBps、slippageBps、minInterval、twapWindow、maxTwapDeviationBps）
试运行：3000e18、0、30e18、3000、30、150、3600、1800、300
正式：  50000e18、0、30e18、3000、30、150、3600、1800、300
约束：minIncentive ≤ 5% × threshold；slippageBps 50~1000；twapWindow = 0 关闭 TWAP（不建议）。

七、测试环境（BSC 测试网）
- 合并 fix/ptc-vault-chain-config；测试环境 Nacos 配 book.ptcVault.chainType=bnbTest，MelonC / haitun 换成测试网 vault（0x9315c065a6A14C67D8455D5e5982CeeBfA46D0fD，claimSigner 0x6136…0082）对应的私钥与一个有 tBNB 的 relayer；测试库执行 sql/ptc-vault-bsc-testnet.sql。
- 用 script/DeployTestnet.s.sol 在测试网部署一套（PTC=0xe1e191BC6eF0c8Bedb29f37f647C55667Bb8250d 复用测试网 PTC，不够时加 POOL_PTC=1000000 缩小池子），地址填进测试环境 book_config，开关置 1。

工程师待办 / Engineer to-do
☐ 1. 审阅 GitHub PR #1（重点 src/FeeDispositionModule.sol，自动、无权限地动钱，逐行）
☐ 2. 审阅 GitLab 两个分支（fix/ptc-vault-chain-config 4 个文件；feat/fee-disposition-automation 14 个文件，重点 ClaimTask 的扫描窗口与幂等、TriggerTask 的 updateOracle 等回执），在 GitLab 建两个 MR，先合并 fix 再合并 feat
☐ 3. 主网部署 + BscScan 验证（四、步骤 1-2），把合约地址发给 Matt
☐ 4. 生产库执行 SQL、填地址、发布后端、确认 relayer 有 BNB、观察一轮后开关置 1（四、步骤 4）
☐ 5. 第一天按「四、步骤 5」核对，把两个 txHash 回给 Matt
☐ 6. 测试环境按第七节配置并部署一套
☐ 7. 安排审计；审计通过后 Matt 把阈值调到 50,000

———

【English】

1. Matt's decisions (settled)
1. Deploy to BSC mainnet now as a pilot, while the project and liquidity are small.
2. Pilot threshold 3,000 PTC (about one day of fees); raise to 50,000 via setConfig once it runs cleanly and the audit is done.
3. Owner = Matt's MetaMask 0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C (same address as the mainnet vault owner), single EOA, no multisig.
4. LP burn: lpRecipient = 0x000000000000000000000000000000000000dEaD; after deploy Matt calls lockLpRecipient() to make the LP destination permanent.
5. Test environments use BSC testnet from now on, not Conflux.

2. What was built
1. Contract FeeDispositionModule (Solidity 0.8.28, OpenZeppelin 5.1)
   - Anyone can call trigger(minUsdtOut): pays the caller incentive from the contract's PTC balance, burns 30% of the rest to the dead address, sells half of the 70% for USDT on PancakeSwap, pairs it with the other half via addLiquidity, LP goes to the dead address. Every run reconciles balances and reverts on any mismatch.
   - Sandwich protection: spot must be within ±3% of the 30-minute TWAP, and swap / addLiquidity floors are set from TWAP; batch size auto-caps to pool depth; minimum 1 hour between runs.
   - Owner limits enforced in code: tune parameters (incentive floor ≤ 5% of threshold), change / lock the LP address, pause / unpause, rescue unrelated tokens; cannot take PTC / USDT / LP, cannot renounce ownership.
   - Tests: 40 unit + 9 regression + fuzz, 7 mainnet-fork tests (real PTC, real pool, real vault claim → module → trigger), Slither no High / Medium; two independent reviews found 8 issues, all fixed with regression tests.
2. Backend service-thebook (two scheduled jobs)
   - FeeDispositionClaimTask: daily 00:10 UTC, sums the previous day's completed redemption fees (status=1, feeNumber>0, settled ≥ 2 h, within 7 days, not yet swept), signs claim(user = module) with the existing claimSigner, relayer pays gas. One claim per day because the vault allows one claim per address per UTC day. New tables fee_disposition_claim / _item ensure each redemption is counted once and failed claims are retried.
   - FeeDispositionTriggerTask: hourly at :05, updateOracle() when the observation is old enough → canTrigger() → previewTrigger() → minUsdtOut = quote × (1 − 1.5%) → trigger(minUsdtOut). Below threshold it only logs.
   - Switch book_config.feeDispositionEnabled (default 0), address FeeDispositionModuleContract. Chain config now reads book.ptcVault.chainType with fallback to book.nft.chainType (zero change for existing environments).
   - The real Java code drove a trigger on an anvil mainnet fork (gas 532,697); 4 unit tests pass.
3. Where the code is (all on remotes)
   - Contracts: GitHub PR #1 https://github.com/ThePromptProtocol/ThePromptProtocol-main/pull/1 (branch feat/fee-disposition-automation → main, 17 commits, folder fee-disposition-module/).
   - Backend: GitLab service-thebook branches fix/ptc-vault-chain-config (commit 890d9d65) and feat/fee-disposition-automation (latest eda650d8). Merge the fix branch first. Please open the MRs on GitLab.
   - Reading order: fee-disposition-module/docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md → contract source → the two backend Tasks.

3. How it operates once live (one redemption of 100 vPTC)
1. User redeems 100 vPTC: backend debits 100 vPTC, records feeNumber = 15, signs a vault voucher for 85 PTC, user receives 85. The 15 PTC stays in the vault, owed to nobody. Unchanged from today.
2. Next day 00:10 UTC: backend sums the previous day's feeNumber (say 200 redemptions ≈ 3,000 PTC), signs one claim to the module address, the vault pays 3,000 PTC to the module.
3. Once the module balance ≥ threshold (pilot 3,000), the backend triggers at the next :05 (an outside keeper may beat it). For a 3,000 PTC batch: caller gets 30 PTC; 891 PTC burned; 1,040 PTC sold for about 7.8 USDT; 1,039 PTC paired with that USDT into the pool; LP to the dead address.
4. Publicly visible: PTC and LP balances of the dead address grow (BscScan token page with ?a=0x…dEaD); the module's FeeDisposed event and running totals (totalBurned, totalPtcToLiquidity, …).
5. Price effect: the sell leg dips the price slightly (about −0.04% for a 3,000 batch, −0.7% for 50,000); adding liquidity does not move price; pool USDT stays roughly flat, pool PTC deepens. Public wording: "burns supply and permanently deepens liquidity", never "supports the price".
6. Safety behaviour: if price moved more than 3% within 30 minutes the run is refused and retried next hour; large backlogs drain in slices automatically.

4. Deployment steps (mainnet pilot)
Prerequisite: contract PR at least reviewed; the deployer key lives only on the deployer's machine, never in a repo.
1. Environment: cd fee-disposition-module && export PATH="$HOME/.foundry/bin:$PATH" && cp .env.example .env (fill BSC_RPC_URL, BSCSCAN_API_KEY)
2. Deploy + verify (defaults are already the pilot values: threshold 3,000, incentive 30 bps with 30 PTC floor, slippage 150, interval 1 h, TWAP 30 min / 3%, owner 0xEecc…F81C, LP → dead address):
   forge script script/Deploy.s.sol --rpc-url $BSC_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
   Note the FeeDispositionModule address in the output and send it to Matt. Deployment costs about 0.005 BNB.
3. Matt calls lockLpRecipient() from 0xEecc…F81C on BscScan "Write Contract" (once, permanent).
4. Backend (production)
   - Run src/main/resources/sql/fee-disposition-automation.sql on the book database (two tables + two book_config rows).
   - book_config.FeeDispositionModuleContract = address from step 2; keep feeDispositionEnabled at 0 for now.
   - Nacos: book.ptcVault.chainType can stay unset (falls back to bnb); confirm haitun (relayer) holds ≥ 0.02 BNB.
   - Release service-thebook with both branches; after one clean cycle set feeDispositionEnabled = 1.
5. First-day verification
   - After 00:10 UTC next day: a fee_disposition_claim row goes status 3→1, its txHash shows a Claimed event from the vault to the module on BscScan; the module's accumulatedFeePTC (Read Contract) increases.
   - At the next :05 once balance ≥ 3,000: log "feeDisposition trigger submitted", module triggerCount = 1, dead-address PTC and LP balances go from 0 to positive.
   - Log "twap unavailable" is normal within 30 minutes of deploy; "price deviates from twap" means wait for the next hour.
   - Send Matt the claim and trigger txHashes.

5. Pilot risks and limits (Matt is aware)
- No third-party audit yet (the PRD requires one before mainnet). During the pilot the contract never holds more than about a day of fees (≈ 3,000 PTC ≈ $22), which caps the worst case; the audit must be done before the threshold is raised.
- Owner is a single EOA: losing the key freezes parameters forever (the mechanism keeps running).
- The vault balance drops by about 3,000 PTC per day from the claims, so the Backing Ratio dips slightly. Expected.

6. Parameters (all owner-adjustable via setConfig; 9 fields in order: threshold, maxBatch, minIncentive, burnBps, callerIncentiveBps, slippageBps, minInterval, twapWindow, maxTwapDeviationBps)
Pilot:      3000e18, 0, 30e18, 3000, 30, 150, 3600, 1800, 300
Production: 50000e18, 0, 30e18, 3000, 30, 150, 3600, 1800, 300
Constraints: minIncentive ≤ 5% × threshold; slippageBps 50–1000; twapWindow = 0 disables TWAP (not recommended).

7. Test environment (BSC testnet)
- Merge fix/ptc-vault-chain-config; in test Nacos set book.ptcVault.chainType=bnbTest and replace MelonC / haitun with the keys for the testnet vault (0x9315c065a6A14C67D8455D5e5982CeeBfA46D0fD, claimSigner 0x6136…0082) and a relayer holding tBNB; run sql/ptc-vault-bsc-testnet.sql on the test database.
- Deploy a testnet set with script/DeployTestnet.s.sol (PTC=0xe1e191BC6eF0c8Bedb29f37f647C55667Bb8250d reuses the testnet PTC; add POOL_PTC=1000000 to shrink the pool if short of PTC), put the address in test book_config, switch = 1.

Engineer to-do
☐ 1. Review GitHub PR #1 (focus src/FeeDispositionModule.sol; it moves funds automatically and permissionlessly, read line by line)
☐ 2. Review the two GitLab branches (fix/ptc-vault-chain-config, 4 files; feat/fee-disposition-automation, 14 files, focus on the ClaimTask sweep window and idempotency and the TriggerTask updateOracle receipt wait); open both MRs on GitLab; merge fix first, then feat
☐ 3. Mainnet deploy + BscScan verification (section 4, steps 1–2); send the contract address to Matt
☐ 4. Production: run the SQL, set the address, release the backend, confirm relayer BNB, switch to 1 after one clean cycle (section 4, step 4)
☐ 5. First day: verify per section 4 step 5 and send Matt the two txHashes
☐ 6. Test environment: configure and deploy per section 7
☐ 7. Schedule the audit; once it passes Matt raises the threshold to 50,000
