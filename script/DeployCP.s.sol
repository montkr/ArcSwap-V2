// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ConstantProductPool.sol";
import "../src/StableSwapPool.sol";
import "../src/MultiRouter.sol";

contract DeployCP is Script {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant USYC = 0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C;

    // Existing pools to register in new router
    address constant POOL_STABLE_USDC_USYC = 0x9baa830F14d43f76ddE073ACcB17D2B5a98ad0e2;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy ConstantProductPool for USDC/EURC (0.3% fee)
        ConstantProductPool cpPool = new ConstantProductPool(
            USDC, EURC, 3000,
            "ArcSwap USDC/EURC CP LP", "cpLP-USDC-EURC"
        );
        console.log("CP Pool USDC/EURC:", address(cpPool));

        // Deploy new MultiRouter with both pool types
        MultiRouter router = new MultiRouter();
        router.addPool(address(cpPool));            // USDC/EURC (constant product)
        router.addPool(POOL_STABLE_USDC_USYC);      // USDC/USYC (stableswap, existing)
        console.log("MultiRouter v2:", address(router));

        vm.stopBroadcast();
    }
}
