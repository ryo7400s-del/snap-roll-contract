// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PayrollFactory.sol";

/// @notice Redeploys PayrollFactory so that its embedded PaymentSchedulerV2
///         creationCode reflects the latest source (including
///         createRecurringSchedulesForBatchWithEURC). This produces a NEW
///         factory address — after running this, update FACTORY_ADDRESS in:
///           - app/api/circle/route.ts
///           - app/setting/page.tsx
///         Existing schedulers deployed via the old factory are unaffected
///         and keep running on the old PaymentSchedulerV2 implementation.
contract DeployFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address verifierAddress = vm.envAddress("VERIFIER_ADDRESS");
        PayrollFactory factory = new PayrollFactory(verifierAddress);

        vm.stopBroadcast();

        console.log("New PayrollFactory deployed at:", address(factory));
    }
}
