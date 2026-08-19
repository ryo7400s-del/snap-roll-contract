// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PayrollFactory.sol";
import "../src/PaymentSchedulerV2.sol";
import "../src/EscrowVault.sol";

contract PayrollFactoryTest is Test {
    PayrollFactory factory;
    address verifier = address(0xBEEF);
    address deployer = address(0x1234);

    function setUp() public {
        factory = new PayrollFactory(verifier);
    }

    function test_Deploy_CreatesBothContractsWithCorrectOwnersAndVerifier() public {
        vm.prank(deployer);
        (address scheduler, address escrowVault) = factory.deploy();

        assertTrue(scheduler != address(0), "scheduler should be deployed");
        assertTrue(escrowVault != address(0), "escrowVault should be deployed");
        assertTrue(scheduler != escrowVault, "the two deployments must be distinct addresses");

        assertEq(PaymentSchedulerV2(scheduler).owner(), deployer, "scheduler owner should be the deployer");
        assertEq(EscrowVault(escrowVault).owner(), deployer, "escrow vault owner should be the deployer");
        assertEq(EscrowVault(escrowVault).verifier(), verifier, "escrow vault should use the factory's verifier");
    }

    function test_Deploy_RevertsOnSecondCallFromSameDeployer() public {
        vm.prank(deployer);
        factory.deploy();

        vm.prank(deployer);
        vm.expectRevert(PayrollFactory.AlreadyDeployed.selector);
        factory.deploy();
    }

    function test_ComputeAddress_MatchesActualDeployment() public {
        address predictedScheduler = factory.computeAddress(deployer);
        address predictedVault = factory.computeEscrowVaultAddress(deployer);

        vm.prank(deployer);
        (address scheduler, address escrowVault) = factory.deploy();

        assertEq(scheduler, predictedScheduler, "computeAddress should match actual scheduler deployment");
        assertEq(escrowVault, predictedVault, "computeEscrowVaultAddress should match actual vault deployment");
    }

    function test_SetVerifierAddress_AffectsOnlyFutureDeployments() public {
        vm.prank(deployer);
        (, address firstVault) = factory.deploy();
        assertEq(EscrowVault(firstVault).verifier(), verifier);

        address newVerifier = address(0xCAFE);
        factory.setVerifierAddress(newVerifier);

        address secondDeployer = address(0x5678);
        vm.prank(secondDeployer);
        (, address secondVault) = factory.deploy();
        assertEq(EscrowVault(secondVault).verifier(), newVerifier, "new deployments should use the updated verifier");

        // The first vault, already deployed, keeps its original verifier.
        assertEq(EscrowVault(firstVault).verifier(), verifier, "existing vaults are unaffected by the factory-level change");
    }

    function test_SetVerifierAddress_RevertsIfNotFactoryOwner() public {
        vm.prank(deployer);
        vm.expectRevert(PayrollFactory.NotFactoryOwner.selector);
        factory.setVerifierAddress(address(0xCAFE));
    }

    function test_Constructor_RevertsOnZeroVerifier() public {
        vm.expectRevert(PayrollFactory.ZeroAddress.selector);
        new PayrollFactory(address(0));
    }
}
