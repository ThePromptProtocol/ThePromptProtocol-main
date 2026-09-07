// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {IPancakeFactory} from "./interfaces/IPancakeFactory.sol";
import {IPancakePair} from "./interfaces/IPancakePair.sol";

/// @title FeeDispositionModule
/// @notice 赎回手续费（PTC）的链上处置合约：累计到阈值后，任何人都可以调用 `trigger()`
///         一次性完成「30% 销毁 / 70% 注入 PTC-USDT 流动性」，调用者获得少量 PTC 激励。
/// @dev 设计要点（为什么这么做，而不是别的方案）：
///  - 不修改已上线的 PTCReserveVault，只做伴生合约：vault 没有任何手续费转发逻辑，
///    改 vault 意味着重新审计；本合约只要求「有人把 PTC 转进来」（后端每日签一笔 claim 到本合约即可）。
///  - 所有金额都以调用时的合约 PTC 余额为准，没有独立的 accumulated 状态变量：
///    避免「记账余额」与「真实余额」脱节（任何直接转账都能被处置，也不会出现无法处置的孤儿余额）。
///  - 激励在拆分之前从整批里扣除（off the top）：这样剩余部分严格按 burnBps 拆分，事件里的数字可直接对账，
///    不需要再从 USDT 里切一刀。
///  - 上一轮 addLiquidity 剩下的 USDT 会在下一轮参与配对（按现价折算成 PTC 后少 swap 一点），
///    否则 USDT 尘埃会在合约里无限累积，与「合约余额归零」的验收目标冲突。
///  - 同一笔交易内先报价再 swap，`slippageBps` 本身挡不住三明治：攻击者可以在同一笔交易里先砸价、
///    再调 trigger(0)、再买回，合约会按砸过的价「合规地」贱卖。所以 swap 前额外要求现价与
///    池子自带的时间加权均价（TWAP，取自 pair 的 priceCumulativeLast）偏差不超过 `maxTwapDeviationBps`：
///    并且 swap 与 addLiquidity 的最低成交价都按 TWAP × (1 − maxTwapDeviationBps) 设定，而不是按当前报价：
///    这样即使攻击者把价格压在偏差带以内，能从本合约身上多拿的也不超过偏差带那几个百分点，抵不过他自己两次换手的手续费。
///    要骗过 TWAP 本身，攻击者必须把价格压住整整 `twapWindow` 这么久，期间会被套利者吃掉。
///    `updateOracle()` 任何人可调（引导 cron 每小时调一次），trigger 结束也会自动记一次观测。
///  - 单次批量会按池子深度自动封顶（见 `_maxSafeBatch`）：积压再多也不会因为价格冲击超标而卡死，只是分多轮消化。
///  - owner 能做的事有明确边界：调参（激励下限不超过阈值的 5%）、换 / 永久锁定 LP 接收地址、暂停、救援无关代币。
///    拿不走 PTC、USDT、LP；也不能放弃所有权（避免暂停后无人能恢复）。
contract FeeDispositionModule is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────── 类型 ───────────────────────────

    /// @dev 所有可运营参数集中在一个 struct 里，方便一次性校验彼此的约束关系（见 `_validateConfig`）。
    struct Config {
        /// 合约 PTC 余额达到多少（wei）后 `trigger()` 才可调用
        uint256 threshold;
        /// 单次处置最多处理多少 PTC（wei）；0 表示不限制。用来把单次卖出规模压在池子深度之内
        uint256 maxBatch;
        /// 激励的绝对下限（wei）。BSC 上一次 trigger 的 gas 远高于「万分之几 × 一天的手续费」，
        /// 没有这个下限外部 keeper 永远不会来调用
        uint256 minIncentive;
        /// 销毁比例（bps）。流动性比例 = 10000 - burnBps
        uint16 burnBps;
        /// 调用者激励比例（bps），按整批计算
        uint16 callerIncentiveBps;
        /// swap 与 addLiquidity 的最大可接受滑点（bps），同时也是本次 swap 相对现价的最大价格冲击
        uint16 slippageBps;
        /// 两次 trigger 之间的最短间隔（秒），0 表示不限制
        uint32 minInterval;
        /// TWAP 观测窗口（秒）。参考观测点必须至少这么老才有效；0 表示关闭 TWAP 校验（紧急逃生口，不建议）
        uint32 twapWindow;
        /// 现价相对 TWAP 的最大允许偏差（bps，双向）；同时也是 swap / addLiquidity 相对 TWAP 的最低成交价容忍度
        uint16 maxTwapDeviationBps;
    }

    /// @dev pair 的累计价格观测点。两槽轮换：只有当 newest 已经比 twapWindow 老，才会被推入 oldest，
    ///      这样攻击者无法通过高频 update 让「够老的观测点」永远不存在
    struct Observation {
        uint256 priceCumulative;
        uint32 timestamp;
    }

    /// @dev 一次处置的金额拆分。恒等式：incentive + burn + swap + pair == batch。
    struct Split {
        uint256 batch;
        uint256 incentive;
        uint256 burn;
        uint256 swap;
        uint256 pair;
    }

    // ─────────────────────────── 常量 / 不可变量 ───────────────────────────

    uint256 public constant BPS = 10_000;
    /// @dev 激励上限 5%、滑点上限 10%：防止 owner 误配把整批手续费当激励发出去，或把滑点放到毫无保护的程度
    uint16 public constant MAX_CALLER_INCENTIVE_BPS = 500;
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;
    /// @dev 池子手续费 0.25%（PancakeSwap V2）：滑点容忍低于它任何 swap 都过不了，所以下限设为 50
    uint256 public constant POOL_FEE_BPS = 25;
    uint16 public constant MIN_SLIPPAGE_BPS = 50;
    /// @dev TWAP 偏差上限 50%：再大就等于没有校验
    uint16 public constant MAX_TWAP_DEVIATION_BPS = 5_000;
    uint256 private constant Q112 = 2 ** 112;
    /// @dev PTC 没有原生 burn()，销毁 = 转到公认的黑洞地址
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable PTC;
    IERC20 public immutable USDT;
    IPancakeRouter02 public immutable ROUTER;
    IPancakePair public immutable PAIR;
    /// @dev 池子里 token0/token1 的顺序由地址大小决定，部署时定死，避免每次 getReserves 后再比较
    bool public immutable PTC_IS_TOKEN0;

    // ─────────────────────────── 状态 ───────────────────────────

    Config public config;
    /// @notice LP 代币的接收地址（销毁地址或锁仓合约）。绝不是调用者
    address public lpRecipient;
    /// @notice 一旦锁定，lpRecipient 永远不能再改：把「LP 去哪」从 owner 的承诺变成链上事实
    bool public lpRecipientLocked;
    uint64 public lastTriggerAt;
    uint256 public triggerCount;
    Observation public observationOld;
    Observation public observationNew;

    /// @dev 累计统计，供 Treasury 看板直接读取，不必回放事件
    uint256 public totalBurned;
    uint256 public totalIncentivePaid;
    uint256 public totalPtcToLiquidity;
    uint256 public totalUsdtToLiquidity;
    uint256 public totalLpMinted;

    // ─────────────────────────── 事件 ───────────────────────────

    event FeeDisposed(
        address indexed caller,
        uint256 batch,
        uint256 incentive,
        uint256 burned,
        uint256 swappedPtc,
        uint256 usdtReceived,
        uint256 ptcToLiquidity,
        uint256 usdtToLiquidity,
        uint256 lpMinted,
        uint256 ptcCarried,
        uint256 usdtCarried
    );
    event ConfigUpdated(Config config);
    event LpRecipientUpdated(address indexed previous, address indexed current);
    event LpRecipientLocked(address indexed recipient);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event OracleUpdated(uint256 priceCumulative, uint32 timestamp);

    // ─────────────────────────── 错误 ───────────────────────────

    error ZeroAddress();
    error PairNotFound();
    error BelowThreshold(uint256 balance, uint256 threshold);
    error IntervalNotElapsed(uint64 lastTriggerAt, uint32 minInterval);
    error IncentiveExceedsBatch(uint256 incentive, uint256 batch);
    error PriceImpactTooHigh(uint256 quotedOut, uint256 minAcceptableOut);
    error InsufficientOutput(uint256 received, uint256 minRequired);
    error AccountingMismatch();
    error TwapUnavailable();
    error PriceDeviatesFromTwap(uint256 spotPriceQ112, uint256 twapPriceQ112, uint16 maxDeviationBps);
    error InvalidConfig(string reason);
    error RescueNotAllowed(address token);
    error LpRecipientIsLocked();
    error RenounceDisabled();

    // ─────────────────────────── 构造 ───────────────────────────

    constructor(
        address initialOwner,
        address ptc,
        address usdt,
        address router,
        address lpRecipient_,
        Config memory initialConfig
    ) Ownable(initialOwner) {
        if (ptc == address(0) || usdt == address(0) || router == address(0)) revert ZeroAddress();
        PTC = IERC20(ptc);
        USDT = IERC20(usdt);
        ROUTER = IPancakeRouter02(router);
        address pair = IPancakeFactory(ROUTER.factory()).getPair(ptc, usdt);
        if (pair == address(0)) revert PairNotFound();
        PAIR = IPancakePair(pair);
        PTC_IS_TOKEN0 = PAIR.token0() == ptc;

        _setLpRecipient(lpRecipient_);
        _setConfig(initialConfig);
        // 部署即记第一个观测点：twapWindow 之后就能触发，不需要额外的初始化步骤
        _updateOracle();
    }

    // ─────────────────────────── 核心：trigger ───────────────────────────

    /// @notice 任何地址都可调用。把当前累计的手续费 PTC 按配置一次性处置完毕。
    /// @param minUsdtOut 调用者自带的 swap 最低产出（来自链下报价）。传 0 则只依赖链上报价 − 滑点；
    ///        引导 cron 必须传链下报价得出的值，这是对三明治攻击唯一真正有效的防线。
    function trigger(uint256 minUsdtOut) external nonReentrant whenNotPaused returns (Split memory s) {
        Config memory c = config;
        Run memory r;
        r.ptcBefore = PTC.balanceOf(address(this));
        r.usdtBefore = USDT.balanceOf(address(this));

        if (r.ptcBefore < c.threshold) revert BelowThreshold(r.ptcBefore, c.threshold);
        if (c.minInterval != 0 && lastTriggerAt != 0 && block.timestamp < uint256(lastTriggerAt) + c.minInterval) {
            revert IntervalNotElapsed(lastTriggerAt, c.minInterval);
        }

        // 先改状态再做外部调用（CEI）；nonReentrant 之外再多一道保险
        lastTriggerAt = uint64(block.timestamp);
        triggerCount += 1;

        (r.reservePtc, r.reserveUsdt) = _reserves();
        uint256 batch = _effectiveBatch(r.ptcBefore, r.reservePtc, c);
        s = computeSplit(batch, _usdtToPtcAtSpot(r.usdtBefore, r.reservePtc, r.reserveUsdt), c);
        (s, r.quoted) = _foldDustSwap(s);

        if (s.swap != 0 || s.pair != 0) r.twap = _requireTwap(r.reservePtc, r.reserveUsdt, c);

        if (s.incentive != 0) PTC.safeTransfer(msg.sender, s.incentive);
        if (s.burn != 0) PTC.safeTransfer(BURN_ADDRESS, s.burn);

        if (s.swap != 0) r.usdtOut = _swapPtcForUsdt(s.swap, minUsdtOut, r, c);

        uint256 usdtAvailable = r.usdtBefore + r.usdtOut;
        if (s.pair != 0 && usdtAvailable != 0) {
            (r.ptcUsed, r.usdtUsed, r.lpMinted) = _addLiquidity(s.pair, usdtAvailable, r.twap, c);
        }

        _settle(s, r, usdtAvailable);
        _updateOracle();
    }

    /// @dev trigger 的中间量集中放在 memory struct 里，否则局部变量太多会触发 stack too deep
    struct Run {
        uint256 ptcBefore;
        uint256 usdtBefore;
        uint256 reservePtc;
        uint256 reserveUsdt;
        uint256 usdtOut;
        uint256 ptcUsed;
        uint256 usdtUsed;
        uint256 lpMinted;
        uint256 quoted;
        uint256 twap;
    }

    /// @dev 对账 + 统计 + 事件。余额必须精确对得上账：PTC 已验证无转账税，任何差异都说明有人动了手脚
    function _settle(Split memory s, Run memory r, uint256 usdtAvailable) internal {
        uint256 ptcAfter = PTC.balanceOf(address(this));
        uint256 usdtAfter = USDT.balanceOf(address(this));
        if (ptcAfter != r.ptcBefore - s.incentive - s.burn - s.swap - r.ptcUsed) revert AccountingMismatch();
        if (usdtAfter != usdtAvailable - r.usdtUsed) revert AccountingMismatch();

        totalBurned += s.burn;
        totalIncentivePaid += s.incentive;
        totalPtcToLiquidity += r.ptcUsed;
        totalUsdtToLiquidity += r.usdtUsed;
        totalLpMinted += r.lpMinted;

        emit FeeDisposed(
            msg.sender,
            s.batch,
            s.incentive,
            s.burn,
            s.swap,
            r.usdtOut,
            r.ptcUsed,
            r.usdtUsed,
            r.lpMinted,
            ptcAfter,
            usdtAfter
        );
    }

    // ─────────────────────────── 只读辅助 ───────────────────────────

    /// @notice 当前待处置的手续费 PTC（即合约余额）
    function accumulatedFeePTC() external view returns (uint256) {
        return PTC.balanceOf(address(this));
    }

    /// @notice 供引导 cron / keeper 在发交易前判断，避免白白花 gas 去 revert
    function canTrigger() external view returns (bool callable, string memory reason) {
        Config memory c = config;
        if (paused()) return (false, "paused");
        uint256 bal = PTC.balanceOf(address(this));
        if (bal < c.threshold) return (false, "below threshold");
        if (c.minInterval != 0 && lastTriggerAt != 0 && block.timestamp < uint256(lastTriggerAt) + c.minInterval) {
            return (false, "interval not elapsed");
        }
        (uint256 reservePtc, uint256 reserveUsdt) = _reserves();
        (,, uint8 code) = _twapStatus(reservePtc, reserveUsdt, c);
        if (code == 1) return (false, "twap unavailable");
        if (code == 2) return (false, "price deviates from twap");
        return (true, "");
    }

    /// @notice 预览下一次 trigger 的拆分和预计换到的 USDT（用于 keeper 估算是否值得调用）
    function previewTrigger() external view returns (Split memory s, uint256 expectedUsdtOut) {
        Config memory c = config;
        uint256 bal = PTC.balanceOf(address(this));
        // 阈值以下不预览：computeSplit 在 batch <= minIncentive 时会 revert，keeper 轮询时不该被 revert 打断
        if (bal < c.threshold) return (s, 0);
        (uint256 reservePtc, uint256 reserveUsdt) = _reserves();
        uint256 batch = _effectiveBatch(bal, reservePtc, c);
        s = computeSplit(batch, _usdtToPtcAtSpot(USDT.balanceOf(address(this)), reservePtc, reserveUsdt), c);
        (s, expectedUsdtOut) = _foldDustSwap(s);
    }

    /// @notice 按当前池子深度算出的单次最大安全批量（价格冲击 ≤ slippageBps）
    function maxSafeBatch() external view returns (uint256) {
        (uint256 reservePtc,) = _reserves();
        return _maxSafeBatch(reservePtc, config);
    }

    /// @notice 任何人可调：把 pair 当前的累计价格记为观测点（两槽轮换，见 Observation）。
    ///         引导 cron 建议每小时调一次，保证 trigger 时总有一个「刚好够老」的参考点。
    function updateOracle() external {
        _updateOracle();
    }

    /// @notice 当前 TWAP 价（USDT/PTC，Q112 定点）与其参考观测点的年龄；无可用参考点时返回 (0, 0)
    function twapPrice() external view returns (uint256 priceQ112, uint32 age) {
        (Observation memory ref, bool ok) = _referenceObservation(config.twapWindow);
        if (!ok) return (0, 0);
        (uint256 cumNow, uint32 tNow) = _currentCumulative();
        age = tNow - ref.timestamp;
        unchecked {
            priceQ112 = (cumNow - ref.priceCumulative) / age;
        }
    }

    /// @notice 纯函数拆分，便于链下复算与 fuzz 测试。
    /// @param usdtHeldInPtc 合约里已有 USDT 按现价折算的 PTC 数量：这部分不需要再 swap，直接参与配对
    function computeSplit(uint256 batch, uint256 usdtHeldInPtc, Config memory c) public pure returns (Split memory s) {
        s.batch = batch;
        s.incentive = batch * c.callerIncentiveBps / BPS;
        if (s.incentive < c.minIncentive) s.incentive = c.minIncentive;
        if (s.incentive >= batch) revert IncentiveExceedsBatch(s.incentive, batch);

        uint256 remainder = batch - s.incentive;
        s.burn = remainder * c.burnBps / BPS;
        uint256 liquidity = remainder - s.burn;
        // 目标是 swap 后手里的 USDT 价值 ≈ 留下的 PTC 价值；已持有的 USDT 先抵掉一部分需要卖出的 PTC
        s.swap = liquidity > usdtHeldInPtc ? (liquidity - usdtHeldInPtc) / 2 : 0;
        s.pair = liquidity - s.swap;
    }

    // ─────────────────────────── Owner 管理 ───────────────────────────

    function setConfig(Config calldata newConfig) external onlyOwner {
        _setConfig(newConfig);
    }

    function setLpRecipient(address newRecipient) external onlyOwner {
        _setLpRecipient(newRecipient);
    }

    /// @notice 单向操作：永久冻结 lpRecipient。LP 销毁的承诺从此不再依赖 owner 的自觉
    function lockLpRecipient() external onlyOwner {
        lpRecipientLocked = true;
        emit LpRecipientLocked(lpRecipient);
    }

    /// @dev 放弃所有权会让暂停后的合约永远无人能恢复；owner 想退出应转移给新地址而不是丢掉
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice 只允许救援误转进来的其它代币。PTC、USDT、LP 是机制本身的资金，owner 也不能取走，
    ///         否则「不依赖公司私钥」的承诺就不成立。
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(PTC) || token == address(USDT) || token == address(PAIR)) revert RescueNotAllowed(token);
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ─────────────────────────── 内部 ───────────────────────────

    function _swapPtcForUsdt(uint256 amountIn, uint256 callerMinOut, Run memory r, Config memory c)
        internal
        returns (uint256 usdtOut)
    {
        // 价格冲击兜底：批量已按 _maxSafeBatch 封顶，正常情况下这里永远不会触发
        uint256 minAcceptable = amountIn * r.reserveUsdt * (BPS - c.slippageBps) / r.reservePtc / BPS;
        if (r.quoted < minAcceptable) revert PriceImpactTooHigh(r.quoted, minAcceptable);

        uint256 minOut = r.quoted * (BPS - c.slippageBps) / BPS;
        // 真正的价格底线来自 TWAP 而不是当前报价：当前报价可以被同一笔交易里的前置砸盘操纵，TWAP 不能
        if (r.twap != 0) {
            uint256 twapFloor = Math.mulDiv(amountIn, r.twap, Q112) * (BPS - c.maxTwapDeviationBps) / BPS;
            if (twapFloor > minOut) minOut = twapFloor;
        }
        if (callerMinOut > minOut) minOut = callerMinOut;

        PTC.forceApprove(address(ROUTER), amountIn);
        uint256[] memory amounts =
            ROUTER.swapExactTokensForTokens(amountIn, minOut, _pathPtcToUsdt(), address(this), block.timestamp);
        usdtOut = amounts[amounts.length - 1];
        // Router 自己也会校验 amountOutMin，这里再兜一层，防范非标准 router 返回值造假
        if (usdtOut < minOut) revert InsufficientOutput(usdtOut, minOut);
    }

    function _addLiquidity(uint256 ptcDesired, uint256 usdtDesired, uint256 twap, Config memory c)
        internal
        returns (uint256 ptcUsed, uint256 usdtUsed, uint256 lpMinted)
    {
        (uint256 ptcMin, uint256 usdtMin) = _liquidityMins(ptcDesired, usdtDesired, twap, c);
        PTC.forceApprove(address(ROUTER), ptcDesired);
        USDT.forceApprove(address(ROUTER), usdtDesired);
        (ptcUsed, usdtUsed, lpMinted) = ROUTER.addLiquidity(
            address(PTC), address(USDT), ptcDesired, usdtDesired, ptcMin, usdtMin, lpRecipient, block.timestamp
        );
        // 未用完的授权归零，不给 router 留任何余量
        PTC.forceApprove(address(ROUTER), 0);
        USDT.forceApprove(address(ROUTER), 0);
    }

    /// @dev addLiquidity 的两侧下限：先按「swap 之后的当前储备」推导，再用 TWAP 抬高。
    ///      router 会按当前比例配对；若当前比例被操纵到偏离 TWAP 超过容忍度，TWAP 下限会让 addLiquidity
    ///      直接失败，而不是按坏价配对。分支选择与 router 内部逻辑一致（先试 PTC 全用，否则 USDT 全用）
    function _liquidityMins(uint256 ptcDesired, uint256 usdtDesired, uint256 twap, Config memory c)
        internal
        view
        returns (uint256 ptcMin, uint256 usdtMin)
    {
        (uint256 reservePtc, uint256 reserveUsdt) = _reserves();
        if (ptcDesired * reserveUsdt / reservePtc <= usdtDesired) {
            ptcMin = ptcDesired * (BPS - c.slippageBps) / BPS;
            usdtMin = ptcDesired * reserveUsdt * (BPS - c.slippageBps) / reservePtc / BPS;
            if (twap != 0) {
                uint256 fromTwap = Math.mulDiv(ptcDesired, twap, Q112) * (BPS - c.maxTwapDeviationBps) / BPS;
                if (fromTwap > usdtMin) usdtMin = fromTwap;
            }
        } else {
            ptcMin = usdtDesired * reservePtc * (BPS - c.slippageBps) / reserveUsdt / BPS;
            usdtMin = usdtDesired * (BPS - c.slippageBps) / BPS;
            if (twap != 0) {
                uint256 fromTwap = Math.mulDiv(usdtDesired, Q112, twap) * (BPS - c.maxTwapDeviationBps) / BPS;
                if (fromTwap > ptcMin) ptcMin = fromTwap;
            }
        }
    }

    /// @dev 单次批量上限：让 swap 部分相对现价的劣化（含池子手续费）不超过 slippageBps。
    ///      推导：V2 报价 out = in·f·Ru/(Rp + in·f)，f = 1 − 0.25%；要求 out ≥ in·Ru/Rp·(1 − s)
    ///      ⇒ in ≤ Rp·(s − fee)/((1 − s)·f)。再由 swap ≈ batch·(1 − inc)·(1 − burn)/2 反推 batch。
    ///      minIncentive 与已持有的 USDT 只会让实际 swap 更小，所以这个上限是保守的。
    function _maxSafeBatch(uint256 reservePtc, Config memory c) internal pure returns (uint256) {
        if (c.burnBps == BPS) return type(uint256).max;
        uint256 maxSwap =
            reservePtc * BPS * (uint256(c.slippageBps) - POOL_FEE_BPS) / ((BPS - c.slippageBps) * (BPS - POOL_FEE_BPS));
        maxSwap = maxSwap * 999 / 1000; // 整数舍入余量，保证兜底检查不会因 1 wei 误差触发
        return Math.mulDiv(maxSwap * 2, BPS * BPS, (BPS - c.callerIncentiveBps) * (BPS - c.burnBps));
    }

    function _effectiveBatch(uint256 balance, uint256 reservePtc, Config memory c)
        internal
        pure
        returns (uint256 batch)
    {
        batch = balance;
        if (c.maxBatch != 0 && batch > c.maxBatch) batch = c.maxBatch;
        uint256 safe = _maxSafeBatch(reservePtc, c);
        if (batch > safe) batch = safe;
    }

    /// @dev swap 量小到 router 报价为 0（十几到一百多 wei）时，真实 pair 会以 INSUFFICIENT_OUTPUT_AMOUNT 拒绝；
    ///      这种尘埃直接并入配对部分，不卖了。只有当合约里刚好持有几乎等值的 USDT 时才会出现
    function _foldDustSwap(Split memory s) internal view returns (Split memory, uint256 quoted) {
        if (s.swap == 0) return (s, 0);
        quoted = ROUTER.getAmountsOut(s.swap, _pathPtcToUsdt())[1];
        if (quoted == 0) {
            s.pair += s.swap;
            s.swap = 0;
        }
        return (s, quoted);
    }

    /// @dev 现价必须落在 TWAP ± maxTwapDeviationBps 内，否则说明有人刚砸/拉过价，本轮拒绝成交。返回 TWAP 供定价下限使用
    function _requireTwap(uint256 reservePtc, uint256 reserveUsdt, Config memory c)
        internal
        view
        returns (uint256 twap)
    {
        uint256 spot;
        uint8 code;
        (twap, spot, code) = _twapStatus(reservePtc, reserveUsdt, c);
        if (code == 1) revert TwapUnavailable();
        if (code == 2) revert PriceDeviatesFromTwap(spot, twap, c.maxTwapDeviationBps);
    }

    /// @return twap USDT/PTC 的时间加权价（Q112）；关闭校验时为 0
    /// @return spot 当前现价（Q112）
    /// @return code 0 = 可以成交，1 = 没有够老的观测点，2 = 现价偏离 TWAP 过大
    function _twapStatus(uint256 reservePtc, uint256 reserveUsdt, Config memory c)
        internal
        view
        returns (uint256 twap, uint256 spot, uint8 code)
    {
        if (c.twapWindow == 0) return (0, 0, 0);
        (Observation memory ref, bool ok) = _referenceObservation(c.twapWindow);
        if (!ok) return (0, 0, 1);
        (uint256 cumNow, uint32 tNow) = _currentCumulative();
        unchecked {
            // 累计价格与时间戳按 V2 的约定允许溢出回绕，差值仍然正确
            twap = (cumNow - ref.priceCumulative) / (tNow - ref.timestamp);
        }
        spot = reserveUsdt * Q112 / reservePtc;
        uint256 diff = spot > twap ? spot - twap : twap - spot;
        if (diff * BPS > twap * c.maxTwapDeviationBps) return (twap, spot, 2);
    }

    /// @dev 取「至少 twapWindow 这么老」的观测点：优先 newest，不够老就退回 oldest
    function _referenceObservation(uint32 window) internal view returns (Observation memory ref, bool ok) {
        uint32 nowTs = uint32(block.timestamp);
        Observation memory n = observationNew;
        if (n.timestamp != 0 && nowTs - n.timestamp >= window) return (n, true);
        Observation memory o = observationOld;
        if (o.timestamp != 0 && nowTs - o.timestamp >= window) return (o, true);
        return (ref, false);
    }

    function _updateOracle() internal {
        (uint256 cumNow, uint32 tNow) = _currentCumulative();
        Observation memory n = observationNew;
        // newest 还不够老就不动它：否则攻击者可以每个区块都 update，让「够老的参考点」永远不出现
        if (n.timestamp != 0 && tNow - n.timestamp < config.twapWindow) return;
        if (n.timestamp != 0) observationOld = n;
        observationNew = Observation({priceCumulative: cumNow, timestamp: tNow});
        emit OracleUpdated(cumNow, tNow);
    }

    /// @dev 等价于 UniswapV2OracleLibrary.currentCumulativePrices：pair 只在自己被交易时才累加，
    ///      这里把「上次更新到现在」这段时间按当前储备补上，否则冷门时段的 TWAP 会漏掉最新价格
    function _currentCumulative() internal view returns (uint256 cumulative, uint32 blockTs) {
        blockTs = uint32(block.timestamp);
        (uint112 r0, uint112 r1, uint32 pairTs) = PAIR.getReserves();
        cumulative = PTC_IS_TOKEN0 ? PAIR.price0CumulativeLast() : PAIR.price1CumulativeLast();
        if (pairTs != blockTs && r0 != 0 && r1 != 0) {
            (uint256 rPtc, uint256 rUsdt) = PTC_IS_TOKEN0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            unchecked {
                cumulative += (rUsdt * Q112 / rPtc) * (blockTs - pairTs);
            }
        }
    }

    function _reserves() internal view returns (uint256 reservePtc, uint256 reserveUsdt) {
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        (reservePtc, reserveUsdt) = PTC_IS_TOKEN0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _usdtToPtcAtSpot(uint256 usdtAmount, uint256 reservePtc, uint256 reserveUsdt)
        internal
        pure
        returns (uint256)
    {
        if (usdtAmount == 0 || reserveUsdt == 0) return 0;
        return usdtAmount * reservePtc / reserveUsdt;
    }

    function _pathPtcToUsdt() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(PTC);
        path[1] = address(USDT);
    }

    function _setLpRecipient(address newRecipient) internal {
        if (lpRecipientLocked) revert LpRecipientIsLocked();
        if (newRecipient == address(0)) revert ZeroAddress();
        emit LpRecipientUpdated(lpRecipient, newRecipient);
        lpRecipient = newRecipient;
    }

    function _setConfig(Config memory c) internal {
        _validateConfig(c);
        config = c;
        emit ConfigUpdated(c);
    }

    function _validateConfig(Config memory c) internal pure {
        if (c.threshold == 0) revert InvalidConfig("threshold=0");
        if (c.burnBps > BPS) revert InvalidConfig("burnBps>100%");
        if (c.callerIncentiveBps > MAX_CALLER_INCENTIVE_BPS) revert InvalidConfig("incentiveBps>max");
        if (c.slippageBps > MAX_SLIPPAGE_BPS) revert InvalidConfig("slippageBps>max");
        if (c.slippageBps < MIN_SLIPPAGE_BPS) revert InvalidConfig("slippageBps<min");
        // 激励下限不得超过批次的 5%：既保证 computeSplit 永远不会因激励吞掉整批而停摆，
        // 也堵住 owner 把「激励」调成整批余额、自己调用 trigger 把手续费拿走的路
        if (c.minIncentive > c.threshold * MAX_CALLER_INCENTIVE_BPS / BPS) {
            revert InvalidConfig("minIncentive>5%threshold");
        }
        if (c.maxBatch != 0 && c.minIncentive > c.maxBatch * MAX_CALLER_INCENTIVE_BPS / BPS) {
            revert InvalidConfig("minIncentive>5%maxBatch");
        }
        if (c.maxTwapDeviationBps > MAX_TWAP_DEVIATION_BPS) revert InvalidConfig("twapDeviation>max");
        if (c.twapWindow != 0 && c.maxTwapDeviationBps == 0) revert InvalidConfig("twapDeviation=0");
    }
}
