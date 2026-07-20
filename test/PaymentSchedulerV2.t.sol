// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaymentSchedulerV2.sol";

contract PaymentSchedulerV2Test is Test {
    PaymentSchedulerV2 scheduler;
    address backend = address(0xB0B);       // バックエンド代理デプロイの鍵
    address user = address(0x1111);         // 本当のCircleユーザー
    address attacker = address(0xEEEE);     // なりすまし犯

    function setUp() public {
        // ケースA: バックエンド代理デプロイ想定 (_initialOwnerIsFinal = false)
        vm.prank(backend);
        scheduler = new PaymentSchedulerV2(backend, false);
    }

    function test_InitialOwnerIsBackend() public view {
        assertEq(scheduler.owner(), backend);
        assertFalse(scheduler.ownerClaimed());
    }

    function test_ClaimOwner_Success() public {
        vm.prank(user);
        scheduler.claimOwner(user);

        assertEq(scheduler.owner(), user);
        assertTrue(scheduler.ownerClaimed());
    }

    function test_ClaimOwner_RevertIfNotSelf() public {
        // attackerがuserのアドレスを勝手にclaimしようとする → 失敗するはず
        vm.prank(attacker);
        vm.expectRevert(PaymentSchedulerV2.MustClaimForSelf.selector);
        scheduler.claimOwner(user);
    }

    function test_ClaimOwner_RevertIfAlreadyClaimed() public {
        vm.prank(user);
        scheduler.claimOwner(user);

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.AlreadyClaimed.selector);
        scheduler.claimOwner(user);
    }

    function test_OnlyOwnerCanAddWhitelist() public {
        vm.prank(user);
        scheduler.claimOwner(user);

        // attackerはwhitelistを追加できない
        vm.prank(attacker);
        vm.expectRevert(PaymentSchedulerV2.NotOwner.selector);
        scheduler.addToWhitelist(attacker);

        // userならできる
        vm.prank(user);
        scheduler.addToWhitelist(address(0x1234));
        assertTrue(scheduler.isWhitelisted(address(0x1234)));
    }

    function test_FactoryStyleDeploy_OwnerIsFinalImmediately() public {
        // ケースB: Factory経由 (_initialOwnerIsFinal = true) の想定
        vm.prank(user);
        PaymentSchedulerV2 factoryStyle = new PaymentSchedulerV2(user, true);

        assertEq(factoryStyle.owner(), user);
        assertTrue(factoryStyle.ownerClaimed());

        // userはclaimOwnerを呼ばずに即座に管理関数を実行できる
        vm.prank(user);
        factoryStyle.addToWhitelist(address(0x5678));
        assertTrue(factoryStyle.isWhitelisted(address(0x5678)));
    }
}
