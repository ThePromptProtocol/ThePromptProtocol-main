# vault-timelock

部署一个标准的 OpenZeppelin `TimelockController`，用来接管 `PTCReserveVault` 的 owner 权限。
对应 CertiK 审计（The Prompt Protocol 2-2026-9）TPP-01 的短期建议：时间锁 + 多签组合，
给所有 owner 级别的敏感操作（换签名者、换 Guardian、改额度上限、暂停、紧急提取）强制加
一个公开的等待期，不再是 Matt 一个人的私钥一签就立刻生效。

## 前置条件

Matt 需要先在 [Safe](https://app.safe.global) 上创建好多签钱包（BSC 主网），确定好签名人
和门槛。**这一步这个脚本代劳不了，必须是多签的每个签名人自己用各自的钱包去确认**。

## 部署

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cp .env.example .env   # 填 BSC_RPC_URL、DEPLOYER_PRIVATE_KEY、MULTISIG_ADDRESS、BSCSCAN_API_KEY

source .env
forge script script/DeployVaultTimelock.s.sol \
  --rpc-url $BSC_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
```

脚本会：
1. 部署 `TimelockController`（minDelay 固定 48 小时，对应 CertiK 建议下限）。
2. 把传入的 `MULTISIG_ADDRESS` 同时设为 proposer 和 executor——`TimelockController` 的
   构造函数会自动把 CANCELLER_ROLE 也一并授予每个 proposer，也就是这个多签同时具备
   "发起提案"和"取消提案"两种权限。独立于多签之外的看门人角色（比如单独找一个人只给
   取消权限，不参与日常操作）现阶段没做，留作以后规模变大再加。
3. 部署完成后**自动放弃部署账户的 `DEFAULT_ADMIN_ROLE`**——这是 OpenZeppelin 官方文档
   明确建议的收尾步骤，避免留下一个能绕开延迟、直接改时间锁自身权限配置的后门。

已经用 `--fork-url` 对 BSC 主网做过一次完整的模拟部署验证（部署 + 放弃 admin 权限全部
成功，预估 gas 约 0.00017 BNB），脚本逻辑没问题。

## 部署之后：只有 Matt 能做的最后一步

拿到脚本输出的时间锁合约地址后，**Matt 需要用他现在的 `PTCReserveVault` owner 钱包**
调用：

```
PTCReserveVault.transferOwnership(<时间锁合约地址>)
```

这一步完成后，Matt 自己的私钥就不再对 `PTCReserveVault` 有任何直接权限，以后任何
owner 级别的操作都要走"多签在时间锁上发起提案 -> 等 48 小时 -> 执行"这套流程。

如果以后也想让 `FeeDispositionModule` 的 owner 走同一套保护，可以复用同一个时间锁
合约地址，对那边也做一次 `transferOwnership`，不需要重新部署时间锁。
