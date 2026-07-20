// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISchedulerOwnable
/// @notice PaymentSchedulerV2がowner管理のために実装すべき最小インターフェース。
///         SchedulerRegistryはこのインターフェース越しにowner照合を行う。
interface ISchedulerOwnable {
    /// @notice 現在の実質的なオーナー（Circleユーザー本人のウォレットアドレス）
    function owner() external view returns (address);

    /// @notice claimOwner()が既に実行済みかどうか
    ///         false のうちは「バックエンドの初期owner」のままなので、
    ///         Registry側はこの状態での登録を拒否する。
    function ownerClaimed() external view returns (bool);
}
