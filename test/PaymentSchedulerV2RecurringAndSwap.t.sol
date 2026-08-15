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
    address user = address(0x1111);     // owner (the company paying salaries)
    address employee = address(0x2222); // recipient

    address constant USDC_ADDR = 0x3600000000000000000000000000000000000000;
    address constant EURC_ADDR = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant CURVE_POOL_ADDR = 0x2D84D79C852f6842AbE0304b70bBaA1506AdD457;

    function setUp() public {
        // Place mock bytecode at the fixed token addresses.
        MockERC20 usdcImpl = new MockERC20();
        MockERC20 eurcImpl = new MockERC20();
        vm.etch(USDC_ADDR, address(usdcImpl).code);
        vm.etch(EURC_ADDR, address(eurcImpl).code);
        usdc = MockERC20(USDC_ADDR);
        eurc = MockERC20(EURC_ADDR);

        // Deploy the pool implementation, etch it onto the fixed pool address,
        // then re-initialize its state via setters (vm.etch does not carry over
        // constructor-set storage from the temporary implementation address).
        MockCurvePool poolImpl = new MockCurvePool(USDC_ADDR, EURC_ADDR);
        vm.etch(CURVE_POOL_ADDR, address(poolImpl).code);
        curvePool = MockCurvePool(CURVE_POOL_ADDR);
        // tokenIn/tokenOut are regular (non-immutable) storage vars with no setter,
        // so restore slots 0 and 1 directly via vm.store.
        vm.store(CURVE_POOL_ADDR, bytes32(uint256(0)), bytes32(uint256(uint160(USDC_ADDR))));
        vm.store(CURVE_POOL_ADDR, bytes32(uint256(1)), bytes32(uint256(uint160(EURC_ADDR))));
        curvePool.setRate(0.92e18);
        eurc.mint(CURVE_POOL_ADDR, 1_000_000e6); // fund the pool so it can pay out swaps

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

    // ── Recurring payment bug fix verification ──────────────────────────────

    function test_RecurringSchedule_ExecutesMultipleTimes() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        // 1st execution
        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 100e6, "1st execution failed");

        PaymentSchedulerV2.Schedule memory s1 = scheduler.getSchedule(scheduleId);
        assertTrue(s1.active, "schedule should remain active after recurring execution");
        assertEq(s1.executeAfter, block.timestamp + 30 days, "executeAfter should advance by interval");

        // Should fail if attempted too early
        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        // Advance 30 days
        vm.warp(block.timestamp + 30 days);

        // 2nd execution (this is the core of the original bug being fixed)
        scheduler.executeSchedule(scheduleId);
        assertEq(usdc.balanceOf(employee), 200e6, "2nd execution failed - the original bug");

        // Advance again and verify a 3rd execution as well
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
        // Whitelist the recipient but do NOT fund/approve USDC, so transferFrom fails.
        vm.prank(user);
        scheduler.addToWhitelist(employee);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleFor(
            employee, 100e6, uint64(block.timestamp), 30 days, bytes32("req1")
        );

        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        // Since the whole tx reverted, executeAfter must not have advanced.
        PaymentSchedulerV2.Schedule memory s = scheduler.getSchedule(scheduleId);
        assertEq(s.executeAfter, block.timestamp, "executeAfter must NOT advance on failed tx");
    }

    // ── EURC / Curve swap feature verification ──────────────────────────────

    function test_EURCSchedule_SwapsAndSendsEURC() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 100 /* 1% */, bytes32("req1")
        );

        scheduler.executeSchedule(scheduleId);

        // Rate is 0.92, so 100 USDC -> 92 EURC equivalent
        assertEq(eurc.balanceOf(employee), 92e6, "employee should receive EURC at pool rate");
        assertEq(usdc.balanceOf(employee), 0, "employee should NOT receive raw USDC");
    }

    function test_EURCSchedule_RevertsWhenSlippageExceeded() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        uint256 scheduleId = scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 100 /* 1% tolerance */, bytes32("req1")
        );

        // Simulate the rate moving unfavorably by 8% specifically at exchange() time
        // (front-running / sudden pool movement), which exceeds the 1% tolerance
        // set at get_dy() quote time and should cause a revert.
        curvePool.setExchangeOnlyRate(0.80e18);

        vm.expectRevert();
        scheduler.executeSchedule(scheduleId);

        // After the revert, executeAfter must not have advanced either
        // (this is what enables automatic retry on the next polling cycle).
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

        // Once the rate recovers, retrying the same scheduleId should succeed.
        curvePool.setExchangeOnlyRate(0.92e18);
        scheduler.executeSchedule(scheduleId);
        assertEq(eurc.balanceOf(employee), 92e6, "retry after rate recovery should succeed");
    }

    function test_CreateSchedule_RevertsIfSlippageAboveMax() public {
        _whitelistAndFundUser(1000e6);

        vm.prank(user);
        vm.expectRevert(PaymentSchedulerV2.SlippageTooHigh.selector);
        scheduler.createRecurringScheduleWithEURC(
            employee, 100e6, uint64(block.timestamp), 30 days, true, 501 /* exceeds 5% cap */, bytes32("req1")
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
}
