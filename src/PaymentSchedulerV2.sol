// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISchedulerOwnable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title PaymentSchedulerV2
/// @notice Circleウォレット特化型ペイロールの本体コントラクト。
///         1社（1 Circleウォレット）につき1つデプロイされる想定（マルチテナントではない）。
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
        bool active;
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

    uint256 public constant MAX_BATCH_SIZE = 50;

    error RecipientNotWhitelisted();
    error ArrayLengthMismatch();
    error InvalidScheduleId();
    error BatchTooLarge();

    function createSchedule(
        address recipient,
        uint256 amount,
        uint64 executeAfter
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, bytes32(0));
    }

    function createScheduleFor(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        bytes32 requestId
    ) external onlyOwner returns (uint256 scheduleId) {
        scheduleId = _createSchedule(recipient, amount, executeAfter, requestId);
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
            scheduleIds[i] = _createSchedule(recipients[i], amounts[i], executeAfters[i], bytes32(0));
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
            scheduleIds[i] = _createSchedule(recipients[i], amounts[i], executeAfters[i], requestIds[i]);
            unchecked { ++i; }
        }
    }

    function _createSchedule(
        address recipient,
        uint256 amount,
        uint64 executeAfter,
        bytes32 requestId
    ) internal returns (uint256 scheduleId) {
        if (!isWhitelisted[recipient]) revert RecipientNotWhitelisted();

        schedules.push(Schedule({
            recipient: recipient,
            amount: amount,
            executeAfter: executeAfter,
            active: true,
            requestId: requestId
        }));

        scheduleId = schedules.length - 1;

        emit ScheduleCreated(scheduleId, recipient, amount, executeAfter, requestId);
    }

    // --- 実行（送金）機能 -------------------------------------------
    address public constant USDC = 0x3600000000000000000000000000000000000000;

    event ScheduleExecuted(uint256 indexed scheduleId, address indexed recipient, uint256 amount);

    error SchedulePaused();
    error TooEarly(uint256 executeAfter, uint256 currentTime);
    error TransferFailed();

    /// @notice スケジュールを実行し、owner（責任者）のUSDC残高からrecipientへ送金する。
    ///         事前に owner が USDC.approve(このコントラクトアドレス, 十分な額) を
    ///         実行している必要がある（ERC20の標準的なallowanceパターン）。
    /// @dev 誰でも呼び出せる設計（GitHub Actions等の自動実行を想定）。
    ///      支払いの実体はowner→recipientへのUSDC移動であり、呼び出し者が
    ///      勝手に資金を動かせるわけではない（transferFromの第一引数は常にowner固定）。
    function executeSchedule(uint256 scheduleId) external {
        if (scheduleId >= schedules.length) revert InvalidScheduleId();
        Schedule storage s = schedules[scheduleId];

        if (!s.active) revert SchedulePaused();
        if (block.timestamp < s.executeAfter) revert TooEarly(s.executeAfter, block.timestamp);
        if (!isWhitelisted[s.recipient]) revert RecipientNotWhitelisted();

        s.active = false;

        bool success = IERC20(USDC).transferFrom(owner, s.recipient, s.amount);
        if (!success) revert TransferFailed();

        emit ScheduleExecuted(scheduleId, s.recipient, s.amount);
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
