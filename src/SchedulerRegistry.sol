// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ISchedulerOwnable.sol";

/// @title SchedulerRegistry
/// @notice Circleウォレット（EOA相当）とPaymentSchedulerV2デプロイアドレスの逆引き台帳。
///         「本当にそのSchedulerのownerであるウォレットだけがregisterできる」ことを保証する。
/// @dev V1のRegistryとは別コントラクトとして新規デプロイする想定（互換性なし）。
contract SchedulerRegistry {
    /// @notice Circleウォレットアドレス => そのウォレットが所有するSchedulerV2のアドレス
    mapping(address => address) public schedulerOf;

    /// @notice Schedulerアドレス => 登録した所有者ウォレット（逆引き & 二重登録防止）
    mapping(address => address) public ownerOfScheduler;

    event Registered(address indexed owner, address indexed scheduler, string name);
    event Unregistered(address indexed owner, address indexed scheduler);

    error NotSchedulerOwner();
    error OwnerNotClaimedYet();
    error AlreadyRegistered();
    error NotYourRegistration();

    /// @notice Schedulerをこのウォレット名義で登録する。
    /// @dev 呼び出し元(msg.sender)が対象SchedulerコントラクトのSchedulerV2.owner()と
    ///      一致していることを必須とする。これにより「他人がデプロイしたSchedulerに
    ///      勝手に自分を紐付ける」なりすましを防ぐ。
    /// @param scheduler PaymentSchedulerV2 のコントラクトアドレス
    /// @param name 表示名（会社名など、UI表示用。オンチェーンでは検証しない）
    function register(address scheduler, string calldata name) external {
        ISchedulerOwnable target = ISchedulerOwnable(scheduler);

        // Scheduler側でclaimOwner()がまだ実行されていない状態での登録は禁止。
        // （バックエンドの初期ownerのままRegistryに紐付いてしまう事故を防ぐ）
        if (!target.ownerClaimed()) revert OwnerNotClaimedYet();

        // Scheduler.owner() と msg.sender が一致する場合のみ登録可能。
        if (target.owner() != msg.sender) revert NotSchedulerOwner();

        if (schedulerOf[msg.sender] != address(0)) revert AlreadyRegistered();
        if (ownerOfScheduler[scheduler] != address(0)) revert AlreadyRegistered();

        schedulerOf[msg.sender] = scheduler;
        ownerOfScheduler[scheduler] = msg.sender;

        emit Registered(msg.sender, scheduler, name);
    }

    /// @notice 登録解除（将来的な移行・作り直し用）。自分の登録のみ解除可能。
    function unregister() external {
        address scheduler = schedulerOf[msg.sender];
        if (scheduler == address(0)) revert NotYourRegistration();

        delete schedulerOf[msg.sender];
        delete ownerOfScheduler[scheduler];

        emit Unregistered(msg.sender, scheduler);
    }
}
