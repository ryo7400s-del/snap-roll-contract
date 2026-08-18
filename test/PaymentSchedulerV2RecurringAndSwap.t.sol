// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaymentSchedulerV2.sol";
import "./mocks/MockTokensAndPool.sol";

contract PaymentSchedulerV2RecurringAndSwapTest is Test {
    PaymentSchedulerV2 scheduler;
    MockERC20 usdc;
    MockERC20 eurc;
    MockCurvePool curvePool;

    address backend = address(0xB0B);
    address user = address(0x1111);
    address employee = address(0x2222);

    address constant USDC_ADDR = 0x3600000000000000000000000000000000000000;
    address constant EURC_ADDR = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant CURVE_POOL_ADDR = 0x2D84D79C852f6842AbE0304b70bBaA1506AdD457;

    function setUp() public {
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

        vm.prank(user);
        scheduler = new PaymentSchedulerV2(user);
    }

    function _whitelistAndFundUser(uint256 usdcAmount) internal {
        vm.prank(user);
        scheduler.addToWhitelist(employee);

        usdc.mint(user, usdcAmount);
        vm.prank(user);
        usdc.approve(address(scheduler), usdcAmount);
    }

    function test_RecurringSchedule_ExecutesMultipleTimes() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 100e6, "1st execution failed");

        PaymentSchedulerV2.Schedule memory s1 = scheduler.getSchedule(scheduleId);
        assertTrue(s1.active, "schedule should remain active after recurring execution");
        assertEq(s1.executeAfter, block.timestamp + 30 days, "executeAfter should advance by interval");

        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        vm.warp(block.timestamp + 30 days);

        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 200e6, "2nd execution failed - the original bug");

        vm.warp(block.timestamp + 30 days);
        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 300e6, "3rd execution failed");
    }

    function test_OneTimeSchedule_DeactivatesAfterExecution() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createScheduleFor(
            employee, 100e6, uint64(block.timestamp), bytes32("req1")
        );

        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 100e6);

        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertFalse(s.active, "one-time schedule should deactivate after execution");

        vm.expectRevert(PaymentSchedulerV2.SchedulePaused.selector);
        scheduler.executeSchedule(scheduleId);
    }

    function test_RecurringSchedule_FailedTransferDoesNotAdvanceNextExecution() public {
        vm.prank(user);
        scheduler.addToWhitelist(employee);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertEq(s.executeAfter, block.timestamp, "executeAfter must NOT advance on failed tx");
    }

    function test_EURCSchedule_SwapsAndSendsEURC() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 100, bytes32("req1")
        );

        scheduler.executeSchedule(scheduleId);

        assertEq(eurc.balanceOf(employee), 92e6, "employee should receive EURC at pool rate");
        assertEq(usdc.balanceOf(employee), 0, "employee should NOT receive raw USDC");
    }

    function test_EURCSchedule_RevertsWhenSlippageExceeded() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 100, bytes32("req1")
        );

        curvePool.setExchangeOnlyRate(0.80e18);

        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertEq(s.executeAfter, block.timestamp, "executeAfter must not advance on slippage revert");
    }

    function test_EURCSchedule_SucceedsOnRetryAfterRateRecovers() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 100, bytes32("req1")
        );

        curvePool.setExchangeOnlyRate(0.80e18);
        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        curvePool.setExchangeOnlyRate(0.92e18);
        scheduler.executeSchedule(scheduleId);
        assertEq(eurc.balanceOf(employee), 92e6, "retry after rate recovery should succeed");
    }

    function test_CreateSchedule_RevertsIfSlippageAboveMax() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.SlippageTooHigh.selector);
        scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 501, bytes32("req1")
        );
    }

    function test_NonEURCSchedule_IgnoresSlippageAndSendsUSDC() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createScheduleFor(
            employee, 100e6, uint64(block.timestamp), bytes32("req1")
        );

        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 100e6);
        assertEq(eurc.balanceOf(employee), 0);
    }

    function test_BatchWithEURC_MixedOneTimeRecurringAndCurrency() public {
        address employee2 = address(0x3333);
        address employee3 = address(0x4444);

        vm.startPrank(user);
        scheduler.addToWhitelist(employee);
        scheduler.addToWhitelist(employee2);
        scheduler.addToWhitelist(employee3);
        vm.stopPrank();

        usdc.mint(user, 1000e6);
        vm.prank(user);
        usdc.approve(address(scheduler), 1000e6);

        address[] memory recipients = new address[](3);
        recipients[0] = employee;
        recipients[1] = employee2;
        recipients[2] = employee3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e6;
        amounts[1] = 150e6;
        amounts[2] = 200e6;

        uint64[] memory executeAfters = new uint64[](3);
        executeAfters[0] = uint64(block.timestamp);
        executeAfters[1] = uint64(block.timestamp);
        executeAfters[2] = uint64(block.timestamp);

        uint64[] memory intervalSecondsArr = new uint64[](3);
        intervalSecondsArr[0] = 0;
        intervalSecondsArr[1] = 30 days;
        intervalSecondsArr[2] = 30 days;

        bool[] memory useEURCArr = new bool[](3);
        useEURCArr[0] = false;
        useEURCArr[1] = false;
        useEURCArr[2] = true;

        uint16[] memory slippageBpsArr = new uint16[](3);
        slippageBpsArr[0] = 0;
        slippageBpsArr[1] = 0;
        slippageBpsArr[2] = 100;

        bytes32[] memory requestIds = new bytes32[](3);
        requestIds[0] = bytes32("batch-req-1");
        requestIds[1] = bytes32("batch-req-2");
        requestIds[2] = bytes32("batch-req-3");

        vm.prank(user);
        uint256[] memory scheduleIds = scheduler.createRecurringSchedulesForBatchWithEURC(
            recipients, amounts, executeAfters, intervalSecondsArr, useEURCArr, slippageBpsArr, requestIds
        );

        assertEq(scheduleIds.length, 3);

        scheduler.executeSchedule(scheduleIds[0]);
        scheduler.executeSchedule(scheduleIds[1]);
        scheduler.executeSchedule(scheduleIds[2]);

        assertEq(usdc.balanceOf(employee), 100e6, "one-time USDC leg should pay USDC");
        assertFalse(scheduler.getSchedule(scheduleIds[0]).active, "one-time leg should deactivate");

        assertEq(usdc.balanceOf(employee2), 150e6, "recurring USDC leg should pay USDC");
        PaymentSchedulerV2.Schedule memory s1 = scheduler.getSchedule(scheduleIds[1]);
        assertTrue(s1.active, "recurring USDC leg should remain active");
        assertEq(s1.executeAfter, block.timestamp + 30 days);

        assertEq(eurc.balanceOf(employee3), 184e6, "recurring EURC leg should pay EURC at pool rate");
        assertEq(usdc.balanceOf(employee3), 0, "recurring EURC leg should not receive raw USDC");
        PaymentSchedulerV2.Schedule memory s2 = scheduler.getSchedule(scheduleIds[2]);
        assertTrue(s2.active, "recurring EURC leg should remain active");
    }

    function test_BatchWithEURC_RevertsOnArrayLengthMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = employee;
        recipients[1] = employee;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 100e6;

        uint64[] memory executeAfters = new uint64[](2);
        executeAfters[0] = uint64(block.timestamp);
        executeAfters[1] = uint64(block.timestamp);

        uint64[] memory intervalSecondsArr = new uint64[](2);
        intervalSecondsArr[0] = 0;
        intervalSecondsArr[1] = 0;

        bool[] memory useEURCArr = new bool[](1);
        useEURCArr[0] = false;

        uint16[] memory slippageBpsArr = new uint16[](2);
        slippageBpsArr[0] = 0;
        slippageBpsArr[1] = 0;

        bytes32[] memory requestIds = new bytes32[](2);
        requestIds[0] = bytes32("a");
        requestIds[1] = bytes32("b");

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.ArrayLengthMismatch.selector);
        scheduler.createRecurringSchedulesForBatchWithEURC(
            recipients, amounts, executeAfters, intervalSecondsArr, useEURCArr, slippageBpsArr, requestIds
        );
    }

    function test_BatchWithEURC_RevertsIfAnyElementExceedsMaxSlippage() public {
        address employee2 = address(0x3333);

        vm.startPrank(user);
        scheduler.addToWhitelist(employee);
        scheduler.addToWhitelist(employee2);
        vm.stopPrank();

        address[] memory recipients = new address[](2);
        recipients[0] = employee;
        recipients[1] = employee2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 100e6;

        uint64[] memory executeAfters = new uint64[](2);
        executeAfters[0] = uint64(block.timestamp);
        executeAfters[1] = uint64(block.timestamp);

        uint64[] memory intervalSecondsArr = new uint64[](2);
        intervalSecondsArr[0] = 0;
        intervalSecondsArr[1] = 0;

        bool[] memory useEURCArr = new bool[](2);
        useEURCArr[0] = false;
        useEURCArr[1] = true;

        uint16[] memory slippageBpsArr = new uint16[](2);
        slippageBpsArr[0] = 0;
        slippageBpsArr[1] = 501;

        bytes32[] memory requestIds = new bytes32[](2);
        requestIds[0] = bytes32("a");
        requestIds[1] = bytes32("b");

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.SlippageTooHigh.selector);
        scheduler.createRecurringSchedulesForBatchWithEURC(
            recipients, amounts, executeAfters, intervalSecondsArr, useEURCArr, slippageBpsArr, requestIds
        );
    }

    function test_BatchWithEURC_RevertsIfBatchTooLarge() public {
        uint256 len = scheduler.MAX_BATCH_SIZE() + 1;

        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);
        uint64[] memory executeAfters = new uint64[](len);
        uint64[] memory intervalSecondsArr = new uint64[](len);
        bool[] memory useEURCArr = new bool[](len);
        uint16[] memory slippageBpsArr = new uint16[](len);
        bytes32[] memory requestIds = new bytes32[](len);

        for (uint256 i = 0; i < len; i++) {
            recipients[i] = employee;
            amounts[i] = 1e6;
            executeAfters[i] = uint64(block.timestamp);
            requestIds[i] = bytes32(i);
        }

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.BatchTooLarge.selector);
        scheduler.createRecurringSchedulesForBatchWithEURC(
            recipients, amounts, executeAfters, intervalSecondsArr, useEURCArr, slippageBpsArr, requestIds
        );
    }

    // ── updateScheduleAmount verification ───────────────────────────────

    function test_UpdateScheduleAmount_AppliesOnNextExecution() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        // First execution at the original amount.
        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 100e6, "first execution should use original amount");

        // Raise: bump from 100 to 150 USDC ahead of the next cycle.
        vm.prank(user);
        scheduler.updateScheduleAmount(scheduleId, 150e6);

        vm.warp(block.timestamp + 30 days);
        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 250e6, "second execution should use the updated amount");

        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertEq(s.intervalSeconds, 30 days, "interval must be unchanged by an amount update");
    }

    function test_UpdateScheduleAmount_AllowsZero() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        vm.prank(user);
        scheduler.updateScheduleAmount(scheduleId, 0);

        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertEq(s.amount, 0, "zero amount should be allowed, not reverted");
    }

    function test_UpdateScheduleAmount_RevertsOnOneTimeSchedule() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createScheduleFor(
            employee, 100e6, uint64(block.timestamp), bytes32("req1")
        );

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.NotRecurring.selector);
        scheduler.updateScheduleAmount(scheduleId, 200e6);
    }

    function test_UpdateScheduleAmount_RevertsOnInvalidScheduleId() public {
        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.InvalidScheduleId.selector);
        scheduler.updateScheduleAmount(999, 200e6);
    }

    function test_UpdateScheduleAmount_RevertsWhenPaused() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        vm.prank(user);
        scheduler.toggleSchedule(scheduleId, false);

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.SchedulePaused.selector);
        scheduler.updateScheduleAmount(scheduleId, 200e6);
    }

}
