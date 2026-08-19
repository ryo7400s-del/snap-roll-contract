// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISchedulerOwnable.sol";

/// @title SchedulerRegistry
/// @notice Reverse lookup ledger between a Circle wallet (EOA-equivalent)
///         and its PaymentSchedulerV2 deployment address. Guarantees that
///         only the wallet that is genuinely that Scheduler's owner can
///         register it.
/// @dev Deployed as a separate contract from any V1 Registry (no
///      compatibility with it).
contract SchedulerRegistry {
    /// @notice Circle wallet address => the SchedulerV2 address it owns.
    mapping(address => address) public schedulerOf;

    /// @notice Scheduler address => the owner wallet that registered it
    ///         (reverse lookup & duplicate-registration prevention).
    mapping(address => address) public ownerOfScheduler;

    event Registered(address indexed owner, address indexed scheduler, string name);
    event Unregistered(address indexed owner, address indexed scheduler);

    error NotSchedulerOwner();
    error OwnerNotClaimedYet();
    error AlreadyRegistered();
    error NotYourRegistration();

    /// @notice Registers a Scheduler under this wallet's name.
    /// @dev Requires the caller (msg.sender) to match the target Scheduler
    ///      contract's SchedulerV2.owner(). This prevents impersonation --
    ///      someone linking themselves to a Scheduler deployed by someone
    ///      else without authorization.
    /// @param scheduler The PaymentSchedulerV2 contract address.
    /// @param name Display name (e.g. company name, for UI display only;
    ///        not verified on-chain).
    function register(address scheduler, string calldata name) external {
        ISchedulerOwnable target = ISchedulerOwnable(scheduler);

        // Registration is disallowed while the Scheduler hasn't had
        // claimOwner() called yet (prevents accidentally linking the
        // Registry to the backend's initial placeholder owner).
        if (!target.ownerClaimed()) revert OwnerNotClaimedYet();

        // Only registerable when Scheduler.owner() matches msg.sender.
        if (target.owner() != msg.sender) revert NotSchedulerOwner();

        if (schedulerOf[msg.sender] != address(0)) revert AlreadyRegistered();
        if (ownerOfScheduler[scheduler] != address(0)) revert AlreadyRegistered();

        schedulerOf[msg.sender] = scheduler;
        ownerOfScheduler[scheduler] = msg.sender;

        emit Registered(msg.sender, scheduler, name);
    }

    /// @notice Unregisters (for future migration/re-creation). Only the
    ///         caller's own registration can be removed.
    function unregister() external {
        address scheduler = schedulerOf[msg.sender];
        if (scheduler == address(0)) revert NotYourRegistration();

        delete schedulerOf[msg.sender];
        delete ownerOfScheduler[scheduler];

        emit Unregistered(msg.sender, scheduler);
    }
}
