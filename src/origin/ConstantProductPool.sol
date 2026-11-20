// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockToken} from "./MockToken.sol";

/// @title ConstantProductPool — a minimal x*y=k AMM used as an origin event source.
/// @notice Every state change emits a `Sync` log carrying both reserves and the origin
///         block timestamp. SUBSECOND's reactive contract reconstructs each pool's price
///         from these logs alone (no cross-chain state reads), which is what lets it decide
///         inside a single ~1s Reactive block.
contract ConstantProductPool {
    MockToken public immutable token0;
    MockToken public immutable token1;

    /// @notice Fee in basis points (30 = 0.30%).
    uint256 public constant FEE_BPS = 30;

    uint256 public reserve0;
    uint256 public reserve1;

    event Swap(address indexed sender, uint256 amountIn, bool zeroForOne, uint256 amountOut, address indexed to);
    /// @dev The log the reactive contract subscribes to. `timestamp` is the ORIGIN chain clock.
    event Sync(uint256 reserve0, uint256 reserve1, uint256 timestamp);
    event Liquidity(address indexed provider, uint256 amount0, uint256 amount1);

    constructor(MockToken token0_, MockToken token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Provision reserves. Tokens must already be transferred to this contract.
    function provision(uint256 amount0, uint256 amount1) external {
        require(amount0 > 0 && amount1 > 0, "pool: zero liquidity");
        reserve0 += amount0;
        reserve1 += amount1;
        emit Liquidity(msg.sender, amount0, amount1);
        emit Sync(reserve0, reserve1, block.timestamp);
    }

    /// @notice Exact-input swap. `zeroForOne` sells token0 for token1.
    function swap(uint256 amountIn, bool zeroForOne, uint256 minOut, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "pool: zero in");
        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        require(rIn > 0 && rOut > 0, "pool: empty");

        uint256 amountInWithFee = amountIn * (10_000 - FEE_BPS);
        amountOut = (amountInWithFee * rOut) / (rIn * 10_000 + amountInWithFee);
        require(amountOut >= minOut, "pool: slippage");
        require(amountOut < rOut, "pool: insufficient liquidity");

        if (zeroForOne) {
            token0.transferFrom(msg.sender, address(this), amountIn);
            token1.transfer(to, amountOut);
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            token1.transferFrom(msg.sender, address(this), amountIn);
            token0.transfer(to, amountOut);
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        emit Swap(msg.sender, amountIn, zeroForOne, amountOut, to);
        emit Sync(reserve0, reserve1, block.timestamp);
    }

    /// @notice Price of token0 denominated in token1, scaled by 1e18.
    function price() external view returns (uint256) {
        require(reserve0 > 0, "pool: empty");
        return (reserve1 * 1e18) / reserve0;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }
}
