// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {SubsecondReactive} from "../src/reactive/SubsecondReactive.sol";

/// @notice Deploys the reactive contract on Reactive Lasna, funded with lREACT so it can pay
///         for react() execution. Origin and destination are both Base Sepolia, so the
///         callback chainId equals the origin chainId read from deployments/origin.json.
contract DeployReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address predicted = vm.envAddress("PREDICTED_REACTIVE");
        uint256 threshold = vm.envOr("THRESHOLD_BPS", uint256(80));
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(0.5 ether));

        string memory oj = vm.readFile("deployments/origin.json");
        address executor = vm.parseJsonAddress(oj, ".executor");
        address poolA = vm.parseJsonAddress(oj, ".poolA");
        address poolB = vm.parseJsonAddress(oj, ".poolB");
        uint256 originChainId = vm.parseJsonUint(oj, ".chainId");

        vm.startBroadcast(pk);
        SubsecondReactive reactive =
            new SubsecondReactive{value: fund}(originChainId, poolA, poolB, executor, originChainId, threshold);
        vm.stopBroadcast();

        require(address(reactive) == predicted, "reactive address != predicted (check Lasna nonce)");

        string memory j = vm.serializeAddress("lasna", "reactive", address(reactive));
        j = vm.serializeAddress("lasna", "executor", executor);
        j = vm.serializeAddress("lasna", "poolA", poolA);
        j = vm.serializeAddress("lasna", "poolB", poolB);
        j = vm.serializeUint("lasna", "originChainId", originChainId);
        j = vm.serializeUint("lasna", "destChainId", originChainId);
        j = vm.serializeUint("lasna", "thresholdBps", threshold);
        j = vm.serializeUint("lasna", "chainId", block.chainid);
        vm.writeJson(j, "deployments/lasna.json");
    }
}
