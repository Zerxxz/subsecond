// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockToken} from "../src/origin/MockToken.sol";
import {ConstantProductPool} from "../src/origin/ConstantProductPool.sol";
import {ArbExecutor} from "../src/destination/ArbExecutor.sol";
import {SubsecondReactive} from "../src/reactive/SubsecondReactive.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";

contract SubsecondTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN = 84532; // Base Sepolia
    uint256 constant SYNC_TOPIC = uint256(keccak256("Sync(uint256,uint256,uint256)"));

    MockToken token0;
    MockToken token1;
    ConstantProductPool poolA;
    ConstantProductPool poolB;
    ArbExecutor executor;
    SubsecondReactive reactive;
    address payable proxy = payable(makeAddr("callbackProxy"));

    event ArbExecuted(uint8, uint256, uint256, uint256, uint256, uint256, uint256, uint256);
    event ArbMissed(uint8, uint256, uint256, uint256, uint256, uint256, string);

    function setUp() public {
        // The Reactive system contract is a predeploy on Lasna; etch a minimal runtime so
        // subscribe()/requestCallback() high-level calls pass the extcodesize check in tests.
        vm.etch(SYSTEM, hex"00");
        token0 = new MockToken("Subsecond WETH", "sWETH", 18);
        token1 = new MockToken("Subsecond USDC", "sUSDC", 18);
        poolA = new ConstantProductPool(token0, token1);
        poolB = new ConstantProductPool(token0, token1);

        _fundPool(poolA, 100e18, 200_000e18); // price 2000
        _fundPool(poolB, 100e18, 200_000e18);

        // Executor first; predict the reactive address so the immutable callbackSender binds.
        uint256 nonce = vm.getNonce(address(this));
        address predictedReactive = vm.computeCreateAddress(address(this), nonce + 1);
        executor = new ArbExecutor(IPayable(proxy), predictedReactive, poolA, poolB);
        reactive = new SubsecondReactive(ORIGIN, address(poolA), address(poolB), address(executor), ORIGIN, 80);
        assertEq(address(reactive), predictedReactive, "reactive address prediction");

        token1.mint(address(executor), 200_000e18); // arb input asset

        _feedSync(poolA);
        _feedSync(poolB);
    }

    function _fundPool(ConstantProductPool p, uint256 a0, uint256 a1) internal {
        token0.mint(address(this), a0);
        token1.mint(address(this), a1);
        token0.transfer(address(p), a0);
        token1.transfer(address(p), a1);
        p.provision(a0, a1);
    }

    function _syncLog(ConstantProductPool p) internal view returns (IReactive.LogRecord memory) {
        (uint256 r0, uint256 r1) = p.getReserves();
        return IReactive.LogRecord({
            chainId: ORIGIN,
            contractAddress: address(p),
            topic0: SYNC_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(r0, r1, block.timestamp),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _feedSync(ConstantProductPool p) internal {
        IReactive.LogRecord memory log = _syncLog(p); // external getReserves() must not eat the prank
        vm.prank(SYSTEM);
        reactive.react(log);
    }

    function _shockA() internal {
        token1.mint(address(this), 20_000e18);
        token1.approve(address(poolA), type(uint256).max);
        poolA.swap(20_000e18, false, 0, address(this)); // token1 -> token0, raises A price
    }

    /// @notice A shock swap in pool A opens a gap; the reactive detects it and fires.
    function test_ReactiveDetectsGapAndFires() public {
        _shockA();
        uint256 before = reactive.callbacks();
        _feedSync(poolA);

        (uint8 dir, uint256 gap) = reactive.currentGap();
        assertEq(dir, 0, "direction 0: token0 dearer in A (buy B / sell A)");
        assertGt(gap, 80, "gap above threshold");
        assertEq(reactive.callbacks(), before + 1, "callback requested");
        assertGt(reactive.lastGapBps(), 80);
    }

    /// @notice Full loop: shock -> react -> (simulated callback delivery) -> profitable arb.
    /// @dev Timestamps are literals: with via_ir the optimizer reloads a local copy of
    ///      block.timestamp after vm.warp, so a captured variable would drift.
    function test_FullLoopProfitableArb() public {
        vm.warp(1000);
        _shockA(); // origin Sync timestamp = 1000
        _feedSync(poolA); // reactive detects + requests callback
        (uint8 dir, uint256 gap) = reactive.currentGap();
        assertGt(gap, 80);

        vm.warp(1003); // ~3s Reactive hop, callback lands at 1003
        uint256 balBefore = token1.balanceOf(address(executor));
        vm.recordLogs();
        vm.prank(proxy);
        executor.executeArb(address(reactive), dir, 1000, gap);

        uint256 profit = token1.balanceOf(address(executor)) - balBefore;
        assertGt(profit, 0, "arb realized a profit");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ArbExecuted.selector) {
                (, uint256 amtIn, uint256 p,,, uint256 oTs, uint256 cTs, uint256 lat) =
                    abi.decode(logs[i].data, (uint8, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                assertTrue(amtIn > 0);
                assertEq(p, profit, "event profit matches balance delta");
                assertEq(oTs, 1000, "origin timestamp preserved");
                assertEq(cTs, 1003, "callback timestamp");
                assertEq(lat, 3, "full-loop latency = callback - origin");
                found = true;
            }
        }
        assertTrue(found, "ArbExecuted emitted");
    }

    /// @notice Once the gap is closed, a late callback is reported MISSED (the latency race).
    function test_LateCallbackMisses() public {
        vm.warp(2000);
        _shockA();
        _feedSync(poolA);
        (uint8 dir, uint256 gap) = reactive.currentGap();

        vm.warp(2001); // fast callback closes the gap
        vm.prank(proxy);
        executor.executeArb(address(reactive), dir, 2000, gap);
        uint256 balAfterFirst = token1.balanceOf(address(executor));

        vm.warp(2007); // legacy ~7s reaction arrives after the window
        vm.recordLogs();
        vm.prank(proxy);
        executor.executeArb(address(reactive), dir, 2000, gap);
        assertEq(token1.balanceOf(address(executor)), balAfterFirst, "late callback earns nothing");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool missed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ArbMissed.selector) missed = true;
        }
        assertTrue(missed, "ArbMissed emitted for the late callback");
    }

    /// @notice Unauthorized callers cannot trigger the executor.
    function test_RevertWhen_NotProxy() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        executor.executeArb(address(reactive), 0, block.timestamp, 200);
    }

    /// @notice A forged reactive sender is rejected even via the proxy.
    function test_RevertWhen_WrongReactiveSender() public {
        vm.prank(proxy);
        vm.expectRevert();
        executor.executeArb(makeAddr("fakeReactive"), 0, block.timestamp, 200);
    }

    /// @notice react() rejects anyone but the system contract.
    function test_RevertWhen_ReactNotSystem() public {
        IReactive.LogRecord memory log = _syncLog(poolA);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        reactive.react(log);
    }
}
