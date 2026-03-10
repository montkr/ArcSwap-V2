// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ConstantProductPool.sol";
import "../src/MultiRouter.sol";
import "../src/StableSwapPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken2 is ERC20 {
    uint8 private _dec;
    constructor(string memory name, string memory symbol, uint8 dec_) ERC20(name, symbol) {
        _dec = dec_;
    }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract ConstantProductPoolTest is Test {
    ConstantProductPool cpPool;
    MockToken2 usdc;
    MockToken2 eurc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockToken2("USDC", "USDC", 6);
        eurc = new MockToken2("EURC", "EURC", 6);

        // 0.3% fee
        cpPool = new ConstantProductPool(
            address(usdc), address(eurc), 3000,
            "ArcSwap USDC/EURC CP LP", "cpLP-USDC-EURC"
        );

        usdc.mint(alice, 10_000_000e6);
        eurc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 100_000e6);
        eurc.mint(bob, 100_000e6);
    }

    // ==================== Add Liquidity ====================

    function test_addLiquidity_initial_respects_ratio() public {
        vm.startPrank(alice);
        usdc.approve(address(cpPool), type(uint256).max);
        eurc.approve(address(cpPool), type(uint256).max);

        // Add at real USDC/EURC rate: 1160 USDC + 1000 EURC
        uint256 lp = cpPool.addLiquidity([uint256(1160e6), uint256(1000e6)], 0);
        assertGt(lp, 0, "Should mint LP");

        // Check reserves
        uint256[2] memory bal = cpPool.balances();
        assertEq(bal[0], 1160e6, "Reserve0 = 1160 USDC");
        assertEq(bal[1], 1000e6, "Reserve1 = 1000 EURC");
        vm.stopPrank();
    }

    // ==================== Swap respects price ====================

    function test_swap_price_reflects_ratio() public {
        _addLiquidity_1_16();

        // 100 USDC -> should get ~86 EURC (1/1.16 * 100 minus fee and slippage)
        vm.startPrank(bob);
        usdc.approve(address(cpPool), type(uint256).max);
        uint256 amountOut = cpPool.swap(0, 100e6, 0, bob);

        // At 1.16:1 ratio, 100 USDC should get approximately 86 EURC (minus fee + slippage)
        // price = 1000/1160 = 0.8621 EURC per USDC
        // With 0.3% fee and price impact: ~85-86 EURC
        assertGt(amountOut, 80e6, "Should get > 80 EURC");
        assertLt(amountOut, 90e6, "Should get < 90 EURC (not 1:1)");
        vm.stopPrank();
    }

    function test_swap_reverse_price() public {
        _addLiquidity_1_16();

        // 100 EURC -> should get ~116 USDC (minus fee and slippage)
        vm.startPrank(bob);
        eurc.approve(address(cpPool), type(uint256).max);
        uint256 amountOut = cpPool.swap(1, 100e6, 0, bob);

        // At 1.16:1 ratio, 100 EURC should get approximately 116 USDC
        assertGt(amountOut, 110e6, "Should get > 110 USDC");
        assertLt(amountOut, 120e6, "Should get < 120 USDC");
        vm.stopPrank();
    }

    function test_getAmountOut_preview() public {
        _addLiquidity_1_16();

        uint256 out = cpPool.getAmountOut(0, 100e6);
        assertGt(out, 80e6);
        assertLt(out, 90e6);
    }

    function test_swap_slippage_protection() public {
        _addLiquidity_1_16();

        vm.startPrank(bob);
        usdc.approve(address(cpPool), type(uint256).max);
        vm.expectRevert("Slippage");
        cpPool.swap(0, 100e6, 200e6, bob); // impossible minOut
        vm.stopPrank();
    }

    // ==================== Remove Liquidity ====================

    function test_removeLiquidity() public {
        _addLiquidity_1_16();

        vm.startPrank(alice);
        uint256 lpBal = cpPool.balanceOf(alice);
        uint256 quarter = lpBal / 4;

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 eurcBefore = eurc.balanceOf(alice);

        uint256[2] memory amounts = cpPool.removeLiquidity(quarter, [uint256(0), uint256(0)]);

        assertGt(amounts[0], 0, "Should receive USDC");
        assertGt(amounts[1], 0, "Should receive EURC");
        // Should maintain ratio ~1.16:1
        uint256 ratio = amounts[0] * 1000 / amounts[1];
        assertGt(ratio, 1100, "Ratio > 1.1");
        assertLt(ratio, 1200, "Ratio < 1.2");
        vm.stopPrank();
    }

    // ==================== Price functions ====================

    function test_price_functions() public {
        _addLiquidity_1_16();

        uint256 p0 = cpPool.price0(); // EURC per USDC (in 1e18)
        uint256 p1 = cpPool.price1(); // USDC per EURC (in 1e18)

        // price0 = 1000/1160 * 1e18 ≈ 0.862e18
        assertGt(p0, 0.85e18, "Price0 > 0.85");
        assertLt(p0, 0.87e18, "Price0 < 0.87");

        // price1 = 1160/1000 * 1e18 ≈ 1.16e18
        assertGt(p1, 1.15e18, "Price1 > 1.15");
        assertLt(p1, 1.17e18, "Price1 < 1.17");
    }

    // ==================== MultiRouter integration ====================

    function test_multiRouter_with_cpPool() public {
        _addLiquidity_1_16();

        MultiRouter router = new MultiRouter();
        router.addPool(address(cpPool));

        vm.startPrank(bob);
        usdc.approve(address(router), type(uint256).max);

        uint256 eurcBefore = eurc.balanceOf(bob);
        router.swap(address(usdc), address(eurc), 100e6, 0, bob, block.timestamp + 300);
        uint256 eurcAfter = eurc.balanceOf(bob);

        uint256 received = eurcAfter - eurcBefore;
        assertGt(received, 80e6, "Router swap works with CP pool");
        assertLt(received, 90e6, "Correct price through router");
        vm.stopPrank();
    }

    // ==================== Helpers ====================

    function _addLiquidity_1_16() internal {
        vm.startPrank(alice);
        usdc.approve(address(cpPool), type(uint256).max);
        eurc.approve(address(cpPool), type(uint256).max);
        // 1.16:1 ratio = real USDC/EURC rate
        cpPool.addLiquidity([uint256(116_000e6), uint256(100_000e6)], 0);
        vm.stopPrank();
    }
}
