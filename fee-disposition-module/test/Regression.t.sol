// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeDispositionModule} from "../src/FeeDispositionModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter, MockPair} from "./mocks/MockPancake.sol";

/// @dev 2026-09-05 独立对抗性复审的 8 条发现（F-1 ~ F-8）修复后的回归测试：每条对应一个曾经可复现的问题
contract RegressionTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant POOL_PTC = 5_100_000e18;
    uint256 constant POOL_USDT = 38_200e18;

    MockERC20 ptc;
    MockERC20 usdt;
    MockRouter router;
    MockPair pair;
    FeeDispositionModule module;
    FeeDispositionModule.Config cfg;

    address owner = makeAddr("owner");
    address lpLock = makeAddr("lpLock");
    address bob = makeAddr("bob");

    function setUp() public {
        ptc = new MockERC20("PromptCoin", "PTC");
        usdt = new MockERC20("Tether", "USDT");
        router = new MockRouter();
        pair = MockPair(router.factoryContract().createPair(address(ptc), address(usdt)));
        ptc.mint(address(pair), POOL_PTC);
        usdt.mint(address(pair), POOL_USDT);
        pair.mint(makeAddr("seeder"));
        cfg = FeeDispositionModule.Config({
            threshold: 50_000e18,
            maxBatch: 0,
            minIncentive: 150e18,
            burnBps: 3000,
            callerIncentiveBps: 30,
            slippageBps: 150,
            minInterval: 3600,
            twapWindow: 1800,
            maxTwapDeviationBps: 300
        });
        module = new FeeDispositionModule(owner, address(ptc), address(usdt), address(router), lpLock, cfg);
        vm.warp(block.timestamp + cfg.twapWindow);
    }

    function _reserves() internal view returns (uint256 rPtc, uint256 rUsdt) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rPtc, rUsdt) = pair.token0() == address(ptc) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _dump(address who, uint256 amount) internal {
        ptc.mint(who, amount);
        vm.startPrank(who);
        ptc.approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = address(ptc);
        path[1] = address(usdt);
        router.swapExactTokensForTokens(amount, 0, path, who, block.timestamp);
        vm.stopPrank();
    }

    /// F-1：偏差带以内的三明治。以前攻击者能净赚 ~5× 激励；现在成交价底线来自 TWAP，
    ///      要么 trigger 被拒，要么成交价 ≥ TWAP × 97%，攻击者两次换手的手续费高于所得
    function test_F1_SandwichInsideBandCannotProfit() public {
        ptc.mint(address(module), 60_000e18);
        SandwichBot bot = new SandwichBot(module, ptc, usdt, router);
        ptc.mint(address(bot), 60_000e18); // 砸价 ≈ −2.3%，在 3% 偏差带以内
        uint256 before = ptc.balanceOf(address(bot));
        bot.attack(60_000e18);
        if (module.triggerCount() == 1) {
            // 成交了：模块拿到的 USDT 不低于 TWAP 价 × 97%
            FeeDispositionModule.Split memory s = module.computeSplit(60_000e18, 0, cfg);
            (uint256 twap,) = module.twapPrice();
            uint256 floor = s.swap * twap / 2 ** 112 * (BPS - cfg.maxTwapDeviationBps) / BPS;
            assertGe(module.totalUsdtToLiquidity() + usdt.balanceOf(address(module)), floor);
        }
        assertLe(ptc.balanceOf(address(bot)), before, "attacker did not profit");
    }

    /// F-2：以前 swap == 0（合约里已有足够 USDT）时完全跳过 TWAP 校验，可按任意价加 LP
    function test_F2_TwapGuardCoversLiquidityOnlyRuns() public {
        ptc.mint(address(module), 60_000e18);
        usdt.mint(address(module), 400e18); // 超过 70% 部分的价值，swap 归零
        (FeeDispositionModule.Split memory p,) = module.previewTrigger();
        assertEq(p.swap, 0);
        _dump(makeAddr("whale"), 2_000_000e18); // 现价 −50%
        vm.prank(bob);
        vm.expectPartialRevert(FeeDispositionModule.PriceDeviatesFromTwap.selector);
        module.trigger(0);
    }

    /// F-3a：以前 owner 可把 minIncentive 调成 threshold − 1，自己调用 trigger 拿走整批
    function test_F3a_OwnerCannotConfigureIncentiveToDrain() public {
        FeeDispositionModule.Config memory c = cfg;
        c.minIncentive = cfg.threshold - 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeDispositionModule.InvalidConfig.selector, "minIncentive>5%threshold"));
        module.setConfig(c);
    }

    /// F-3b：LP 接收地址可永久锁定；LP 代币不可被 rescue
    function test_F3b_LpRecipientLockAndLpNotRescuable() public {
        vm.startPrank(owner);
        module.lockLpRecipient();
        vm.expectRevert(FeeDispositionModule.LpRecipientIsLocked.selector);
        module.setLpRecipient(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeDispositionModule.RescueNotAllowed.selector, address(pair)));
        module.rescueToken(address(pair), owner, 1);
        vm.expectRevert(FeeDispositionModule.RenounceDisabled.selector);
        module.renounceOwnership();
        vm.stopPrank();
        assertTrue(module.lpRecipientLocked());
    }

    /// F-4：canTrigger 以前对 TWAP 状态一无所知，cron 会白白发一笔必 revert 的交易
    function test_F4_CanTriggerReportsTwapState() public {
        FeeDispositionModule fresh =
            new FeeDispositionModule(owner, address(ptc), address(usdt), address(router), lpLock, cfg);
        ptc.mint(address(fresh), 60_000e18);
        (bool ok, string memory why) = fresh.canTrigger();
        assertFalse(ok);
        assertEq(why, "twap unavailable");

        ptc.mint(address(module), 60_000e18);
        _dump(makeAddr("whale"), 300_000e18);
        (ok, why) = module.canTrigger();
        assertFalse(ok);
        assertEq(why, "price deviates from twap");
    }

    /// F-5：参考点太旧 + 行情真实漂移 → 一次 revert，但 updateOracle + 等一个窗口后自愈
    function test_F5_StaleReferenceSelfHealsAfterUpdateAndWindow() public {
        vm.warp(block.timestamp + 20 days);
        _dump(makeAddr("seller"), 200_000e18); // 真实下跌 ≈ −7%，无人操纵
        vm.warp(block.timestamp + 1 days);
        ptc.mint(address(module), 60_000e18);
        (bool ok,) = module.canTrigger();
        assertFalse(ok, "20-day-old reference vs today's price: blocked");
        module.updateOracle();
        vm.warp(block.timestamp + cfg.twapWindow);
        vm.prank(bob);
        module.trigger(0);
        assertEq(module.triggerCount(), 1);
    }

    /// F-6：滑点低于池子手续费的配置以前能通过校验，然后每次 trigger 必 revert
    function test_F6_SlippageBelowPoolFeeRejectedAtConfig() public {
        FeeDispositionModule.Config memory c = cfg;
        c.slippageBps = 20;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeDispositionModule.InvalidConfig.selector, "slippageBps<min"));
        module.setConfig(c);
    }

    /// F-7：maxBatch = 0 时大积压以前会 PriceImpactTooHigh 卡死；现在自动按池深封顶
    function test_F7_BacklogDrainsInSlicesWithoutOwnerAction() public {
        ptc.mint(address(module), 1_000_000e18);
        uint256 rounds;
        while (ptc.balanceOf(address(module)) >= cfg.threshold && rounds < 20) {
            vm.warp(block.timestamp + cfg.minInterval);
            module.updateOracle();
            vm.warp(block.timestamp + cfg.twapWindow);
            vm.prank(bob);
            module.trigger(0);
            rounds++;
        }
        assertLt(ptc.balanceOf(address(module)), cfg.threshold, "backlog fully drained");
        assertGt(rounds, 1, "took several slices");
    }

    /// F-8：swap 尘埃（router 报价为 0）以前会让真实 pair revert；现在并入配对部分
    function test_F8_DustSwapFoldedIntoPair() public {
        uint256 batch = 60_000e18;
        ptc.mint(address(module), batch);
        FeeDispositionModule.Split memory base = module.computeSplit(batch, 0, cfg);
        uint256 liquidity = base.swap + base.pair;
        (uint256 rP, uint256 rU) = _reserves();
        // 让 usdtHeldInPtc ≈ liquidity − 60 wei → swap ≈ 30 wei → 报价为 0
        uint256 donation = (liquidity - 60) * rU / rP + 1;
        usdt.mint(address(module), donation);
        (FeeDispositionModule.Split memory p, uint256 out) = module.previewTrigger();
        assertEq(p.swap, 0, "dust folded");
        assertEq(out, 0);
        assertEq(p.pair, liquidity, "pair absorbed the dust");
        vm.prank(bob);
        module.trigger(0);
        assertEq(module.triggerCount(), 1);
    }
}

contract SandwichBot {
    FeeDispositionModule immutable module;
    MockERC20 immutable ptc;
    MockERC20 immutable usdt;
    MockRouter immutable router;

    constructor(FeeDispositionModule m, MockERC20 p, MockERC20 u, MockRouter r) {
        module = m;
        ptc = p;
        usdt = u;
        router = r;
    }

    function attack(uint256 amount) external {
        ptc.approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = address(ptc);
        path[1] = address(usdt);
        router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
        try module.trigger(0) {} catch {}
        uint256 u = usdt.balanceOf(address(this));
        usdt.approve(address(router), u);
        address[] memory back = new address[](2);
        back[0] = address(usdt);
        back[1] = address(ptc);
        router.swapExactTokensForTokens(u, 0, back, address(this), block.timestamp);
    }
}
