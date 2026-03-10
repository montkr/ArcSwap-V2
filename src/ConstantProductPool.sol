// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IPool.sol";

/// @title Constant Product Pool (Uniswap v2 style)
/// @notice x * y = k AMM — price is determined by reserve ratio
contract ConstantProductPool is IPool, ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 1e6;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public fee; // e.g. 3000 = 0.3%

    event Swap(
        address indexed sender,
        uint256 tokenInIndex,
        uint256 amountIn,
        uint256 amountOut,
        address indexed receiver
    );
    event AddLiquidity(
        address indexed provider,
        uint256[2] amounts,
        uint256 lpMinted
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256[2] amounts,
        uint256 lpBurned
    );

    constructor(
        address _token0,
        address _token1,
        uint256 _fee,
        string memory _lpName,
        string memory _lpSymbol
    ) ERC20(_lpName, _lpSymbol) Ownable(msg.sender) {
        require(_fee <= 50000, "Fee too high"); // max 5%
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        fee = _fee;
    }

    // ==================== View ====================

    function balances() public view returns (uint256[2] memory) {
        return [reserve0, reserve1];
    }

    function getAmountOut(uint256 tokenInIndex, uint256 amountIn) external view returns (uint256) {
        require(tokenInIndex < 2, "Invalid index");
        (uint256 reserveIn, uint256 reserveOut) = tokenInIndex == 0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        uint256 amountInAfterFee = amountIn * (FEE_DENOMINATOR - fee) / FEE_DENOMINATOR;
        return reserveOut * amountInAfterFee / (reserveIn + amountInAfterFee);
    }

    /// @notice Get price: how much token1 per 1 unit of token0
    function price0() external view returns (uint256) {
        if (reserve0 == 0) return 0;
        return reserve1 * 1e18 / reserve0;
    }

    /// @notice Get price: how much token0 per 1 unit of token1
    function price1() external view returns (uint256) {
        if (reserve1 == 0) return 0;
        return reserve0 * 1e18 / reserve1;
    }

    // ==================== State-Changing ====================

    function swap(
        uint256 tokenInIndex,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external nonReentrant returns (uint256 amountOut) {
        require(tokenInIndex < 2, "Invalid index");
        require(amountIn > 0, "Zero amount");
        if (receiver == address(0)) receiver = msg.sender;

        (IERC20 tokenIn, IERC20 tokenOut, uint256 reserveIn, uint256 reserveOut) = tokenInIndex == 0
            ? (token0, token1, reserve0, reserve1)
            : (token1, token0, reserve1, reserve0);

        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Transfer in
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        // x * y = k formula
        uint256 amountInAfterFee = amountIn * (FEE_DENOMINATOR - fee) / FEE_DENOMINATOR;
        amountOut = reserveOut * amountInAfterFee / (reserveIn + amountInAfterFee);

        require(amountOut >= minAmountOut, "Slippage");
        require(amountOut < reserveOut, "Insufficient reserves");

        // Transfer out
        tokenOut.safeTransfer(receiver, amountOut);

        // Update reserves
        _syncReserves();

        emit Swap(msg.sender, tokenInIndex, amountIn, amountOut, receiver);
    }

    function addLiquidity(
        uint256[2] calldata amounts,
        uint256 minLpAmount
    ) external nonReentrant returns (uint256 lpAmount) {
        uint256 _totalSupply = totalSupply();

        if (amounts[0] > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amounts[0]);
        }
        if (amounts[1] > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amounts[1]);
        }

        if (_totalSupply == 0) {
            // First deposit: LP = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
            lpAmount = _sqrt(amounts[0] * amounts[1]);
            require(lpAmount > MINIMUM_LIQUIDITY, "Insufficient initial liquidity");
            lpAmount -= MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY); // lock minimum
        } else {
            // Proportional: LP = min(a0/r0, a1/r1) * totalSupply
            uint256 lp0 = amounts[0] * _totalSupply / reserve0;
            uint256 lp1 = amounts[1] * _totalSupply / reserve1;
            lpAmount = lp0 < lp1 ? lp0 : lp1;
        }

        require(lpAmount >= minLpAmount, "Slippage");
        _mint(msg.sender, lpAmount);

        _syncReserves();

        emit AddLiquidity(msg.sender, amounts, lpAmount);
    }

    function removeLiquidity(
        uint256 lpAmount,
        uint256[2] calldata minAmounts
    ) external nonReentrant returns (uint256[2] memory amounts) {
        uint256 _totalSupply = totalSupply();
        require(lpAmount > 0 && lpAmount <= balanceOf(msg.sender), "Invalid LP amount");

        amounts[0] = reserve0 * lpAmount / _totalSupply;
        amounts[1] = reserve1 * lpAmount / _totalSupply;

        require(amounts[0] >= minAmounts[0], "Slippage token0");
        require(amounts[1] >= minAmounts[1], "Slippage token1");

        _burn(msg.sender, lpAmount);
        token0.safeTransfer(msg.sender, amounts[0]);
        token1.safeTransfer(msg.sender, amounts[1]);

        _syncReserves();

        emit RemoveLiquidity(msg.sender, amounts, lpAmount);
    }

    // ==================== Admin ====================

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= 50000, "Fee too high");
        fee = _fee;
    }

    // ==================== Internal ====================

    function _syncReserves() internal {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
