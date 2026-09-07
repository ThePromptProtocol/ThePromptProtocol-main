// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FeeDispositionModule} from "../src/FeeDispositionModule.sol";

/// @notice 引导 cron 的参考实现（forge 版）。后端 Java 定时任务照此逻辑用 web3j 实现即可：
///   1. canTrigger() 为 false 时静默退出（不报错、不发交易）
///   2. previewTrigger() 取链下报价，乘 (1 - slippageBps) 作为 minUsdtOut —— 这是对三明治攻击的硬下限
///   3. 发送 trigger(minUsdtOut)
///
///   MODULE=0x... forge script script/Trigger.s.sol --rpc-url $BSC_RPC_URL --private-key $RELAYER_KEY --broadcast
contract Trigger is Script {
    function run() external {
        FeeDispositionModule module = FeeDispositionModule(vm.envAddress("MODULE"));

        (bool callable, string memory reason) = module.canTrigger();
        if (!callable) {
            console2.log("skip:", reason);
            return;
        }

        (FeeDispositionModule.Split memory s, uint256 expectedOut) = module.previewTrigger();
        (,,,,, uint16 slippageBps,,,) = module.config();
        uint256 minUsdtOut = expectedOut * (10_000 - slippageBps) / 10_000;
        console2.log("batch (PTC wei):", s.batch);
        console2.log("expected USDT out:", expectedOut);
        console2.log("minUsdtOut:", minUsdtOut);

        vm.startBroadcast();
        // 顺手记一个观测点（不够老时是空操作），保证下一轮总有可用的 TWAP 参考
        module.updateOracle();
        module.trigger(minUsdtOut);
        vm.stopBroadcast();
    }
}
