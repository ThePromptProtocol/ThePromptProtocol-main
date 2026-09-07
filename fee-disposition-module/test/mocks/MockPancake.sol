// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev 用 PancakeSwap V2 的真实公式（0.25% 手续费、恒定乘积、最优配对）复刻的本地池子，
///      让单元测试离线也能验证真实数额；另带两个「故障注入」开关，专门用来证明合约把最小值传对了：
///      - swapPenaltyBps：swap 实际给付比报价少这么多（模拟一个不诚实/非标准的 router）
///      - liquidityRatioSkewBps：addLiquidity 时按偏移后的比例配对（模拟储备在报价与配对之间被改动）
contract MockPair is ERC20 {
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    constructor(address a, address b) ERC20("Pancake LPs", "Cake-LP") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @dev 与 UniswapV2Pair._update 一致：先按旧储备累加价格，再刷新储备
    function sync() public {
        uint32 ts = uint32(block.timestamp);
        unchecked {
            uint32 elapsed = ts - blockTimestampLast;
            if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
                price0CumulativeLast += (uint256(reserve1) * 2 ** 112 / reserve0) * elapsed;
                price1CumulativeLast += (uint256(reserve0) * 2 ** 112 / reserve1) * elapsed;
            }
        }
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
        blockTimestampLast = ts;
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - reserve0;
        uint256 amount1 = bal1 - reserve1;
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(amount0 * supply / reserve0, amount1 * supply / reserve1);
        }
        require(liquidity > 0, "Pancake: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        sync();
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "Pancake: INSUFFICIENT_OUTPUT_AMOUNT");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        sync();
    }
}

contract MockFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        pair = address(new MockPair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract MockRouter {
    MockFactory public immutable factoryContract;
    uint256 public swapPenaltyBps;
    uint256 public liquidityRatioSkewBps;

    constructor() {
        factoryContract = new MockFactory();
    }

    function factory() external view returns (address) {
        return address(factoryContract);
    }

    function setSwapPenaltyBps(uint256 bps) external {
        swapPenaltyBps = bps;
    }

    function setLiquidityRatioSkewBps(uint256 bps) external {
        liquidityRatioSkewBps = bps;
    }

    function _pair(address a, address b) internal view returns (MockPair) {
        return MockPair(factoryContract.getPair(a, b));
    }

    function _reserves(address a, address b) internal view returns (uint256 ra, uint256 rb) {
        MockPair p = _pair(a, b);
        (uint112 r0, uint112 r1,) = p.getReserves();
        (ra, rb) = a == p.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 9975;
        return amountInWithFee * reserveOut / (reserveIn * 10000 + amountInWithFee);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "mock: path");
        (uint256 ri, uint256 ro) = _reserves(path[0], path[1]);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = getAmountOut(amountIn, ri, ro);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        (uint256 ri, uint256 ro) = _reserves(path[0], path[1]);
        uint256 out = getAmountOut(amountIn, ri, ro);
        out = out * (10000 - swapPenaltyBps) / 10000;
        require(out >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MockPair p = _pair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, address(p), amountIn);
        (uint256 out0, uint256 out1) = path[1] == p.token0() ? (out, uint256(0)) : (uint256(0), out);
        p.swap(out0, out1, to);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        return amountA * reserveB / reserveA;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (uint256 ra, uint256 rb) = _reserves(tokenA, tokenB);
        // 故障注入：让 router 看到的储备比例与合约刚读到的不一致
        rb = rb * (10000 + liquidityRatioSkewBps) / 10000;
        if (ra == 0 && rb == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 bOptimal = quote(amountADesired, ra, rb);
            if (bOptimal <= amountBDesired) {
                require(bOptimal >= amountBMin, "PancakeRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, bOptimal);
            } else {
                uint256 aOptimal = quote(amountBDesired, rb, ra);
                assert(aOptimal <= amountADesired);
                require(aOptimal >= amountAMin, "PancakeRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (aOptimal, amountBDesired);
            }
        }
        MockPair p = _pair(tokenA, tokenB);
        IERC20(tokenA).transferFrom(msg.sender, address(p), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(p), amountB);
        liquidity = p.mint(to);
    }
}
