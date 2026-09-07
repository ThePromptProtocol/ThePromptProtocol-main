// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeDispositionModule} from "../src/FeeDispositionModule.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";
import {IPancakeFactory} from "../src/interfaces/IPancakeFactory.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice BSC 测试网（chainId 97）一键部署：测试网上没有 PTC/USDT 池，所以先部署两个测试代币、
///         在 PancakeSwap 测试网 router 上建池并注入与主网同量级的流动性，再部署模块。
///         仅用于验收 PRD 里「测试网端到端」那一条；主网请用 Deploy.s.sol。
///
///   forge script script/DeployTestnet.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
///        --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY
///
///   部署账户需要约 0.01 tBNB（水龙头：https://www.bnbchain.org/en/testnet-faucet）。
///   测试网上已有 PTCReserveVault 0x9315c065a6A14C67D8455D5e5982CeeBfA46D0fD（PTC 0xe1e191BC6eF0c8Bedb29f37f647C55667Bb8250d）；
///   传 PTC=0xe1e1…8250d 复用它，后端每日 claim 就能真的把测试网 vault 里的 PTC 打进模块。
///   部署者手里的测试网 PTC 可以由 claimSigner 签一张 claim 从测试网 vault 领出来（perTxCap 100 万/笔）；
///   不足 5.1M 时加 POOL_PTC=1000000 之类缩小池子。
contract DeployTestnet is Script {
    /// PancakeSwap V2 测试网 router（factory 0x6725F303…7a17，已在链上核对）
    address constant TESTNET_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function run()
        external
        returns (FeeDispositionModule module, MockERC20 ptc, MockERC20 usdt, address pair)
    {
        require(block.chainid == 97, "testnet only");
        address deployer = msg.sender;
        address owner = vm.envOr("OWNER", deployer);

        // 默认与主网池同量级：5.1M PTC / 38.2k USDT，价格 ≈ 0.0075。测试网 PTC 不够时用 POOL_PTC 缩小
        // （USDT 按同一价格等比缩），模块的单次上限会按实际池深自动收敛，不影响验收。
        uint256 poolPtc = vm.envOr("POOL_PTC", uint256(5_100_000)) * 1e18;
        uint256 poolUsdt = poolPtc * 38_200 / 5_100_000;

        vm.startBroadcast();
        // 优先复用测试网上已有的 PTC（PTCReserveVault 0x9315…D0fD 持有的 0xe1e1…8250d），
        // 这样后端的「每日 claim → 模块 → trigger」链路能在测试网完整走通；部署者需持有 ≥ 5.1M 该 PTC。
        // 不传 PTC 时退化为自建 tPTC，只能测模块本身。
        address existingPtc = vm.envOr("PTC", address(0));
        if (existingPtc != address(0)) {
            ptc = MockERC20(existingPtc);
            require(IERC20(existingPtc).balanceOf(deployer) >= poolPtc, "deployer lacks testnet PTC for the pool");
        } else {
            ptc = new MockERC20("PromptCoin (testnet)", "tPTC");
            ptc.mint(deployer, poolPtc + 500_000e18); // 多铸 50 万给部署者当「手续费」喂给模块
        }
        usdt = new MockERC20("Tether (testnet)", "tUSDT");
        usdt.mint(deployer, poolUsdt);
        IERC20(address(ptc)).approve(TESTNET_ROUTER, poolPtc);
        usdt.approve(TESTNET_ROUTER, poolUsdt);
        IPancakeRouter02(TESTNET_ROUTER).addLiquidity(
            address(ptc), address(usdt), poolPtc, poolUsdt, poolPtc, poolUsdt, deployer, block.timestamp + 600
        );
        pair = IPancakeFactory(IPancakeRouter02(TESTNET_ROUTER).factory()).getPair(address(ptc), address(usdt));

        FeeDispositionModule.Config memory cfg = FeeDispositionModule.Config({
            threshold: vm.envOr("THRESHOLD_PTC", uint256(3_000)) * 1e18,
            maxBatch: 0,
            minIncentive: vm.envOr("MIN_INCENTIVE_PTC", uint256(30)) * 1e18,
            burnBps: 3000,
            callerIncentiveBps: 30,
            slippageBps: 150,
            minInterval: uint32(vm.envOr("MIN_INTERVAL_SECONDS", uint256(3600))),
            twapWindow: uint32(vm.envOr("TWAP_WINDOW_SECONDS", uint256(1800))),
            maxTwapDeviationBps: 300
        });
        module = new FeeDispositionModule(owner, address(ptc), address(usdt), TESTNET_ROUTER, DEAD, cfg);
        vm.stopBroadcast();

        console2.log("tPTC:", address(ptc));
        console2.log("tUSDT:", address(usdt));
        console2.log("pair:", pair);
        console2.log("FeeDispositionModule:", address(module));
        console2.log("owner:", owner);
        console2.log("deployer holds 500k tPTC to feed the module; first trigger after (unix):", block.timestamp + cfg.twapWindow);
    }
}
