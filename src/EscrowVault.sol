// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IEscrowERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IEscrowCurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @title EscrowVault
/// @notice Holds USDC/EURC on behalf of a company (owner) for recipients who
///         are identified only by email at send time -- i.e. they don't yet
///         have a SnapRoll wallet to receive a normal scheduled/instant
///         payment. Funds sit here until the recipient registers on
///         SnapRoll and claims with a signature from SnapRoll's backend
///         verifier confirming their wallet owns that email address, or
///         until expiresAt passes and anyone can trigger a refund back to
///         the original sender.
///
/// @dev CENTRALIZED TRUST DISCLOSURE
///      Email addresses are not an on-chain concept, so this contract can't
///      verify wallet-to-email ownership itself. recipientEmailHash exists
///      only for off-chain lookup/dedup (e.g. so the backend can find which
///      escrows are waiting on a given email) and is NOT a security
///      boundary -- claimEscrow's actual authorization comes entirely from
///      the verifier's signature. This means the security of every escrow
///      depends on the verifier's private key remaining uncompromised and
///      SnapRoll's backend only signing for wallets it has genuinely
///      confirmed own the claimed email. This is a centralized trust
///      assumption, not a trustless cryptographic guarantee: whoever holds
///      the verifier private key can, in principle, sign a claim for any
///      escrow regardless of whether real email verification occurred.
///
///      MITIGATIONS IN PLACE TODAY:
///      - Every signature verification happens on-chain and is publicly
///        auditable via EscrowClaimed events -- anyone can check, after the
///        fact, exactly which escrowId/claimant pairs were ever validly
///        signed for by the current verifier.
///      - setVerifier is owner-only and emits VerifierUpdated, so a key
///        rotation (e.g. after suspected compromise) is itself a public,
///        timestamped on-chain event.
///      - The backend's signature-issuance logic (the code deciding *when*
///        to call signMessage for a given escrow/claimant) is intended to
///        be open-sourced so the stated policy ("only sign after confirmed
///        email verification") can be independently reviewed, and every
///        issuance is logged off-chain for audit (see backend
///        verifier-signing service) -- though note that publishing the
///        intended logic does not by itself prove the exact code running
///        in production matches it.
///
///      PLANNED FUTURE HARDENING (not yet implemented):
///      This contract currently trusts a single `verifier` address. The
///      intent is to migrate to an M-of-N multisig scheme (e.g. requiring
///      signatures from a fixed set of independent verifiers, no single
///      one of which is sufficient alone) so that a single compromised or
///      malicious key cannot unilaterally authorize a claim. That change
///      is deliberately deferred rather than speculatively built into this
///      version -- see project notes for reasoning -- but is flagged here
///      so the current single-verifier design is understood as an interim
///      state, not the intended end state.
contract EscrowVault {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    address public immutable USDC;
    address public immutable EURC;
    address public immutable CURVE_POOL;
    int128 public constant USDC_INDEX = 0;
    int128 public constant EURC_INDEX = 1;

    uint16 public constant MAX_SLIPPAGE_BPS = 500; // 5%

    address public owner;
    address public verifier;
    address public executor;

    struct Escrow {
        address sender;
        bytes32 recipientEmailHash; // off-chain lookup only, see contract-level note
        uint256 amount; // USDC amount locked at creation time
        bool useEURC;
        uint16 slippageBps; // ignored if useEURC = false
        uint64 createdAt;
        uint64 expiresAt;
        bool claimed;
        bool refunded;
    }

    Escrow[] public escrows;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed sender,
        bytes32 recipientEmailHash,
        uint256 amount,
        bool useEURC,
        uint64 expiresAt
    );
    event EscrowClaimed(uint256 indexed escrowId, address indexed claimant, uint256 amountSent);
    event EscrowRefunded(uint256 indexed escrowId, address indexed sender, uint256 amount);
    event VerifierUpdated(address indexed newVerifier);
    event ExecutorUpdated(address indexed newExecutor);

    error NotOwner();
    error NotAuthorized();
    error ZeroAddress();
    error InvalidEscrowId();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error NotExpiredYet();
    error ExpiryInPast();
    error EscrowExpired();
    error InvalidSignature();
    error SlippageTooHigh();
    error SwapAmountTooLow();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Allows either the owner (company) or a designated executor
    ///         (e.g. the auto-execute.mjs backend job) to call createEscrow.
    ///         The executor concept mirrors PaymentSchedulerV2's design,
    ///         where executeSchedule is callable by anyone because the
    ///         send parameters (recipient, amount) are already fixed by
    ///         the time it's called. createEscrow is different: it takes
    ///         recipientEmailHash, amount, etc. as fresh arguments at call
    ///         time, so letting *anyone* call it (not just a designated
    ///         executor) would let an attacker spend the owner's USDC
    ///         allowance on an escrow addressed to an email they control,
    ///         as long as any allowance remained. Restricting to owner or
    ///         a specifically-authorized executor closes that gap.
    modifier onlyOwnerOrExecutor() {
        if (msg.sender != owner && msg.sender != executor) revert NotAuthorized();
        _;
    }

    constructor(address _owner, address _verifier, address _executor) {
        if (_owner == address(0) || _verifier == address(0) || _executor == address(0)) revert ZeroAddress();
        owner = _owner;
        verifier = _verifier;
        executor = _executor;
        USDC = 0x3600000000000000000000000000000000000000;
        EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
        CURVE_POOL = 0x2D84D79C852f6842AbE0304b70bBaA1506AdD457;
    }

    /// @notice Lets the owner rotate the executor address, e.g. if the
    ///         backend's auto-execute.mjs signer key is replaced.
    function setExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        executor = newExecutor;
        emit ExecutorUpdated(newExecutor);
    }

    /// @notice Lets the owner rotate the verifier address, e.g. if the
    ///         backend's Circle Developer-Controlled Wallet is replaced.
    ///         Does not affect escrows already created; claimEscrow always
    ///         checks against the *current* verifier at claim time, so
    ///         rotating invalidates any not-yet-claimed escrow's ability to
    ///         be claimed with signatures from the old verifier.
    function setVerifier(address newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress();
        verifier = newVerifier;
        emit VerifierUpdated(newVerifier);
    }

    /// @notice Locks `amount` USDC (pulled from owner, who must have
    ///         approved this contract beforehand) into a new escrow for a
    ///         recipient identified by recipientEmailHash. If useEURC is
    ///         true, the USDC is swapped to EURC via Curve at claim time
    ///         (not at creation time) so the exchange rate used is as
    ///         fresh as possible.
    function createEscrow(
        bytes32 recipientEmailHash,
        uint256 amount,
        bool useEURC,
        uint16 slippageBps,
        uint64 expiresAt
    ) external onlyOwnerOrExecutor returns (uint256 escrowId) {
        if (useEURC && slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        if (expiresAt <= block.timestamp) revert ExpiryInPast();

        bool pulled = IEscrowERC20(USDC).transferFrom(owner, address(this), amount);
        if (!pulled) revert TransferFailed();

        escrowId = escrows.length;
        escrows.push(
            Escrow({
                sender: owner,
                recipientEmailHash: recipientEmailHash,
                amount: amount,
                useEURC: useEURC,
                slippageBps: slippageBps,
                createdAt: uint64(block.timestamp),
                expiresAt: expiresAt,
                claimed: false,
                refunded: false
            })
        );

        emit EscrowCreated(escrowId, owner, recipientEmailHash, amount, useEURC, expiresAt);
    }

    /// @notice Claims escrow `escrowId` to msg.sender. Requires a signature
    ///         from the current verifier over
    ///         keccak256(abi.encodePacked(escrowId, msg.sender, address(this))),
    ///         proving SnapRoll's backend has confirmed msg.sender owns the
    ///         email address this escrow was created for. Including
    ///         address(this) prevents a signature meant for this vault
    ///         being replayed against a different EscrowVault deployment;
    ///         including msg.sender prevents any other wallet from
    ///         front-running the intended claimant with a stolen signature,
    ///         since the signature only recovers correctly for the exact
    ///         address it was issued to.
    function claimEscrow(uint256 escrowId, bytes calldata signature) external {
        if (escrowId >= escrows.length) revert InvalidEscrowId();
        Escrow storage e = escrows[escrowId];
        if (e.claimed) revert AlreadyClaimed();
        if (e.refunded) revert AlreadyRefunded();
        if (block.timestamp > e.expiresAt) revert EscrowExpired();

        bytes32 messageHash = keccak256(abi.encodePacked(escrowId, msg.sender, address(this)));
        address recovered = messageHash.toEthSignedMessageHash().recover(signature);
        if (recovered != verifier) revert InvalidSignature();

        e.claimed = true;

        uint256 amountSent;
        if (e.useEURC) {
            amountSent = _swapAndSend(e.amount, e.slippageBps, msg.sender);
        } else {
            amountSent = e.amount;
            bool sent = IEscrowERC20(USDC).transfer(msg.sender, e.amount);
            if (!sent) revert TransferFailed();
        }

        emit EscrowClaimed(escrowId, msg.sender, amountSent);
    }

    /// @notice Returns an unclaimed, expired escrow's funds to the original
    ///         sender. Callable by anyone (typically an automated job,
    ///         mirroring how auto-execute.mjs drives scheduled payments)
    ///         since there's no reason to restrict who can trigger a refund
    ///         once expiry has passed -- the destination is fixed to
    ///         e.sender regardless of caller.
    function refundExpiredEscrow(uint256 escrowId) external {
        if (escrowId >= escrows.length) revert InvalidEscrowId();
        Escrow storage e = escrows[escrowId];
        if (e.claimed) revert AlreadyClaimed();
        if (e.refunded) revert AlreadyRefunded();
        if (block.timestamp <= e.expiresAt) revert NotExpiredYet();

        e.refunded = true;

        bool sent = IEscrowERC20(USDC).transfer(e.sender, e.amount);
        if (!sent) revert TransferFailed();

        emit EscrowRefunded(escrowId, e.sender, e.amount);
    }

    /// @dev Mirrors PaymentSchedulerV2._executeWithSwap's approve-then-exchange
    ///      pattern: quote via get_dy, apply slippageBps to get min_dy, approve
    ///      the pool for exactly `usdcAmount`, then exchange and forward the
    ///      resulting EURC to the recipient.
    function _swapAndSend(uint256 usdcAmount, uint16 slippageBps, address recipient) internal returns (uint256) {
        uint256 expectedOut = IEscrowCurvePool(CURVE_POOL).get_dy(USDC_INDEX, EURC_INDEX, usdcAmount);
        if (expectedOut == 0) revert SwapAmountTooLow();

        uint256 minDy = expectedOut - (expectedOut * slippageBps / 10_000);

        bool approved = IEscrowERC20(USDC).approve(CURVE_POOL, usdcAmount);
        if (!approved) revert TransferFailed();

        uint256 eurcOut = IEscrowCurvePool(CURVE_POOL).exchange(USDC_INDEX, EURC_INDEX, usdcAmount, minDy);

        bool sent = IEscrowERC20(EURC).transfer(recipient, eurcOut);
        if (!sent) revert TransferFailed();

        return eurcOut;
    }

    function escrowCount() external view returns (uint256) {
        return escrows.length;
    }

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        if (escrowId >= escrows.length) revert InvalidEscrowId();
        return escrows[escrowId];
    }
}
