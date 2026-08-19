// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaymentSchedulerV2.sol";
import "./EscrowVault.sol";

/// @title PayrollFactory
/// @notice ① Circleウォレットの contractExecution から呼び出す前提のFactory。
///         通常デプロイ(toが空のTX)がCircleで失敗する問題を回避するため、
///         「既存コントラクト(Factory)への関数呼び出し」という形でデプロイを行う。
/// @dev deploy() now provisions both a PaymentSchedulerV2 and an
///      EscrowVault per caller, sharing the same CREATE2 salt so both
///      addresses are deterministic and independently reproducible via
///      computeAddress/computeEscrowVaultAddress. The EscrowVault needs a
///      verifier address at construction time; verifierAddress is stored
///      here and used for every new deployment, but existing EscrowVaults
///      are unaffected if it's later changed (each vault has its own
///      independent setVerifier, see EscrowVault.sol).
contract PayrollFactory {
    event SchedulerDeployed(address indexed scheduler, address indexed deployer, bytes32 salt);
    event EscrowVaultDeployed(address indexed escrowVault, address indexed deployer, bytes32 salt);
    event VerifierAddressUpdated(address indexed newVerifierAddress);

    error DeployFailed();
    error NotFactoryOwner();
    error ZeroAddress();

    address public factoryOwner;
    address public verifierAddress;

    mapping(address => bool) public hasDeployed;

    error AlreadyDeployed();

    constructor(address _verifierAddress) {
        if (_verifierAddress == address(0)) revert ZeroAddress();
        factoryOwner = msg.sender;
        verifierAddress = _verifierAddress;
    }

    modifier onlyFactoryOwner() {
        if (msg.sender != factoryOwner) revert NotFactoryOwner();
        _;
    }

    /// @notice Lets the Factory owner update which verifier address gets
    ///         baked into newly-deployed EscrowVaults. Does not retroactively
    ///         change any already-deployed vault -- each one keeps whatever
    ///         verifier it was constructed with until its own owner calls
    ///         setVerifier on it directly.
    function setVerifierAddress(address newVerifierAddress) external onlyFactoryOwner {
        if (newVerifierAddress == address(0)) revert ZeroAddress();
        verifierAddress = newVerifierAddress;
        emit VerifierAddressUpdated(newVerifierAddress);
    }

    function deploy() external returns (address scheduler, address escrowVault) {
        if (hasDeployed[msg.sender]) revert AlreadyDeployed();

        bytes32 salt = bytes32(uint256(uint160(msg.sender)));

        bytes memory schedulerBytecode = abi.encodePacked(
            type(PaymentSchedulerV2).creationCode,
            abi.encode(msg.sender)
        );
        assembly {
            scheduler := create2(0, add(schedulerBytecode, 0x20), mload(schedulerBytecode), salt)
        }
        if (scheduler == address(0)) revert DeployFailed();

        bytes memory escrowBytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            abi.encode(msg.sender, verifierAddress)
        );
        assembly {
            escrowVault := create2(0, add(escrowBytecode, 0x20), mload(escrowBytecode), salt)
        }
        if (escrowVault == address(0)) revert DeployFailed();

        hasDeployed[msg.sender] = true;

        emit SchedulerDeployed(scheduler, msg.sender, salt);
        emit EscrowVaultDeployed(escrowVault, msg.sender, salt);
    }

    function computeAddress(address expectedDeployer) external view returns (address predicted) {
        bytes32 salt = bytes32(uint256(uint160(expectedDeployer)));
        bytes memory bytecode = abi.encodePacked(
            type(PaymentSchedulerV2).creationCode,
            abi.encode(expectedDeployer)
        );
        bytes32 bytecodeHash = keccak256(bytecode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, bytecodeHash
        )))));
    }

    function computeEscrowVaultAddress(address expectedDeployer) external view returns (address predicted) {
        bytes32 salt = bytes32(uint256(uint160(expectedDeployer)));
        bytes memory bytecode = abi.encodePacked(
            type(EscrowVault).creationCode,
            abi.encode(expectedDeployer, verifierAddress)
        );
        bytes32 bytecodeHash = keccak256(bytecode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, bytecodeHash
        )))));
    }
}
