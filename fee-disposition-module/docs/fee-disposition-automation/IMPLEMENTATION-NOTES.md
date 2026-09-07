# FeeDispositionModule — 实现说明与待决事项

- 日期：2026-09-04
- 对应 PRD：`PRD-fee-disposition-automation.md`
- 状态：代码完成、单元/fuzz/主网 fork 测试全绿、Slither 已跑、部署/cron 脚本已在 anvil 主网 fork 上实跑；**待工程师审核，未部署**
- 2026-09-05 更新：新增 TWAP 防三明治校验（§4.4）；独立对抗性复审 8 条发现全部修复（§10）；Matt 已拍板 owner = 本人 EOA、阈值 50,000 PTC、激励下限 30 PTC、LP 销毁
- 代码：`src/FeeDispositionModule.sol`（Solidity 0.8.28，OpenZeppelin v5.1.0，Foundry 1.8.1）

---

## 1. PRD 与实现的对应关系

| PRD 要求 | 实现 | 备注 |
|---|---|---|
| `accumulatedFeePTC` | `PTC.balanceOf(module)`（view `accumulatedFeePTC()`） | 不另设记账变量，任何转进来的 PTC 都会被处置，不会产生「记账与真实余额脱节」 |
| `threshold` / `burnBps` / `callerIncentiveBps` / `slippageBps` / `lpRecipient` | `Config` struct + `setConfig` / `setLpRecipient`，全部 owner 可改 | 另加 `maxBatch`、`minIncentive`、`minInterval`、`twapWindow`、`maxTwapDeviationBps`，理由见 §3、§4.4 |
| `liquidityBps = 10000 - burnBps` | 隐含在 `computeSplit` 里 | |
| `trigger()` 任何人可调 | `trigger(uint256 minUsdtOut)`，无权限检查，`nonReentrant` + `whenNotPaused` | 参数 `minUsdtOut` 传 0 即等价于 PRD 的无参版本 |
| 销毁 | 转账到 `0x…dEaD` | PTC 无原生 `burn()`（fork 验证：只有 12 个标准 selector） |
| swap `amountOutMin` 来自 `getAmountsOut` − 滑点 | 是；另外要求报价不能比「卖出前现价 × (1 − slippageBps)」更差 | 后一条是**价格冲击上限**，防止阈值配大后一口气砸池 |
| addLiquidity 两侧 `amountMin` 来自当前储备 − 滑点 | 是（swap 之后重读储备再推导） | |
| 余额归零断言 | `_settle` 里逐项对账：PTC 前后差 == 激励 + 销毁 + 卖出 + 配对用量；USDT 同理；不等即 `AccountingMismatch` | PTC 无转账税（fork 验证），所以可以用精确相等 |
| 单事件包含全部金额 | `FeeDisposed(caller, batch, incentive, burned, swappedPtc, usdtReceived, ptcToLiquidity, usdtToLiquidity, lpMinted, ptcCarried, usdtCarried)` | 另有累计统计 `totalBurned` 等，看板可直接读 |
| 激励来源 | **PTC，拆分之前从整批扣除（off the top）** | PRD 悬而未决的点，见 §4 决策 1 |

## 2. 拆分算法（`computeSplit`，纯函数）

```
incentive = max(batch × callerIncentiveBps / 10000, minIncentive)      // 必须 < batch
remainder = batch − incentive
burn      = remainder × burnBps / 10000
liquidity = remainder − burn
swap      = (liquidity − usdtHeldInPtc) / 2   （usdtHeldInPtc 为合约里已有 USDT 按现价折算；首轮为 0）
pair      = liquidity − swap
恒等式     incentive + burn + swap + pair == batch   （fuzz 512 轮验证）
```

`usdtHeldInPtc` 的作用：addLiquidity 总会剩一点 USDT（池子手续费 0.25% + 价格冲击导致两侧比例不完全吻合），
下一轮把这点 USDT 算进去、少卖一点 PTC，尘埃就会被消耗而不是无限累积。测试 `test_UsdtCarryForwardConsumedNextRun` 验证尘埃逐轮缩小。

## 3. PRD 之外新增的三个参数（为什么）

1. **`minIncentive`（激励绝对下限）** — 按比例算的激励在小批次下不够覆盖 gas（见 §5），没有下限就没有外部 keeper。
2. **`maxBatch`（单次处置上限，0 = 不限）** — 如果手续费积压很久（比如后端 claim 停了几周），一次性卖出会超过价格冲击上限而 revert；
   `maxBatch` 让积压分多次、每次都在池子深度之内消化。fork 测试：2M PTC 积压直接 trigger 会 revert（`PriceImpactTooHigh`），
   设 `maxBatch = 100k` 后可分批消化。
3. **`minInterval`（最短间隔）** — PRD「sensitive points」里建议的最小频率限制，减少批次大小/时机的可预测性。
4. **`twapWindow` / `maxTwapDeviationBps`（TWAP 防操纵）** — 见 §4.4。

## 4. PRD 悬而未决点的处理

1. **激励从哪里出** → PTC、拆分前扣除。理由：剩余部分严格 30/70，事件数字可直接对账，不用再从 USDT 里切一刀。
2. **`lpRecipient`** → **已决定（Matt，2026-09-04）：LP 销毁，`lpRecipient = 0x…dEaD`。** LP 一经打入即永久不可取回，
   流动性深度在链上可证明。构造函数必填、非零；部署脚本只接受黑洞地址或有代码的合约，EOA 需显式
   `ALLOW_EOA_LP_RECIPIENT=true`（只用于测试网）。个人 MetaMask 地址被明确否决：那等于「一个人随时能撤走流动性」，与 PRD 目的相反。
3. **`threshold` / `slippageBps` 默认值** → 脚本默认 50,000 PTC / 150 bps，见 §5。
4. **MEV / 三明治 → 已加 TWAP 校验（2026-09-05）。** 第一版只有 `slippageBps`，复审时确认这挡不住三明治：
   合约在同一笔交易里先报价再 swap，攻击者用一个合约做「砸价 → trigger(0) → 买回」三步，全部原子完成，
   合约会按砸过的价「合规地」贱卖并按坏价加 LP，可提取的价值不受 `slippageBps` 限制（上限接近整批的 70%）。
   现在 swap / addLiquidity 前额外要求：**现价与 TWAP 的偏差 ≤ `maxTwapDeviationBps`（默认 3%）**，并且
   **swap 的 `amountOutMin` 与 addLiquidity 的两侧下限都按 TWAP × (1 − 3%) 设定，而不是按当前报价**——
   这样即使攻击者把价格压在偏差带以内，本合约的成交价也不会比 TWAP 差超过 3%，攻击者两次换手的手续费高于所得
   （回归测试 `test_F1_SandwichInsideBandCannotProfit`）。TWAP 来自 pair 自带的 `price0/1CumulativeLast`，
   参考观测点必须至少 `twapWindow`（默认 30 分钟）老。要骗过 TWAP 本身，攻击者得把价格压住 30 分钟，期间会被套利者吃掉。实现细节：
   - 两槽观测（`observationOld` / `observationNew`），只有 newest 够老时才轮换，所以高频 `updateOracle()` 无法让
     「够老的参考点」消失（测试 `test_UpdateOracleSpamDoesNotStarveReference`）。
   - 部署即记第一个观测点；`trigger()` 结束自动再记一次；`updateOracle()` 任何人可调，引导 cron 每次顺手调。
   - `twapWindow = 0` 关闭校验（紧急逃生口，不建议用）。
   - 攻击测试：单元 `test_AtomicSandwichIsRejected`（300k PTC 砸价 −11% → `PriceDeviatesFromTwap`），
     主网 fork `testFork_AtomicSandwichRejectedOnRealPool`（400k PTC 砸真实池 → 拒绝）；0.8% 的正常波动不受影响。
   - 剩余风险：一个能连续 30 分钟压住价格且不被套利的攻击者。对 $38k 深度的池子这需要持续暴露大量资金，收益上限 ≈ 3% × 一批的卖出部分（约 $4），不成立。
   - 代价：真实行情在 30 分钟内波动超过 3% 时，本轮会被拒（`PriceDeviatesFromTwap`），等 TWAP 跟上再触发；cron 每小时跑一次即可自愈。
   调用者仍可传 `minUsdtOut`（引导 cron 传链下报价 − 滑点），作为第二道保险。
5. **资金来源（PRD 的核心假设有误）** → 见 §6。

## 5. 参数默认值与经济性（2026-09-04 链上实测）

- PTC/USDT 池：5,100,837 PTC / 38,243 USDT → PTC ≈ **$0.0075**
- BSC gas price：**0.05 gwei**；BNB ≈ $713（WBNB/USDT 池现价）
- `trigger()` 主网 fork 实测 gas：**466,339**（首次调用、冷存储）→ 一次调用 gas 成本 ≈ 0.0000233 BNB ≈ **$0.017**

HANDOFF 里「gas ≈ $0.3–1」的估算已过时（BSC Maxwell 之后 gas price 降到 0.05 gwei）。按 PRD 的 20–50 bps、每天约 3,000 PTC 手续费：

- 阈值 50,000 PTC ≈ 17 天手续费；激励 = max(50k × 0.3%, 150 PTC) = **150 PTC ≈ $1.12**，减 gas 后 keeper 净赚 ≈ $1.10
- 阈值 3,000 PTC（一天）：激励 = max(9 PTC, 150 PTC) = 150 PTC，下限主导；此时激励占批次 5%，太贵

脚本默认（**Matt 2026-09-05 拍板，2026-09-06 改试运行阈值**）：`threshold 3,000 PTC（试运行，约一天手续费；跑顺后 setConfig 调到 50,000）· maxBatch 0 · minIncentive 30 PTC · burnBps 3000 · callerIncentiveBps 30 · slippageBps 150 · minInterval 3600s · twapWindow 1800s · maxTwapDeviationBps 300`。
50k 阈值下按比例激励 = 150 PTC（≈ $1.12），已高于 30 PTC 下限；下限只在 owner 日后把阈值调小时起作用。所有值上线后可用 `setConfig` 调整，无需重新部署。
`slippageBps` 150 含池子 0.25% 手续费，对 50k 批次（卖出 17.4k PTC，占池子 0.34%）绰绰有余。

## 6. 资金来源：手续费在链下扣，不会自动到合约 —— **方案 (a) 已用 vault 源码确认可行（2026-09-05）**

vault 源码：https://github.com/ThePromptProtocol/ThePromptProtocol-main/blob/main/contracts/PTCReserveVault.sol
（已核对：主网 0x9e4cEa…e025 的全部选择器与该文件一致，包括之前未解析的 `dailyUsedToday` / `hasWithdrawnToday` / `pendingEmergencyWithdrawal`）。

赎回时 15% 手续费只在数据库 `user_vptc_record.feeNumber` 记账，vault 的 `claim()` 签的是**净额**；手续费 PTC 从未离开 vault。
同仓库里的 `contracts/Vault.sol` 是另一版设计（链上直接扣 15% 转给不可变的 `feeRecipient`），**没有部署**，主网跑的是 PTCReserveVault。

**每日 claim 到模块的三个疑问，逐条对照源码：**
1. `claim(user, amount, requestId, deadline, signature)`：收款人就是显式参数 `user`，合约只验证 claimSigner 的 EIP-712 签名，**不限制 msg.sender，也不要求 user 与提交者相同**（源码第 189-200 行）。`user = 模块地址` 可行。
2. 限额（链上实读 2026-09-05）：`perTxCap` = 500,000 PTC，`dailyCap` = 3,000,000 PTC，当日已用 0。每天约 3,000 PTC 的手续费远在限额之内。
   **同一地址每 UTC 日只能成功 claim 一次**（`_userLastWithdrawDay`，第 261-263 行）—— 所以必须把整天的手续费**合成一笔**，`batchClaim` 里也不能让模块地址出现两次。
3. 收款用 `safeTransfer(user, amount)`，普通 ERC20 转账，**合约地址可以收**；唯一的地址检查是非零。

主网 fork 测试 `testFork_DailyFeeClaimToModule_ThenTrigger` 在真实 vault 上走通了全流程：签 claim → 模块收到 → 同日第二笔被 `UserDailyLimitReached` 拒绝 → 连续 17 天累计到阈值 → 随机 EOA 触发 → 销毁与 LP 销毁均落地。

**后端每日任务的规格（service-thebook）**
- 触发时间：每日 UTC 00:10 之后（vault 的「每日」按 `block.timestamp / 1 days` 即 UTC 日计算；避开日界线）。
- 金额：前一 UTC 日内状态为已完成的赎回记录 `feeNumber` 求和；为 0 则跳过。
- `requestId`：由日期派生，例如 `keccak256("FEE-DISPOSITION-" + yyyyMMdd)`，天然幂等，重跑不会重复放款（vault 用 `usedRequestId` 防重放）。
- 签名：与用户提现完全相同的 EIP-712 `ClaimRequest(address user,uint256 amount,bytes32 requestId,uint256 deadline)`，domain `PTCReserveVault` / `1` / chainId 56 / vault 地址；`user = 模块地址`。
- 提交：relayer 调 `vault.claim(module, amount, requestId, deadline, sig)`。提交前可先查 `vault.hasWithdrawnToday(module)`，为 true 则说明今天已经打过，直接跳过。
- 记账：把这笔 claim 的 txHash 记回当天的手续费汇总记录，供 Treasury 看板对账（模块的 `FeeDisposed` 事件负责另一头）。

**对 Backing Ratio 的影响**：手续费 PTC 从 vault 转出后，vault 余额会按每天约 3,000 PTC 下降。这部分 PTC 本来就不对应任何用户的 vPTC 债务，
所以「vault PTC ÷ 流通 vPTC」的分子减少但分母不变，指标会略降——这是真实情况，不是 bug；看板说明里应注明。

## 7. 安全属性

- `Ownable2Step`（两步转移，避免转错地址）、`ReentrancyGuard`、`Pausable`（紧急停止，只影响 trigger）。**owner = Matt 的 EOA `0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C`**（与主网 vault owner 同一地址；2026-09-05 决定，不用多签）
- **owner 权力的明确边界**（对社区可以这样说）：能调参数（激励下限不超过阈值的 5%，所以最多把一批的 5% 当激励发给调用者）、能换 LP 接收地址（**调用 `lockLpRecipient()` 后永久不能再换**——建议主网部署后立刻锁定到黑洞地址）、能暂停 / 恢复、能救援误转的无关代币。
  **不能**：取走 PTC / USDT / LP（`rescueToken` 三者都拒绝）、放弃所有权（`renounceOwnership` 已禁用，避免暂停后无人能恢复）
- owner **不能**取走 PTC / USDT（`rescueToken` 明确拒绝这两个 token）—— 否则「不依赖公司私钥」的承诺就是空话
- 参数上限：激励 ≤ 5%、滑点 ≤ 10%、`minIncentive < threshold`（且 < `maxBatch`），防止误配把机制配死或配成漏洞
- router 授权每次按精确额度给、用完归零
- 只读辅助：`canTrigger()`（cron 先问再发）、`previewTrigger()`（keeper 估算是否值得调用）

## 8. 测试覆盖（对应 PRD 验收标准）

单元 40 项 + 回归 9 项 + fuzz（`forge test --no-match-contract Fork`）；主网 fork 6 项（`--match-contract Fork`）；部署 / 引导 cron 脚本已在 anvil 主网 fork 上实跑（下方 §11）：

- 阈值以下 revert、恰好阈值成功、任意 EOA 可调 ✔
- 拆分到 wei：小 / 大（1e9 PTC）/ 奇数批次精确匹配 PRD 公式；fuzz 恒等式 ✔
- 激励只付一次；`minIncentive` 下限；零激励 ✔
- swap 滑点 revert（router 少给 2%）、1% 内通过；addLiquidity 比例偏移 revert；调用者 `minUsdtOut` 生效 ✔
- 大积压按池深自动封顶、分多轮消化（不再 revert 卡死）；`maxBatch` 手动上限 ✔
- 重入：恶意代币回调里再调 `trigger()`，被 `ReentrancyGuardReentrantCall` 挡住，激励只付一次 ✔
- LP 只到 `lpRecipient`（合约 / 调用者 / owner / router 都为 0）✔
- USDT 结转、`burnBps = 100%`、pause、onlyOwner、Ownable2Step、参数校验、rescue 限制、授权归零 ✔
- TWAP：原子三明治被拒、小幅波动放行、砸价后立刻 update 也被旧槽拦下、update 刷屏不会饿死参考点、window=0 关闭、首窗口前 `TwapUnavailable` ✔
- **主网 fork 端到端**：从分发钱包转 60k PTC 进合约，随机 EOA 调用 → 黑洞地址增量、池子 PTC 与 k 变深、LP 到 `lpRecipient`、合约只剩尘埃 ✔

**尚未做**（需要 Matt / 工程师）：测试网部署 + BscScan 验证；后端 cron 接入；审计。`lpRecipient` 已定为黑洞地址，不再是阻塞项。

## 9. Slither 0.11.6 结果与分类（`slither . --filter-paths "lib/|test/|script/" --exclude-dependencies`）

无 High。已修：`divide-before-multiply`（拆分/滑点 3 处，改为先乘后除）。其余全部为 Informational / Optimization 或有意为之，逐条说明：

| 检测器 | 位置 | 处理 |
|---|---|---|
| `incorrect-equality` | `_usdtToPtcAtSpot` 的 `== 0` | 零值保护，不是余额比较，误报 |
| `uninitialized-local` | `trigger` 里的 `Run memory r` | 故意留零值，字段随后逐个赋值 |
| `unused-return` | `_reserves` 忽略 `blockTimestampLast` | 不需要该字段 |
| `reentrancy-benign` / `reentrancy-no-eth` | `_settle` 与 `_updateOracle` 在 router 调用之后写统计量 / 观测点 | 已有 `nonReentrant`；`test_ReentrancyBlocked` 证明重入被挡。观测点必须在本轮交易之后记录，这是设计要求 |
| `divide-before-multiply` | `_currentCumulative` 的 `(rUsdt × 2^112 / rPtc) × elapsed`；`_twapStatus` 的 `diff × BPS`；`_maxSafeBatch` 的 `maxSwap × 999 / 1000` 后再乘 | 第一处刻意与 UniswapV2Pair._update 的 UQ112x112 编码逐位一致，否则 TWAP 与 pair 自己的累加器对不上；后两处精度损失 < 1 wei，且 `_maxSafeBatch` 本来就是保守上限 |
| `incorrect-equality` | `_twapStatus` 返回码 `== 1 / == 2`、`_foldDustSwap` 的 `quoted == 0` | 枚举值与零值比较，不是余额比较，误报 |
| `timestamp` | `minInterval` 比较 + 若干被误归类的普通比较 | `minInterval` 本来就是按区块时间设计的频率限制，矿工能操纵的幅度（秒级）对小时级间隔无意义 |
| `naming-convention` | `PTC` / `USDT` / `ROUTER` / `PAIR` / `PTC_IS_TOKEN0` 用大写 | immutable 用常量风格是项目约定 |

## 10. 2026-09-05 独立对抗性复审：8 条发现与处理

第二个独立审查（对抗性视角，每条都先写出可复现的攻击测试）在加了 TWAP 之后的版本上找到 8 条。全部已修，
每条对应 `test/Regression.t.sol` 里一个回归测试：

| # | 严重度 | 问题 | 修复 |
|---|---|---|---|
| F-1 | 中 | 偏差带（当时 10%）以内的原子三明治仍能净赚 ≈ 5× 激励：swap 的 `amountOutMin` 来自被操纵的报价 | swap 与 addLiquidity 的底线改为 **TWAP × (1 − maxTwapDeviationBps)**；默认偏差 10% → 3% |
| F-2 | 低 | 合约里已有足够 USDT、swap 归零时，完全跳过 TWAP 校验，可按任意价加 LP | 只要有 swap 或配对就校验；addLiquidity 两侧下限也按 TWAP |
| F-3 | 低 | owner 可把 `minIncentive` 调到 threshold − 1 自己调用 trigger 拿走整批；可把 lpRecipient 指向自己；LP 代币可被 rescue | `minIncentive ≤ 5% × threshold`（及 maxBatch）；新增单向 `lockLpRecipient()`；`rescueToken` 拒绝 LP；禁用 `renounceOwnership` |
| F-4 | 低 | `canTrigger()` 不看 TWAP 状态，cron 会发必 revert 的交易 | 返回 `twap unavailable` / `price deviates from twap` |
| F-5 | 低 | 参考观测点无上限地变旧，真实行情漂移后一次 revert | 设计上自愈：`updateOracle()` + 等一个窗口；cron 改为**每小时**跑并顺手 `updateOracle()` |
| F-6 | 信息 | `slippageBps < 25` 能通过校验但每次必 revert | 校验 `slippageBps ≥ 50` |
| F-7 | 低 | `maxBatch = 0` 时大积压触发 `PriceImpactTooHigh` 卡死，直到 owner 手动设 maxBatch | 新增 `_maxSafeBatch`：按池子储备自动封顶，超出留到下一轮；`maxSafeBatch()` 可查 |
| F-8 | 低 | 捐几百 USDT 让 swap 只剩几十 wei → router 报价 0 → 真实 pair revert（mock 测不出） | 报价为 0 的尘埃并入配对部分；mock 补上 pair 的零输出拒绝 |

复审同时确认无问题的类别：拆分/滑点/TWAP 算术无溢出；token0/token1 处理正确；资金只能经激励/销毁/router 离开；
`_settle` 精确对账既不过严也不过松；授权归零；重入/暂停/两步转移；router 行为假设（addLiquidity 不退款、deadline、0.25% 费）全部正确；
mock 的 V2 公式与真实 router 一致。

## 11. 脚本在 anvil 主网 fork 上的实跑记录（2026-09-05）

`anvil --fork-url <bsc>` → `Deploy.s.sol` 部署（owner = 本地账户，LP = 黑洞）→ 从分发钱包转 60k PTC → `evm_increaseTime 1800`：

- `script/bootstrap-trigger.sh`：阈值以下 `skip: below threshold` 退出码 0；窗口未到 `trigger reverted: custom error 0x146f8be2`（TwapUnavailable）退出码 2；窗口过后发出 trigger，gas 482,032，激励 180 PTC 到 relayer，合约 PTC 余额归零，LP 到黑洞；紧接着再跑 `skip: interval not elapsed`。
- `script/Trigger.s.sol`：同样流程，阈值以下 `skip`，否则 `updateOracle()` + `trigger(minUsdtOut)` 成功。
- 修掉的脚本 bug：bash 的 `read` 在无换行输入时返回非零被 `set -e` 终止；bash 64 位整数对 18 位小数金额静默溢出（`minUsdtOut` 算成一个极小值，等于没有保护）→ 改用 `bc`。**后端用 Java/BigInteger 实现时不会有这个问题，但请注意所有金额都超过 long 的范围。**
- 公共 RPC 只保留最近 ~100 个区块的状态，anvil fork 必须在一分钟内完成首笔交易；工程师本地复现时建议用带 archive 的付费节点。

## 12. 后端与仓库落地（2026-09-05，周末代工程师完成）

- **service-thebook** 分支 `feat/fee-disposition-automation`（已推到 GitLab，MR 待建）：
  `FeeDispositionClaimTask`（每日 UTC 00:10 喂料 claim）、`FeeDispositionTriggerTask`（每小时引导触发）、
  `FeeDispositionModuleTools`（合约只读 + 两个交易）、两张新表 + 两个 `book_config` 键（`src/main/resources/sql/fee-disposition-automation.sql`）。
  单元测试 4 项通过；`FeeDispositionManualHarnessTest`（设 `MODULE_ADDRESS` 才启用）已对着 anvil 主网 fork 上部署的模块
  跑通真实 `trigger()`：ABI 解码正确、`minUsdtOut` 与 forge 脚本逐位一致、交易成功 gas 532,697、模块余额归零。
- **ThePromptProtocol-main**（合约仓库）分支 `feat/fee-disposition-automation`：本项目以 `git subtree` 并入 `fee-disposition-module/`，
  子模块路径已改到根 `.gitmodules`，在该仓库内 `forge build` 通过。本地位于 `~/ThePromptProtocol/ThePromptProtocol-main`，
  **尚未推送**（推送 GitHub 需要 Matt 本人操作或授权）。
- **测试网**：`script/DeployTestnet.s.sol` 在测试网 fork 上模拟通过（自建 tPTC/tUSDT 池 + 模块，约 0.001 tBNB）；
  真正广播需要一把有 tBNB 的部署私钥，由 Matt / 工程师执行。
