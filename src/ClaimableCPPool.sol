// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IPool.sol";

/// @title Claimable Constant Product Pool
/// @notice x*y=k AMM with separate fee claiming — fees are NOT mixed into reserves
contract ClaimableCPPool is IPool, ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 1e6;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant ACC_PRECISION = 1e18;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public fee; // e.g. 3000 = 0.3%

    // Fee accounting — accumulated fees per LP share (scaled by ACC_PRECISION)
    uint256 public accFeePerShare0;
    uint256 public accFeePerShare1;

    // Total unclaimed fees held by the contract
    uint256 public collectedFees0;
    uint256 public collectedFees1;

    // Per-user fee snapshots
    mapping(address => uint256) public userFeeDebt0;
    mapping(address => uint256) public userFeeDebt1;
    mapping(address => uint256) public pendingFees0;
    mapping(address => uint256) public pendingFees1;

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
    event ClaimFees(address indexed user, uint256 amount0, uint256 amount1);

    constructor(
        address _token0,
        address _token1,
        uint256 _fee,
        string memory _lpName,
        string memory _lpSymbol
    ) ERC20(_lpName, _lpSymbol) Ownable(msg.sender) {
        require(_fee <= 50000, "Fee too high");
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

    function price0() external view returns (uint256) {
        if (reserve0 == 0) return 0;
        return reserve1 * 1e18 / reserve0;
    }

    function price1() external view returns (uint256) {
        if (reserve1 == 0) return 0;
        return reserve0 * 1e18 / reserve1;
    }

    /// @notice View pending claimable fees for a user
    function claimable(address user) external view returns (uint256 f0, uint256 f1) {
        uint256 lp = balanceOf(user);
        f0 = pendingFees0[user];
        f1 = pendingFees1[user];
        if (lp > 0) {
            f0 += lp * (accFeePerShare0 - userFeeDebt0[user]) / ACC_PRECISION;
            f1 += lp * (accFeePerShare1 - userFeeDebt1[user]) / ACC_PRECISION;
        }
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

        (IERC20 tokenIn,, uint256 reserveIn, uint256 reserveOut) = tokenInIndex == 0
            ? (token0, token1, reserve0, reserve1)
            : (token1, token0, reserve1, reserve0);

        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Transfer in
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        // Separate fee from input
        uint256 feeAmount = amountIn * fee / FEE_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - feeAmount;

        // x * y = k on reserves (fee excluded)
        amountOut = reserveOut * amountInAfterFee / (reserveIn + amountInAfterFee);

        require(amountOut >= minAmountOut, "Slippage");
        require(amountOut < reserveOut, "Insufficient reserves");

        // Transfer out
        IERC20 tokenOut = tokenInIndex == 0 ? token1 : token0;
        tokenOut.safeTransfer(receiver, amountOut);

        // Update reserves (fee NOT included)
        if (tokenInIndex == 0) {
            reserve0 += amountInAfterFee;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountInAfterFee;
            reserve0 -= amountOut;
        }

        // Distribute fee to LP holders
        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0) {
            if (tokenInIndex == 0) {
                collectedFees0 += feeAmount;
                accFeePerShare0 += feeAmount * ACC_PRECISION / _totalSupply;
            } else {
                collectedFees1 += feeAmount;
                accFeePerShare1 += feeAmount * ACC_PRECISION / _totalSupply;
            }
        }

        emit Swap(msg.sender, tokenInIndex, amountIn, amountOut, receiver);
    }

    function addLiquidity(
        uint256[2] calldata amounts,
        uint256 minLpAmount
    ) external nonReentrant returns (uint256 lpAmount) {
        // Snapshot fees before LP balance changes
        _updateFees(msg.sender);

        uint256 _totalSupply = totalSupply();

        if (amounts[0] > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amounts[0]);
        }
        if (amounts[1] > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amounts[1]);
        }

        if (_totalSupply == 0) {
            lpAmount = _sqrt(amounts[0] * amounts[1]);
            require(lpAmount > MINIMUM_LIQUIDITY, "Insufficient initial liquidity");
            lpAmount -= MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
            // Set debt for locked LP (address(1) won't claim)
        } else {
            uint256 lp0 = amounts[0] * _totalSupply / reserve0;
            uint256 lp1 = amounts[1] * _totalSupply / reserve1;
            lpAmount = lp0 < lp1 ? lp0 : lp1;
        }

        require(lpAmount >= minLpAmount, "Slippage");
        _mint(msg.sender, lpAmount);

        // Update reserves (exclude collected fees)
        reserve0 = token0.balanceOf(address(this)) - collectedFees0;
        reserve1 = token1.balanceOf(address(this)) - collectedFees1;

        // Reset debt to current accumulator after mint
        userFeeDebt0[msg.sender] = accFeePerShare0;
        userFeeDebt1[msg.sender] = accFeePerShare1;

        emit AddLiquidity(msg.sender, amounts, lpAmount);
    }

    function removeLiquidity(
        uint256 lpAmount,
        uint256[2] calldata minAmounts
    ) external nonReentrant returns (uint256[2] memory amounts) {
        // Snapshot fees before LP balance changes
        _updateFees(msg.sender);

        uint256 _totalSupply = totalSupply();
        require(lpAmount > 0 && lpAmount <= balanceOf(msg.sender), "Invalid LP amount");

        amounts[0] = reserve0 * lpAmount / _totalSupply;
        amounts[1] = reserve1 * lpAmount / _totalSupply;

        require(amounts[0] >= minAmounts[0], "Slippage token0");
        require(amounts[1] >= minAmounts[1], "Slippage token1");

        _burn(msg.sender, lpAmount);
        token0.safeTransfer(msg.sender, amounts[0]);
        token1.safeTransfer(msg.sender, amounts[1]);

        // Update reserves
        reserve0 -= amounts[0];
        reserve1 -= amounts[1];

        // Reset debt
        userFeeDebt0[msg.sender] = accFeePerShare0;
        userFeeDebt1[msg.sender] = accFeePerShare1;

        emit RemoveLiquidity(msg.sender, amounts, lpAmount);
    }

    /// @notice Claim accumulated trading fees
    function claimFees() external nonReentrant {
        _updateFees(msg.sender);

        uint256 f0 = pendingFees0[msg.sender];
        uint256 f1 = pendingFees1[msg.sender];
        require(f0 > 0 || f1 > 0, "No fees to claim");

        if (f0 > 0) {
            pendingFees0[msg.sender] = 0;
            collectedFees0 -= f0;
            token0.safeTransfer(msg.sender, f0);
        }
        if (f1 > 0) {
            pendingFees1[msg.sender] = 0;
            collectedFees1 -= f1;
            token1.safeTransfer(msg.sender, f1);
        }

        emit ClaimFees(msg.sender, f0, f1);
    }

    // ==================== Admin ====================

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= 50000, "Fee too high");
        fee = _fee;
    }

    // ==================== Internal ====================

    /// @dev Snapshot pending fees for a user before their LP balance changes
    function _updateFees(address user) internal {
        uint256 lp = balanceOf(user);
        if (lp > 0) {
            pendingFees0[user] += lp * (accFeePerShare0 - userFeeDebt0[user]) / ACC_PRECISION;
            pendingFees1[user] += lp * (accFeePerShare1 - userFeeDebt1[user]) / ACC_PRECISION;
        }
        userFeeDebt0[user] = accFeePerShare0;
        userFeeDebt1[user] = accFeePerShare1;
    }

    /// @dev Handle fee snapshots on LP token transfers
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _updateFees(from);
        if (to != address(0)) _updateFees(to);
        super._update(from, to, value);
        // Reset debt after balance change
        if (from != address(0)) {
            userFeeDebt0[from] = accFeePerShare0;
            userFeeDebt1[from] = accFeePerShare1;
        }
        if (to != address(0)) {
            userFeeDebt0[to] = accFeePerShare0;
            userFeeDebt1[to] = accFeePerShare1;
        }
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
