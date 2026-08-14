// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISchedulerOwnable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal interface for the Curve StableSwap pool (USDC/EURC) on Arc Testnet.
///         Verified on-chain that coins(0) = USDC and coins(1) = EURC.
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @title PaymentSchedulerV2
/// @notice Core contract for the Circle-wallet-specific payroll app.
///         Intended to be deployed once per company (per Circle wallet), not multi-tenant.
contract PaymentSchedulerV2 is ISchedulerOwnable {
    address public immutable deployer;
    address public owner;
    bool public ownerClaimed;

    event OwnerClaimed(address indexed newOwner);

    error NotOwner();
    error AlreadyClaimed();
    error MustClaimForSelf();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _deployer, bool _initialOwnerIsFinal) {
        if (_deployer == address(0)) revert ZeroAddress();
        deployer = _deployer;
        owner = _deployer;
        ownerClaimed = _initialOwnerIsFinal;

        if (_initialOwnerIsFinal) {
            emit OwnerClaimed(_deployer);
        }
    }

    function claimOwner(address newOwner) external {
        if (ownerClaimed) revert AlreadyClaimed();
        if (newOwner == address(0)) revert ZeroAddress();
        if (msg.sender != newOwner) revert MustClaimForSelf();

        owner = newOwner;
        ownerClaimed = true;

        emit OwnerClaimed(newOwner);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerClaimed(newOwner);
    }

    mapping(address => bool) public isWhitelisted;

    event WhitelistUpdated(address indexed account, bool status);

    function addToWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = true;
        emit WhitelistUpdated(account, true);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        isWhitelisted[account] = false;
        emit WhitelistUpdated(account, false);
    }

    function addToWhitelistBatch(address[] calldata accounts) external onlyOwner {
        uint256 len = accounts.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < len; ) {
            isWhitelisted[accounts[i]] = true;
            emit WhitelistUpdated(accounts[i], true);
            unchecked { ++i; }
        }
    }

    struct Schedule {
        address recipient;
        uint256 amount;
        uint64 executeAfter;
        uint64 intervalSeconds; // 0 = one-time payment, >0 = recurring interval in seconds
        bool active;
        bool useEURC;           // true = swap USDC -> EURC via Curve at execution time before sending
        uint16 slippageBps;     // slippage tolerance in basis points (100 = 1%); ignored if useEURC = false
        bytes32 requestId;
    }

    Schedule[] public schedules;

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed recipient,
        uint256 amount,
        uint64 executeAfter,
        bytes32 indexed requestId
    );
    event ScheduleToggled(uint256 indexed scheduleId, bool active);
    event ScheduleSwapped(uint256 indexed scheduleId, uint256 usdcIn, uint256 eurcOut);

    uint256 public constant MAX_BATCH_SIZE = 50;
    uint16 public constant MAX_SLIPPAGE_BPS = 500; // 5% hard cap to prevent runaway slippage settings

    error RecipientNotWhitelisted();
    error ArrayLengthMismatch();
    error InvalidScheduleId();
    error BatchTooLarge();
    error SlippageTooHigh();
    error SwapAmountTooLow();

    function createSchedule(
        address recipient,
        uint256 amount,
        uint64 executeAfter
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, 0, false, 0, bytes32(0));
    }

    function createScheduleFor(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        bytes32 requestId
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, 0, false, 0, requestId);
    }

    /// @notice Creates a recurring schedule. If intervalSeconds > 0, the contract
    ///         automatically advances the next execution time each time executeSchedule runs.
    function createRecurringScheduleFor(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        uint64 intervalSeconds,
        bytes32 requestId
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, intervalSeconds, false, 0, requestId);
    }

    /// @notice Creates a recurring schedule with optional EURC auto-swap support.
    /// @param slippageBps Slippage tolerance in basis points (100 = 1%); ignored if useEURC = false.
    function createRecurringScheduleWithEURC(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        uint64 intervalSeconds,
        bool useEURC,
        uint16 slippageBps,
        bytes32 requestId
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, intervalSeconds, useEURC, slippageBps, requestId);
    }

    function createSchedulesBatch(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint64[] calldata executeAfters
    ) external onlyOwner returns (uint256[] memory scheduleIds) {
        uint256 len = recipients.length;
        if (amounts.length != len || executeAfters.length != len) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();

        scheduleIds = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            scheduleIds[i] = _createSchedule(recipients[i], amounts[i], executeAfters[i], 0, false, 0, bytes32(0));
            unchecked { ++i; }
        }
    }

    function createSchedulesForBatch(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint64[] calldata executeAfters,
        bytes32[] calldata requestIds
    ) external onlyOwner returns (uint256[] memory scheduleIds) {
        uint256 len = recipients.length;
        if (amounts.length != len || executeAfters.length != len || requestIds.length != len) {
            revert ArrayLengthMismatch();
        }
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();

        scheduleIds = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            scheduleIds[i] = _createSchedule(recipients[i], amounts[i], executeAfters[i], 0, false, 0, requestIds[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Creates recurring schedules in batch. intervalSeconds is specified per element (0 = one-time).
    function createRecurringSchedulesForBatch(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint64[] calldata executeAfters,
        uint64[] calldata intervalSecondsArr,
        bytes32[] calldata requestIds
    ) external onlyOwner returns (uint256[] memory scheduleIds) {
        uint256 len = recipients.length;
        if (
            amounts.length != len ||
            executeAfters.length != len ||
            intervalSecondsArr.length != len ||
            requestIds.length != len
        ) {
            revert ArrayLengthMismatch();
        }
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();

        scheduleIds = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            scheduleIds[i] = _createSchedule(
                recipients[i],
                amounts[i],
                executeAfters[i],
                intervalSecondsArr[i],
                false,
                0,
                requestIds[i]
            );
            unchecked { ++i; }
        }
    }

    function _createSchedule(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        uint64 intervalSeconds,
        bool useEURC,
        uint16 slippageBps,
        bytes32 requestId
    ) internal returns (uint256 scheduleId) {
        if (!isWhitelisted[recipient]) revert RecipientNotWhitelisted();
        if (useEURC && slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();

        schedules.push(Schedule({
            recipient: recipient,
            amount: amount,
            executeAfter: executeAfter,
            intervalSeconds: intervalSeconds,
            active: true,
            useEURC: useEURC,
            slippageBps: slippageBps,
            requestId: requestId
        }));

        scheduleId = schedules.length - 1;

        emit ScheduleCreated(scheduleId, recipient, amount, executeAfter, requestId);
    }

    // --- Execution (payment) logic -------------------------------------------
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    address public constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address public constant CURVE_POOL = 0x2D84D79c852f6842ABe0304B70bBAa1506Add457;
    int128 public constant USDC_INDEX = 0;
    int128 public constant EURC_INDEX = 1;

    event ScheduleExecuted(uint256 indexed scheduleId, address indexed recipient, uint256 amount);

    error SchedulePaused();
    error TooEarly(uint256 executeAfter, uint256 currentTime);
    error TransferFailed();

    /// @notice Executes a schedule, transferring USDC from owner's balance to the recipient.
    ///         The owner must have already called USDC.approve(this contract, sufficient amount)
    ///         beforehand (standard ERC20 allowance pattern).
    /// @dev Callable by anyone (designed for automated execution via e.g. GitHub Actions).
    ///      The actual payment always moves funds from owner -> recipient; the caller cannot
    ///      redirect funds elsewhere (transferFrom's first argument is always the fixed owner).
    ///      When intervalSeconds is set, the schedule is NOT deactivated after execution;
    ///      instead executeAfter is advanced, allowing the same scheduleId to be reused
    ///      and automatically executed again next cycle.
    ///
    ///      When useEURC is true, USDC is swapped to EURC via the Curve pool before being
    ///      sent to the recipient. If the swap cannot satisfy min_dy (computed from get_dy
    ///      minus slippageBps), the entire transaction reverts, including the executeAfter
    ///      advancement, so the next automated polling cycle will retry automatically.
    function executeSchedule(uint256 scheduleId) external {
        if (scheduleId >= schedules.length) revert InvalidScheduleId();
        Schedule storage s = schedules[scheduleId];

        if (!s.active) revert SchedulePaused();
        if (block.timestamp < s.executeAfter) revert TooEarly(s.executeAfter, block.timestamp);
        if (!isWhitelisted[s.recipient]) revert RecipientNotWhitelisted();

        if (s.intervalSeconds > 0) {
            s.executeAfter = s.executeAfter + s.intervalSeconds;
        } else {
            s.active = false;
        }

        if (s.useEURC) {
            _executeWithSwap(scheduleId, s.recipient, s.amount, s.slippageBps);
        } else {
            bool success = IERC20(USDC).transferFrom(owner, s.recipient, s.amount);
            if (!success) revert TransferFailed();
        }

        emit ScheduleExecuted(scheduleId, s.recipient, s.amount);
    }

    /// @dev Pulls USDC from owner into this contract, swaps it via Curve, and forwards
    ///      the resulting EURC to the recipient.
    function _executeWithSwap(uint256 scheduleId, address recipient, uint256 amount, uint16 slippageBps) internal {
        bool pulled = IERC20(USDC).transferFrom(owner, address(this), amount);
        if (!pulled) revert TransferFailed();

        uint256 expectedOut = ICurvePool(CURVE_POOL).get_dy(USDC_INDEX, EURC_INDEX, amount);
        if (expectedOut == 0) revert SwapAmountTooLow();

        uint256 minDy = expectedOut - (expectedOut * slippageBps / 10_000);

        bool approved = IERC20(USDC).approve(CURVE_POOL, amount);
        if (!approved) revert TransferFailed();

        uint256 eurcOut = ICurvePool(CURVE_POOL).exchange(USDC_INDEX, EURC_INDEX, amount, minDy);

        bool sent = IERC20(EURC).transfer(recipient, eurcOut);
        if (!sent) revert TransferFailed();

        emit ScheduleSwapped(scheduleId, amount, eurcOut);
    }

    function toggleSchedule(uint256 scheduleId, bool active) external onlyOwner {
        if (scheduleId >= schedules.length) revert InvalidScheduleId();
        schedules[scheduleId].active = active;
        emit ScheduleToggled(scheduleId, active);
    }

    function toggleSchedulesBatch(uint256[] calldata scheduleIds, bool active) external onlyOwner {
        uint256 len = scheduleIds.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < len; ) {
            uint256 id = scheduleIds[i];
            if (id >= schedules.length) revert InvalidScheduleId();
            schedules[id].active = active;
            emit ScheduleToggled(id, active);
            unchecked { ++i; }
        }
    }

    function scheduleCount() external view returns (uint256) {
        return schedules.length;
    }

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        if (scheduleId >= schedules.length) revert InvalidScheduleId();
        return schedules[scheduleId];
    }
}
