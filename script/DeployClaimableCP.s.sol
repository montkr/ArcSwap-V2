// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ClaimableCPPool.sol";

contract DeployClaimableCP is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // ARC/USDC Claimable CP Pool (0.3% fee)
        // token0 = USDC, token1 = ARC
        ClaimableCPPool pool = new ClaimableCPPool(
            0x3600000000000000000000000000000000000000, // USDC (6 dec)
            0x905E3eAf899591398B6Ab6937851f896DE811Ee5, // ARC (18 dec)
            3000, // 0.3%
            "ArcSwap USDC-ARC LP",
            "asUSDC-ARC"
        );
        console.log("ClaimableCPPool USDC/ARC:", address(pool));

        vm.stopBroadcast();
    }
}
