#!/usr/bin/env bash
# 引导 cron 参考脚本（cast 版）：每日跑一次；阈值未到时退出码 0、不发交易。
# 环境变量：MODULE（合约地址）、BSC_RPC_URL、RELAYER_KEY（只从密钥管理/环境注入，严禁写进仓库）
set -euo pipefail
: "${MODULE:?MODULE unset}" "${BSC_RPC_URL:?BSC_RPC_URL unset}" "${RELAYER_KEY:?RELAYER_KEY unset}"

# cast 把元组的每个元素单独打印一行；不用 read，因为末尾无换行时 read 会返回非零并被 set -e 终止
can=$(cast call "$MODULE" "canTrigger()(bool,string)" --rpc-url "$BSC_RPC_URL")
callable=$(printf '%s\n' "$can" | sed -n 1p)
reason=$(printf '%s\n' "$can" | sed -n 2p | tr -d '"')
if [ "$callable" != "true" ]; then
  echo "skip: $reason"
  exit 0
fi

# previewTrigger 返回 (Split, expectedUsdtOut)；第二行就是预计换到的 USDT
# cast 会在大数后面附加 "[1.5e20]" 这样的科学计数提示，做算术前必须去掉
expected_out=$(cast call "$MODULE" "previewTrigger()((uint256,uint256,uint256,uint256,uint256),uint256)" --rpc-url "$BSC_RPC_URL" | sed -n 2p | awk '{print $1}')
slippage_bps=$(cast call "$MODULE" "config()(uint256,uint256,uint256,uint16,uint16,uint16,uint32,uint32,uint16)" --rpc-url "$BSC_RPC_URL" | sed -n 6p | awk '{print $1}')
# 18 位小数的金额远超 bash 的 64 位整数，$(( )) 会静默溢出成一个很小的数，等于没有保护；必须用 bc
min_out=$(echo "$expected_out * (10000 - $slippage_bps) / 10000" | bc)
[[ "$min_out" =~ ^[1-9][0-9]*$ ]] || { echo "bad minUsdtOut: $min_out"; exit 1; }
echo "trigger: expectedUsdtOut=$expected_out minUsdtOut=$min_out slippageBps=$slippage_bps"

# 先记观测点（不够老时是空操作，几乎不费 gas），再触发
cast send "$MODULE" "updateOracle()" --rpc-url "$BSC_RPC_URL" --private-key "$RELAYER_KEY" >/dev/null
if ! out=$(cast send "$MODULE" "trigger(uint256)" "$min_out" --rpc-url "$BSC_RPC_URL" --private-key "$RELAYER_KEY" 2>&1); then
  # 常见原因：TwapUnavailable（部署/观测后未满 twapWindow）、PriceDeviatesFromTwap（价格刚被操纵）——下一轮再来
  echo "trigger reverted: $(printf '%s' "$out" | grep -oE 'execution reverted[^"]*|0x[0-9a-f]{8}' | head -1)"
  exit 2
fi
echo "trigger sent: $(printf '%s\n' "$out" | grep -E '^transactionHash' | awk '{print $2}') gasUsed=$(printf '%s\n' "$out" | grep -E '^gasUsed' | awk '{print $2}')"
