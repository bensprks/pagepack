// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// The token movements of a swap through an AMM pool, without the pricing: pull one token from
/// the trader and pay out the other. Works with any ERC-20, including TokenLedger facades.
contract SwapPool {
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;

    constructor(IERC20 tokenIn_, IERC20 tokenOut_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    function swap(uint256 amountIn, uint256 amountOut) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, amountOut);
    }
}
