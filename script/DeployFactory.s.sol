// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PayrollFactory.sol";
import "../src/EscrowVaultFactory.sol";

/// @notice Redeploys PayrollFactory (and, if needed, EscrowVaultFactory) so
///         that embedded creationCode reflects the latest source. This
///         produces NEW factory addresses -- after running this, update
///         FACTORY_ADDRESS in:
///           - app/api/circle/route.ts
///           - app/setting/page.tsx
///         Existing schedulers/escrow vaults deployed via the old
///         factories are unaffected and keep running on whatever
///         implementation they were deployed with.
///
///         EscrowVaultFactory is deployed separately from PayrollFactory
///         (rather than PayrollFactory embedding EscrowVault's creationCode
///         directly) purely to stay under the EIP-170 contract size limit
///         -- see PayrollFactory.sol's NatSpec for details. This means a
///         PayrollFactory redeploy does NOT require redeploying
///         EscrowVaultFactory too, since EscrowVaultFactory's own bytecode
///         (and therefore the EscrowVault creationCode it embeds) is
///         unaffected by changes to PaymentSchedulerV2 or PayrollFactory
///         itself. Set REDEPLOY_ESCROW_VAULT_FACTORY=true only when
///         EscrowVault.sol's own source has changed.
contract DeployFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address verifierAddress = vm.envAddress("VERIFIER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        address escrowVaultFactoryAddress;
        bool redeployEscrowVaultFactory = vm.envOr("REDEPLOY_ESCROW_VAULT_FACTORY", false);
        if (redeployEscrowVaultFactory) {
            EscrowVaultFactory escrowVaultFactory = new EscrowVaultFactory();
            escrowVaultFactoryAddress = address(escrowVaultFactory);
            console.log("New EscrowVaultFactory deployed at:", escrowVaultFactoryAddress);
        } else {
            escrowVaultFactoryAddress = vm.envAddress("ESCROW_VAULT_FACTORY_ADDRESS");
            console.log("Reusing existing EscrowVaultFactory at:", escrowVaultFactoryAddress);
        }

        PayrollFactory factory = new PayrollFactory(verifierAddress, escrowVaultFactoryAddress);

        vm.stopBroadcast();

        console.log("New PayrollFactory deployed at:", address(factory));
    }
}
