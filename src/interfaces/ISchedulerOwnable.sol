// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISchedulerOwnable
/// @notice Minimal interface PaymentSchedulerV2 must implement for owner
///         management. SchedulerRegistry checks ownership through this
///         interface rather than depending on the concrete contract.
interface ISchedulerOwnable {
    /// @notice The current de facto owner (the actual Circle user's wallet
    ///         address).
    function owner() external view returns (address);

    /// @notice Whether claimOwner() has already been called. While false,
    ///         the contract is still on the backend's initial placeholder
    ///         owner, so the Registry refuses to register it in this state.
    function ownerClaimed() external view returns (bool);
}
