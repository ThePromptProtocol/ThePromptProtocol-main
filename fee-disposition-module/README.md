# FeeDispositionModule

赎回手续费（PTC）的链上自动处置合约：累计到阈值后，**任何人**都可以调用 `trigger()`，一次原子交易完成
**30% 销毁 / 70% 注入 PancakeSwap V2 PTC-USDT 流动性**（卖出一半换 USDT、与另一半配对、LP 打到固定地址），
调用者获得少量 PTC 激励。需求文档见 `docs/fee-disposition-automation/PRD-fee-disposition-automation.md`，
实现说明与待决事项见 `docs/fee-disposition-automation/IMPLEMENTATION-NOTES.md`。

## 目录

```
src/FeeDispositionModule.sol        合约本体
src/interfaces/                     PancakeSwap V2 最小接口
test/FeeDispositionModule.t.sol     单元测试（本地复刻的 V2 池，含故障注入）
test/Regression.t.sol               2026-09-05 对抗性复审 8 条发现的回归测试
test/FeeDispositionModule.fork.t.sol BSC 主网 fork 端到端（真实 PTC / 真实池 / 真实 router）
test/mocks/                         MockERC20 / MockPancake（V2 公式）/ ReentrantERC20
script/Deploy.s.sol                 部署脚本（参数全部来自环境变量）
script/Trigger.s.sol                引导 cron 参考实现（forge 版）
script/bootstrap-trigger.sh         引导 cron 参考实现（cast 版）
```

## 环境

```bash
export PATH="$HOME/.foundry/bin:$PATH"   # Foundry 1.8.x
cp .env.example .env                      # 填 RPC；私钥只通过命令行 / 硬件钱包传入
```

## 测试

```bash
forge test --no-match-contract Fork                                   # 单元 + fuzz，离线
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-contract Fork -vv   # 主网 fork 端到端
```

公共 RPC 会限流或断连（`bsc-dataseed.binance.org` 经常 TLS handshake eof），失败就换一个节点重跑；
CI 建议用付费 RPC key。

## 部署

```bash
OWNER=0x... LP_RECIPIENT=0x000000000000000000000000000000000000dEaD THRESHOLD_PTC=3000 MIN_INCENTIVE_PTC=30 \
forge script script/Deploy.s.sol --rpc-url $BSC_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
```

`LP_RECIPIENT` 只接受黑洞地址（`0x…dEaD`）或有代码的锁仓合约；普通 EOA 会被脚本拒绝
（测试网调试可加 `ALLOW_EOA_LP_RECIPIENT=true`）。

## 运营参数（全部 owner 可改，`setConfig`）

`threshold` 触发阈值 · `maxBatch` 单次上限（0 不限）· `burnBps` 销毁比例 · `callerIncentiveBps` 激励比例 ·
`minIncentive` 激励绝对下限 · `slippageBps` 滑点 / 价格冲击上限 · `minInterval` 两次触发最短间隔 ·
`twapWindow` TWAP 观测窗口（0 关闭）· `maxTwapDeviationBps` 现价对 TWAP 的最大偏差，同时是成交价相对 TWAP 的底线。
另有 `lockLpRecipient()`（单向，永久冻结 LP 去向）、`maxSafeBatch()`（按池深算出的单次上限，超出部分自动留到下一轮）。
部署后要等 `twapWindow`（默认 30 分钟）才能第一次 trigger。
另有 `setLpRecipient`、`pause/unpause`、`rescueToken`（不能取 PTC / USDT）。
