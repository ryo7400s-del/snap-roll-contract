// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaymentSchedulerV2.sol";

interface IEscrowVaultFactory {
    function deployFor(address deployer, address verifierAddress, address executorAddress) external returns (address escrowVault);
    function computeAddress(address deployer, address verifierAddress, address executorAddress) external view returns (address predicted);
}

/// @title PayrollFactory
/// @notice Factory intended to be called via a Circle wallet's contractExecution.
///         Circle's contractExecution flow fails for a "plain" deployment
///         transaction (one with an empty `to` field), so instead we perform
///         deployment as a regular call into an already-deployed contract
///         (this Factory), which internally does the CREATE2.
/// @dev deploy() provisions both a PaymentSchedulerV2 (directly, via
///      CREATE2 in this contract) and an EscrowVault (indirectly, via an
///      external call to EscrowVaultFactory) per caller, sharing the same
///      CREATE2 salt in each Factory so both addresses stay deterministic
///      and independently reproducible via computeAddress /
///      computeEscrowVaultAddress.
///
///      EscrowVault deployment is delegated to a separate
///      EscrowVaultFactory contract rather than done inline here purely to
///      stay under the EIP-170 contract size limit -- embedding both
///      PaymentSchedulerV2's and EscrowVault's full creationCode directly
///      in this contract pushed it past 24,576 bytes. See
///      EscrowVaultFactory.sol's NatSpec for more.
contract PayrollFactory {
    event SchedulerDeployed(address indexed scheduler, address indexed deployer, bytes32 salt);
    event EscrowVaultDeployed(address indexed escrowVault, address indexed deployer, bytes32 salt);
    event VerifierAddressUpdated(address indexed newVerifierAddress);
    event ExecutorAddressUpdated(address indexed newExecutorAddress);

    error DeployFailed();
    error NotFactoryOwner();
    error ZeroAddress();
    error AlreadyDeployed();

    address public factoryOwner;
    address public verifierAddress;
    address public executorAddress;
    IEscrowVaultFactory public immutable escrowVaultFactory;

    mapping(address => bool) public hasDeployed;

    constructor(address _verifierAddress, address _executorAddress, address _escrowVaultFactory) {
        if (
            _verifierAddress == address(0) ||
            _executorAddress == address(0) ||
            _escrowVaultFactory == address(0)
        ) revert ZeroAddress();
        factoryOwner = msg.sender;
        verifierAddress = _verifierAddress;
        executorAddress = _executorAddress;
        escrowVaultFactory = IEscrowVaultFactory(_escrowVaultFactory);
    }

    modifier onlyFactoryOwner() {
        if (msg.sender != factoryOwner) revert NotFactoryOwner();
        _;
    }

    /// @notice Lets the Factory owner update which verifier address gets
    ///         passed to EscrowVaultFactory for newly-deployed EscrowVaults.
    ///         Does not retroactively change any already-deployed vault --
    ///         each one keeps whatever verifier it was constructed with
    ///         until its own owner calls setVerifier on it directly.
    function setVerifierAddress(address newVerifierAddress) external onlyFactoryOwner {
        if (newVerifierAddress == address(0)) revert ZeroAddress();
        verifierAddress = newVerifierAddress;
        emit VerifierAddressUpdated(newVerifierAddress);
    }

    /// @notice Lets the Factory owner update which executor address gets
    ///         passed to EscrowVaultFactory for newly-deployed EscrowVaults.
    ///         Does not retroactively change any already-deployed vault --
    ///         each one keeps whatever executor it was constructed with
    ///         until its own owner calls setExecutor on it directly.
    function setExecutorAddress(address newExecutorAddress) external onlyFactoryOwner {
        if (newExecutorAddress == address(0)) revert ZeroAddress();
        executorAddress = newExecutorAddress;
        emit ExecutorAddressUpdated(newExecutorAddress);
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

        escrowVault = escrowVaultFactory.deployFor(msg.sender, verifierAddress, executorAddress);
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
        return escrowVaultFactory.computeAddress(expectedDeployer, verifierAddress, executorAddress);
    }
}
