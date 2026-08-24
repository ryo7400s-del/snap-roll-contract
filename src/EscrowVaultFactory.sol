// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./EscrowVault.sol";

/// @title EscrowVaultFactory
/// @notice Deploys EscrowVault instances via CREATE2. Split out from
///         PayrollFactory purely to stay under the EIP-170 contract size
///         limit: PayrollFactory embedding both PaymentSchedulerV2's and
///         EscrowVault's full creationCode inline exceeded 24,576 bytes.
///         Having PayrollFactory make an external call into this contract
///         instead keeps each Factory's own bytecode small, since each one
///         only needs to embed a single target contract's creationCode.
/// @dev Callable by anyone, not just PayrollFactory, though in practice
///      PayrollFactory.deploy() is the only intended caller (see its
///      NatSpec). There's no meaningful harm in allowing direct calls: the
///      CREATE2 salt is derived from `deployer`, so a given deployer/vault
///      pairing can only be produced once regardless of who calls this.
contract EscrowVaultFactory {
    event EscrowVaultDeployed(address indexed escrowVault, address indexed deployer, bytes32 salt);

    error DeployFailed();
    error AlreadyDeployed();

    mapping(address => bool) public hasDeployed;

    function deployFor(
        address deployer,
        address verifierAddress,
        address executorAddress
    ) external returns (address escrowVault) {
        if (hasDeployed[deployer]) revert AlreadyDeployed();

        bytes32 salt = bytes32(uint256(uint160(deployer)));

        bytes memory bytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            abi.encode(deployer, verifierAddress, executorAddress)
        );

        assembly {
            escrowVault := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (escrowVault == address(0)) revert DeployFailed();

        hasDeployed[deployer] = true;

        emit EscrowVaultDeployed(escrowVault, deployer, salt);
    }

    function computeAddress(
        address deployer,
        address verifierAddress,
        address executorAddress
    ) external view returns (address predicted) {
        bytes32 salt = bytes32(uint256(uint160(deployer)));
        bytes memory bytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            abi.encode(deployer, verifierAddress, executorAddress)
        );
        bytes32 bytecodeHash = keccak256(bytecode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, bytecodeHash
        )))));
    }
}
