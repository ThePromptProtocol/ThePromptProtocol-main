// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FeeDispositionModule} from "../src/FeeDispositionModule.sol";

/// @notice 部署脚本。所有参数来自环境变量（见 .env.example），私钥只通过 --private-key / 硬件钱包传入，
///         绝不写进仓库。
///
///   forge script script/Deploy.s.sol --rpc-url $BSC_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY \
///        --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
contract Deploy is Script {
    address constant PTC = 0x7291B049dC9A16bC75BaD51B0e0AA9EA99cCA2fa;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant MAINNET_OWNER = 0xEeccBF3A2B2BE808C69d3209516a1b7abf7AF81C;

    function run() external returns (FeeDispositionModule module) {
        // 主网 owner = Matt 的 MetaMask，与 PTCReserveVault 的 owner 同一地址（2026-09-05 决定）；测试网可用 OWNER 覆盖
        address owner = vm.envOr("OWNER", MAINNET_OWNER);
        address lpRecipient = vm.envAddress("LP_RECIPIENT");
        address ptc = vm.envOr("PTC", PTC);
        address usdt = vm.envOr("USDT", USDT);
        address router = vm.envOr("ROUTER", ROUTER);

        // lpRecipient 决定 LP 永远去哪：只接受黑洞地址或有代码的锁仓合约。
        // 普通 EOA 意味着「某个人可以随时撤走流动性」，与 PRD 的目的相反，必须显式打开开关才允许（仅测试网）。
        require(lpRecipient != address(0), "LP_RECIPIENT unset");
        bool allowEoa = vm.envOr("ALLOW_EOA_LP_RECIPIENT", false);
        require(lpRecipient == DEAD || lpRecipient.code.length > 0 || allowEoa, "LP_RECIPIENT is an EOA");
        require(owner != address(0), "OWNER unset");

        FeeDispositionModule.Config memory cfg = FeeDispositionModule.Config({
            threshold: vm.envOr("THRESHOLD_PTC", uint256(3_000)) * 1e18,
            maxBatch: vm.envOr("MAX_BATCH_PTC", uint256(0)) * 1e18,
            minIncentive: vm.envOr("MIN_INCENTIVE_PTC", uint256(30)) * 1e18,
            burnBps: uint16(vm.envOr("BURN_BPS", uint256(3000))),
            callerIncentiveBps: uint16(vm.envOr("CALLER_INCENTIVE_BPS", uint256(30))),
            slippageBps: uint16(vm.envOr("SLIPPAGE_BPS", uint256(150))),
            minInterval: uint32(vm.envOr("MIN_INTERVAL_SECONDS", uint256(3600))),
            twapWindow: uint32(vm.envOr("TWAP_WINDOW_SECONDS", uint256(1800))),
            maxTwapDeviationBps: uint16(vm.envOr("MAX_TWAP_DEVIATION_BPS", uint256(300)))
        });

        vm.startBroadcast();
        module = new FeeDispositionModule(owner, ptc, usdt, router, lpRecipient, cfg);
        vm.stopBroadcast();

        console2.log("FeeDispositionModule:", address(module));
        console2.log("pair:", address(module.PAIR()));
        console2.log("owner:", owner);
        console2.log("lpRecipient:", lpRecipient);
        console2.log("threshold (PTC):", cfg.threshold / 1e18);
        console2.log("minIncentive (PTC):", cfg.minIncentive / 1e18);
        console2.log("twapWindow (s):", cfg.twapWindow);
        console2.log("first trigger possible after (unix):", block.timestamp + cfg.twapWindow);
    }
}
