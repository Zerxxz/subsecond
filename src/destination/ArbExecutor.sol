// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {ConstantProductPool} from "../origin/ConstantProductPool.sol";
import {MockToken} from "../origin/MockToken.sol";

/// @title ArbExecutor — the destination-side callback contract of SUBSECOND.
/// @notice Receives an authenticated callback from the reactive contract and closes a
///         cross-pool price gap with a two-leg swap. It re-reads reserves at callback time:
///         if the gap has already closed, the arbitrage is reported as MISSED. That single
///         branch is the whole thesis of the track — the reaction only pays when it lands
///         inside the window, which is why ~1s finality (not ~7s) is required.
contract ArbExecutor is AbstractCallback {
    ConstantProductPool public immutable poolA;
    ConstantProductPool public immutable poolB;
    MockToken public immutable token0;
    MockToken public immutable token1;

    uint256 private constant FEE_BPS = 30;
    uint256 private constant FEE_NUM = 10_000 - FEE_BPS; // 9970

    event ArbExecuted(
        uint8 direction,
        uint256 amountIn,
        uint256 profit,
        uint256 gapBpsAtDetection,
        uint256 gapBpsAtExecution,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 fullLoopLatency
    );
    event ArbMissed(
        uint8 direction,
        uint256 gapBpsAtDetection,
        uint256 gapBpsAtExecution,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 fullLoopLatency,
        string reason
    );

    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        ConstantProductPool poolA_,
        ConstantProductPool poolB_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        poolA = poolA_;
        poolB = poolB_;
        token0 = poolA_.token0();
        token1 = poolA_.token1();
        // The executor front-loads token1 and recycles token0 within a single callback.
        token1.approve(address(poolA_), type(uint256).max);
        token1.approve(address(poolB_), type(uint256).max);
        token0.approve(address(poolA_), type(uint256).max);
        token0.approve(address(poolB_), type(uint256).max);
    }

    /// @notice Callback entry point. First arg is the reactive address injected by the proxy.
    /// @param direction_ 0 => token0 cheaper in B (buy B / sell A); 1 => cheaper in A (buy A / sell B).
    /// @param originTimestamp_ Origin-chain timestamp of the Swap that opened the gap.
    /// @param gapBpsAtDetection_ Gap the reactive contract measured when it fired.
    function executeArb(address reactive_, uint8 direction_, uint256 originTimestamp_, uint256 gapBpsAtDetection_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        (ConstantProductPool cheap, ConstantProductPool dear) = direction_ == 0 ? (poolB, poolA) : (poolA, poolB);

        (uint256 c0, uint256 c1) = cheap.getReserves();
        (uint256 d0, uint256 d1) = dear.getReserves();
        uint256 gapNow = _gapBps(c0, c1, d0, d1, direction_);

        // The gap must still clear both legs' fees to be worth closing.
        if (gapNow <= 2 * FEE_BPS) {
            emit ArbMissed(
                direction_,
                gapBpsAtDetection_,
                gapNow,
                originTimestamp_,
                block.timestamp,
                block.timestamp - originTimestamp_,
                "gap closed before callback"
            );
            return;
        }

        uint256 amountIn = _optimalInput(c0, c1, d0, d1);
        // Never size beyond the token1 the executor actually holds.
        uint256 avail = token1.balanceOf(address(this));
        if (amountIn > avail) amountIn = avail;
        uint256 expected = _twoLegOut(amountIn, c0, c1, d0, d1);
        if (amountIn == 0 || expected <= amountIn) {
            emit ArbMissed(
                direction_,
                gapBpsAtDetection_,
                gapNow,
                originTimestamp_,
                block.timestamp,
                block.timestamp - originTimestamp_,
                "no profitable size"
            );
            return;
        }

        uint256 balBefore = token1.balanceOf(address(this));
        // Leg 1: token1 -> token0 in the cheap pool.
        uint256 got0 = cheap.swap(amountIn, false, 0, address(this));
        // Leg 2: token0 -> token1 in the dear pool.
        dear.swap(got0, true, 0, address(this));
        uint256 profit = token1.balanceOf(address(this)) - balBefore;

        emit ArbExecuted(
            direction_,
            amountIn,
            profit,
            gapBpsAtDetection_,
            gapNow,
            originTimestamp_,
            block.timestamp,
            block.timestamp - originTimestamp_
        );
    }

    /// @dev Gap in bps of the dear price over the cheap price for the given direction.
    function _gapBps(uint256 c0, uint256 c1, uint256 d0, uint256 d1, uint8) internal pure returns (uint256) {
        // price = token1 per token0. direction 0: dear=A, cheap=B handled by caller ordering.
        uint256 pCheap = (c1 * 1e18) / c0;
        uint256 pDear = (d1 * 1e18) / d0;
        if (pDear <= pCheap) return 0;
        return ((pDear - pCheap) * 10_000) / pCheap;
    }

    /// @dev Constant-product exact-input quote with the 30 bps fee.
    function _quote(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        if (amountIn == 0 || rIn == 0 || rOut == 0) return 0;
        uint256 inWithFee = amountIn * FEE_NUM;
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    /// @dev token1 out after routing x token1 through cheap (->token0) then dear (->token1).
    function _twoLegOut(uint256 x, uint256 c0, uint256 c1, uint256 d0, uint256 d1) internal pure returns (uint256) {
        uint256 y = _quote(x, c1, c0); // token1 -> token0 in cheap
        return _quote(y, d0, d1); // token0 -> token1 in dear
    }

    /// @dev Ternary search for the profit-maximising token1 input (profit is concave in x).
    function _optimalInput(uint256 c0, uint256 c1, uint256 d0, uint256 d1) internal pure returns (uint256) {
        uint256 lo = 0;
        uint256 hi = c1 / 2; // never drain more than half the cheap pool's token1
        for (uint256 i = 0; i < 48; i++) {
            if (hi - lo < 3) break;
            uint256 m1 = lo + (hi - lo) / 3;
            uint256 m2 = hi - (hi - lo) / 3;
            int256 p1 = int256(_twoLegOut(m1, c0, c1, d0, d1)) - int256(m1);
            int256 p2 = int256(_twoLegOut(m2, c0, c1, d0, d1)) - int256(m2);
            if (p1 < p2) lo = m1;
            else hi = m2;
        }
        uint256 best = (lo + hi) / 2;
        // Guard against a size that is not actually profitable after fees.
        if (_twoLegOut(best, c0, c1, d0, d1) <= best) return 0;
        return best;
    }
}
