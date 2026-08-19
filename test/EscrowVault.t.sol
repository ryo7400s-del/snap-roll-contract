// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/EscrowVault.sol";
import "./mocks/MockTokensAndPool.sol";

contract EscrowVaultTest is Test {
    EscrowVault vault;
    MockERC20 usdc;
    MockERC20 eurc;
    MockCurvePool curvePool;

    address owner = address(0x1111);
    address claimant = address(0x2222);
    address outsider = address(0x3333);

    uint256 verifierPrivateKey = 0xA11CE;
    address verifier;

    address constant USDC_ADDR = 0x3600000000000000000000000000000000000000;
    address constant EURC_ADDR = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant CURVE_POOL_ADDR = 0x2D84D79C852f6842AbE0304b70bBaA1506AdD457;

    function setUp() public {
        verifier = vm.addr(verifierPrivateKey);

        MockERC20 usdcImpl = new MockERC20();
        MockERC20 eurcImpl = new MockERC20();
        vm.etch(USDC_ADDR, address(usdcImpl).code);
        vm.etch(EURC_ADDR, address(eurcImpl).code);
        usdc = MockERC20(USDC_ADDR);
        eurc = MockERC20(EURC_ADDR);

        MockCurvePool poolImpl = new MockCurvePool(USDC_ADDR, EURC_ADDR);
        vm.etch(CURVE_POOL_ADDR, address(poolImpl).code);
        curvePool = MockCurvePool(CURVE_POOL_ADDR);
        vm.store(CURVE_POOL_ADDR, bytes32(uint256(0)), bytes32(uint256(uint160(USDC_ADDR))));
        vm.store(CURVE_POOL_ADDR, bytes32(uint256(1)), bytes32(uint256(uint160(EURC_ADDR))));
        curvePool.setRate(0.92e18);
        eurc.mint(CURVE_POOL_ADDR, 1_000_000e6);

        vm.prank(owner);
        vault = new EscrowVault(owner, verifier);
    }

    function _fundOwner(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.prank(owner);
        usdc.approve(address(vault), amount);
    }

    function _sign(uint256 escrowId, address claimantAddr, address vaultAddr) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(escrowId, claimantAddr, vaultAddr));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierPrivateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ── createEscrow ──────────────────────────────────────────────────

    function test_CreateEscrow_PullsUsdcAndStoresEscrow() public {
        _fundOwner(100e6);

        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should hold the USDC");
        assertEq(usdc.balanceOf(owner), 0, "owner's USDC should be pulled");

        EscrowVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.sender, owner);
        assertEq(e.amount, 100e6);
        assertFalse(e.useEURC);
        assertFalse(e.claimed);
        assertFalse(e.refunded);
    }

    function test_CreateEscrow_RevertsIfNotOwner() public {
        _fundOwner(100e6);
        vm.prank(outsider);
        vm.expectRevert(EscrowVault.NotOwner.selector);
        vault.createEscrow(keccak256("x@example.com"), 100e6, false, 0, uint64(block.timestamp + 1 days));
    }

    function test_CreateEscrow_RevertsIfExpiryInPast() public {
        _fundOwner(100e6);
        vm.prank(owner);
        vm.expectRevert(EscrowVault.ExpiryInPast.selector);
        vault.createEscrow(keccak256("x@example.com"), 100e6, false, 0, uint64(block.timestamp));
    }

    function test_CreateEscrow_RevertsIfSlippageTooHighForEURC() public {
        _fundOwner(100e6);
        vm.prank(owner);
        vm.expectRevert(EscrowVault.SlippageTooHigh.selector);
        vault.createEscrow(keccak256("x@example.com"), 100e6, true, 501, uint64(block.timestamp + 1 days));
    }

    // ── claimEscrow ───────────────────────────────────────────────────

    function test_ClaimEscrow_UsdcSucceedsWithValidSignature() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        bytes memory sig = _sign(escrowId, claimant, address(vault));

        vm.prank(claimant);
        vault.claimEscrow(escrowId, sig);

        assertEq(usdc.balanceOf(claimant), 100e6, "claimant should receive USDC");
        assertTrue(vault.getEscrow(escrowId).claimed);
    }

    function test_ClaimEscrow_EURCSwapsAndSends() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, true, 100, uint64(block.timestamp + 30 days)
        );

        bytes memory sig = _sign(escrowId, claimant, address(vault));

        vm.prank(claimant);
        vault.claimEscrow(escrowId, sig);

        assertEq(eurc.balanceOf(claimant), 92e6, "claimant should receive EURC at pool rate");
        assertEq(usdc.balanceOf(claimant), 0, "claimant should not receive raw USDC");
    }

    function test_ClaimEscrow_RevertsWithSignatureForWrongClaimant() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        // Signature issued for `claimant`, but `outsider` tries to use it.
        bytes memory sig = _sign(escrowId, claimant, address(vault));

        vm.prank(outsider);
        vm.expectRevert(EscrowVault.InvalidSignature.selector);
        vault.claimEscrow(escrowId, sig);
    }

    function test_ClaimEscrow_RevertsWithSignatureFromWrongSigner() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        // Signed by a random key, not the real verifier.
        uint256 wrongKey = 0xBEEF;
        bytes32 messageHash = keccak256(abi.encodePacked(escrowId, claimant, address(vault)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(claimant);
        vm.expectRevert(EscrowVault.InvalidSignature.selector);
        vault.claimEscrow(escrowId, badSig);
    }

    function test_ClaimEscrow_RevertsIfAlreadyClaimed() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        bytes memory sig = _sign(escrowId, claimant, address(vault));
        vm.prank(claimant);
        vault.claimEscrow(escrowId, sig);

        vm.prank(claimant);
        vm.expectRevert(EscrowVault.AlreadyClaimed.selector);
        vault.claimEscrow(escrowId, sig);
    }

    function test_ClaimEscrow_RevertsIfExpired() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 1 days)
        );

        vm.warp(block.timestamp + 2 days);

        bytes memory sig = _sign(escrowId, claimant, address(vault));
        vm.prank(claimant);
        vm.expectRevert(EscrowVault.EscrowExpired.selector);
        vault.claimEscrow(escrowId, sig);
    }

    // ── refundExpiredEscrow ──────────────────────────────────────────

    function test_RefundExpiredEscrow_ReturnsFundsToSender() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 1 days)
        );

        vm.warp(block.timestamp + 2 days);

        // Callable by anyone, not just owner.
        vm.prank(outsider);
        vault.refundExpiredEscrow(escrowId);

        assertEq(usdc.balanceOf(owner), 100e6, "owner should get their USDC back");
        assertTrue(vault.getEscrow(escrowId).refunded);
    }

    function test_RefundExpiredEscrow_RevertsIfNotYetExpired() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        vm.expectRevert(EscrowVault.NotExpiredYet.selector);
        vault.refundExpiredEscrow(escrowId);
    }

    function test_RefundExpiredEscrow_RevertsIfAlreadyClaimed() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 1 days)
        );

        bytes memory sig = _sign(escrowId, claimant, address(vault));
        vm.prank(claimant);
        vault.claimEscrow(escrowId, sig);

        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(EscrowVault.AlreadyClaimed.selector);
        vault.refundExpiredEscrow(escrowId);
    }

    // ── setVerifier ───────────────────────────────────────────────────

    function test_SetVerifier_UpdatesAndOldSignaturesNoLongerWork() public {
        _fundOwner(100e6);
        vm.prank(owner);
        uint256 escrowId = vault.createEscrow(
            keccak256("employee@example.com"), 100e6, false, 0, uint64(block.timestamp + 30 days)
        );

        bytes memory oldSig = _sign(escrowId, claimant, address(vault));

        address newVerifier = address(0x9999);
        vm.prank(owner);
        vault.setVerifier(newVerifier);

        assertEq(vault.verifier(), newVerifier);

        vm.prank(claimant);
        vm.expectRevert(EscrowVault.InvalidSignature.selector);
        vault.claimEscrow(escrowId, oldSig);
    }

    function test_SetVerifier_RevertsIfNotOwner() public {
        vm.prank(outsider);
        vm.expectRevert(EscrowVault.NotOwner.selector);
        vault.setVerifier(address(0x9999));
    }
}
