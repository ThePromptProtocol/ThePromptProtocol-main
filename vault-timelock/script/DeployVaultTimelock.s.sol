// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice 部署一个标准的 OpenZeppelin TimelockController，用来接管 PTCReserveVault 的
///         owner 权限（CertiK 审计 TPP-01 短期建议：时间锁 + 多签）。
///
///   MULTISIG_ADDRESS=0x... \
///   forge script script/DeployVaultTimelock.s.sol --rpc-url $BSC_RPC_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
///
/// minDelay 固定 48 小时（CertiK 建议下限）。传入的多签地址同时被设为 proposer 和
/// executor；TimelockController 的构造函数会自动把 CANCELLER_ROLE 也一并授予每个
/// proposer，即这个多签同时具备"发起"和"取消"提案的权限——现阶段先这样，独立看门人
/// 角色（不在多签里的单独取消权限）留作以后再加，不在这次范围内。
///
/// 部署完成后脚本会自动放弃临时的 DEFAULT_ADMIN_ROLE（部署者），避免留下一个能绕开
/// 48 小时延迟、直接改时间锁自身权限配置的后门——这是 OpenZeppelin 官方文档明确建议
/// 的收尾步骤，不能省略。
///
/// 这一步只部署时间锁合约本身，不会改动 PTCReserveVault 的 owner——那一步需要 Matt
/// 用他现在的 owner 钱包单独调用 PTCReserveVault.transferOwnership(部署出来的时间锁地址)，
/// 这一步只有他能做，脚本代劳不了。
contract DeployVaultTimelock is Script {
    uint256 constant MIN_DELAY_SECONDS = 48 hours;

    function run() external returns (TimelockController timelock) {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        require(multisig != address(0), "MULTISIG_ADDRESS unset");

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        vm.startBroadcast();
        address deployer = msg.sender;
        timelock = new TimelockController(MIN_DELAY_SECONDS, proposers, executors, deployer);

        // 放弃临时 admin 权限：部署完成后，谁都不能再绕开延迟直接改这个时间锁自己的
        // 权限配置，后续只能通过"多签发起提案 -> 等 48 小时 -> 执行"的正常流程来调整。
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        console2.log("TimelockController:", address(timelock));
        console2.log("multisig (proposer + executor + canceller):", multisig);
        console2.log("minDelay (seconds):", MIN_DELAY_SECONDS);
        console2.log("");
        console2.log(unicode"下一步（只能由 Matt 用现在的 PTCReserveVault owner 钱包执行）：");
        console2.log("  PTCReserveVault.transferOwnership(", address(timelock), ")");
    }
}
