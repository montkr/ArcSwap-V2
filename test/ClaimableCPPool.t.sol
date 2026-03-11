// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ClaimableCPPool.sol";
import "../src/MultiRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    uint8 private _dec;
    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract ClaimableCPPoolTest is Test {
    MockToken usdc;  // 6 decimals
    MockToken arc;   // 18 decimals
    ClaimableCPPool pool;
    MultiRouter router;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new MockToken("USDC", "USDC", 6);
        arc = new MockToken("ARC", "ARC", 18);
        pool = new ClaimableCPPool(
            address(usdc), address(arc), 3000, // 0.3%
            "ArcSwap USDC-ARC LP", "asUSDC-ARC"
        );
        router = new MultiRouter();
        router.addPool(address(pool));

        // Fund alice and bob
        usdc.mint(alice, 100_000e6);
        arc.mint(alice, 10_000_000e18);
        usdc.mint(bob, 100_000e6);
        arc.mint(bob, 10_000_000e18);
    }

    function _addInitialLiquidity() internal {
        // 1 ARC = 0.01 USDC → 10,000 USDC + 1,000,000 ARC
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        arc.approve(address(pool), type(uint256).max);
        pool.addLiquidity([uint256(10_000e6), uint256(1_000_000e18)], 0);
        vm.stopPrank();
    }

    // ==================== Basic Tests ====================

    function test_addLiquidity() public {
        _addInitialLiquidity();
        uint256[2] memory bal = pool.balances();
        assertEq(bal[0], 10_000e6);
        assertEq(bal[1], 1_000_000e18);
        assertGt(pool.balanceOf(alice), 0);
    }

    function test_swap_usdc_to_arc() public {
        _addInitialLiquidity();
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        // Swap 100 USDC for ARC
        uint256 arcBefore = arc.balanceOf(bob);
        pool.swap(0, 100e6, 0, bob);
        uint256 arcAfter = arc.balanceOf(bob);
        uint256 arcGot = arcAfter - arcBefore;
        // 100 USDC at 0.01 USDC/ARC → ~9900 ARC (with fee + slippage)
        assertGt(arcGot, 9000e18);
        assertLt(arcGot, 10_000e18);
        vm.stopPrank();
    }

    function test_swap_arc_to_usdc() public {
        _addInitialLiquidity();
        vm.startPrank(bob);
        arc.approve(address(pool), type(uint256).max);
        uint256 usdcBefore = usdc.balanceOf(bob);
        pool.swap(1, 10_000e18, 0, bob);
        uint256 usdcAfter = usdc.balanceOf(bob);
        uint256 usdcGot = usdcAfter - usdcBefore;
        // 10000 ARC at 0.01 → ~99 USDC
        assertGt(usdcGot, 90e6);
        assertLt(usdcGot, 100e6);
        vm.stopPrank();
    }

    // ==================== Fee Claiming Tests ====================

    function test_fees_accumulate_after_swap() public {
        _addInitialLiquidity();
        // Before any swap, no fees
        (uint256 f0, uint256 f1) = pool.claimable(alice);
        assertEq(f0, 0);
        assertEq(f1, 0);

        // Bob swaps USDC→ARC (fee in USDC)
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.swap(0, 1000e6, 0, bob);
        vm.stopPrank();

        // Alice should have claimable USDC fees (0.3% of 1000 = 3 USDC)
        (f0, f1) = pool.claimable(alice);
        assertGt(f0, 2.9e6); // ~3 USDC minus rounding
        assertLe(f0, 3e6);
        assertEq(f1, 0); // no ARC fees yet
    }

    function test_claim_fees() public {
        _addInitialLiquidity();

        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.swap(0, 1000e6, 0, bob);
        vm.stopPrank();

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.claimFees();
        uint256 usdcAfter = usdc.balanceOf(alice);

        uint256 claimed = usdcAfter - usdcBefore;
        assertGt(claimed, 2.9e6);
        assertLe(claimed, 3e6);

        // After claiming, no more pending
        (uint256 f0, uint256 f1) = pool.claimable(alice);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_fees_both_tokens() public {
        _addInitialLiquidity();

        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        arc.approve(address(pool), type(uint256).max);
        // Swap USDC→ARC (fee in USDC)
        pool.swap(0, 1000e6, 0, bob);
        // Swap ARC→USDC (fee in ARC)
        pool.swap(1, 100_000e18, 0, bob);
        vm.stopPrank();

        (uint256 f0, uint256 f1) = pool.claimable(alice);
        assertGt(f0, 0, "Should have USDC fees");
        assertGt(f1, 0, "Should have ARC fees");
    }

    function test_fees_proportional_to_lp() public {
        // Alice adds liquidity first
        _addInitialLiquidity();

        // Bob adds equal liquidity
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        arc.approve(address(pool), type(uint256).max);
        pool.addLiquidity([uint256(10_000e6), uint256(1_000_000e18)], 0);
        vm.stopPrank();

        // Someone swaps (use alice's remaining funds)
        vm.startPrank(alice);
        pool.swap(0, 500e6, 0, alice);
        vm.stopPrank();

        // Both should have roughly equal fees (50/50 LP)
        (uint256 fAlice,) = pool.claimable(alice);
        (uint256 fBob,) = pool.claimable(bob);

        // Allow 1% tolerance for rounding
        assertApproxEqRel(fAlice, fBob, 0.01e18);
    }

    function test_fees_not_in_reserves() public {
        _addInitialLiquidity();
        uint256[2] memory balBefore = pool.balances();

        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.swap(0, 1000e6, 0, bob);
        vm.stopPrank();

        uint256[2] memory balAfter = pool.balances();
        // Reserve increased by amountInAfterFee (997 USDC), NOT by full 1000
        uint256 reserveIncrease = balAfter[0] - balBefore[0];
        assertEq(reserveIncrease, 997e6); // 1000 - 0.3% fee = 997

        // But contract holds more (reserves + collectedFees)
        assertEq(pool.collectedFees0(), 3e6);
    }

    function test_removeLiquidity_does_not_include_fees() public {
        _addInitialLiquidity();

        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.swap(0, 1000e6, 0, bob);
        vm.stopPrank();

        // Alice removes all liquidity — should get reserves, not fees
        uint256 lp = pool.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        pool.removeLiquidity(lp, [uint256(0), uint256(0)]);
        uint256 usdcAfterRemove = usdc.balanceOf(alice);

        // Now claim fees separately
        pool.claimFees();
        uint256 usdcAfterClaim = usdc.balanceOf(alice);
        vm.stopPrank();

        uint256 fromRemove = usdcAfterRemove - usdcBefore;
        uint256 fromClaim = usdcAfterClaim - usdcAfterRemove;

        // Remove gives back reserves, claim gives fees
        assertGt(fromRemove, 0, "Should get reserves");
        assertGt(fromClaim, 0, "Should get fees separately");
    }

    function test_router_works_with_claimable_pool() public {
        _addInitialLiquidity();
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        (uint256 quote,) = router.getBestQuote(address(usdc), address(arc), 100e6);
        assertGt(quote, 0);
        vm.stopPrank();
    }

    function test_no_claim_when_no_fees() public {
        _addInitialLiquidity();
        vm.prank(alice);
        vm.expectRevert("No fees to claim");
        pool.claimFees();
    }
}
