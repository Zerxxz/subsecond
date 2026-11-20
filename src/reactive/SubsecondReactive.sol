// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @title SubsecondReactive — the on-chain reflex of SUBSECOND (deployed on Reactive Lasna).
/// @notice Subscribes to the `Sync` logs of two Base Sepolia AMM pools, reconstructs each
///         pool's price from the log payload alone, and the instant a cross-pool gap clears
///         the fee threshold it requests a callback to the ArbExecutor. No off-chain bot,
///         no cross-chain state read: the decision is made inside one ~1s Reactive block.
contract SubsecondReactive is AbstractReactive {
    uint256 public immutable originChainId;
    address public immutable poolA;
    address public immutable poolB;
    address public immutable executor;
    uint256 public immutable destChainId;
    /// @notice Minimum gap (bps) that must clear both legs' fees before firing.
    uint256 public immutable thresholdBps;

    // Reconstructed pool state, fed purely by origin logs.
    uint256 public rA0;
    uint256 public rA1;
    uint256 public rB0;
    uint256 public rB1;
    bool public aReady;
    bool public bReady;

    uint256 public detections;
    uint256 public callbacks;
    uint256 public lastGapBps;
    uint256 public lastOriginTimestamp;
    uint256 public lastReactTimestamp;

    event PriceUpdate(address indexed pool, uint256 reserve0, uint256 reserve1, uint256 originTimestamp);
    event GapDetected(
        uint8 direction, uint256 gapBps, uint256 priceA, uint256 priceB, uint256 originTimestamp, uint256 reactTimestamp
    );
    event CallbackRequested(
        uint8 direction, uint256 gapBps, address executor, uint256 originTimestamp, uint256 reactTimestamp
    );

    constructor(
        uint256 originChainId_,
        address poolA_,
        address poolB_,
        address executor_,
        uint256 destChainId_,
        uint256 thresholdBps_
    ) payable {
        originChainId = originChainId_;
        poolA = poolA_;
        poolB = poolB_;
        executor = executor_;
        destChainId = destChainId_;
        thresholdBps = thresholdBps_;

        uint256 syncTopic = uint256(keccak256("Sync(uint256,uint256,uint256)"));
        SYSTEM.subscribe(originChainId_, poolA_, syncTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, poolB_, syncTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != uint256(keccak256("Sync(uint256,uint256,uint256)"))) return;
        (uint256 reserve0, uint256 reserve1, uint256 originTimestamp) =
            abi.decode(log_.data, (uint256, uint256, uint256));

        if (log_.contractAddress == poolA) {
            rA0 = reserve0;
            rA1 = reserve1;
            aReady = true;
        } else if (log_.contractAddress == poolB) {
            rB0 = reserve0;
            rB1 = reserve1;
            bReady = true;
        } else {
            return;
        }
        emit PriceUpdate(log_.contractAddress, reserve0, reserve1, originTimestamp);

        if (!aReady || !bReady || rA0 == 0 || rB0 == 0) return;

        uint256 priceA = (rA1 * 1e18) / rA0;
        uint256 priceB = (rB1 * 1e18) / rB0;

        uint8 direction;
        uint256 gapBps;
        if (priceA > priceB) {
            direction = 0; // token0 dearer in A -> buy B, sell A
            gapBps = ((priceA - priceB) * 10_000) / priceB;
        } else if (priceB > priceA) {
            direction = 1; // token0 dearer in B -> buy A, sell B
            gapBps = ((priceB - priceA) * 10_000) / priceA;
        } else {
            return;
        }

        if (gapBps < thresholdBps) return;

        detections++;
        lastGapBps = gapBps;
        lastOriginTimestamp = originTimestamp;
        lastReactTimestamp = block.timestamp;
        emit GapDetected(direction, gapBps, priceA, priceB, originTimestamp, block.timestamp);

        bytes memory payload = abi.encodeWithSignature(
            "executeArb(address,uint8,uint256,uint256)",
            address(0), // proxy overwrites this with the reactive contract's address
            direction,
            originTimestamp,
            gapBps
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: executor, gasLimit: 1_000_000, payload: payload
            })
        );
        callbacks++;
        emit CallbackRequested(direction, gapBps, executor, originTimestamp, block.timestamp);
    }

    /// @notice Current reconstructed gap, for the dashboard / tests.
    function currentGap() external view returns (uint8 direction, uint256 gapBps) {
        if (!aReady || !bReady || rA0 == 0 || rB0 == 0) return (0, 0);
        uint256 priceA = (rA1 * 1e18) / rA0;
        uint256 priceB = (rB1 * 1e18) / rB0;
        if (priceA > priceB) return (0, ((priceA - priceB) * 10_000) / priceB);
        if (priceB > priceA) return (1, ((priceB - priceA) * 10_000) / priceA);
        return (0, 0);
    }
}
