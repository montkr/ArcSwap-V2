// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Pool Interface
/// @notice Common interface for StableSwapPool and ConstantProductPool
interface IPool {
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
    function getAmountOut(uint256 tokenInIndex, uint256 amountIn) external view returns (uint256);
    function swap(uint256 tokenInIndex, uint256 amountIn, uint256 minAmountOut, address receiver) external returns (uint256);
    function balances() external view returns (uint256[2] memory);
}
