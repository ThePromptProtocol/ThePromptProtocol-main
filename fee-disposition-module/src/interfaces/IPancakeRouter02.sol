// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice PancakeSwap V2 Router 的最小接口。PTC 已在 fork 上验证为无转账税的普通 ERC20，
///         因此不需要 SupportingFeeOnTransferTokens 系列变体。
interface IPancakeRouter02 {
    function factory() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
