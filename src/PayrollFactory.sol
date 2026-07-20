// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaymentSchedulerV2.sol";

/// @title PayrollFactory
/// @notice ① Circleウォレットの contractExecution から呼び出す前提のFactory。
///         通常デプロイ(toが空のTX)がCircleで失敗する問題を回避するため、
///         「既存コントラクト(Factory)への関数呼び出し」という形でデプロイを行う。
contract PayrollFactory {
    event SchedulerDeployed(address indexed scheduler, address indexed deployer, bytes32 salt);

    error DeployFailed();

    mapping(address => bool) public hasDeployed;

    error AlreadyDeployed();

    function deploy() external returns (address scheduler) {
        if (hasDeployed[msg.sender]) revert AlreadyDeployed();

        bytes32 salt = bytes32(uint256(uint160(msg.sender)));

        bytes memory bytecode = abi.encodePacked(
            type(PaymentSchedulerV2).creationCode,
            abi.encode(msg.sender, true)
        );

        assembly {
            scheduler := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (scheduler == address(0)) revert DeployFailed();

        hasDeployed[msg.sender] = true;

        emit SchedulerDeployed(scheduler, msg.sender, salt);
    }

    function computeAddress(address expectedDeployer) external view returns (address predicted) {
        bytes32 salt = bytes32(uint256(uint160(expectedDeployer)));
        bytes memory bytecode = abi.encodePacked(
            type(PaymentSchedulerV2).creationCode,
            abi.encode(expectedDeployer, true)
        );
        bytes32 bytecodeHash = keccak256(bytecode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, bytecodeHash
        )))));
    }
}
