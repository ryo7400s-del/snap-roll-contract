// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC20 mock for testing. Deployed and then placed at the
///         fixed USDC/EURC addresses via vm.etch.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock of a Curve StableSwap pool for testing.
///         Simulates USDC<->EURC swaps at a fixed or adjustable rate, and
///         reproduces the real pool's behavior of reverting when min_dy is not met.
contract MockCurvePool {
    address public tokenIn;  // coins(0) equivalent = USDC
    address public tokenOut; // coins(1) equivalent = EURC

    // Rate is scaled by 1e18. e.g. 0.92e18 means 1 USDC (6 decimals) -> 0.92 EURC (6 decimals) equivalent rate.
    uint256 public rate = 0.92e18;

    // If 0, falls back to `rate`. Lets a test simulate a rate change (e.g. front-running)
    // that occurs specifically at exchange() time, after get_dy() was already quoted.
    uint256 public exchangeOnlyRate;

    constructor(address _tokenIn, address _tokenOut) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    /// @notice Sets a rate that only applies during exchange(), separate from the
    ///         rate returned by get_dy(). Pass 0 to fall back to `rate`.
    function setExchangeOnlyRate(uint256 _rate) external {
        exchangeOnlyRate = _rate;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        require(i == 0 && j == 1, "unsupported direction");
        return dx * rate / 1e18;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256) {
        require(i == 0 && j == 1, "unsupported direction");
        uint256 effectiveRate = exchangeOnlyRate > 0 ? exchangeOnlyRate : rate;
        uint256 dy = dx * effectiveRate / 1e18;
        require(dy >= min_dy, "Exchange resulted in fewer coins than expected");

        // Mirror real pool behavior: pull tokenIn from the caller, then send tokenOut.
        (bool pulled, ) = tokenIn.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), dx)
        );
        require(pulled, "pull failed");

        (bool sent, ) = tokenOut.call(
            abi.encodeWithSignature("transfer(address,uint256)", msg.sender, dy)
        );
        require(sent, "send failed");

        return dy;
    }
}
